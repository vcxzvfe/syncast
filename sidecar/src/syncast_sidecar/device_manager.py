"""Device manager.

Tracks AirPlay 2 receivers, runs scans, and drives the shared OwnTone
backend that does the actual streaming. The router never sees OwnTone
directly — it only sees this manager via JSON-RPC.

Architecture (per ADR-006):

  • One shared `OwnToneBackend` per sidecar process.
  • Each AirPlay 2 device maps to an OwnTone "output" identified by its
    name/host/port. We call REST `/api/outputs` to enable the right ones
    for the active stream and `/api/outputs/{id}/volume` for per-device
    gain.
  • The audio data path runs in parallel: `AudioSocketReader` accepts
    PCM packets from the Swift router on a SOCK_SEQPACKET socket and
    forwards them straight into OwnTone's FIFO pipe.

Whole-home AirPlay mode (Strategy 1):

  • A second data plane exists alongside the inbound `AudioSocketReader`:
    `LocalFifoBroadcaster` reads OwnTone's OUTPUT fifo (configured via
    the `fifo {}` section in owntone.conf) and fans player-clock-driven
    PCM out to N Swift `LocalAirPlayBridge` clients. This lets local
    CoreAudio outputs stay in lockstep with AirPlay receivers, since
    every output rides OwnTone's single player clock.
  • Modes:
      - "stereo"     — broadcast listener is OFF. OwnTone may or may not
                       be running; the legacy `stream.start` path still
                       works for AirPlay-only output as before.
      - "whole_home" — broadcast listener is ON. OwnTone is required to
                       be running, since Swift bridges depend on it
                       producing PCM into the output fifo.
"""

from __future__ import annotations

import asyncio
import os
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable

from . import jsonrpc, log
from .audio_socket import AudioSocketReader, LocalFifoBroadcaster

logger = log.get("sidecar.devices")


def default_local_fifo_socket_path() -> Path:
    """Canonical broadcast-socket path for whole-home AirPlay mode.

    Uses ``/tmp/syncast-$UID.localfifo.sock`` so multiple concurrent
    macOS user sessions on the same machine each get their own listener.
    The router resolves the path via the ``local_fifo.path`` IPC method
    rather than hardcoding it; this function is the single source of
    truth.
    """
    uid = os.geteuid()
    return Path(f"/tmp/syncast-{uid}.localfifo.sock")


NotifyFn = Callable[[str, dict[str, Any]], None]


@dataclass
class Device:
    id: str
    transport: str
    host: str
    port: int
    name: str
    state: str = "added"
    volume: float = 1.0
    owntone_output_id: str | None = None     # populated on first OwnTone match
    last_state_emit: float = field(default_factory=time.monotonic)


class DeviceManager:
    def __init__(
        self,
        notify: NotifyFn,
        owntone_binary: Path | None = None,
        owntone_config_template: Path | None = None,
        state_dir: Path | None = None,
    ) -> None:
        self._notify = notify
        self._devices: dict[str, Device] = {}
        self._streaming: bool = False
        # asyncio.Lock created lazily on first use (must be inside the loop;
        # see the same note in server.py).
        self._lock: asyncio.Lock | None = None
        self._owntone: Any = None      # OwnToneBackend, lazily started
        self._audio_reader: AudioSocketReader | None = None
        # Whole-home mode plumbing. The broadcaster is created on
        # transition into whole_home mode and torn down on transition
        # out. `_mode` is the latched state — single source of truth.
        self._mode: str = "stereo"
        self._broadcaster: LocalFifoBroadcaster | None = None
        self._local_fifo_socket_path: Path = default_local_fifo_socket_path()
        self._owntone_binary = owntone_binary
        self._owntone_config_template = owntone_config_template
        self._state_dir = state_dir

    def _get_lock(self) -> asyncio.Lock:
        if self._lock is None:
            self._lock = asyncio.Lock()
        return self._lock

    async def shutdown(self) -> None:
        async with self._get_lock():
            await self._stop_streaming_unlocked()
            self._devices.clear()
            # Tear the broadcaster down BEFORE OwnTone — otherwise the
            # broadcaster's read on the (now unreffed) fifo would have
            # to wait for the OS to send EOF, adding ~seconds to shutdown.
            if self._broadcaster is not None:
                try:
                    self._broadcaster.stop()
                except Exception:  # noqa: BLE001
                    logger.exception("broadcaster_stop_failed")
                self._broadcaster = None
            if self._owntone is not None:
                try:
                    await self._owntone.stop()
                except Exception:  # noqa: BLE001
                    logger.exception("owntone_stop_failed")
                self._owntone = None
            self._mode = "stereo"

    # ---------- discovery ----------

    async def scan(self, timeout_ms: int) -> dict[str, Any]:
        scan_id = str(uuid.uuid4())
        asyncio.create_task(self._scan_task(scan_id, timeout_ms))
        return {"scan_id": scan_id}

    async def _scan_task(self, scan_id: str, timeout_ms: int) -> None:
        try:
            from .airplay2 import scan_airplay2
        except ImportError:
            logger.warning("scan_unavailable", extra={"reason": "airplay2 backend missing"})
            return
        try:
            async for found in scan_airplay2(timeout_ms / 1000.0):
                self._notify("event.device_found", {"scan_id": scan_id, **found})
        except Exception:  # noqa: BLE001
            logger.exception("scan_failed", extra={"scan_id": scan_id})

    # ---------- device add/remove/volume ----------

    async def add(self, params: dict[str, Any]) -> dict[str, Any]:
        device_id = params["device_id"]
        transport = params["transport"]
        if transport != "airplay2":
            raise jsonrpc.RpcError(
                jsonrpc.CAPABILITY_UNSUPPORTED,
                f"unsupported transport: {transport}",
            )
        host = params["host"]
        port = int(params.get("port", 7000))
        name = params.get("name", device_id)
        async with self._get_lock():
            existing = self._devices.get(device_id)
            if existing is not None:
                # Idempotent re-register. The Swift menubar's `pushAirplayState`
                # is called on every `reconcileEngine`, which can fire dozens
                # of times per second when the user mashes toggle rows.
                # Treat re-registration as an upsert: refresh host/port/name
                # in place and return success. Do NOT raise — the prior
                # "device_id already exists" error spammed the warning log
                # 100s of times per session.
                existing.host = host
                existing.port = port
                existing.name = name
                return {"connected": True, "reported_latency_ms": 1800}
            dev = Device(
                id=device_id,
                transport=transport,
                host=host,
                port=port,
                name=name,
                state="added",
            )
            self._devices[device_id] = dev
            self._notify("event.device_state", {
                "device_id": device_id, "state": "added", "buffer_ms": 1800,
            })
            return {"connected": True, "reported_latency_ms": 1800}

    async def remove(self, device_id: str) -> dict[str, Any]:
        async with self._get_lock():
            dev = self._devices.pop(device_id, None)
        if dev is None:
            raise jsonrpc.RpcError(jsonrpc.DEVICE_NOT_FOUND, device_id)
        if self._owntone is not None and dev.owntone_output_id is not None:
            try:
                self._owntone.set_output_enabled(dev.owntone_output_id, False)
            except Exception:  # noqa: BLE001
                logger.exception("owntone_disable_failed", extra={"id": device_id})
        return {"removed": True}

    async def set_volume(self, device_id: str, volume: float) -> dict[str, Any]:
        if not 0.0 <= volume <= 1.0:
            raise jsonrpc.RpcError(jsonrpc.INVALID_PARAMS, "volume out of range")
        dev = self._devices.get(device_id)
        if dev is None:
            raise jsonrpc.RpcError(jsonrpc.DEVICE_NOT_FOUND, device_id)
        dev.volume = volume
        if self._owntone is not None and dev.owntone_output_id is not None:
            try:
                self._owntone.set_output_volume(dev.owntone_output_id, volume)
            except Exception:  # noqa: BLE001
                logger.exception("owntone_volume_failed", extra={"id": device_id})
        return {"volume": volume}

    # ---------- streaming ----------

    async def start_stream(
        self, params: dict[str, Any], audio_socket: Path,
    ) -> dict[str, Any]:
        device_ids = list(params.get("device_ids", []))
        if not device_ids:
            raise jsonrpc.RpcError(jsonrpc.INVALID_PARAMS, "device_ids empty")
        async with self._get_lock():
            missing = [d for d in device_ids if d not in self._devices]
            if missing:
                raise jsonrpc.RpcError(
                    jsonrpc.DEVICE_NOT_FOUND, f"unknown: {missing}",
                )
            await self._ensure_owntone()
            self._reconcile_outputs(device_ids)
            await self._ensure_audio_reader(audio_socket)
            self._owntone.play_pipe()  # idempotent: tells OwnTone to start consuming the FIFO
            for d in device_ids:
                dev = self._devices[d]
                dev.state = "streaming"
                self._notify("event.device_state", {"device_id": d, "state": "streaming"})
            self._streaming = True
        return {"started": True, "device_count": len(device_ids)}

    async def stop_stream(self) -> dict[str, Any]:
        async with self._get_lock():
            await self._stop_streaming_unlocked()
        return {"stopped": True}

    # ---------- whole-home mode ----------

    async def set_mode(self, mode: str) -> dict[str, Any]:
        """Switch between "stereo" and "whole_home" data planes.

        Idempotent: re-entering the same mode is a no-op (returns
        ``applied=False``). Otherwise:

          * ``stereo``      — stop the broadcast listener if running.
                              OwnTone is left ALIVE if it's already up
                              (other code paths may want it for legacy
                              AirPlay-only streaming) but we don't bring
                              it up just for this. We DO clear streaming
                              state so a future ``stream.start`` is clean.
          * ``whole_home``  — ensure OwnTone is running (so the output
                              fifo has a writer), then start the
                              broadcaster. Future Swift bridges will
                              connect to the listener path returned by
                              ``local_fifo.path``.
        """
        if mode not in ("stereo", "whole_home"):
            raise jsonrpc.RpcError(
                jsonrpc.INVALID_PARAMS,
                f"unknown mode: {mode!r} (expected 'stereo' or 'whole_home')",
            )
        async with self._get_lock():
            if mode == self._mode:
                return {"applied": False, "mode": self._mode}
            if mode == "whole_home":
                await self._ensure_owntone()
                self._ensure_broadcaster()
            else:  # stereo
                if self._broadcaster is not None:
                    try:
                        self._broadcaster.stop()
                    except Exception:  # noqa: BLE001
                        logger.exception("broadcaster_stop_failed")
                    self._broadcaster = None
            self._mode = mode
        return {"applied": True, "mode": self._mode}

    def get_local_fifo_path(self) -> dict[str, Any]:
        """Return the broadcast-socket path Swift bridges connect to.

        Synchronous (no lock): the path is computed once at construction
        and never changes for the life of the sidecar.
        """
        return {"socket_path": str(self._local_fifo_socket_path)}

    def broadcaster_diagnostics(self) -> dict[str, Any]:
        """Expose the broadcaster's running counters. Used by the
        diagnostic UI / log dumps; the menubar may surface this for the
        user. Safe to call at any time — returns zeros if no broadcaster
        is currently running."""
        if self._broadcaster is None:
            return {
                "running": False,
                "mode": self._mode,
                "bytes_broadcast": 0,
                "chunks_broadcast": 0,
                "clients_connected": 0,
                "fifo_open_failures": 0,
                "per_client": [],
            }
        diag = self._broadcaster.diagnostics()
        diag["running"] = True
        diag["mode"] = self._mode
        return diag

    async def flush(self) -> dict[str, Any]:
        if self._owntone is None:
            return {"flushed": True}
        try:
            self._owntone.flush()
        except Exception:  # noqa: BLE001
            logger.exception("owntone_flush_failed")
        return {"flushed": True}

    # ---------- internals ----------

    async def _ensure_owntone(self) -> None:
        # Health check: if we have a backend but the child died (crash,
        # OOM, external SIGTERM), drop the stale reference so we respawn.
        # Symptom this guards against: after one streaming session, OwnTone
        # exits, sidecar still holds the dead Popen handle, the next
        # `stream.start` calls play_pipe → urlopen fails → audio is silent.
        if self._owntone is not None and not self._owntone.is_alive():
            logger.warning("owntone_dead_will_respawn")
            # Drop fd / state but don't await stop() — proc is already gone.
            self._owntone = None
            # Reset every device's owntone_output_id; OwnTone reassigns
            # them on each launch, so the cached IDs are stale.
            for dev in self._devices.values():
                dev.owntone_output_id = None
        if self._owntone is not None:
            return
        try:
            from .owntone_backend import OwnToneBackend
        except ImportError as e:
            raise jsonrpc.RpcError(
                jsonrpc.INTERNAL_ERROR, f"owntone backend unavailable: {e}",
            ) from e
        backend = OwnToneBackend(
            binary=str(self._owntone_binary) if self._owntone_binary else None,
            state_dir=self._state_dir,
            config_template=self._owntone_config_template,
        )
        try:
            await backend.start()
        except Exception as e:  # noqa: BLE001
            raise jsonrpc.RpcError(
                jsonrpc.INTERNAL_ERROR, f"owntone start failed: {e}",
            ) from e
        self._owntone = backend

    def _ensure_broadcaster(self) -> None:
        """Spin up the LocalFifoBroadcaster if not already running.

        Called only from inside `set_mode("whole_home")` while holding
        the lock; OwnTone is guaranteed to be alive at this point because
        `_ensure_owntone()` ran first. The broadcaster opens OwnTone's
        output fifo for read, so OwnTone has to be up first or the open
        will spin in the broadcaster's retry loop until timeout.
        """
        if self._broadcaster is not None:
            return
        if self._owntone is None:
            # Defensive — set_mode already calls _ensure_owntone before
            # us. If we get here, something is very wrong; surface it
            # rather than silently producing a half-wired data plane.
            raise jsonrpc.RpcError(
                jsonrpc.INTERNAL_ERROR,
                "cannot start broadcaster without owntone",
            )
        broadcaster = LocalFifoBroadcaster(
            socket_path=self._local_fifo_socket_path,
            fifo_path=self._owntone.output_fifo_path,
        )
        broadcaster.start()
        self._broadcaster = broadcaster
        logger.info(
            "broadcaster_started",
            extra={
                "socket": str(self._local_fifo_socket_path),
                "fifo": str(self._owntone.output_fifo_path),
            },
        )

    async def _ensure_audio_reader(self, audio_socket: Path) -> None:
        if self._audio_reader is not None:
            return
        if self._owntone is None:
            return
        backend = self._owntone
        reader = AudioSocketReader(
            socket_path=audio_socket,
            sink=lambda data: backend.write_pcm(data),
        )
        reader.start()
        self._audio_reader = reader

    def _reconcile_outputs(self, enabled_ids: list[str]) -> None:
        """Tell OwnTone which of its known outputs to send to.

        OwnTone's REST `/api/outputs` returns a list of receivers it has
        discovered; we match by host+name and enable/disable accordingly.
        """
        if self._owntone is None:
            return
        outputs = self._owntone.list_outputs()
        # Index OwnTone outputs by (name, host) tolerantly.
        by_name = {str(o.get("name", "")).lower(): o for o in outputs}
        enabled_set = set(enabled_ids)
        for dev_id, dev in self._devices.items():
            match = by_name.get(dev.name.lower())
            if match is None:
                continue
            dev.owntone_output_id = str(match.get("id"))
            try:
                self._owntone.set_output_enabled(dev.owntone_output_id, dev_id in enabled_set)
                if dev_id in enabled_set:
                    self._owntone.set_output_volume(dev.owntone_output_id, dev.volume)
            except Exception:  # noqa: BLE001
                logger.exception("owntone_reconcile_failed", extra={"id": dev_id})

    async def _stop_streaming_unlocked(self) -> None:
        if not self._streaming:
            return
        if self._audio_reader is not None:
            self._audio_reader.stop()
            self._audio_reader = None
        if self._owntone is not None:
            try:
                self._owntone.flush()
            except Exception:  # noqa: BLE001
                logger.exception("flush_failed")
        for dev in self._devices.values():
            if dev.state == "streaming":
                dev.state = "added"
                self._notify("event.device_state", {
                    "device_id": dev.id, "state": "connected",
                })
        self._streaming = False
