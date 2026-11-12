"""Hand the PTP ports to macOS's own AirPlay sender the moment it asks.

Why this exists (diagnosed 2026-11-12, macOS 27.0.1, OwnTone 29.1):

OwnTone binds UDP 319/320 for AirPlay 2 PTP timing in ``main()``
(``ptpd_find_or_bind``, owntone-server/src/main.c:716) whether or not any
receiver is in use. macOS's AirPlay sender (``AirPlayXPCHelper``) needs the
same two ports through IOTimeSync. While another process holds them its peer
add fails with ``kIOReturnExclusiveAccess`` (0xE00002C5), every ``SetRate`` on
the session then fails with -71976, and Apple Music plays nothing on a
HomePod, a Mac or any third-party AirPlay 2 receiver. Nothing is shown to the
user: the speaker is ticked, the progress bar moves, the room stays silent.

Measured timing: ``AirPlayXPCHelper`` logs ``Activating endpoint [..] '<name>'
with features ..`` about 600 ms before it adds the PTP peer. Freeing the ports
inside that window lets the session come up normally (verified: no failed
peer add, no SetRate failure). Freeing them AFTER the failed add does not
rescue that session; it never re-adds the peer and stays silent until the
user picks the speaker again. So the activation line is the trigger, and the
``kIOReturnExclusiveAccess`` failure is only a late fallback for an
activation we missed.

The watcher runs ``/usr/bin/log stream`` on a reader thread and calls back on
that thread, so the caller can release the ports without waiting for the
asyncio loop (which may be busy behind a slow OwnTone REST call).
"""

from __future__ import annotations

import json
import re
import subprocess
import threading
from collections.abc import Callable
from dataclasses import dataclass
from typing import IO, Any

from . import log

logger = log.get("sidecar.system_airplay")

LOG_BINARY = "/usr/bin/log"

KIND_ACTIVATION = "activation"
KIND_PTP_CONFLICT = "ptp_conflict"

ACTIVATION_PREFIX = "Activating endpoint ["
PTP_CONFLICT_MARKER = "kIOReturnExclusiveAccess"

# An endpoint activated only for remote control (the Home app or Control
# Center adjusting a HomePod) carries no media and opens no clock. Yielding
# for it would tear down whole-home for nothing.
CONTROL_ONLY_FEATURES = frozenset({"Control"})

# Narrow on purpose: `log stream` evaluates the predicate in logd, so only
# these two message shapes ever reach the pipe. The second "Activating
# endpoint" line AirPlayXPCHelper prints ("[0x..] Activating endpoint '<name>'
# (model vers) with seed ..") starts with the bracket, so BEGINSWITH keeps it
# out and one pick yields exactly one activation per endpoint.
LOG_PREDICATE = (
    'process == "AirPlayXPCHelper" AND subsystem == "com.apple.airplay" AND ('
    f'eventMessage BEGINSWITH "{ACTIVATION_PREFIX}" OR '
    f'eventMessage CONTAINS "{PTP_CONFLICT_MARKER}")'
)

_ACTIVATION_RE = re.compile(
    r"^Activating endpoint \[0x[0-9A-Fa-f]+\] '(?P<name>.*?)' "
    r"with features 0x[0-9A-Fa-f]+ <(?P<features>[^>]*)>"
)


@dataclass(frozen=True)
class SystemAirPlayEvent:
    """One moment at which macOS's AirPlay sender wants the PTP ports."""

    kind: str
    endpoint: str | None
    features: tuple[str, ...]
    message: str


def parse_event_message(message: str) -> SystemAirPlayEvent | None:
    """Classify one ``eventMessage``. ``None`` means "not a reason to yield"."""
    if message.startswith(ACTIVATION_PREFIX):
        match = _ACTIVATION_RE.match(message)
        if match is None:
            # The shape changed in some future macOS. Yielding on an
            # activation we cannot read costs one whole-home session;
            # ignoring it leaves the user's speaker silent. Yield.
            return SystemAirPlayEvent(KIND_ACTIVATION, None, (), message)
        features = tuple(match.group("features").split())
        if features and set(features) <= CONTROL_ONLY_FEATURES:
            return None
        return SystemAirPlayEvent(
            KIND_ACTIVATION, match.group("name"), features, message,
        )
    if PTP_CONFLICT_MARKER in message:
        lowered = message.lower()
        if "peer" in lowered or "ptp" in lowered:
            return SystemAirPlayEvent(KIND_PTP_CONFLICT, None, (), message)
    return None


def parse_log_line(line: str) -> SystemAirPlayEvent | None:
    """Parse one line of ``log stream --style ndjson`` output."""
    line = line.strip()
    # `log stream` opens with a plain-text "Filtering the log data using ..."
    # banner before the JSON records start.
    if not line.startswith("{"):
        return None
    try:
        record = json.loads(line)
    except ValueError:
        return None
    message = record.get("eventMessage")
    if not isinstance(message, str):
        return None
    return parse_event_message(message)


PopenFactory = Callable[..., Any]


class SystemAirPlayWatcher:
    """Streams AirPlayXPCHelper's log and reports when it needs PTP.

    ``on_event`` runs on the reader thread. It must be quick and thread-safe;
    anything that needs the asyncio loop has to be handed over by the caller.
    """

    def __init__(
        self,
        on_event: Callable[[SystemAirPlayEvent], None],
        *,
        log_binary: str = LOG_BINARY,
        popen: PopenFactory = subprocess.Popen,
    ) -> None:
        self._on_event = on_event
        self._log_binary = log_binary
        self._popen = popen
        self._proc: Any = None
        self._thread: threading.Thread | None = None
        self._stopping = threading.Event()

    @property
    def running(self) -> bool:
        proc = self._proc
        return proc is not None and proc.poll() is None

    def command(self) -> list[str]:
        return [self._log_binary, "stream", "--style", "ndjson", "--predicate", LOG_PREDICATE]

    def start(self) -> bool:
        """Spawn ``log stream``. Returns False (and logs why) if it cannot."""
        if self._proc is not None:
            return self.running
        self._stopping.clear()
        try:
            proc = self._popen(  # noqa: S603 - fixed system binary, fixed args
                self.command(),
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                close_fds=True,
            )
        except OSError as e:
            logger.warning(
                "system_airplay_watch_unavailable", extra={"error": str(e)},
            )
            return False
        self._proc = proc
        self._thread = threading.Thread(
            target=self._read_loop,
            args=(proc.stdout,),
            name="system-airplay-watch",
            daemon=True,
        )
        self._thread.start()
        logger.info("system_airplay_watch_started", extra={"pid": getattr(proc, "pid", None)})
        return True

    def stop(self) -> None:
        self._stopping.set()
        proc, self._proc = self._proc, None
        thread, self._thread = self._thread, None
        if proc is not None and proc.poll() is None:
            try:
                proc.terminate()
                proc.wait(timeout=2.0)
            except subprocess.TimeoutExpired:
                proc.kill()
            except ProcessLookupError:
                pass
        if thread is not None and thread is not threading.current_thread():
            thread.join(timeout=2.0)

    def _read_loop(self, stream: IO[str] | None) -> None:
        if stream is None:
            return
        try:
            for line in stream:
                if self._stopping.is_set():
                    return
                event = parse_log_line(line)
                if event is None:
                    continue
                try:
                    self._on_event(event)
                except Exception:  # noqa: BLE001 - the watcher must survive its callback
                    logger.exception("system_airplay_callback_failed")
        except (OSError, ValueError):
            # The pipe closed under us during stop(); nothing to report.
            if not self._stopping.is_set():
                logger.exception("system_airplay_watch_read_failed")
            return
        if not self._stopping.is_set():
            # `log stream` exited on its own (logd restart, permission). The
            # owner restarts the watcher with the next OwnTone start; until
            # then a conflict goes unnoticed, so say so loudly.
            logger.warning("system_airplay_watch_exited")
