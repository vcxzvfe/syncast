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

    # ---------- audio path ----------

    def write_pcm(self, data: bytes) -> int:
        """Best-effort write of PCM bytes into OwnTone's FIFO. Returns bytes
        written. If OwnTone isn't reading yet, returns 0 (caller drops)."""
        if self._fifo_fd is None:
            return 0
        try:
            return os.write(self._fifo_fd, data)
        except BlockingIOError:
            return 0
        except BrokenPipeError:
            logger.warning("fifo_broken_pipe")
            self._fifo_fd = None
            return 0

    # ---------- REST helpers ----------

    def list_outputs(self) -> list[dict[str, Any]]:
        return self._get("/api/outputs").get("outputs", [])

    def set_output_enabled(self, output_id: str, enabled: bool) -> None:
        self._put(f"/api/outputs/{output_id}", {"selected": enabled})

    def set_output_volume(self, output_id: str, volume: float) -> None:
        # OwnTone uses 0..100; we accept 0.0..1.0.
        v = max(0, min(100, int(round(volume * 100))))
        self._put(f"/api/outputs/{output_id}/volume", {"volume": v})

    def play_pipe(self) -> None:
        # POST /api/queue/items/add with the pipe URI, then play.
        uri = f"pipe://{self.fifo_path}"
        self._post("/api/queue/items/add", {"uris": uri})
        self._put("/api/player/play", None)

    def flush(self) -> None:
        with contextlib.suppress(OwnToneError):
            self._post("/api/queue/clear", None)

    # ---------- internals ----------

    def _ensure_fifo(self) -> None:
        if self.fifo_path.exists():
            if self.fifo_path.is_fifo():
                return
            self.fifo_path.unlink()
        os.mkfifo(self.fifo_path, 0o600)

    def _write_config(self) -> None:
        cfg = f"""# Generated by SyncCast. Do not edit.
general {{
  uid = "{os.getuid()}"
  logfile = "{self.state_dir}/owntone.log"
  loglevel = "info"
  cache_path = "{self.state_dir}/cache.db"
  db_path = "{self.state_dir}/songs.db"
  websocket_port = 0
}}
library {{
  name = "SyncCast"
  port = {self.rest_port}
  directories = {{ }}
  filepath_pattern = ""
  pipe_autostart = true
}}
audio {{
  nb_outputs = 0
}}
airplay_shared {{
  password = ""
}}
"""
        self.config_path.write_text(cfg, encoding="utf-8")

    async def _wait_for_rest(self, timeout_s: float) -> None:
        deadline = time.monotonic() + timeout_s
        last_err: Exception | None = None
        while time.monotonic() < deadline:
            try:
                self._get("/api/config")
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
