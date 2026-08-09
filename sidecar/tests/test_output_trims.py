"""Per-output user delay trim: listening-position compensation.

This is the knob the human turns, and it is deliberately NOT the same thing as
the Layer-3 offset next door in `test_airplay_offset.py`. That one is a system
correction cancelling the local leg's pipeline latency; this one says "the
kitchen speaker is three metres further away than the desk one". The
properties that make the pair safe to ship together:

  * they ADD — a trim never overwrites the system correction, and the SUM is
    what gets clamped against OwnTone's accepted range,
  * an output nobody trimmed carries exactly the system correction, so
    installing the feature changes nothing for a user who never touches it,
  * the map is a FULL REPLACEMENT, so no forgotten key can leave a trim
    behind,
  * and re-sending the same map cycles nothing, because every cycle is an
    audible dropout on that receiver.
"""

from __future__ import annotations

from typing import Any, ClassVar

import pytest

from syncast_sidecar.device_manager import (
    AIRPLAY_SYNC_OFFSET_DEFAULT_MS,
    OUTPUT_TRIM_DEFAULT_MS,
    OUTPUT_TRIM_LIMIT_MS,
    Device,
    DeviceManager,
)
from syncast_sidecar.owntone_backend import (
    OWNTONE_OFFSET_MAX_MS,
    clamp_output_offset_ms,
)

# OwnTone derives an AirPlay output id from the receiver's Bonjour `deviceid`
# read as hex, so these two pairs must stay consistent with each other.
XIAOMI_DEVICE_ID_HEX = "02AB00CD00EF"
XIAOMI_OUTPUT_ID = "2933476098287"
KITCHEN_DEVICE_ID_HEX = "02AB00CD00F0"
KITCHEN_OUTPUT_ID = "2933476098288"
FIFO_OUTPUT_ID = "100"


class _FakeOwnTone:
    """Records REST calls in order — sequencing is half of what is asserted."""

    calls: ClassVar[list[tuple[str, str, Any]]]

    def __init__(self) -> None:
        self.calls = []
        self.outputs: list[dict[str, Any]] = [
            {"id": FIFO_OUTPUT_ID, "name": "SyncCast Local Bridge",
             "type": "fifo", "selected": True, "offset_ms": 0},
            {"id": XIAOMI_OUTPUT_ID, "name": "Xiaomi Sound",
             "type": "airplay", "selected": True, "offset_ms": 0,
             "needs_auth_key": False},
            {"id": KITCHEN_OUTPUT_ID, "name": "Kitchen",
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


def _device(dev_id: str, name: str, airplay_device_id: str) -> Device:
    return Device(
        id=dev_id,
        transport="airplay2",
        host="192.0.2.20",
        port=7000,
        name=name,
        state="added",
        airplay_device_id=airplay_device_id,
    )


def _manager(mode: str = "whole_home") -> tuple[DeviceManager, _FakeOwnTone]:
    manager = DeviceManager(notify=lambda _m, _p: None)
    fake = _FakeOwnTone()
    manager._owntone = fake
    manager._mode = mode
    manager._devices = {
        "dev-xiaomi": _device("dev-xiaomi", "Xiaomi Sound", XIAOMI_DEVICE_ID_HEX),
        "dev-kitchen": _device("dev-kitchen", "Kitchen", KITCHEN_DEVICE_ID_HEX),
    }
    # Both receivers are already playing at the system correction, which is
    # the realistic starting point: the router pushed it when whole-home
    # began. Without this the first trim would relatch on "unknown" rather
    # than on "changed", and the no-gratuitous-dropout assertions below would
    # be testing the wrong thing.
    manager._latched_output_offsets = {
        XIAOMI_OUTPUT_ID: AIRPLAY_SYNC_OFFSET_DEFAULT_MS,
        KITCHEN_OUTPUT_ID: AIRPLAY_SYNC_OFFSET_DEFAULT_MS,
    }
    return manager, fake


# --------------------------------------------------------------------------
# Composition with the Layer-3 system correction
# --------------------------------------------------------------------------


def test_untrimmed_output_carries_exactly_the_system_correction() -> None:
    """Installing the feature must be invisible to a user who never uses it."""
    manager, _fake = _manager()
    assert manager._trim_ms_for_output(XIAOMI_OUTPUT_ID) == OUTPUT_TRIM_DEFAULT_MS
    assert manager._target_airplay_offset_ms(XIAOMI_OUTPUT_ID) == (
        AIRPLAY_SYNC_OFFSET_DEFAULT_MS
    )
    # And the no-argument form is unchanged from before the feature existed.
    assert manager._target_airplay_offset_ms() == AIRPLAY_SYNC_OFFSET_DEFAULT_MS


def test_trim_adds_to_the_system_correction_it_does_not_replace_it() -> None:
    manager, _fake = _manager()
    manager._output_trim_ms = {"dev-xiaomi": 7}
    assert manager._target_airplay_offset_ms(XIAOMI_OUTPUT_ID) == (
        AIRPLAY_SYNC_OFFSET_DEFAULT_MS + 7
    )
    # The untrimmed neighbour is untouched: the trim is per-output.
    assert manager._target_airplay_offset_ms(KITCHEN_OUTPUT_ID) == (
        AIRPLAY_SYNC_OFFSET_DEFAULT_MS
    )


def test_stereo_mode_carries_neither_correction_nor_trim() -> None:
    manager, _fake = _manager(mode="stereo")
    manager._output_trim_ms = {"dev-xiaomi": 40}
    assert manager._target_airplay_offset_ms(XIAOMI_OUTPUT_ID) == 0
    assert manager._target_airplay_offset_ms() == 0


def test_the_composite_is_clamped_not_the_trim_alone() -> None:
    """OwnTone rejects anything outside its range with an opaque HTTP 400."""
    manager, _fake = _manager()
    manager._airplay_offset_ms = OWNTONE_OFFSET_MAX_MS
    manager._output_trim_ms = {"dev-xiaomi": OUTPUT_TRIM_LIMIT_MS}
    assert manager._target_airplay_offset_ms(XIAOMI_OUTPUT_ID) == OWNTONE_OFFSET_MAX_MS


def test_unknown_output_gets_the_default_trim() -> None:
    """The fifo output — and anything discovered outside SyncCast — has no
    device behind it, and must not inherit a neighbour's trim."""
    manager, _fake = _manager()
    manager._output_trim_ms = {"dev-xiaomi": 25}
    assert manager._trim_ms_for_output(FIFO_OUTPUT_ID) == OUTPUT_TRIM_DEFAULT_MS


# --------------------------------------------------------------------------
# Applying trims over the wire
# --------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_setting_a_trim_writes_the_composite_and_relatches() -> None:
    manager, fake = _manager()
    state = await manager.set_output_trims_ms({"dev-xiaomi": 12})

    assert ("offset", XIAOMI_OUTPUT_ID, AIRPLAY_SYNC_OFFSET_DEFAULT_MS + 12) in fake.calls
    # Relatch = disable then enable, because OwnTone latches the offset when
    # it builds the session and refuses to touch a live one.
    assert ("enable", XIAOMI_OUTPUT_ID, False) in fake.calls
    assert ("enable", XIAOMI_OUTPUT_ID, True) in fake.calls
    assert state["relatched"] == [XIAOMI_OUTPUT_ID]
    # The untouched receiver keeps playing: its composite did not change.
    assert KITCHEN_OUTPUT_ID in state["unchanged"]
    assert ("enable", KITCHEN_OUTPUT_ID, False) not in fake.calls


@pytest.mark.asyncio
async def test_the_offset_is_written_before_the_enable() -> None:
    """A session reads the offset at construction, so ordering is the feature."""
    manager, fake = _manager()
    await manager.set_output_trims_ms({"dev-xiaomi": 12})
    kinds = [(k, oid) for k, oid, _v in fake.calls if oid == XIAOMI_OUTPUT_ID]
    assert kinds[0][0] == "offset"
    assert kinds[1][0] == "enable"


@pytest.mark.asyncio
async def test_resending_the_same_map_cycles_nothing() -> None:
    """Idempotence is audible: every cycle is a dropout on that receiver."""
    manager, fake = _manager()
    await manager.set_output_trims_ms({"dev-xiaomi": 12})
    fake.calls.clear()
    state = await manager.set_output_trims_ms({"dev-xiaomi": 12})
    assert state["relatched"] == []
    assert not [c for c in fake.calls if c[0] == "enable"]


@pytest.mark.asyncio
async def test_an_all_zero_map_relatches_nobody() -> None:
    """The "reset all" path on a system that was already clean must be free."""
    manager, fake = _manager()
    state = await manager.set_output_trims_ms({"dev-xiaomi": 0, "dev-kitchen": 0})
    assert state["relatched"] == []
    assert not [c for c in fake.calls if c[0] == "enable"]
    assert state["output_trims_ms"] == {}


@pytest.mark.asyncio
async def test_the_map_is_a_full_replacement_so_omitted_ids_reset() -> None:
    manager, fake = _manager()
    await manager.set_output_trims_ms({"dev-xiaomi": 30, "dev-kitchen": 9})
    fake.calls.clear()

    state = await manager.set_output_trims_ms({"dev-kitchen": 9})
    assert state["output_trims_ms"] == {"dev-kitchen": 9}
    # Xiaomi goes back to the bare system correction, and pays one relatch for
    # it; Kitchen is unchanged and is left alone.
    assert ("offset", XIAOMI_OUTPUT_ID, AIRPLAY_SYNC_OFFSET_DEFAULT_MS) in fake.calls
    assert state["relatched"] == [XIAOMI_OUTPUT_ID]


@pytest.mark.asyncio
async def test_values_are_clamped_to_the_user_range_on_the_way_in() -> None:
    manager, _fake = _manager()
    state = await manager.set_output_trims_ms({"dev-xiaomi": 10_000})
    assert state["output_trims_ms"] == {"dev-xiaomi": OUTPUT_TRIM_LIMIT_MS}


@pytest.mark.asyncio
async def test_relatch_false_writes_the_value_without_a_dropout() -> None:
    """Used when the caller is about to enable the outputs anyway."""
    manager, fake = _manager()
    state = await manager.set_output_trims_ms({"dev-xiaomi": 12}, relatch=False)
    assert ("offset", XIAOMI_OUTPUT_ID, AIRPLAY_SYNC_OFFSET_DEFAULT_MS + 12) in fake.calls
    assert not [c for c in fake.calls if c[0] == "enable"]
    assert state["relatched"] == []


# --------------------------------------------------------------------------
# Cleanliness: no pollution left in OwnTone's persisted `speakers` table
# --------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_disabling_an_output_zeroes_it_even_when_trimmed() -> None:
    manager, fake = _manager()
    await manager.set_output_trims_ms({"dev-xiaomi": 45})
    fake.calls.clear()

    await manager._apply_output_state(
        "dev-xiaomi", manager._devices["dev-xiaomi"],
        fake.outputs[1], False,
    )
    assert ("offset", XIAOMI_OUTPUT_ID, 0) in fake.calls


@pytest.mark.asyncio
async def test_leaving_whole_home_retires_every_trimmed_offset() -> None:
    """OwnTone PERSISTS `speakers.offset_ms`, so a value computed for one
    session must never be left behind to skew the next one."""
    manager, fake = _manager()
    await manager.set_output_trims_ms({"dev-xiaomi": 45, "dev-kitchen": 12})
    fake.calls.clear()

    await manager.set_mode("stereo")

    assert ("offset", XIAOMI_OUTPUT_ID, 0) in fake.calls
    assert ("offset", KITCHEN_OUTPUT_ID, 0) in fake.calls
    state = manager.airplay_offset_state()
    assert state["applied"] == {}
    assert state["write_failures"] == []
    assert state["latched"] == {}


@pytest.mark.asyncio
async def test_enabling_a_trimmed_output_writes_the_composite_first() -> None:
    manager, fake = _manager()
    manager._output_trim_ms = {"dev-xiaomi": 18}
    fake.outputs[1]["selected"] = False
    fake.calls.clear()

    await manager._apply_output_state(
        "dev-xiaomi", manager._devices["dev-xiaomi"], fake.outputs[1], True,
    )
    ordered = [(k, v) for k, oid, v in fake.calls if oid == XIAOMI_OUTPUT_ID]
    assert ordered[0] == ("offset", AIRPLAY_SYNC_OFFSET_DEFAULT_MS + 18)
    assert ordered[1] == ("enable", True)
    # A genuine off->on transition builds a fresh session, so we know what it
    # latched — and the next push can skip it instead of buying a dropout.
    assert manager._latched_output_offsets[XIAOMI_OUTPUT_ID] == (
        AIRPLAY_SYNC_OFFSET_DEFAULT_MS + 18
    )


# --------------------------------------------------------------------------
# JSON-RPC boundary: `trims_ms` arrives from outside, so it is untrusted
# --------------------------------------------------------------------------


def _control_server() -> Any:
    from pathlib import Path

    from syncast_sidecar.server import ControlServer

    return ControlServer(
        control_socket=Path("/tmp/syncast-test.control.sock"),
        audio_socket=Path("/tmp/syncast-test.audio.sock"),
    )


@pytest.mark.asyncio
async def test_rpc_rejects_non_object_trims() -> None:
    from syncast_sidecar import jsonrpc

    server = _control_server()
    with pytest.raises(jsonrpc.RpcError):
        await server._on_sync_set_output_trims_ms({"trims_ms": [1, 2, 3]})


@pytest.mark.asyncio
@pytest.mark.parametrize("bad", [True, False, "12", None, float("nan"), float("inf")])
async def test_rpc_rejects_non_finite_and_non_numeric_values(bad: Any) -> None:
    """bool is a subclass of int in Python — True must not slip through as 1."""
    from syncast_sidecar import jsonrpc

    server = _control_server()
    with pytest.raises(jsonrpc.RpcError):
        await server._on_sync_set_output_trims_ms({"trims_ms": {"dev-1": bad}})


@pytest.mark.asyncio
async def test_rpc_rejects_non_boolean_relatch() -> None:
    from syncast_sidecar import jsonrpc

    server = _control_server()
    with pytest.raises(jsonrpc.RpcError):
        await server._on_sync_set_output_trims_ms(
            {"trims_ms": {}, "relatch": "yes"},
        )


@pytest.mark.asyncio
async def test_rpc_clamps_and_forwards() -> None:
    server = _control_server()
    server._devices._owntone = None
    state = await server._on_sync_set_output_trims_ms(
        {"trims_ms": {"dev-1": 10_000, "dev-2": -10_000, "dev-3": 0}},
    )
    assert state["output_trims_ms"] == {
        "dev-1": OUTPUT_TRIM_LIMIT_MS,
        "dev-2": -OUTPUT_TRIM_LIMIT_MS,
    }


@pytest.mark.asyncio
async def test_rpc_defaults_to_an_empty_map() -> None:
    """Omitting `trims_ms` entirely means "clear every trim", not "error"."""
    server = _control_server()
    server._devices._owntone = None
    server._devices._output_trim_ms = {"dev-1": 20}
    state = await server._on_sync_set_output_trims_ms({})
    assert state["output_trims_ms"] == {}


# --------------------------------------------------------------------------
# The bound is on the NORMALISED span, not on the signed user range
# --------------------------------------------------------------------------

# `DeviceDelayTrim.rangeMs` on the Swift side is -200...+200 ms of SIGNED
# intent. `DelayTrimNormalizer` slides the set up until the earliest speaker
# sits at 0, so the widest legal pair (-200 on one speaker, +200 on another)
# arrives here as 400 on ONE output. Mirrored as a literal on purpose: if the
# Swift range ever widens, this number has to move with it, and a test that
# derived it from OUTPUT_TRIM_LIMIT_MS itself could never catch that.
WIDEST_NORMALISED_TRIM_MS = 400


def test_the_limit_covers_the_widest_normalised_trim() -> None:
    assert OUTPUT_TRIM_LIMIT_MS >= WIDEST_NORMALISED_TRIM_MS


@pytest.mark.asyncio
async def test_widest_normalised_trim_survives_the_round_trip_untruncated() -> None:
    """The regression: a 200 ms bound silently truncated a legal 400 ms trim.

    The local leg honours the full span (its ring is sized for it), so a
    clamp here moves that receiver 200 ms EARLIER than asked with nothing
    logged as an error — the exact misalignment the feature exists to remove.
    """
    server = _control_server()
    server._devices._owntone = None
    state = await server._on_sync_set_output_trims_ms(
        {"trims_ms": {"dev-far": WIDEST_NORMALISED_TRIM_MS}},
    )
    assert state["output_trims_ms"] == {"dev-far": WIDEST_NORMALISED_TRIM_MS}


def test_widest_normalised_trim_reaches_the_composite() -> None:
    manager, _fake = _manager()
    manager._output_trim_ms = {"dev-xiaomi": WIDEST_NORMALISED_TRIM_MS}
    assert manager._target_airplay_offset_ms(XIAOMI_OUTPUT_ID) == (
        AIRPLAY_SYNC_OFFSET_DEFAULT_MS + WIDEST_NORMALISED_TRIM_MS
    )


# --------------------------------------------------------------------------
# Receivers matched by NAME (no Bonjour `deviceid`)
# --------------------------------------------------------------------------


def test_trim_resolves_for_a_receiver_matched_by_name() -> None:
    """Older receivers advertise no `deviceid`; `_match_output` falls back to
    the name and stamps `owntone_output_id`. The trim lookup has to use that
    same resolution or the receiver plays untrimmed while every diagnostic
    reports the trim as in force."""
    manager, _fake = _manager()
    nameless = _device("dev-old", "Kitchen", "")
    nameless.airplay_device_id = None
    nameless.owntone_output_id = KITCHEN_OUTPUT_ID
    manager._devices = {"dev-old": nameless}
    manager._output_trim_ms = {"dev-old": 12}

    assert manager._trim_ms_for_output(KITCHEN_OUTPUT_ID) == 12
    assert manager._target_airplay_offset_ms(KITCHEN_OUTPUT_ID) == (
        AIRPLAY_SYNC_OFFSET_DEFAULT_MS + 12
    )


def test_trim_for_an_unresolvable_device_stays_the_default() -> None:
    """A device with neither a `deviceid` nor a matched output cannot be
    reached. The honest answer is the default — and it is logged, not
    swallowed (see `_trim_ms_for_output`)."""
    manager, _fake = _manager()
    orphan = _device("dev-ghost", "Ghost", "")
    orphan.airplay_device_id = None
    manager._devices = {"dev-ghost": orphan}
    manager._output_trim_ms = {"dev-ghost": 30}

    assert manager._trim_ms_for_output(XIAOMI_OUTPUT_ID) == OUTPUT_TRIM_DEFAULT_MS
