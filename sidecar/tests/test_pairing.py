"""Pairing coordinator behaviour.

The properties under test are the ones that keep the sidecar usable and the
user's secrets off disk: nothing blocks the request loop, a bad PIN never
reaches OwnTone, and no failure path echoes the PIN back.
"""

from __future__ import annotations

import asyncio
from typing import Any

import pytest

from syncast_sidecar import pairing
from syncast_sidecar.device_manager import (
    _normalize_airplay_device_id,
    _owntone_output_id_for,
)


class _Recorder:
    def __init__(self) -> None:
        self.events: list[tuple[str, dict[str, Any]]] = []
        self.submitted: list[tuple[str, str]] = []

    def notify(self, method: str, params: dict[str, Any]) -> None:
        self.events.append((method, params))

    def submit(self, output_id: str, pin: str) -> None:
        self.submitted.append((output_id, pin))

    def states(self) -> list[str]:
        return [p["state"] for m, p in self.events if m == "event.pairing_state"]


def _coordinator(
    recorder: _Recorder,
    *,
    needs_auth: bool = True,
    auth_key: str | None = "stored-credential",
) -> pairing.PairingCoordinator:
    return pairing.PairingCoordinator(
        notify=recorder.notify,
        resolve_output=lambda _key: ("2202428899329", needs_auth),
        submit_pin=recorder.submit,
        read_auth_key=lambda _output_id: auth_key,
    )


@pytest.mark.asyncio
async def test_begin_returns_immediately_and_waits_in_the_background() -> None:
    recorder = _Recorder()
    coordinator = _coordinator(recorder)

    result = coordinator.begin("ap:0200CAFE0001")

    # The contract that keeps stream.stop responsive: begin() must not block.
    assert result["state"] == pairing.STATE_AWAITING_PIN
    assert coordinator.status("ap:0200CAFE0001")["paired"] is False
    await coordinator.shutdown()


@pytest.mark.asyncio
async def test_full_flow_reaches_paired_and_forwards_the_pin_once() -> None:
    recorder = _Recorder()
    coordinator = _coordinator(recorder)
    coordinator.begin("ap:0200CAFE0001")

    assert coordinator.submit_pin("ap:0200CAFE0001", "1234")["accepted"] is True
    for _ in range(50):
        await asyncio.sleep(0.01)
        if coordinator.status("ap:0200CAFE0001")["paired"]:
            break

    assert recorder.submitted == [("2202428899329", "1234")]
    assert coordinator.status("ap:0200CAFE0001")["state"] == pairing.STATE_PAIRED
    assert pairing.STATE_VERIFYING in recorder.states()
    await coordinator.shutdown()


@pytest.mark.asyncio
async def test_malformed_pin_is_rejected_without_reaching_owntone() -> None:
    recorder = _Recorder()
    coordinator = _coordinator(recorder)
    coordinator.begin("ap:0200CAFE0001")

    for bad in ("", "12", "12345", "abcd", "12 4"):
        result = coordinator.submit_pin("ap:0200CAFE0001", bad)
        assert result["accepted"] is False, bad

    assert recorder.submitted == []
    await coordinator.shutdown()


@pytest.mark.asyncio
async def test_no_event_or_status_ever_contains_the_pin() -> None:
    recorder = _Recorder()
    coordinator = _coordinator(recorder)
    coordinator.begin("ap:0200CAFE0001")
    coordinator.submit_pin("ap:0200CAFE0001", "9876")
    for _ in range(50):
        await asyncio.sleep(0.01)
        if coordinator.status("ap:0200CAFE0001")["paired"]:
            break

    serialized = repr(recorder.events) + repr(coordinator.status("ap:0200CAFE0001"))
    assert "9876" not in serialized
    await coordinator.shutdown()


@pytest.mark.asyncio
async def test_backend_failure_reports_a_fixed_message_not_the_exception() -> None:
    recorder = _Recorder()

    def _explode(_output_id: str, pin: str) -> None:
        # A realistic failure: the underlying HTTP layer quotes the request
        # body, PIN included, in its exception text.
        raise RuntimeError(f'HTTP 400 for body {{"pin": "{pin}"}}')

    coordinator = pairing.PairingCoordinator(
        notify=recorder.notify,
        resolve_output=lambda _key: ("2202428899329", True),
        submit_pin=_explode,
        read_auth_key=lambda _output_id: None,
    )
    coordinator.begin("ap:0200CAFE0001")
    coordinator.submit_pin("ap:0200CAFE0001", "4321")
    for _ in range(50):
        await asyncio.sleep(0.01)
        if coordinator.status("ap:0200CAFE0001")["state"] == pairing.STATE_FAILED:
            break

    status = coordinator.status("ap:0200CAFE0001")
    assert status["state"] == pairing.STATE_FAILED
    assert status["last_error"] == pairing.ERROR_REJECTED
    assert "4321" not in repr(recorder.events)
    await coordinator.shutdown()


@pytest.mark.asyncio
async def test_cancel_ends_the_attempt() -> None:
    recorder = _Recorder()
    coordinator = _coordinator(recorder)
    coordinator.begin("ap:0200CAFE0001")

    assert coordinator.cancel("ap:0200CAFE0001")["cancelled"] is True
    for _ in range(50):
        await asyncio.sleep(0.01)
        if coordinator.status("ap:0200CAFE0001")["state"] == pairing.STATE_CANCELLED:
            break
    assert coordinator.status("ap:0200CAFE0001")["state"] == pairing.STATE_CANCELLED
    await coordinator.shutdown()


@pytest.mark.asyncio
async def test_receiver_that_needs_no_pairing_short_circuits() -> None:
    recorder = _Recorder()
    coordinator = _coordinator(recorder, needs_auth=False)
    assert coordinator.begin("ap:0200CAFE0001")["state"] == pairing.STATE_NOT_REQUIRED
    assert recorder.submitted == []
    await coordinator.shutdown()


@pytest.mark.asyncio
async def test_invisible_receiver_fails_without_claiming_a_pairing_error() -> None:
    recorder = _Recorder()
    coordinator = pairing.PairingCoordinator(
        notify=recorder.notify,
        resolve_output=lambda _key: None,
        submit_pin=recorder.submit,
    )
    result = coordinator.begin("ap:DEADBEEF0000")
    assert result["state"] == pairing.STATE_FAILED
    assert result["last_error"] == pairing.ERROR_NO_OUTPUT
    await coordinator.shutdown()


def test_owntone_output_id_is_the_deviceid_read_as_hex() -> None:
    # Verified against the live OwnTone database: this Mac's speakers row
    # primary key is exactly int("0200CAFE0001", 16).
    assert _owntone_output_id_for("0200CAFE0001") == "2202428899329"
    assert _owntone_output_id_for(None) is None
    assert _owntone_output_id_for("not-hex") is None


def test_deviceid_normalization_matches_the_swift_side() -> None:
    assert _normalize_airplay_device_id("02:00:CA:FE:00:01") == "0200CAFE0001"
    assert _normalize_airplay_device_id("0200cafe0001") == "0200CAFE0001"
    assert _normalize_airplay_device_id("") is None
    assert _normalize_airplay_device_id("zz:zz") is None


# ---------------------------------------------------------------------------
# Distinguishing failure causes
#
# Every failure below used to collapse into ERROR_REJECTED, "the receiver
# rejected that PIN". That message sends the user to re-pair — the one action
# that cannot help when the real problem is a dead helper or a closed window —
# and it tells someone who typed the correct code that their code was wrong.
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_submit_without_an_attempt_says_the_window_closed() -> None:
    recorder = _Recorder()
    coordinator = _coordinator(recorder)

    # No begin() first: this is the "walked to the other room, came back after
    # the window expired, typed the right digits" case.
    result = coordinator.submit_pin("ap:0200CAFE0001", "1234")

    assert result["accepted"] is False
    assert result["reason"] == pairing.ERROR_NO_ATTEMPT
    assert result["reason"] != pairing.ERROR_BAD_PIN


@pytest.mark.asyncio
async def test_malformed_pin_says_so_specifically() -> None:
    recorder = _Recorder()
    coordinator = _coordinator(recorder)
    coordinator.begin("ap:0200CAFE0001")

    result = coordinator.submit_pin("ap:0200CAFE0001", "12")

    assert result["accepted"] is False
    assert result["reason"] == pairing.ERROR_BAD_PIN
    assert recorder.submitted == []
    await coordinator.shutdown()


@pytest.mark.asyncio
async def test_helper_not_running_is_a_backend_fault_not_a_rejection() -> None:
    recorder = _Recorder()

    def _no_helper(_output_id: str, _pin: str) -> None:
        raise RuntimeError("owntone not running")

    coordinator = pairing.PairingCoordinator(
        notify=recorder.notify,
        resolve_output=lambda _key: ("2202428899329", True),
        submit_pin=_no_helper,
        read_auth_key=lambda _output_id: None,
    )
    coordinator.begin("ap:0200CAFE0001")
    coordinator.submit_pin("ap:0200CAFE0001", "1234")
    for _ in range(50):
        await asyncio.sleep(0.01)
        if coordinator.status("ap:0200CAFE0001")["state"] == pairing.STATE_FAILED:
            break

    status = coordinator.status("ap:0200CAFE0001")
    assert status["last_error"] == pairing.ERROR_BACKEND
    assert status["last_error"] != pairing.ERROR_REJECTED
    await coordinator.shutdown()


@pytest.mark.asyncio
async def test_http_status_code_on_the_exception_selects_the_rejection() -> None:
    class _Rejected(RuntimeError):
        code = 400

    def _reject(_output_id: str, _pin: str) -> None:
        raise _Rejected("owntone PUT /api/outputs/1")

    recorder = _Recorder()
    coordinator = pairing.PairingCoordinator(
        notify=recorder.notify,
        resolve_output=lambda _key: ("2202428899329", True),
        submit_pin=_reject,
        read_auth_key=lambda _output_id: None,
    )
    coordinator.begin("ap:0200CAFE0001")
    coordinator.submit_pin("ap:0200CAFE0001", "1234")
    for _ in range(50):
        await asyncio.sleep(0.01)
        if coordinator.status("ap:0200CAFE0001")["state"] == pairing.STATE_FAILED:
            break

    assert coordinator.status("ap:0200CAFE0001")["last_error"] == pairing.ERROR_REJECTED
    await coordinator.shutdown()


@pytest.mark.asyncio
async def test_unreadable_credential_is_unconfirmed_not_rejected() -> None:
    """The PIN went through; only the confirmation read came back empty.

    That read fails transiently too (the database is briefly locked), and the
    two are indistinguishable from here, so the honest message is the softer
    one — not an accusation that the user's PIN was wrong.
    """
    recorder = _Recorder()
    coordinator = _coordinator(recorder, auth_key=None)
    coordinator.begin("ap:0200CAFE0001")
    coordinator.submit_pin("ap:0200CAFE0001", "1234")
    # The confirm read now retries a few times to ride out a transient DB lock
    # (PAIRING_CONFIRM_ATTEMPTS attempts spaced by PAIRING_CONFIRM_RETRY_DELAY_S),
    # so allow more than that whole window before checking the terminal state.
    for _ in range(300):
        await asyncio.sleep(0.01)
        if coordinator.status("ap:0200CAFE0001")["state"] == pairing.STATE_FAILED:
            break

    assert coordinator.status("ap:0200CAFE0001")["last_error"] == pairing.ERROR_UNCONFIRMED
    await coordinator.shutdown()


# ---------------------------------------------------------------------------
# Re-reconciling after a successful pair
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_successful_pairing_asks_the_owner_to_retry_the_enable() -> None:
    """Nothing else re-runs reconciliation.

    `_apply_output_state` refuses to enable an output whose `needs_auth_key`
    is set and returns BEFORE the device joins any watch set, so without this
    callback a successful pairing produced a sheet that closed, a row with no
    error, and no audio.
    """
    recorder = _Recorder()
    paired: list[str] = []
    coordinator = pairing.PairingCoordinator(
        notify=recorder.notify,
        resolve_output=lambda _key: ("2202428899329", True),
        submit_pin=recorder.submit,
        read_auth_key=lambda _output_id: "stored-credential",
        on_paired=paired.append,
    )
    coordinator.begin("ap:0200CAFE0001")
    coordinator.submit_pin("ap:0200CAFE0001", "1234")
    for _ in range(50):
        await asyncio.sleep(0.01)
        if coordinator.status("ap:0200CAFE0001")["state"] == pairing.STATE_PAIRED:
            break

    assert paired == ["ap:0200CAFE0001"]
    await coordinator.shutdown()


@pytest.mark.asyncio
async def test_a_failing_on_paired_callback_does_not_break_pairing() -> None:
    recorder = _Recorder()

    def _explode(_key: str) -> None:
        raise RuntimeError("reconcile blew up")

    coordinator = pairing.PairingCoordinator(
        notify=recorder.notify,
        resolve_output=lambda _key: ("2202428899329", True),
        submit_pin=recorder.submit,
        read_auth_key=lambda _output_id: "stored-credential",
        on_paired=_explode,
    )
    coordinator.begin("ap:0200CAFE0001")
    coordinator.submit_pin("ap:0200CAFE0001", "1234")
    for _ in range(50):
        await asyncio.sleep(0.01)
        if coordinator.status("ap:0200CAFE0001")["state"] == pairing.STATE_PAIRED:
            break

    assert coordinator.status("ap:0200CAFE0001")["state"] == pairing.STATE_PAIRED
    await coordinator.shutdown()


# --------------------------------------------------------------------------
# The PIN must not survive a crash, in the reply OR in the log
# --------------------------------------------------------------------------


class _NullWriter:
    """Minimal `asyncio.StreamWriter` stand-in that records what was sent."""

    def __init__(self) -> None:
        self.written: list[bytes] = []

    def write(self, data: bytes) -> None:
        self.written.append(data)

    async def drain(self) -> None:
        return None


@pytest.mark.asyncio
async def test_a_crashing_pairing_handler_leaks_the_pin_nowhere(
    caplog, tmp_path,
) -> None:
    """`logger.exception` renders the message AND the traceback.

    Substituting a fixed string for the REPLY was only half the job: the
    exception text can quote the request body, so the four digits went
    straight into the log file on disk, where nothing rotates them away and
    the scrubbed reply hides that it happened at all.
    """
    from syncast_sidecar.server import ControlServer

    pin = "9137"
    server = ControlServer(
        control_socket=tmp_path / "control.sock",
        audio_socket=tmp_path / "audio.sock",
    )

    async def _explode(params: dict[str, Any]) -> dict[str, Any]:
        # Exactly the shape that leaks: a message interpolating the params.
        raise ValueError(f"bad params: {params}")

    server._handlers["pairing.submit_pin"] = _explode
    writer = _NullWriter()
    request = (
        '{"jsonrpc":"2.0","id":7,"method":"pairing.submit_pin",'
        f'"params":{{"device_key":"ap:AA","pin":"{pin}"}}}}\n'
    ).encode("utf-8")

    with caplog.at_level("DEBUG"):
        await server._handle_line(request, writer)  # type: ignore[arg-type]

    reply = b"".join(writer.written).decode("utf-8")
    assert "pairing request failed" in reply
    assert pin not in reply
    assert pin not in caplog.text
    # The crash is still reported — just by TYPE, so it stays diagnosable.
    # The type rides in `extra`, which the structured handler emits but
    # caplog.text does not render, so read it off the record.
    crash = next(r for r in caplog.records if r.getMessage() == "handler_crash")
    assert getattr(crash, "error_kind", None) == "ValueError"
    assert crash.exc_info is None, "a traceback would re-introduce the leak"
    for record in caplog.records:
        assert pin not in str(getattr(record, "args", "") or "")
        assert pin not in record.getMessage()


@pytest.mark.asyncio
async def test_a_non_pairing_crash_still_gets_its_full_traceback(
    caplog, tmp_path,
) -> None:
    """The scrubbing is scoped to pairing; everything else keeps its detail."""
    from syncast_sidecar.server import ControlServer

    server = ControlServer(
        control_socket=tmp_path / "control.sock",
        audio_socket=tmp_path / "audio.sock",
    )

    async def _explode(_params: dict[str, Any]) -> dict[str, Any]:
        raise ValueError("distinctive-non-pairing-detail")

    server._handlers["discovery.scan"] = _explode
    writer = _NullWriter()
    request = (
        b'{"jsonrpc":"2.0","id":8,"method":"discovery.scan","params":{}}\n'
    )

    with caplog.at_level("DEBUG"):
        await server._handle_line(request, writer)  # type: ignore[arg-type]

    assert "distinctive-non-pairing-detail" in b"".join(
        writer.written
    ).decode("utf-8")
    assert "Traceback" in caplog.text
