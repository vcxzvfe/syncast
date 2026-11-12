"""SyncCast gives the PTP ports to macOS's own AirPlay sender.

Background (2026-11-12): OwnTone binds UDP 319/320 for as long as it runs.
While it does, macOS's AirPlay sender cannot add a PTP peer
(`kIOReturnExclusiveAccess`) and Apple Music plays silence to every AirPlay 2
receiver. These tests pin the two halves of the fix: OwnTone does not outlive
the modes that need it, and when macOS activates an AirPlay endpoint the
ports are released at once, on the watcher's own thread.
"""

from __future__ import annotations

import asyncio
import io
import json
import threading
from pathlib import Path
from typing import ClassVar

import pytest

from syncast_sidecar import jsonrpc
from syncast_sidecar import owntone_backend as owntone_backend_module
from syncast_sidecar.device_manager import YIELD_HOLD_S, Device, DeviceManager
from syncast_sidecar.system_airplay_watch import (
    KIND_ACTIVATION,
    KIND_PTP_CONFLICT,
    LOG_PREDICATE,
    SystemAirPlayEvent,
    SystemAirPlayWatcher,
    parse_event_message,
    parse_log_line,
)

# Verbatim shapes captured from AirPlayXPCHelper on macOS 27.0.1.
ACTIVATION_HOMEPOD = (
    "Activating endpoint [0xBA00] 'Living Room' with features 0x8 < BufferedAudio >, "
    "correlationID: 'NULL', options: {"
)
ACTIVATION_MAC = (
    "Activating endpoint [0xE378] 'Studio Mac mini' with features 0xC "
    "< Playback BufferedAudio >, correlationID: 'NULL', options: {"
)
ACTIVATION_CONTROL_ONLY = (
    "Activating endpoint [0x74A5] 'Living Room' with features 0x10 < Control >, "
    "correlationID: 'A3465BAC-E62A-43C0-80CB-C62CF552C17E', options: {"
)
SECOND_ACTIVATION_LINE = (
    "[0xBA00] Activating endpoint 'Living Room' (AudioAccessory6,1 v1005.13.2) with seed 4..."
)
PEER_ADD_FAILED = (
    "[0x7F69] Failed to add peer: -536870203/0xE00002C5 kIOReturnExclusiveAccess"
)
OPEN_PORTS_FAILED = (
    "ptpClock_openClockPortsForPeer:885: got error -536870203/0xE00002C5 "
    "kIOReturnExclusiveAccess"
)


def _ndjson(message: str) -> str:
    return json.dumps({
        "timestamp": "2026-11-12 21:02:02.695000+0100",
        "processImagePath": "/usr/libexec/AirPlayXPCHelper",
        "subsystem": "com.apple.airplay",
        "category": "APEndpoint",
        "eventMessage": message,
    }, ensure_ascii=False) + "\n"


# --------------------------------------------------------------------------
# Parsing
# --------------------------------------------------------------------------


def test_media_activation_is_a_reason_to_yield() -> None:
    event = parse_event_message(ACTIVATION_HOMEPOD)
    assert event == SystemAirPlayEvent(
        KIND_ACTIVATION, "Living Room", ("BufferedAudio",), ACTIVATION_HOMEPOD,
    )


def test_playback_activation_keeps_every_feature() -> None:
    event = parse_event_message(ACTIVATION_MAC)
    assert event is not None
    assert event.endpoint == "Studio Mac mini"
    assert event.features == ("Playback", "BufferedAudio")


def test_control_only_activation_is_ignored() -> None:
    """The Home app adjusting a HomePod must not tear whole-home down."""
    assert parse_event_message(ACTIVATION_CONTROL_ONLY) is None


def test_speaker_name_with_an_apostrophe_survives() -> None:
    message = (
        "Activating endpoint [0x1234] 'Guest's HomePod' with features 0x8 "
        "< BufferedAudio >, correlationID: 'NULL'"
    )
    event = parse_event_message(message)
    assert event is not None
    assert event.endpoint == "Guest's HomePod"


def test_unreadable_activation_still_yields() -> None:
    """A future macOS rewording must fail towards Music playing."""
    event = parse_event_message("Activating endpoint [0x1] something new")
    assert event is not None
    assert event.kind == KIND_ACTIVATION
    assert event.endpoint is None


def test_second_activation_line_does_not_double_count() -> None:
    assert parse_event_message(SECOND_ACTIVATION_LINE) is None


@pytest.mark.parametrize("message", [PEER_ADD_FAILED, OPEN_PORTS_FAILED])
def test_ptp_exclusive_access_is_the_late_fallback(message: str) -> None:
    event = parse_event_message(message)
    assert event is not None
    assert event.kind == KIND_PTP_CONFLICT


def test_exclusive_access_unrelated_to_ptp_is_ignored() -> None:
    assert parse_event_message("IOServiceOpen: kIOReturnExclusiveAccess") is None


@pytest.mark.parametrize("line", [
    "Filtering the log data using \"process == ...\"\n",
    "{not json\n",
    json.dumps({"eventMessage": 7}) + "\n",
    "\n",
])
def test_noise_lines_are_ignored(line: str) -> None:
    assert parse_log_line(line) is None


def test_ndjson_record_round_trips() -> None:
    event = parse_log_line(_ndjson(ACTIVATION_HOMEPOD))
    assert event is not None
    assert event.endpoint == "Living Room"


def test_predicate_pins_process_and_both_shapes() -> None:
    assert 'process == "AirPlayXPCHelper"' in LOG_PREDICATE
    assert 'BEGINSWITH "Activating endpoint ["' in LOG_PREDICATE
    assert 'CONTAINS "kIOReturnExclusiveAccess"' in LOG_PREDICATE


# --------------------------------------------------------------------------
# Watcher process plumbing
# --------------------------------------------------------------------------


class _FakeLogProc:
    def __init__(self, text: str) -> None:
        self.stdout = io.StringIO(text)
        self.pid = 4242
        self.terminated = False

    def poll(self) -> int | None:
        return 0 if self.terminated else None

    def terminate(self) -> None:
        self.terminated = True

    def wait(self, timeout: float | None = None) -> int:
        return 0

    def kill(self) -> None:
        self.terminated = True


def test_watcher_reports_events_in_order_and_skips_noise() -> None:
    lines = (
        "Filtering the log data using ...\n"
        + _ndjson(ACTIVATION_CONTROL_ONLY)
        + _ndjson(ACTIVATION_HOMEPOD)
        + _ndjson(PEER_ADD_FAILED)
    )
    proc = _FakeLogProc(lines)
    seen: list[SystemAirPlayEvent] = []
    done = threading.Event()
    commands: list[list[str]] = []

    def on_event(event: SystemAirPlayEvent) -> None:
        seen.append(event)
        if len(seen) == 2:
            done.set()

    def popen(cmd: list[str], **_kwargs: object) -> _FakeLogProc:
        commands.append(cmd)
        return proc

    watcher = SystemAirPlayWatcher(on_event, popen=popen)
    assert watcher.start() is True
    assert done.wait(2.0)
    watcher.stop()
    assert [e.kind for e in seen] == [KIND_ACTIVATION, KIND_PTP_CONFLICT]
    assert commands == [[
        "/usr/bin/log", "stream", "--style", "ndjson", "--predicate", LOG_PREDICATE,
    ]]
    assert proc.terminated


def test_watcher_survives_a_failing_callback() -> None:
    proc = _FakeLogProc(_ndjson(ACTIVATION_HOMEPOD) + _ndjson(ACTIVATION_MAC))
    calls: list[str | None] = []
    done = threading.Event()

    def on_event(event: SystemAirPlayEvent) -> None:
        calls.append(event.endpoint)
        if len(calls) == 1:
            raise RuntimeError("boom")
        done.set()

    watcher = SystemAirPlayWatcher(on_event, popen=lambda *_a, **_k: proc)
    watcher.start()
    assert done.wait(2.0)
    watcher.stop()
    assert calls == ["Living Room", "Studio Mac mini"]


def test_watcher_reports_a_missing_log_binary() -> None:
    def popen(*_a: object, **_k: object) -> None:
        raise FileNotFoundError("/usr/bin/log")

    watcher = SystemAirPlayWatcher(lambda _e: None, popen=popen)
    assert watcher.start() is False
    watcher.stop()  # must be harmless


# --------------------------------------------------------------------------
# DeviceManager lifecycle
# --------------------------------------------------------------------------


class _FakeBackend:
    """The slice of OwnToneBackend the release and hand-over paths touch."""

    def __init__(self) -> None:
        self.alive = True
        self.killed = 0
        self.stopped = 0
        self.flushed = 0

    def is_alive(self) -> bool:
        return self.alive

    def kill_now(self) -> bool:
        if not self.alive:
            return False
        self.alive = False
        self.killed += 1
        return True

    async def stop(self) -> None:
        self.stopped += 1
        self.alive = False

    def flush(self) -> None:
        self.flushed += 1


class _FakeWatcher:
    def __init__(self, on_event) -> None:  # type: ignore[no-untyped-def]
        self.on_event = on_event
        self.started = 0
        self.stopped = 0

    def start(self) -> bool:
        self.started += 1
        return True

    def stop(self) -> None:
        self.stopped += 1


class _FakeBroadcaster:
    def __init__(self) -> None:
        self.stopped = 0

    def stop(self) -> None:
        self.stopped += 1

    def reset(self) -> None:
        pass


def _manager(mode: str) -> tuple[DeviceManager, _FakeBackend, list[tuple[str, dict]]]:
    events: list[tuple[str, dict]] = []
    watchers: list[_FakeWatcher] = []

    def factory(on_event):  # type: ignore[no-untyped-def]
        w = _FakeWatcher(on_event)
        watchers.append(w)
        return w

    manager = DeviceManager(
        notify=lambda m, p: events.append((m, p)),
        system_airplay_watch_factory=factory,
    )
    backend = _FakeBackend()
    manager._owntone = backend
    manager._mode = mode
    manager._devices = {
        "dev-homepod": Device(
            id="dev-homepod", transport="airplay2", host="192.0.2.30",
            port=7000, name="HomePod", owntone_output_id="123",
        ),
    }
    return manager, backend, events


def _attach_watcher(manager: DeviceManager) -> _FakeWatcher:
    watcher = _FakeWatcher(manager._on_system_airplay_event)
    manager._airplay_watch = watcher
    return watcher


@pytest.mark.asyncio
async def test_leaving_whole_home_releases_owntone() -> None:
    """The incident: whole-home for two seconds, then OwnTone held PTP all night."""
    manager, backend, _events = _manager("whole_home")
    watcher = _attach_watcher(manager)
    broadcaster = _FakeBroadcaster()
    manager._broadcaster = broadcaster  # type: ignore[assignment]

    result = await manager.set_mode("stereo")

    assert result == {"applied": True, "mode": "stereo"}
    assert backend.stopped == 1
    assert manager._owntone is None
    assert broadcaster.stopped == 1
    assert watcher.stopped == 1
    assert manager._airplay_watch is None
    assert manager._devices["dev-homepod"].owntone_output_id is None


@pytest.mark.asyncio
async def test_stereo_keeps_owntone_while_an_airplay_stream_is_live() -> None:
    manager, backend, _events = _manager("whole_home")
    manager._streaming = True
    await manager.set_mode("stereo")
    assert backend.stopped == 0
    assert manager._owntone is backend


@pytest.mark.asyncio
async def test_stopping_a_stereo_stream_releases_owntone() -> None:
    manager, backend, _events = _manager("stereo")
    manager._streaming = True
    await manager.stop_stream()
    assert backend.stopped == 1
    assert manager._owntone is None


@pytest.mark.asyncio
async def test_stopping_a_whole_home_stream_keeps_owntone() -> None:
    """Whole-home's local legs ride OwnTone's clock even with no AirPlay leg."""
    manager, backend, _events = _manager("whole_home")
    manager._streaming = True
    await manager.stop_stream()
    assert backend.stopped == 0
    assert manager._owntone is backend


@pytest.mark.asyncio
async def test_activation_kills_owntone_on_the_watcher_thread() -> None:
    manager, backend, events = _manager("whole_home")
    _attach_watcher(manager)
    manager._loop = asyncio.get_running_loop()
    manager._streaming = True
    manager._active_stream_device_ids = ("dev-homepod",)
    manager._devices["dev-homepod"].state = "streaming"
    event = parse_event_message(ACTIVATION_HOMEPOD)
    assert event is not None

    thread = threading.Thread(target=manager._on_system_airplay_event, args=(event,))
    thread.start()
    thread.join()
    # The ports are free before the loop has run a single callback.
    assert backend.killed == 1
    assert not any(m == "event.system_airplay_yield" for m, _ in events)

    for _ in range(5):
        await asyncio.sleep(0)
    assert manager._yield_task is not None
    await manager._yield_task

    yields = [p for m, p in events if m == "event.system_airplay_yield"]
    assert yields == [{
        "kind": KIND_ACTIVATION,
        "endpoint": "Living Room",
        "features": ["BufferedAudio"],
        "previous_mode": "whole_home",
        "device_ids": ["dev-homepod"],
    }]
    assert manager._mode == "stereo"
    assert manager._owntone is None
    assert manager._airplay_watch is None
    assert manager._streaming is False
    assert manager._yield_blocked_since is not None
    assert backend.flushed == 0  # never REST-call a process we just killed
    assert ("event.device_state", {"device_id": "dev-homepod", "state": "connected"}) in events


@pytest.mark.asyncio
async def test_a_burst_of_activations_yields_once() -> None:
    manager, backend, events = _manager("whole_home")
    _attach_watcher(manager)
    manager._loop = asyncio.get_running_loop()
    first = parse_event_message(ACTIVATION_HOMEPOD)
    second = parse_event_message(ACTIVATION_MAC)
    assert first is not None and second is not None

    manager._on_system_airplay_event(first)
    manager._on_system_airplay_event(second)
    for _ in range(5):
        await asyncio.sleep(0)
    assert manager._yield_task is not None
    await manager._yield_task
    # A late fallback after the hand-over finds nothing to kill.
    late = parse_event_message(PEER_ADD_FAILED)
    assert late is not None
    manager._on_system_airplay_event(late)

    assert backend.killed == 1
    assert len([m for m, _ in events if m == "event.system_airplay_yield"]) == 1


@pytest.mark.asyncio
async def test_activation_while_owntone_is_still_starting_kills_it() -> None:
    """OwnTone binds the ports in main(), seconds before REST answers."""
    manager, _backend, _events = _manager("stereo")
    manager._owntone = None
    starting = _FakeBackend()
    manager._owntone_starting = starting
    manager._loop = asyncio.get_running_loop()
    event = parse_event_message(ACTIVATION_HOMEPOD)
    assert event is not None

    manager._on_system_airplay_event(event)

    assert starting.killed == 1


def test_activation_without_owntone_is_a_no_op() -> None:
    manager, _backend, events = _manager("stereo")
    manager._owntone = None
    event = parse_event_message(ACTIVATION_HOMEPOD)
    assert event is not None
    manager._on_system_airplay_event(event)
    assert events == []


class _SpawnRecorder:
    """Stands in for OwnToneBackend inside `_ensure_owntone`."""

    instances: ClassVar[list[_SpawnRecorder]] = []
    fail: ClassVar[bool] = False
    holds_ptp: ClassVar[bool | None] = True

    def __init__(self, **_kwargs: object) -> None:
        self.watch_running_at_start: bool | None = None
        self.killed = 0
        self.manager: DeviceManager | None = None
        _SpawnRecorder.instances.append(self)

    async def start(self) -> None:
        assert self.manager is not None
        self.watch_running_at_start = self.manager._airplay_watch is not None
        if _SpawnRecorder.fail:
            raise owntone_backend_module.OwnToneError("REST never answered")

    def kill_now(self) -> bool:
        self.killed += 1
        return True

    def is_alive(self) -> bool:
        return True

    def play_pipe(self) -> None:
        pass

    def holds_ptp_port(self) -> bool | None:
        return _SpawnRecorder.holds_ptp


@pytest.mark.asyncio
async def test_watch_starts_before_owntone_binds_the_ports(monkeypatch) -> None:  # type: ignore[no-untyped-def]
    manager, _backend, _events = _manager("stereo")
    manager._owntone = None
    _SpawnRecorder.instances = []
    _SpawnRecorder.fail = False

    def make(**kwargs: object) -> _SpawnRecorder:
        rec = _SpawnRecorder(**kwargs)
        rec.manager = manager
        return rec

    monkeypatch.setattr(owntone_backend_module, "OwnToneBackend", make)
    await manager._ensure_owntone()

    [spawned] = _SpawnRecorder.instances
    assert spawned.watch_running_at_start is True
    assert manager._owntone is spawned
    assert manager._owntone_starting is None


@pytest.mark.asyncio
async def test_failed_owntone_start_leaves_nothing_holding_the_ports(monkeypatch) -> None:  # type: ignore[no-untyped-def]
    manager, _backend, _events = _manager("stereo")
    manager._owntone = None
    _SpawnRecorder.instances = []
    _SpawnRecorder.fail = True

    def make(**kwargs: object) -> _SpawnRecorder:
        rec = _SpawnRecorder(**kwargs)
        rec.manager = manager
        return rec

    monkeypatch.setattr(owntone_backend_module, "OwnToneBackend", make)
    with pytest.raises(jsonrpc.RpcError):
        await manager._ensure_owntone()

    [spawned] = _SpawnRecorder.instances
    assert spawned.killed == 1
    assert manager._airplay_watch is None
    assert manager._owntone_starting is None
    _SpawnRecorder.fail = False


# --------------------------------------------------------------------------
# No stale request may take the ports back
# --------------------------------------------------------------------------


async def _yield_now(manager: DeviceManager) -> None:
    event = parse_event_message(ACTIVATION_HOMEPOD)
    assert event is not None
    manager._on_system_airplay_event(event)
    for _ in range(5):
        await asyncio.sleep(0)
    assert manager._yield_task is not None
    await manager._yield_task


@pytest.mark.asyncio
async def test_a_stream_start_in_flight_cannot_respawn_owntone() -> None:
    """A `stream.start` queued before the hand-over must not re-grab PTP."""
    manager, _backend, _events = _manager("whole_home")
    _attach_watcher(manager)
    manager._loop = asyncio.get_running_loop()
    await _yield_now(manager)

    with pytest.raises(jsonrpc.RpcError, match="PTP clock"):
        await manager.start_stream({"device_ids": ["dev-homepod"]}, Path("/nonexistent"))
    assert manager._owntone is None


@pytest.mark.asyncio
async def test_whole_home_right_after_a_hand_over_is_refused() -> None:
    manager, _backend, _events = _manager("whole_home")
    _attach_watcher(manager)
    manager._loop = asyncio.get_running_loop()
    now = [1000.0]
    manager._clock = lambda: now[0]
    await _yield_now(manager)

    now[0] += YIELD_HOLD_S - 0.5
    with pytest.raises(jsonrpc.RpcError, match="stays off"):
        await manager.set_mode("whole_home")
    assert manager._mode == "stereo"
    assert manager._yield_blocked_since is not None


@pytest.mark.asyncio
async def test_an_explicit_whole_home_later_takes_the_ports_back(monkeypatch) -> None:  # type: ignore[no-untyped-def]
    manager, _backend, _events = _manager("whole_home")
    _attach_watcher(manager)
    manager._loop = asyncio.get_running_loop()
    now = [1000.0]
    manager._clock = lambda: now[0]
    await _yield_now(manager)
    assert manager._airplay_watch is None

    _SpawnRecorder.instances = []
    _SpawnRecorder.fail = False

    def make(**kwargs: object) -> _SpawnRecorder:
        rec = _SpawnRecorder(**kwargs)
        rec.manager = manager
        return rec

    monkeypatch.setattr(owntone_backend_module, "OwnToneBackend", make)
    # Keep the whole-home plumbing that is not under test out of the way.
    monkeypatch.setattr(manager, "_ensure_broadcaster", lambda: None)
    monkeypatch.setattr(manager, "_enable_fifo_output_unlocked", lambda: None)
    now[0] += YIELD_HOLD_S + 0.1

    result = await manager.set_mode("whole_home")

    assert result == {"applied": True, "mode": "whole_home"}
    assert manager._yield_blocked_since is None
    assert manager._airplay_watch is not None
    [spawned] = _SpawnRecorder.instances
    assert manager._owntone is spawned


@pytest.mark.parametrize("holds", [True, None, False])
@pytest.mark.asyncio
async def test_watch_stays_on_even_when_owntone_lost_the_bind(  # type: ignore[no-untyped-def]
    monkeypatch, holds: bool | None,
) -> None:
    """An NTP-only OwnTone still disturbed HomePod sessions on the real
    network (2 of 2 runs), so the hand-over does not depend on the bind."""
    manager, _backend, _events = _manager("stereo")
    manager._owntone = None
    _SpawnRecorder.instances = []
    _SpawnRecorder.fail = False
    _SpawnRecorder.holds_ptp = holds

    def make(**kwargs: object) -> _SpawnRecorder:
        rec = _SpawnRecorder(**kwargs)
        rec.manager = manager
        return rec

    monkeypatch.setattr(owntone_backend_module, "OwnToneBackend", make)
    try:
        await manager._ensure_owntone()
    finally:
        _SpawnRecorder.holds_ptp = True

    assert manager._airplay_watch is not None
