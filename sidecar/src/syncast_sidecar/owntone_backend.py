"""OwnTone backend.

Spawns the OwnTone (forked-daapd) binary, manages its lifecycle, and exposes
the operations our `device_manager` needs: connect a receiver, set its
volume, start/stop a multi-target stream by writing PCM into a FIFO pipe.

OwnTone process model
---------------------
We launch one OwnTone instance per SyncCast session. Its config is generated
into ``$STATE_DIR/owntone.conf`` and points at:

  * a FIFO pipe at ``$STATE_DIR/audio.fifo`` as the audio source
  * a REST API on ``127.0.0.1:$PORT`` (loopback only)

The REST API surface we use:

  GET  /api/outputs                            list known outputs
  PUT  /api/outputs/{id}                       enable/disable
  PUT  /api/outputs/{id}/volume                set 0..100
  GET  /api/queue, POST /api/queue/clear       (used to flush state)

This module deliberately keeps the OwnTone surface small. If we need
something more, add it here rather than letting it leak into device_manager.
"""

from __future__ import annotations

import asyncio
import contextlib
import os
import shutil
import signal
import subprocess
import time
from pathlib import Path
from typing import Any
from urllib import error as urlerror
from urllib import request as urlrequest

from . import log

logger = log.get("sidecar.owntone")


class OwnToneError(RuntimeError):
    pass


class OwnToneBackend:
    """Lifecycle manager + thin REST client for an OwnTone child process."""

    def __init__(
        self,
        binary: str | None = None,
        state_dir: Path | None = None,
        config_template: Path | None = None,
        rest_port: int = 3689,
    ) -> None:
        self.binary = binary or shutil.which("owntone") or shutil.which("forked-daapd")
        self.state_dir = state_dir or (
            Path(os.environ.get("XDG_STATE_HOME") or
                 (Path.home() / "Library" / "Application Support" / "SyncCast"))
            / "owntone"
        )
        self.fifo_path = self.state_dir / "audio.fifo"
        # OUTPUT fifo: this is the OTHER half of OwnTone's pipe plumbing.
        # While `fifo_path` (audio.fifo) is the INPUT pipe — Swift writes
        # captured PCM into it for OwnTone to consume — `output_fifo_path`
        # is configured via OwnTone's `fifo {}` config section as a SINK:
        # OwnTone duplicates the player stream into it as 44.1 kHz s16le 2ch
        # (hardcoded in owntone-server/src/outputs/fifo.c:64). The Python
        # `LocalFifoBroadcaster` reads this fifo and fans the bytes out to
        # any number of Swift `LocalAirPlayBridge` clients so they stay in
        # lockstep with the AirPlay receivers (all driven by OwnTone's
        # single player clock). See ADR for "whole-home AirPlay mode".
        #
        # CRITICAL: this MUST live OUTSIDE `library.directories`. OwnTone's
        # `pipe_autostart` library scanner classifies any FIFO it finds in
        # the library directory as a `data_kind=pipe` INPUT track. With
        # `output.fifo` in state_dir alongside `audio.fifo`, the scanner
        # was creating a phantom input track for the output fifo, and
        # `play_pipe()` would non-deterministically queue THAT track
        # (instead of the real input) — OwnTone would try to read from
        # output.fifo while our broadcaster also held the read end, the
        # player would stall in pause, and bridges would receive zero
        # bytes. Symptom: whole-home mode silent for both local-only AND
        # local+AirPlay scenarios. (Diagnosed by Ultra Review.)
        # Solution: park output.fifo under /tmp where the library scanner
        # cannot see it.
        uid = os.geteuid()
        self.output_fifo_path = Path(f"/tmp/syncast-{uid}.output.fifo")
        self.config_path = self.state_dir / "owntone.conf"
        self.config_template = config_template
        self.rest_port = rest_port
        self._proc: subprocess.Popen[bytes] | None = None
        self._fifo_fd: int | None = None

    # ---------- lifecycle ----------

    async def start(self) -> None:
        if self.binary is None:
            raise OwnToneError(
                "owntone binary not found in PATH; run scripts/bootstrap.sh"
            )
        self.state_dir.mkdir(parents=True, exist_ok=True)
        # CRITICAL: an OwnTone left over from a previous session (e.g. the
        # menubar was force-killed without running its shutdown handler,
        # or install-app.sh missed it) holds an exclusive SQLite lock on
        # `songs.db`. Spawning a second OwnTone against the same db then
        # fails with "DB init error: database is locked" and exits within
        # a few seconds. Defend against that by killing any prior OwnTone
        # bound to OUR config path before we spawn ours.
        self._kill_stale_owntone()
        self._ensure_fifo()
        self._write_config()
        cmd = [self.binary, "-c", str(self.config_path), "-f"]
        logger.info("spawning_owntone", extra={"cmd": cmd})
        self._proc = subprocess.Popen(  # noqa: S603 - trusted binary
            cmd,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            close_fds=True,
        )
        await self._wait_for_rest(timeout_s=10.0)
        # Open FIFO for write only AFTER OwnTone has it open for read,
        # otherwise we block. OwnTone opens its pipe input lazily on first
        # play; we open O_NONBLOCK and accept short writes initially.
        self._open_fifo_nonblocking()

    def _kill_stale_owntone(self) -> None:
        """Find and SIGKILL any other owntone process that has our config
        path on its command line. Best-effort: any pgrep/pkill failure is
        swallowed (e.g. on systems without procps the BusyBox fallback
        differs)."""
        target = str(self.config_path)
        try:
            res = subprocess.run(  # noqa: S603,S607
                ["pgrep", "-f", target],
                capture_output=True,
                text=True,
                timeout=2.0,
            )
        except Exception:  # noqa: BLE001
            return
        my_pid = os.getpid()
        for line in res.stdout.splitlines():
            try:
                pid = int(line.strip())
            except ValueError:
                continue
            if pid == my_pid:
                continue
            logger.warning("killing_stale_owntone", extra={"pid": pid})
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            except PermissionError:
                logger.warning("could_not_kill_pid", extra={"pid": pid})
        # Brief pause so the killed process releases its sqlite lock
        # before we spawn our own.
        time.sleep(0.2)

    async def stop(self) -> None:
        if self._fifo_fd is not None:
            with contextlib.suppress(OSError):
                os.close(self._fifo_fd)
            self._fifo_fd = None
        proc = self._proc
        self._proc = None
        if proc is None:
            return
        with contextlib.suppress(ProcessLookupError):
            proc.send_signal(signal.SIGTERM)
        try:
            await asyncio.get_running_loop().run_in_executor(
                None, proc.wait, 5.0
            )
        except subprocess.TimeoutExpired:
            with contextlib.suppress(ProcessLookupError):
                proc.kill()

    def is_alive(self) -> bool:
        """True if the OwnTone child process is still running. Cheap; uses
        Popen.poll(). When this flips to False unexpectedly (crash, OOM,
        external SIGTERM) the device_manager should clear its reference so
        the next request triggers a fresh start()."""
        proc = self._proc
        if proc is None:
            return False
        return proc.poll() is None

    # ---------- audio path ----------

    def write_pcm(self, data: bytes) -> int:
        """Best-effort write of PCM bytes into OwnTone's FIFO. Returns bytes
        written. If OwnTone isn't reading yet, attempts to (re)open the
        FIFO write side; on persistent failure, drops the data and returns 0.

        Threading note: this is called from the audio-socket reader thread.
        We snapshot the fd into a local under the GIL so a concurrent
        `stop()` cannot close the fd between our `is None` check and
        `os.write` — closing the global is atomic w.r.t. our local copy.

        Why we retry the open on every call when fd is None: OwnTone opens
        the FIFO read end LAZILY on the first `play_pipe` REST call. On
        cold start, our initial `_open_fifo_nonblocking` from `start()`
        races OwnTone's open and usually loses (ENXIO, "no reader yet").
        Without retry, every PCM packet was silently dropped from then
        on, OwnTone read 0 bytes from its pipe, hit "Source is not
        providing sufficient data, temporarily suspending playback", and
        the AirPlay receiver got no audio — exact match for "Xiaomi
        Sound 没有声音" after stream.start. The retry is one cheap
        non-blocking syscall per packet while disconnected; once
        connected it's a single null-check.
        """
        fd = self._fifo_fd
        if fd is None:
            self._open_fifo_nonblocking()
            fd = self._fifo_fd
            if fd is None:
                return 0
        try:
            return os.write(fd, data)
        except BlockingIOError:
            return 0
        except BrokenPipeError:
            logger.warning("fifo_broken_pipe")
            # Best-effort; if a concurrent caller already cleared this we
            # don't care.
            self._fifo_fd = None
            return 0
        except OSError as e:
            # fd might have been reused by another part of the process; in
            # that case writes are silently sent elsewhere, but we cannot
            # detect it. The snapshot at the top minimizes the window.
            logger.warning("fifo_write_failed", extra={"errno": e.errno})
            return 0

    # ---------- REST helpers ----------

    def list_outputs(self) -> list[dict[str, Any]]:
        return self._get("/api/outputs").get("outputs", [])

    def set_output_enabled(self, output_id: str, enabled: bool) -> None:
        self._put(f"/api/outputs/{output_id}", {"selected": enabled})

    def set_output_volume(self, output_id: str, volume: float) -> None:
        # OwnTone uses 0..100; we accept 0.0..1.0.
        # Endpoint: PUT /api/outputs/{id} with body {volume: N}.
        # (Not /api/outputs/{id}/volume — that path returns HTTP 400.)
        v = max(0, min(100, int(round(volume * 100))))
        self._put(f"/api/outputs/{output_id}", {"volume": v})

    def play_pipe(self) -> None:
        # OwnTone scans the FIFO into its library as a track when it
        # appears in the library directory. We:
        #   1. Find the track id via /api/search?type=tracks
        #   2. POST /api/queue/items/add?uris=library:track:N&playback=start
        # POSTing with body fields fails with HTTP 400 — the API
        # requires the URIs as a QUERY STRING.
        from urllib.parse import quote
        track_id: int | None = None
        try:
            res = self._get("/api/search?type=tracks&query=")
            tracks = res.get("tracks", {}).get("items", []) if isinstance(res, dict) else []
            for t in tracks:
                if t.get("data_kind") == "pipe":
                    track_id = t.get("id")
                    break
        except Exception:  # noqa: BLE001
            pass

        if track_id is not None:
            uri = f"library:track:{track_id}"
            # Use query-string variant; clear queue first so we don't pile up.
            try:
                self._put("/api/queue/clear", None)
            except Exception:  # noqa: BLE001
                pass
            self._request_no_body(
                "POST",
                f"/api/queue/items/add?uris={quote(uri)}&playback=start",
            )
        else:
            # Fall back to streaming the pipe directly via file://.
            self._request_no_body(
                "POST",
                f"/api/queue/items/add?uris={quote('file://' + str(self.fifo_path))}&playback=start",
            )

    def flush(self) -> None:
        # OwnTone registers /api/queue/clear as PUT-only (verified in
        # owntone-server/src/httpd_jsonapi.c:4713 — HTTPD_METHOD_PUT only).
        # POSTing here gets "Unrecognized JSON API request: '/api/queue/clear'".
        with contextlib.suppress(OwnToneError):
            self._put("/api/queue/clear", None)

    # ---------- internals ----------

    def _ensure_fifo(self) -> None:
        # INPUT fifo: Swift → OwnTone (captured system audio).
        if self.fifo_path.exists():
            if not self.fifo_path.is_fifo():
                self.fifo_path.unlink()
                os.mkfifo(self.fifo_path, 0o600)
        else:
            os.mkfifo(self.fifo_path, 0o600)
        # OUTPUT fifo: OwnTone → LocalFifoBroadcaster (player-clock PCM).
        # OwnTone's fifo output module insists on creating its own pipe if
        # the path is missing (it calls mkfifo with mode 0666 on first
        # write). Pre-creating with 0o600 is fine: same uid, OwnTone's
        # `fifo_check` accepts an existing FIFO. We only delete + recreate
        # if a non-fifo file is squatting at the path (e.g. a leftover
        # regular file from a botched prior session).
        if self.output_fifo_path.exists():
            if not self.output_fifo_path.is_fifo():
                self.output_fifo_path.unlink()
                os.mkfifo(self.output_fifo_path, 0o600)
        else:
            os.mkfifo(self.output_fifo_path, 0o600)

    def _write_config(self) -> None:
        # OwnTone resolves `uid` via getpwnam — must be a USERNAME, not a
        # numeric UID. Looking up the calling user is the safe default;
        # if pwd is unavailable (e.g. PyInstaller frozen build) we fall
        # back to USER env var.
        username = os.environ.get("USER", "")
        try:
            import pwd  # noqa
            username = pwd.getpwuid(os.getuid()).pw_name
        except Exception:  # noqa: BLE001
            pass
        media = self.state_dir
        cfg = f"""# Generated by SyncCast. Do not edit.
general {{
  uid = "{username}"
  logfile = "{self.state_dir}/owntone.log"
  loglevel = "log"
  db_path = "{self.state_dir}/songs.db"
}}
library {{
  name = "SyncCast"
  port = {self.rest_port}
  directories = {{ "{media}" }}
  pipe_autostart = true
  # CRITICAL: must match the rate the Swift side writes into the FIFO.
  # SCKCapture delivers system audio at 48 kHz, AudioSocketWriter
  # converts Float32 → s16le and sends it through the unix socket to
  # the FIFO unchanged at 48 kHz. If pipe_sample_rate stayed at
  # OwnTone's 44100 default, OwnTone would interpret the same bytes
  # as a 44.1 kHz stream — pitched up 8.8% AND the rate-of-arrival
  # vs rate-of-consumption mismatch would build a backlog that
  # surfaces as audible stutter on the AirPlay receiver. User
  # observed exactly that: "卡顿以及非常低质量音频的感觉" on
  # Xiaomi Sound after the FIFO retry fix landed.
  pipe_sample_rate = 48000
}}
# Whole-home AirPlay mode: emit the player stream into a named pipe so
# `LocalFifoBroadcaster` can fan it out to N Swift LocalAirPlayBridge
# clients. The fifo output is ALWAYS configured (cheap when nobody is
# listening); when stereo mode is active the broadcaster simply has zero
# clients and the sidecar's reader thread keeps the pipe drained so
# OwnTone never blocks on full-pipe write. Output format is hardcoded
# in owntone-server/src/outputs/fifo.c:64 to 44.1 kHz s16le 2ch — Swift
# bridges decode that and let CoreAudio handle SRC up to the device's
# nominal rate.
fifo {{
  nickname = "SyncCast Local Bridge"
  path = "{self.output_fifo_path}"
}}
"""
        self.config_path.write_text(cfg, encoding="utf-8")

    async def _wait_for_rest(self, timeout_s: float) -> None:
        loop = asyncio.get_running_loop()
        deadline = time.monotonic() + timeout_s
        last_err: Exception | None = None
        while time.monotonic() < deadline:
            try:
                # Run the blocking urllib call on the default executor to
                # avoid stalling the event loop on slow startups.
                await loop.run_in_executor(None, self._get, "/api/config")
                return
            except Exception as e:  # noqa: BLE001
                last_err = e
                await asyncio.sleep(0.25)
        raise OwnToneError(f"owntone did not come up: {last_err}")

    def _open_fifo_nonblocking(self) -> None:
        try:
            fd = os.open(str(self.fifo_path), os.O_WRONLY | os.O_NONBLOCK)
        except OSError as e:
            # ENXIO = no reader yet — OwnTone hasn't called play_pipe.
            # write_pcm now retries this open, so we'd hit ENXIO 100×/sec
            # during the gap between stream.start and OwnTone's pipe-read
            # priming (~1-2 sec on cold start). Log only the FIRST miss
            # per disconnect, plus a single "connected" line on success
            # below, to keep the log readable.
            if not getattr(self, "_fifo_logged_miss", False):
                logger.info("fifo_no_reader_yet", extra={"errno": e.errno})
                self._fifo_logged_miss = True
            self._fifo_fd = None
            return
        self._fifo_fd = fd
        if getattr(self, "_fifo_logged_miss", False):
            logger.info("fifo_reader_attached")
            self._fifo_logged_miss = False

    def _url(self, path: str) -> str:
        return f"http://127.0.0.1:{self.rest_port}{path}"

    def _get(self, path: str) -> dict[str, Any]:
        return self._request("GET", path, None)

    def _post(self, path: str, body: Any) -> dict[str, Any]:
        return self._request("POST", path, body)

    def _put(self, path: str, body: Any) -> dict[str, Any]:
        return self._request("PUT", path, body)

    def _request(self, method: str, path: str, body: Any) -> dict[str, Any]:
        import json
        data = None if body is None else json.dumps(body).encode("utf-8")
        req = urlrequest.Request(
            self._url(path),
            data=data,
            method=method,
            headers={"Content-Type": "application/json"} if data else {},
        )
        try:
            with urlrequest.urlopen(req, timeout=2.0) as resp:  # noqa: S310
                raw = resp.read()
                if not raw:
                    return {}
                return json.loads(raw)
        except urlerror.URLError as e:
            raise OwnToneError(f"owntone {method} {path}: {e}") from e

    def _request_no_body(self, method: str, path: str) -> dict[str, Any]:
        """Like _request but explicitly sends NO body and no JSON
        Content-Type. Required for OwnTone endpoints that expect data
        only via query string (e.g. /api/queue/items/add)."""
        import json
        req = urlrequest.Request(self._url(path), method=method)
        try:
            with urlrequest.urlopen(req, timeout=2.0) as resp:  # noqa: S310
                raw = resp.read()
                return json.loads(raw) if raw else {}
        except urlerror.URLError as e:
            raise OwnToneError(f"owntone {method} {path}: {e}") from e
