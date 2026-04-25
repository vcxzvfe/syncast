"""JSON-RPC control server over a Unix socket.

The router connects exactly once. We do not handle multiple concurrent
control clients — the router owns this sidecar.
"""

from __future__ import annotations

import asyncio
import os
from pathlib import Path
from typing import Any, Awaitable, Callable

from . import __version__, jsonrpc, log
from .device_manager import DeviceManager

logger = log.get("sidecar.server")

PROTOCOL_VERSION = 1


Handler = Callable[[dict[str, Any]], Awaitable[Any]]


class ControlServer:
    def __init__(
        self,
        control_socket: Path,
        audio_socket: Path,
        owntone_binary: Path | None = None,
        owntone_config_template: Path | None = None,
        state_dir: Path | None = None,
    ) -> None:
        self._control_path = control_socket
        self._audio_path = audio_socket
        self._writer: asyncio.StreamWriter | None = None
        self._server: asyncio.AbstractServer | None = None
        # NOTE: asyncio.Event/Lock must NOT be constructed before the event
        # loop runs. PyInstaller-built binaries trigger
        # "Future attached to a different loop" if we create them here.
        # We lazy-init them inside run() / first-use methods.
        self._stopping: asyncio.Event | None = None
        self._devices = DeviceManager(
            notify=self._notify,
            owntone_binary=owntone_binary,
            owntone_config_template=owntone_config_template,
            state_dir=state_dir,
        )
        self._handlers: dict[str, Handler] = {
            "sidecar.hello": self._on_hello,
            "discovery.scan": self._on_scan,
            "device.add": self._on_device_add,
            "device.remove": self._on_device_remove,
            "device.set_volume": self._on_device_volume,
            "stream.start": self._on_stream_start,
            "stream.stop": self._on_stream_stop,
            "stream.flush": self._on_stream_flush,
            # Whole-home AirPlay mode (Strategy 1). See ../proto/ipc-schema.md.
            "mode.set": self._on_mode_set,
            "local_fifo.path": self._on_local_fifo_path,
            "local_fifo.diagnostics": self._on_local_fifo_diagnostics,
        }

    async def run(self) -> None:
        # Lazy-init asyncio primitives inside the running loop. PyInstaller
        # builds blow up with "Future attached to a different loop" if these
        # are constructed in __init__ before the loop exists.
        self._stopping = asyncio.Event()
        self._unlink(self._control_path)
        # Pre-set restrictive umask so the socket file is created with mode
        # 0600 atomically — closes the TOCTOU window between start_unix_server
        # creating the file and a follow-up chmod.
        old_umask = os.umask(0o177)
        try:
            self._server = await asyncio.start_unix_server(
                self._on_client, path=str(self._control_path),
            )
        finally:
            os.umask(old_umask)
        # Defensive belt-and-braces: enforce 0600 even if umask was overridden.
        os.chmod(self._control_path, 0o600)
        logger.info("listening", extra={"socket": str(self._control_path)})
        async with self._server:
            await self._stopping.wait()

    async def shutdown(self) -> None:
        logger.info("shutdown_begin")
        await self._devices.shutdown()
        if self._server is not None:
            self._server.close()
            await self._server.wait_closed()
        if self._stopping is not None:
            self._stopping.set()

    @staticmethod
    def _unlink(path: Path) -> None:
        try:
            path.unlink()
        except FileNotFoundError:
            pass

    def _notify(self, method: str, params: dict[str, Any]) -> None:
        if self._writer is None or self._writer.is_closing():
            return
        self._writer.write(jsonrpc.encode_notification(method, params))

    async def _on_client(
        self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter,
    ) -> None:
        if self._writer is not None and not self._writer.is_closing():
            logger.warning("rejecting_second_client")
            writer.close()
            await writer.wait_closed()
            return
        self._writer = writer
        peer = writer.get_extra_info("peername")
        logger.info("client_connected", extra={"peer": str(peer)})
        try:
            await self._read_loop(reader, writer)
        except (asyncio.IncompleteReadError, ConnectionResetError):
            logger.info("client_disconnected")
        finally:
            self._writer = None
            writer.close()
            try:
                await writer.wait_closed()
            except Exception:  # noqa: BLE001
                pass
            # Don't tear down OwnTone or the device registry here — the
            # menubar app may reconnect (e.g. after system sleep, or when
            # the user toggles a permission and the IpcClient reconnects).
            # Killing OwnTone on every disconnect is wrong: it makes the
            # next stream.start fail and forces a costly cold start
            # (DB vacuum, mDNS re-register, RTSP reconnect to receivers).
            # Instead, just stop the active stream — `stream.start` on
            # reconnect will spin a new audio reader.
            # Sidecar-level cleanup (stop OwnTone, clear devices) only
            # happens on real shutdown via SIGTERM/SIGINT (see __main__).
            try:
                await self._devices.stop_stream()
            except Exception:  # noqa: BLE001
                logger.exception("disconnect_stop_stream_failed")

    async def _read_loop(
        self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter,
    ) -> None:
        while not reader.at_eof():
            line = await reader.readline()
            if not line:
                return
            await self._handle_line(line, writer)

    async def _handle_line(
        self, line: bytes, writer: asyncio.StreamWriter,
    ) -> None:
        req_id: Any = None
        try:
            req = jsonrpc.parse_request(line.decode("utf-8"))
            req_id = req.id
            # Diagnostic: every incoming method. Info level (rather than
            # debug) since the sidecar runs with `--log-level info` in
            # production and we need this in field logs to triage the
            # Xiaomi-never-selected class of bugs. The volume is bounded
            # — a few dozen RPCs per session, well below noise threshold.
            logger.info(
                "rpc_request",
                extra={"method": req.method, "id": req_id},
            )
            handler = self._handlers.get(req.method)
            if handler is None:
                raise jsonrpc.RpcError(jsonrpc.METHOD_NOT_FOUND, req.method)
            result = await handler(req.params)
            if req_id is not None:
                writer.write(jsonrpc.encode_result(req_id, result))
                await writer.drain()
        except jsonrpc.RpcError as e:
            logger.warning("rpc_error", extra={"code": e.code, "err_msg": e.message})
            writer.write(jsonrpc.encode_error(req_id, e))
            await writer.drain()
        except Exception as e:  # noqa: BLE001
            logger.exception("handler_crash")
            writer.write(jsonrpc.encode_error(
                req_id, jsonrpc.RpcError(jsonrpc.INTERNAL_ERROR, str(e)),
            ))
            await writer.drain()

    # ---- handlers ----

    async def _on_hello(self, params: dict[str, Any]) -> dict[str, Any]:
        v = params.get("v")
        if v != PROTOCOL_VERSION:
            raise jsonrpc.RpcError(
                jsonrpc.PROTOCOL_VERSION_MISMATCH,
                f"unsupported protocol v={v}, expected {PROTOCOL_VERSION}",
            )
        try:
            from pyatv import const  # type: ignore[import-not-found]
            pyatv_version = getattr(const, "MAJOR_VERSION", "unknown")
        except ImportError:
            pyatv_version = "unavailable"
        return {
            "v": PROTOCOL_VERSION,
            "sidecar_version": __version__,
            "pyatv_version": str(pyatv_version),
            "capabilities": [
                "airplay2.stream",
                "airplay2.multi_target",
                "airplay2.volume",
                "airplay2.metadata",
                # Strategy 1: bundled OwnTone outputs PCM into a fifo
                # broadcast socket so local CoreAudio outputs and AirPlay
                # receivers all ride OwnTone's single player clock.
                "whole_home.local_fifo",
            ],
        }

    async def _on_scan(self, params: dict[str, Any]) -> dict[str, Any]:
        timeout_ms = int(params.get("timeout_ms", 3000))
        return await self._devices.scan(timeout_ms)

    async def _on_device_add(self, params: dict[str, Any]) -> dict[str, Any]:
        return await self._devices.add(params)

    async def _on_device_remove(self, params: dict[str, Any]) -> dict[str, Any]:
        return await self._devices.remove(params["device_id"])

    async def _on_device_volume(self, params: dict[str, Any]) -> dict[str, Any]:
        return await self._devices.set_volume(
            params["device_id"], float(params["volume"]),
        )

    async def _on_stream_start(self, params: dict[str, Any]) -> dict[str, Any]:
        return await self._devices.start_stream(params, self._audio_path)

    async def _on_stream_stop(self, params: dict[str, Any]) -> dict[str, Any]:
        return await self._devices.stop_stream()

    async def _on_stream_flush(self, params: dict[str, Any]) -> dict[str, Any]:
        return await self._devices.flush()

    async def _on_mode_set(self, params: dict[str, Any]) -> dict[str, Any]:
        """Switch the data plane between stereo and whole-home modes.

        Whole-home brings up OwnTone (if not already running) AND opens
        the local-fifo broadcast listener; stereo tears the listener
        down. See `proto/ipc-schema.md` and DeviceManager.set_mode().
        """
        mode = params.get("mode")
        if not isinstance(mode, str):
            raise jsonrpc.RpcError(jsonrpc.INVALID_PARAMS, "mode must be string")
        return await self._devices.set_mode(mode)

    async def _on_local_fifo_path(
        self, params: dict[str, Any],
    ) -> dict[str, Any]:
        """Return the broadcast Unix socket path Swift bridges connect to.

        Synchronous in spirit (no I/O), but kept async to match the
        handler signature contract.
        """
        return self._devices.get_local_fifo_path()

    async def _on_local_fifo_diagnostics(
        self, params: dict[str, Any],
    ) -> dict[str, Any]:
        """Diagnostic counters for the broadcast plane (for `state.report`
        / log dumps). Returns zero-valued payload when broadcaster is off.
        """
        return self._devices.broadcaster_diagnostics()
