"""JSON-RPC control server over a Unix socket.

The router connects exactly once. We do not handle multiple concurrent
control clients — the router owns this sidecar.
"""

from __future__ import annotations

import asyncio
import math
import os
from pathlib import Path
from typing import Any, Awaitable, Callable

from . import __version__, jsonrpc, log
from .audio_socket import MAX_LOCAL_FIFO_DELAY_MS
from .device_manager import (
    AIRPLAY_SYNC_OFFSET_MAX_MS,
    AIRPLAY_SYNC_OFFSET_MIN_MS,
    OFFSET_SOURCE_MANUAL,
    OFFSET_SOURCE_MEASURED,
    OUTPUT_TRIM_LIMIT_MS,
    DeviceManager,
)
from .pairing import PairingCoordinator

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
            "local_fifo.set_delay_ms": self._on_local_fifo_set_delay_ms,
            # Layer 3: residual AirPlay-vs-local offset. See
            # `device_manager.AIRPLAY_SYNC_OFFSET_DEFAULT_MS`.
            "sync.airplay_offset": self._on_sync_airplay_offset,
            "sync.set_airplay_offset_ms": self._on_sync_set_airplay_offset_ms,
            # Per-output user delay trim (listening-position compensation).
            # Added to the Layer-3 correction above, never replacing it.
            "sync.set_output_trims_ms": self._on_sync_set_output_trims_ms,
            # AirPlay pairing. Every one of these returns in milliseconds:
            # the human-scale wait for a PIN lives in a background task
            # inside PairingCoordinator, because `_read_loop` awaits each
            # handler inline and a blocking handler would freeze stream.stop.
            "pairing.status": self._on_pairing_status,
            "pairing.begin": self._on_pairing_begin,
            "pairing.submit_pin": self._on_pairing_submit_pin,
            "pairing.cancel": self._on_pairing_cancel,
        }
        self._pairing = PairingCoordinator(
            notify=self._notify,
            resolve_output=self._devices.resolve_pairing_output,
            submit_pin=self._submit_pairing_pin,
            read_auth_key=self._read_pairing_auth_key,
            on_paired=self._on_receiver_paired,
        )
        self._devices.set_pairing_coordinator(self._pairing)

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
        # Cancel any in-flight pairing attempt first: it holds a background
        # task waiting on a human, and leaving it running would keep the loop
        # alive past shutdown.
        await self._pairing.shutdown()
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
        req_method: str = ""
        try:
            req = jsonrpc.parse_request(line.decode("utf-8"))
            req_id = req.id
            req_method = req.method
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
            # Pairing methods carry a PIN in their params. An exception raised
            # anywhere below can quote the request body, and that text travels
            # back over IPC AND into the log — so BOTH have to be scrubbed.
            # `logger.exception` renders the message and the traceback, which
            # is why it cannot be used here: substituting the reply alone would
            # leave the digits sitting in the log file forever. Log the type
            # only, the same rule `pairing.py` follows internally.
            is_pairing = str(req_method).startswith("pairing.")
            if is_pairing:
                logger.warning(
                    "handler_crash",
                    extra={"method": req_method, "error_kind": type(e).__name__},
                )
            else:
                logger.exception("handler_crash")
            detail = "pairing request failed" if is_pairing else str(e)
            writer.write(jsonrpc.encode_error(
                req_id, jsonrpc.RpcError(jsonrpc.INTERNAL_ERROR, detail),
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
                # Interactive AirPlay pairing for remote receivers (the PIN
                # shows on the receiver's own screen). Advertised so the
                # menubar can gate its pairing UI on a capability instead of
                # probing for a method.
                "airplay2.pairing",
            ],
        }

    async def _on_pairing_status(self, params: dict[str, Any]) -> dict[str, Any]:
        return self._pairing.status(str(params["device_key"]))

    async def _on_pairing_begin(self, params: dict[str, Any]) -> dict[str, Any]:
        return self._pairing.begin(str(params["device_key"]))

    async def _on_pairing_submit_pin(
        self, params: dict[str, Any],
    ) -> dict[str, Any]:
        # The PIN is read straight out of params and handed on. It is never
        # logged here, never placed in a URL, and never echoed back.
        return self._pairing.submit_pin(
            str(params["device_key"]), str(params.get("pin", "")),
        )

    async def _on_pairing_cancel(self, params: dict[str, Any]) -> dict[str, Any]:
        return self._pairing.cancel(str(params["device_key"]))

    def _submit_pairing_pin(self, output_id: str, pin: str) -> None:
        """Blocking REST call, run on a worker thread by the coordinator."""
        owntone = self._devices.owntone_backend
        if owntone is None:
            raise RuntimeError("owntone not running")
        owntone.set_output_pin(output_id, pin)

    def _on_receiver_paired(self, device_key: str) -> None:
        """A receiver finished pairing, so retry the enable it blocked.

        `_apply_output_state` refuses to enable an output whose
        `needs_auth_key` is set and returns BEFORE the output joins any watch
        set, so nothing on either side of the IPC re-runs reconciliation on
        its own. Scheduling it here is what turns a successful pairing into
        actual audio instead of a silently-still-disabled receiver.
        """
        self._devices.schedule_pairing_retry(device_key)

    def _read_pairing_auth_key(self, output_id: str) -> str | None:
        owntone = self._devices.owntone_backend
        if owntone is None:
            return None
        key = owntone.read_speaker_auth_key(output_id)
        return str(key) if key else None

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

    async def _on_local_fifo_set_delay_ms(
        self, params: dict[str, Any],
    ) -> dict[str, Any]:
        """Tweak the broadcast-side delay (whole-home mode wall-clock
        alignment) at runtime. Used by the menubar's Sync Settings
        panel and by automated drift-correction tooling.

        Negative values clamp to 0. The applied value is returned so
        the caller can re-render the UI from the canonical state.
        """
        raw = params.get("delay_ms")
        if not isinstance(raw, (int, float)) or isinstance(raw, bool):
            raise jsonrpc.RpcError(
                jsonrpc.INVALID_PARAMS, "delay_ms must be a number",
            )
        # bool is a subclass of int — exclude explicitly above so True/False
        # don't sneak through as 1/0.
        if math.isnan(raw) or math.isinf(raw):
            raise jsonrpc.RpcError(
                jsonrpc.INVALID_PARAMS, "delay_ms must be a finite number",
            )
        clamped = max(0, min(int(raw), MAX_LOCAL_FIFO_DELAY_MS))
        return self._devices.set_local_fifo_delay_ms(clamped)

    async def _on_sync_airplay_offset(
        self, params: dict[str, Any],
    ) -> dict[str, Any]:
        """Read the Layer-3 AirPlay offset state (no I/O, no side effects)."""
        return self._devices.airplay_offset_state()

    async def _on_sync_set_airplay_offset_ms(
        self, params: dict[str, Any],
    ) -> dict[str, Any]:
        """Set how far the AirPlay leg is delayed to meet the local leg.

        `offset_ms` is `L_local` — the local pipeline latency the router
        measured (ring backoff + render quantum + CoreAudio device latency),
        or a hand-tuned value. Positive delays AirPlay; 0 retires the
        correction. Clamped to OwnTone's own accepted range so a slider can
        never produce an opaque REST 400.

        Optional `source` labels where the number came from (for the UI);
        optional `relatch` (default true) cycles live outputs so the new value
        takes effect immediately instead of at the next enable.
        """
        raw = params.get("offset_ms")
        if not isinstance(raw, (int, float)) or isinstance(raw, bool):
            raise jsonrpc.RpcError(
                jsonrpc.INVALID_PARAMS, "offset_ms must be a number",
            )
        # bool is a subclass of int — excluded explicitly above so True/False
        # cannot slip through as 1/0.
        if math.isnan(raw) or math.isinf(raw):
            raise jsonrpc.RpcError(
                jsonrpc.INVALID_PARAMS, "offset_ms must be a finite number",
            )
        clamped = max(
            AIRPLAY_SYNC_OFFSET_MIN_MS,
            min(int(raw), AIRPLAY_SYNC_OFFSET_MAX_MS),
        )
        source_raw = params.get("source")
        if source_raw is None:
            source = OFFSET_SOURCE_MANUAL
        elif source_raw in (OFFSET_SOURCE_MANUAL, OFFSET_SOURCE_MEASURED):
            source = str(source_raw)
        else:
            raise jsonrpc.RpcError(
                jsonrpc.INVALID_PARAMS,
                f"source must be {OFFSET_SOURCE_MANUAL!r} or "
                f"{OFFSET_SOURCE_MEASURED!r}",
            )
        relatch_raw = params.get("relatch", True)
        if not isinstance(relatch_raw, bool):
            raise jsonrpc.RpcError(
                jsonrpc.INVALID_PARAMS, "relatch must be a boolean",
            )
        return await self._devices.set_airplay_offset_ms(
            clamped, source=source, relatch=relatch_raw,
        )

    async def _on_sync_set_output_trims_ms(
        self, params: dict[str, Any],
    ) -> dict[str, Any]:
        """Replace the per-output user delay trims.

        `trims_ms` maps SyncCast device id -> milliseconds of extra delay,
        compensating how far that speaker sits from the listener. FULL
        REPLACEMENT: an omitted id is reset to zero, so "clear every trim" is
        `{"trims_ms": {}}`.

        The value ADDS to the Layer-3 `sync.set_airplay_offset_ms` correction
        rather than replacing it — that one cancels the local leg's pipeline
        latency and is not the user's business. Each value is clamped to
        ±`OUTPUT_TRIM_LIMIT_MS` — which bounds the NORMALISED value on the
        wire (0…span), not the signed ±200 ms the UI offers, because
        normalisation can concentrate the whole span on one output — and the
        sum with the Layer-3 offset is clamped again to OwnTone's own
        accepted range further down, so no combination can produce an opaque
        REST 400.

        Optional `relatch` (default true) cycles the outputs whose composite
        actually changed, so the new value takes effect now instead of at
        their next enable. Each cycle is a short dropout on that receiver.
        """
        raw_map = params.get("trims_ms", {})
        if not isinstance(raw_map, dict):
            raise jsonrpc.RpcError(
                jsonrpc.INVALID_PARAMS, "trims_ms must be an object",
            )
        trims: dict[str, int] = {}
        for key, value in raw_map.items():
            if not isinstance(key, str) or not key:
                raise jsonrpc.RpcError(
                    jsonrpc.INVALID_PARAMS, "trims_ms keys must be device ids",
                )
            # bool is a subclass of int — excluded explicitly so True/False
            # cannot slip through as 1/0.
            if not isinstance(value, (int, float)) or isinstance(value, bool):
                raise jsonrpc.RpcError(
                    jsonrpc.INVALID_PARAMS,
                    f"trims_ms[{key!r}] must be a number",
                )
            if math.isnan(value) or math.isinf(value):
                raise jsonrpc.RpcError(
                    jsonrpc.INVALID_PARAMS,
                    f"trims_ms[{key!r}] must be a finite number",
                )
            trims[key] = max(
                -OUTPUT_TRIM_LIMIT_MS, min(int(value), OUTPUT_TRIM_LIMIT_MS),
            )
        relatch_raw = params.get("relatch", True)
        if not isinstance(relatch_raw, bool):
            raise jsonrpc.RpcError(
                jsonrpc.INVALID_PARAMS, "relatch must be a boolean",
            )
        return await self._devices.set_output_trims_ms(trims, relatch=relatch_raw)
