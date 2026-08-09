"""Layer-3 residual offset: delaying the AirPlay leg to meet the local one.

Layers 1 and 2 (broadcaster delay 0, plus the Swift PLL that slaves the local
device clock to OwnTone's fifo write rate) leave both legs departing OwnTone
together and never drifting apart. What is left is the local leg's own
pipeline latency `L_local`, and since the local leg cannot be advanced the
AirPlay leg is delayed by the same amount instead.

The properties that matter here are the ones that make that safe to ship:

  * the SIGN is the one OwnTone's source implements (positive = delay),
  * the offset is written BEFORE the enable, because OwnTone latches it when
    it builds an output session and will not change a live one,
  * it is clamped to the range OwnTone accepts, so a tuning knob can never
    turn into an opaque HTTP 400,
  * and because OwnTone PERSISTS it in `speakers.offset_ms`, every path out
    (disable, leaving whole-home mode, shutdown) zeroes it again.
"""

from __future__ import annotations

import json
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import Any, ClassVar

import pytest

from syncast_sidecar import owntone_backend
from syncast_sidecar.device_manager import (
    AIRPLAY_SYNC_OFFSET_DEFAULT_MS,
    OFFSET_SOURCE_DEFAULT,
    OFFSET_SOURCE_MEASURED,
    DeviceManager,
)
from syncast_sidecar.owntone_backend import (
    OWNTONE_OFFSET_MAX_MS,
    OWNTONE_OFFSET_MIN_MS,
    OWNTONE_OUTPUT_BUFFER_DURATION_MS,
    OwnToneBackend,
    clamp_output_offset_ms,
)

AIRPLAY_OUTPUT_ID = "2933476098287"
FIFO_OUTPUT_ID = "100"


# --------------------------------------------------------------------------
# REST client
# --------------------------------------------------------------------------


class _CapturingHandler(BaseHTTPRequestHandler):
    """Records the PUT path + decoded body so tests can assert the wire form."""

    puts: ClassVar[list[tuple[str, Any]]] = []

    def do_PUT(self) -> None:  # BaseHTTPRequestHandler API name
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length)
        type(self).puts.append((self.path, json.loads(raw) if raw else None))
        self.send_response(204)
        self.end_headers()

    def log_message(self, *_args: object) -> None:
        pass


@pytest.fixture()
def rest_server():
    _CapturingHandler.puts = []
    server = HTTPServer(("127.0.0.1", 0), _CapturingHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield server
    finally:
        server.shutdown()
        server.server_close()


def test_offset_goes_to_the_documented_endpoint_as_a_real_int(
    rest_server, tmp_path,
) -> None:
    """`PUT /api/outputs/{id}` with `{"offset_ms": N}`.

    OwnTone's handler gates on `json_type_int` (httpd_jsonapi.c:1753), so a
    float would be silently ignored — the call would look like it worked and
    the offset would never be applied.
    """
    backend = OwnToneBackend(
        state_dir=tmp_path, rest_port=rest_server.server_address[1],
    )

    applied = backend.set_output_offset_ms(AIRPLAY_OUTPUT_ID, 132)

    assert applied == 132
    path, body = _CapturingHandler.puts[-1]
    assert path == f"/api/outputs/{AIRPLAY_OUTPUT_ID}"
    assert body == {"offset_ms": 132}
    assert isinstance(body["offset_ms"], int)
    assert not isinstance(body["offset_ms"], bool)


def test_offset_is_clamped_to_the_range_owntone_accepts(
    rest_server, tmp_path,
) -> None:
    """player.c:2930 rejects anything outside ±2000 with a bare HTTP 400."""
    backend = OwnToneBackend(
        state_dir=tmp_path, rest_port=rest_server.server_address[1],
    )

    assert backend.set_output_offset_ms(AIRPLAY_OUTPUT_ID, 9_000) == (
        OWNTONE_OFFSET_MAX_MS
    )
    assert backend.set_output_offset_ms(AIRPLAY_OUTPUT_ID, -9_000) == (
        OWNTONE_OFFSET_MIN_MS
    )
    for _path, body in _CapturingHandler.puts:
        assert OWNTONE_OFFSET_MIN_MS <= body["offset_ms"] <= OWNTONE_OFFSET_MAX_MS


def test_the_negative_floor_stays_clear_of_the_fifo_wraparound() -> None:
    """`outputs/fifo.c:263`'s negative guard is dead code.

    It compares `delay_ms + device->offset_ms < 0` with `delay_ms` a uint64_t,
    so C promotes the signed offset and the comparison can never be true. An
    offset more negative than the output buffer duration wraps to ~1.8e19 ms
    of delay and the local leg goes silent forever, logging nothing. Our floor
    must sit strictly inside that.
    """
    assert OWNTONE_OFFSET_MIN_MS > -OWNTONE_OUTPUT_BUFFER_DURATION_MS
    assert clamp_output_offset_ms(-10_000) > -OWNTONE_OUTPUT_BUFFER_DURATION_MS


# --------------------------------------------------------------------------
# Device manager wiring
# --------------------------------------------------------------------------


class _FakeOwnTone:
    """Records the ORDER of REST calls — that is the property under test."""

    def __init__(self) -> None:
        self.calls: list[tuple[str, str, Any]] = []
        self.outputs: list[dict[str, Any]] = [
            {"id": FIFO_OUTPUT_ID, "name": "SyncCast Local Bridge",
             "type": "fifo", "selected": True, "offset_ms": 0},
            {"id": AIRPLAY_OUTPUT_ID, "name": "Xiaomi Sound",
             "type": "airplay", "selected": True, "offset_ms": 0,
             "needs_auth_key": False},
        ]

    def list_outputs(self) -> list[dict[str, Any]]:
        return self.outputs

    def set_output_offset_ms(self, output_id: str, offset_ms: int) -> int:
        applied = clamp_output_offset_ms(offset_ms)
        self.calls.append(("offset", output_id, applied))
        return applied

    def set_output_enabled(self, output_id: str, enabled: bool) -> None:
        self.calls.append(("enable", output_id, enabled))
        for o in self.outputs:
            if o["id"] == output_id:
                o["selected"] = enabled

    def set_output_volume(self, output_id: str, volume: float) -> None:
        self.calls.append(("volume", output_id, volume))

    def kinds(self) -> list[str]:
        return [kind for kind, _id, _v in self.calls]


def _manager(mode: str = "whole_home") -> tuple[DeviceManager, _FakeOwnTone]:
    manager = DeviceManager(notify=lambda _m, _p: None)
    fake = _FakeOwnTone()
    manager._owntone = fake
    manager._mode = mode
    return manager, fake


def test_the_default_offset_is_the_documented_l_local_estimate() -> None:
    manager, _fake = _manager()
    state = manager.airplay_offset_state()
    assert state["offset_ms"] == AIRPLAY_SYNC_OFFSET_DEFAULT_MS
    assert state["source"] == OFFSET_SOURCE_DEFAULT
    # Positive: the AirPlay leg is DELAYED to meet the trailing local leg.
    # A negative default would double the error instead of cancelling it.
    assert state["effective_offset_ms"] > 0


def test_stereo_mode_carries_no_offset() -> None:
    """Stereo has no fifo→bridge chain, so there is no `L_local` to cancel.

    Delaying AirPlay there would skew an otherwise-correct stream against
    nothing at all.
    """
    manager, _fake = _manager(mode="stereo")
    assert manager._target_airplay_offset_ms() == 0
    assert manager.airplay_offset_state()["offset_ms"] == (
        AIRPLAY_SYNC_OFFSET_DEFAULT_MS
    )


@pytest.mark.asyncio
async def test_the_offset_is_written_before_the_enable() -> None:
    """Order is the whole ballgame.

    `outputs/airplay.c:1598` copies `device->offset_ms` into the session when
    `session_make` runs, and `player.c:2937-2944` refuses to touch a session
    that is already playing. An offset written after the enable therefore
    takes effect only on the NEXT enable — the receiver plays this session
    uncorrected while the REST call reports success.
    """
    manager, fake = _manager()

    await manager._apply_output_state(
        "dev-1",
        _device("dev-1", "Xiaomi Sound"),
        fake.outputs[1],
        should_enable=True,
    )

    kinds = fake.kinds()
    assert kinds.index("offset") < kinds.index("enable")
    assert ("offset", AIRPLAY_OUTPUT_ID, AIRPLAY_SYNC_OFFSET_DEFAULT_MS) in fake.calls


@pytest.mark.asyncio
async def test_disabling_an_output_retires_its_offset() -> None:
    """OwnTone persists `speakers.offset_ms`, so it has to be zeroed.

    A receiver the user switched off must not keep carrying a correction for
    a local leg it is no longer playing alongside.
    """
    manager, fake = _manager()

    await manager._apply_output_state(
        "dev-1",
        _device("dev-1", "Xiaomi Sound"),
        fake.outputs[1],
        should_enable=False,
    )

    assert ("offset", AIRPLAY_OUTPUT_ID, 0) in fake.calls
    assert AIRPLAY_OUTPUT_ID not in manager.airplay_offset_state()["applied"]


@pytest.mark.asyncio
async def test_leaving_whole_home_mode_zeroes_every_offset_we_wrote() -> None:
    manager, fake = _manager()
    await manager._apply_output_state(
        "dev-1", _device("dev-1", "Xiaomi Sound"), fake.outputs[1], True,
    )
    assert manager.airplay_offset_state()["applied"]

    await manager.set_mode("stereo")

    assert fake.calls[-1] == ("offset", AIRPLAY_OUTPUT_ID, 0)
    assert manager.airplay_offset_state()["applied"] == {}


@pytest.mark.asyncio
async def test_setting_a_new_offset_relatches_live_outputs() -> None:
    """A live session keeps its old offset until it is rebuilt.

    Without the disable/enable cycle the user would move the knob, see the
    call succeed, and hear nothing change — the classic "it did nothing"
    report.
    """
    manager, fake = _manager()

    result = await manager.set_airplay_offset_ms(
        200, source=OFFSET_SOURCE_MEASURED,
    )

    assert result["offset_ms"] == 200
    assert result["source"] == OFFSET_SOURCE_MEASURED
    assert result["relatched"] == [AIRPLAY_OUTPUT_ID]
    # offset first, then a full stop/start so the new value is latched.
    assert fake.calls == [
        ("offset", AIRPLAY_OUTPUT_ID, 200),
        ("enable", AIRPLAY_OUTPUT_ID, False),
        ("enable", AIRPLAY_OUTPUT_ID, True),
    ]


@pytest.mark.asyncio
async def test_the_local_fifo_output_is_never_moved_by_this_knob() -> None:
    """The fifo output IS the local leg. Moving it would chase our own tail.

    It is also the output where a large negative value would trip the
    unsigned-wraparound bug in fifo.c and silence the local leg outright.
    """
    manager, fake = _manager()

    await manager.set_airplay_offset_ms(200)

    assert FIFO_OUTPUT_ID not in [output_id for _k, output_id, _v in fake.calls]


@pytest.mark.asyncio
async def test_re_applying_the_same_offset_is_idempotent() -> None:
    manager, fake = _manager()

    first = await manager.set_airplay_offset_ms(150, relatch=False)
    second = await manager.set_airplay_offset_ms(150, relatch=False)

    assert first["offset_ms"] == second["offset_ms"] == 150
    assert fake.calls == [
        ("offset", AIRPLAY_OUTPUT_ID, 150),
        ("offset", AIRPLAY_OUTPUT_ID, 150),
    ]


@pytest.mark.asyncio
async def test_zero_retires_the_correction_completely() -> None:
    manager, _fake = _manager()
    await manager.set_airplay_offset_ms(150, relatch=False)

    await manager.set_airplay_offset_ms(0, relatch=False)

    assert manager.airplay_offset_state()["offset_ms"] == 0
    assert manager.airplay_offset_state()["applied"] == {}


@pytest.mark.asyncio
async def test_a_rest_failure_does_not_block_the_enable() -> None:
    """A receiver a few ms out of alignment beats a receiver that never plays."""
    manager, fake = _manager()

    def boom(_output_id: str, _offset_ms: int) -> int:
        raise owntone_backend.OwnToneError("offset rejected", code=400)

    fake.set_output_offset_ms = boom  # type: ignore[method-assign]

    await manager._apply_output_state(
        "dev-1", _device("dev-1", "Xiaomi Sound"), fake.outputs[1], True,
    )

    assert ("enable", AIRPLAY_OUTPUT_ID, True) in fake.calls


# --------------------------------------------------------------------------
# What a LIVE session is carrying, as opposed to what we wrote
# --------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_a_fresh_enable_records_what_the_session_latched() -> None:
    """An off→on transition builds the session that reads our offset."""
    manager, fake = _manager()
    fake.outputs[1]["selected"] = False

    await manager._apply_output_state(
        "dev-1", _device("dev-1", "Xiaomi Sound"), fake.outputs[1], True,
    )

    assert manager.airplay_offset_state()["latched"] == {
        AIRPLAY_OUTPUT_ID: AIRPLAY_SYNC_OFFSET_DEFAULT_MS
    }


@pytest.mark.asyncio
async def test_an_already_selected_output_is_never_reported_as_latched() -> None:
    """The case that silently misaligned a receiver for a whole session.

    A receiver that was already playing when whole-home started keeps the
    offset ITS session latched — OwnTone will not change a live one, and
    enabling an already-selected output is a no-op inside OwnTone. Reporting
    it as latched let the router's deadband suppress the one push that would
    have re-latched it.
    """
    manager, fake = _manager()
    assert fake.outputs[1]["selected"] is True

    await manager._apply_output_state(
        "dev-1", _device("dev-1", "Xiaomi Sound"), fake.outputs[1], True,
    )

    state = manager.airplay_offset_state()
    # We DID write the row — the value is right for the next session…
    assert state["applied"] == {AIRPLAY_OUTPUT_ID: AIRPLAY_SYNC_OFFSET_DEFAULT_MS}
    # …but nothing may be claimed about the session playing right now.
    assert state["latched"] == {}


@pytest.mark.asyncio
async def test_re_sending_the_offset_already_in_force_costs_no_dropout() -> None:
    """Idempotent in EFFECT, not only in value.

    A relatch is an audible dropout on every receiver. A retried RPC (the
    reply was lost after the sidecar already applied it) or a UI refresh
    re-sends the identical value, and that must not cycle anything.
    """
    manager, fake = _manager()

    first = await manager.set_airplay_offset_ms(200, source=OFFSET_SOURCE_MEASURED)
    fake.calls.clear()
    second = await manager.set_airplay_offset_ms(200, source=OFFSET_SOURCE_MEASURED)

    assert first["relatched"] == [AIRPLAY_OUTPUT_ID]
    assert second["relatched"] == []
    assert second["unchanged"] == [AIRPLAY_OUTPUT_ID]
    # The row is still rewritten (cheap, and keeps the database authoritative)
    # but the receiver is not stopped and restarted.
    assert fake.calls == [("offset", AIRPLAY_OUTPUT_ID, 200)]


@pytest.mark.asyncio
async def test_a_genuinely_new_value_still_relatches() -> None:
    manager, fake = _manager()

    await manager.set_airplay_offset_ms(200, source=OFFSET_SOURCE_MEASURED)
    fake.calls.clear()
    result = await manager.set_airplay_offset_ms(140, source=OFFSET_SOURCE_MEASURED)

    assert result["relatched"] == [AIRPLAY_OUTPUT_ID]
    assert fake.calls == [
        ("offset", AIRPLAY_OUTPUT_ID, 140),
        ("enable", AIRPLAY_OUTPUT_ID, False),
        ("enable", AIRPLAY_OUTPUT_ID, True),
    ]


@pytest.mark.asyncio
async def test_a_failed_write_is_still_visited_by_the_rollback() -> None:
    """A failure is not evidence the row is clean — it is evidence we do not
    know what is in it.

    Recording only successes meant a transient REST timeout during the enable
    left OwnTone's persisted `speakers.offset_ms` untouched AND unswept, so a
    value from an earlier session outlived every rollback path.
    """
    manager, fake = _manager()
    failing = True

    def flaky(output_id: str, offset_ms: int) -> int:
        if failing:
            raise owntone_backend.OwnToneError("offset rejected", code=400)
        return _FakeOwnTone.set_output_offset_ms(fake, output_id, offset_ms)

    fake.set_output_offset_ms = flaky  # type: ignore[method-assign]
    await manager._apply_output_state(
        "dev-1", _device("dev-1", "Xiaomi Sound"), fake.outputs[1], True,
    )
    state = manager.airplay_offset_state()
    assert state["applied"] == {}
    assert state["write_failures"] == [AIRPLAY_OUTPUT_ID]

    failing = False
    await manager.set_mode("stereo")

    assert ("offset", AIRPLAY_OUTPUT_ID, 0) in fake.calls
    assert manager.airplay_offset_state()["write_failures"] == []


def _device(dev_id: str, name: str):
    from syncast_sidecar.device_manager import Device

    return Device(
        id=dev_id,
        transport="airplay2",
        host="192.0.2.20",
        port=7000,
        name=name,
        state="added",
    )
