"""Device manager.

Tracks AirPlay 2 receivers, runs scans, and orchestrates the per-device
streamers. Keeps pyatv usage isolated behind a thin adapter so we can swap
the streaming backend later.
"""

from __future__ import annotations

import asyncio
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Protocol

from . import jsonrpc, log

logger = log.get("sidecar.devices")


NotifyFn = Callable[[str, dict[str, Any]], None]


class StreamerProtocol(Protocol):
    """Per-device streamer implementation. Concrete: AirPlay2Streamer (pyatv)."""

    async def connect(self) -> int: ...   # returns reported_latency_ms
    async def disconnect(self) -> None: ...
    async def set_volume(self, volume: float) -> None: ...
    async def start(self, audio_socket: Path, anchor_time_ns: int) -> None: ...
    async def stop(self) -> None: ...
    async def flush(self) -> None: ...

    @property
    def measured_latency_ms(self) -> int | None: ...


@dataclass
class Device:
    id: str
    transport: str
    host: str
    port: int
    name: str
    streamer: StreamerProtocol
    state: str = "added"
    volume: float = 1.0
    last_state_emit: float = field(default_factory=time.monotonic)


class DeviceManager:
    def __init__(self, notify: NotifyFn) -> None:
        self._notify = notify
        self._devices: dict[str, Device] = {}
        self._streaming: bool = False
        self._lock = asyncio.Lock()

    async def shutdown(self) -> None:
        async with self._lock:
            for dev in list(self._devices.values()):
                try:
                    await dev.streamer.stop()
                except Exception:  # noqa: BLE001
                    logger.exception("stop_failed", extra={"device_id": dev.id})
                try:
                    await dev.streamer.disconnect()
                except Exception:  # noqa: BLE001
                    logger.exception("disconnect_failed", extra={"device_id": dev.id})
            self._devices.clear()
            self._streaming = False

    async def scan(self, timeout_ms: int) -> dict[str, Any]:
        scan_id = str(uuid.uuid4())
        asyncio.create_task(self._scan_task(scan_id, timeout_ms))
        return {"scan_id": scan_id}

    async def _scan_task(self, scan_id: str, timeout_ms: int) -> None:
        # Lazy import: keep CLI import-time lean and avoid hard pyatv requirement
        # for unit tests of the JSON-RPC plumbing.
        try:
            from .airplay2 import scan_airplay2  # type: ignore[import-not-found]
        except ImportError:
            logger.warning("scan_unavailable", extra={"reason": "airplay2 backend missing"})
            return
        try:
            async for found in scan_airplay2(timeout_ms / 1000.0):
                self._notify("event.device_found", {
                    "scan_id": scan_id, **found,
                })
        except Exception:  # noqa: BLE001
            logger.exception("scan_failed", extra={"scan_id": scan_id})

    async def add(self, params: dict[str, Any]) -> dict[str, Any]:
        device_id = params["device_id"]
        transport = params["transport"]
        if transport != "airplay2":
            raise jsonrpc.RpcError(
                jsonrpc.CAPABILITY_UNSUPPORTED,
                f"unsupported transport: {transport}",
            )
        from .airplay2 import AirPlay2Streamer  # local import for testability

        async with self._lock:
            if device_id in self._devices:
                raise jsonrpc.RpcError(jsonrpc.INVALID_PARAMS, "device_id already exists")
            streamer = AirPlay2Streamer(
                host=params["host"],
                port=int(params.get("port", 7000)),
                name=params.get("name", device_id),
                credentials=params.get("credentials"),
                notify=lambda method, p: self._notify(method, {**p, "device_id": device_id}),
            )
            try:
                latency_ms = await streamer.connect()
            except Exception as e:  # noqa: BLE001
                raise jsonrpc.RpcError(
                    jsonrpc.INTERNAL_ERROR, f"connect failed: {e}",
                ) from e
            dev = Device(
                id=device_id,
                transport=transport,
                host=params["host"],
                port=int(params.get("port", 7000)),
                name=params.get("name", device_id),
                streamer=streamer,
            )
            dev.state = "connected"
            self._devices[device_id] = dev
            self._notify("event.device_state", {
                "device_id": device_id, "state": "connected",
                "buffer_ms": latency_ms,
            })
            return {"connected": True, "reported_latency_ms": latency_ms}

    async def remove(self, device_id: str) -> dict[str, Any]:
        async with self._lock:
            dev = self._devices.pop(device_id, None)
        if dev is None:
            raise jsonrpc.RpcError(jsonrpc.DEVICE_NOT_FOUND, device_id)
        try:
            await dev.streamer.stop()
        except Exception:  # noqa: BLE001
            logger.exception("remove_stop_failed", extra={"device_id": device_id})
        try:
            await dev.streamer.disconnect()
        except Exception:  # noqa: BLE001
            logger.exception("remove_disconnect_failed", extra={"device_id": device_id})
        return {"removed": True}

    async def set_volume(self, device_id: str, volume: float) -> dict[str, Any]:
        if not 0.0 <= volume <= 1.0:
            raise jsonrpc.RpcError(jsonrpc.INVALID_PARAMS, "volume out of range")
        dev = self._devices.get(device_id)
        if dev is None:
            raise jsonrpc.RpcError(jsonrpc.DEVICE_NOT_FOUND, device_id)
        await dev.streamer.set_volume(volume)
        dev.volume = volume
        return {"volume": volume}

    async def start_stream(
        self, params: dict[str, Any], audio_socket: Path,
    ) -> dict[str, Any]:
        device_ids = list(params.get("device_ids", []))
        anchor_time_ns = int(params["anchor_time_ns"])
        if not device_ids:
            raise jsonrpc.RpcError(jsonrpc.INVALID_PARAMS, "device_ids empty")
        async with self._lock:
            missing = [d for d in device_ids if d not in self._devices]
            if missing:
                raise jsonrpc.RpcError(
                    jsonrpc.DEVICE_NOT_FOUND, f"unknown: {missing}",
                )
            for d in device_ids:
                dev = self._devices[d]
                await dev.streamer.start(audio_socket, anchor_time_ns)
                dev.state = "streaming"
                self._notify("event.device_state", {
                    "device_id": d, "state": "streaming",
                })
            self._streaming = True
        return {"started": True, "device_count": len(device_ids)}

    async def stop_stream(self) -> dict[str, Any]:
        async with self._lock:
            for dev in self._devices.values():
                if dev.state == "streaming":
                    try:
                        await dev.streamer.stop()
                    except Exception:  # noqa: BLE001
                        logger.exception("stop_failed", extra={"device_id": dev.id})
                    dev.state = "connected"
                    self._notify("event.device_state", {
                        "device_id": dev.id, "state": "connected",
                    })
            self._streaming = False
        return {"stopped": True}

    async def flush(self) -> dict[str, Any]:
        async with self._lock:
            for dev in self._devices.values():
                try:
                    await dev.streamer.flush()
                except Exception:  # noqa: BLE001
                    logger.exception("flush_failed", extra={"device_id": dev.id})
        return {"flushed": True}
