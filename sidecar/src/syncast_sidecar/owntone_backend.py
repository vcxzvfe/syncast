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
        written. If OwnTone isn't reading yet, returns 0 (caller drops).

        Threading note: this is called from the audio-socket reader thread.
        We snapshot the fd into a local under the GIL so a concurrent
        `stop()` cannot close the fd between our `is None` check and
        `os.write` — closing the global is atomic w.r.t. our local copy.
        """
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
        if self.fifo_path.exists():
            if self.fifo_path.is_fifo():
                return
            self.fifo_path.unlink()
        os.mkfifo(self.fifo_path, 0o600)

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
            # ENXIO = no reader yet. We'll retry on first write attempt.
            logger.info("fifo_no_reader_yet", extra={"errno": e.errno})
            self._fifo_fd = None
            return
        self._fifo_fd = fd

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
