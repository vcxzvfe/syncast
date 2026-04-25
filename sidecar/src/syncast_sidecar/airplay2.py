"""AirPlay 2 backend (pyatv).

Thin adapter around `pyatv.stream` so the rest of the sidecar can stay
backend-agnostic. Keep this file small — anything that's not pyatv-specific
belongs in `device_manager.py`.

NOTE on pyatv streaming maturity: pyatv's streaming surface evolves; this
module deliberately wraps the minimum API and degrades gracefully when a
feature isn't available.
"""

from __future__ import annotations

import asyncio
from collections.abc import AsyncIterator
from pathlib import Path
from typing import Any, Callable

from . import log

logger = log.get("sidecar.airplay2")

NotifyFn = Callable[[str, dict[str, Any]], None]


async def scan_airplay2(timeout_s: float) -> AsyncIterator[dict[str, Any]]:
    """Yield AirPlay 2 receivers found via mDNS within `timeout_s`."""
    try:
        import pyatv  # type: ignore[import-not-found]
    except ImportError:
        logger.warning("pyatv_missing")
        return

    loop = asyncio.get_running_loop()
    try:
        results = await pyatv.scan(loop=loop, timeout=timeout_s)
    except Exception:  # noqa: BLE001
        logger.exception("pyatv_scan_failed")
        return

    for atv in results:
        services = list(getattr(atv, "services", []))
        is_airplay2 = any(
            getattr(s, "protocol", None).__class__.__name__ == "Protocol"
            and "airplay" in str(getattr(s, "protocol", "")).lower()
            for s in services
        )
        if not is_airplay2 and not services:
            continue
        host = str(getattr(atv, "address", ""))
        name = getattr(atv, "name", host) or host
        port = 7000
        for svc in services:
            p = getattr(svc, "port", None)
            if p:
                port = int(p)
                break
        yield {
            "host": host,
            "port": port,
            "name": str(name),
            "model": str(getattr(atv, "device_info", "") or ""),
            "features": 0,
            "requires_password": any(
                getattr(s, "requires_password", False) for s in services
            ),
        }


class AirPlay2Streamer:
    """Per-receiver streamer. One instance per connected AirPlay 2 device."""

    def __init__(
        self,
        host: str,
        port: int,
        name: str,
        credentials: str | None,
        notify: NotifyFn,
    ) -> None:
        self.host = host
        self.port = port
        self.name = name
        self.credentials = credentials
        self._notify = notify
        self._atv: Any | None = None
        self._stream_task: asyncio.Task[None] | None = None
        self._measured_latency_ms: int | None = None

    @property
    def measured_latency_ms(self) -> int | None:
        return self._measured_latency_ms

    async def connect(self) -> int:
        try:
            import pyatv  # type: ignore[import-not-found]
        except ImportError as e:
            raise RuntimeError("pyatv not installed") from e
        loop = asyncio.get_running_loop()
        confs = await pyatv.scan(loop=loop, hosts=[self.host], timeout=2.0)
        if not confs:
            raise RuntimeError(f"no atv at {self.host}")
        conf = confs[0]
        self._atv = await pyatv.connect(conf, loop=loop)
        # AirPlay 2's typical end-to-end buffer is ~1.8s; this is a sane default
        # until we measure it from the RTSP exchange.
        return 1800

    async def disconnect(self) -> None:
        atv = self._atv
        self._atv = None
        if atv is None:
            return
        try:
            atv.close()
        except Exception:  # noqa: BLE001
            logger.exception("close_failed")

    async def set_volume(self, volume: float) -> None:
        if self._atv is None:
            return
        try:
            audio = self._atv.audio  # type: ignore[attr-defined]
            await audio.set_volume(volume * 100.0)
        except Exception:  # noqa: BLE001
            logger.exception("set_volume_failed")

    async def start(self, audio_socket: Path, anchor_time_ns: int) -> None:
        if self._atv is None:
            raise RuntimeError("not connected")
        if self._stream_task is not None and not self._stream_task.done():
            return
        self._stream_task = asyncio.create_task(
            self._stream_loop(audio_socket, anchor_time_ns)
        )

    async def stop(self) -> None:
        task = self._stream_task
        self._stream_task = None
        if task is None:
            return
        task.cancel()
        try:
            await task
        except (asyncio.CancelledError, Exception):
            pass

    async def flush(self) -> None:
        # pyatv does not expose a fine-grained flush; restart is the safe op.
        # Concrete implementation deferred to the sync-pass.
        return None

    async def _stream_loop(self, audio_socket: Path, anchor_time_ns: int) -> None:
        # Phase 2 implementation: open SOCK_SEQPACKET, decode incoming PCM
        # packets, hand them to pyatv's stream API. The full implementation
        # lives in `streamer.py` and is wired in P3.
        logger.info(
            "stream_loop_placeholder",
            extra={"host": self.host, "anchor_ns": anchor_time_ns},
        )
        try:
            while True:
                await asyncio.sleep(1)
        except asyncio.CancelledError:
            raise
