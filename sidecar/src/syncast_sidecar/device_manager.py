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
from .audio_socket import (
    DEFAULT_LOCAL_FIFO_DELAY_MS,
    MAX_LOCAL_FIFO_DELAY_MS,
    AudioSocketReader,
    LocalFifoBroadcaster,
)

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
        local_fifo_delay_ms: int = DEFAULT_LOCAL_FIFO_DELAY_MS,
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
        # OwnTone REST id of the fifo output, cached on first
        # `set_mode("whole_home")` lookup. Reset on OwnTone respawn
        # (see `_ensure_owntone` health-check path) since the id
        # changes per OwnTone process.
        self._fifo_output_id: str | None = None
        self._local_fifo_socket_path: Path = default_local_fifo_socket_path()
        # Broadcast-side delay applied to bridge fan-out so local
        # CoreAudio playback aligns wall-clock with AirPlay receivers
        # (which play ~1.8 s behind capture). Forwarded to every
        # newly-constructed LocalFifoBroadcaster, and re-applied via
        # `set_local_fifo_delay_ms` if the menubar tweaks it at runtime.
        self._local_fifo_delay_ms = max(0, int(local_fifo_delay_ms))
        self._owntone_binary = owntone_binary
        self._owntone_config_template = owntone_config_template
        self._state_dir = state_dir
        # Background asyncio.Task that retries OwnTone-output discovery
        # for any device that wasn't found in time during start_stream.
        # See `_schedule_deferred_reconcile` for lifetime details.
        # Stored as Optional and lazily created — keeps __init__ free
        # of asyncio primitives that must live inside the running loop.
        self._deferred_reconcile_task: asyncio.Task[None] | None = None

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
                # Diagnostic: prove that re-add is hitting the upsert
                # branch with the expected name. The Xiaomi-stuck-off
                # bug only surfaces when `_reconcile_outputs` runs with
                # the device present in self._devices — explicit logging
                # here removes any doubt about whether device.add is
                # arriving at all.
                #
                # NOTE: stdlib `logging.LogRecord` reserves `name` for
                # the logger's name; passing it via `extra=` raises
                # KeyError. We use `device_name` for the same reason
                # everywhere this module logs a device's display name.
                logger.info(
                    "device_add_idempotent",
                    extra={"device_id": device_id, "device_name": name},
                )
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
            # Diagnostic: first-time registration, the canonical signal
            # that the menubar successfully reached the sidecar with a
            # device. Used by the Xiaomi-stuck-off triage.
            #
            # NOTE: stdlib `logging.LogRecord` reserves `name` for the
            # logger's name; passing `name=` via `extra=` raises
            # KeyError("Attempt to overwrite 'name' in LogRecord"). Use
            # `device_name` consistently throughout.
            logger.info(
                "device_add_new",
                extra={"device_id": device_id, "device_name": name,
                       "host": host, "port": port,
                       "device_count": len(self._devices)},
            )
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
        # Diagnostic: log every stream.start call with the precise
        # device_ids list. This is the single most important breadcrumb
        # for diagnosing the Xiaomi-never-selected bug — if start_stream
        # never logs, the menubar isn't sending it; if it logs with an
        # empty or wrong list, the menubar's pushAirplayState is wrong;
        # if it logs with Xiaomi present then the bug is downstream in
        # _reconcile_outputs.
        logger.info(
            "start_stream_entry",
            extra={"device_ids": device_ids,
                   "known_device_count": len(self._devices)},
        )
        # Whole-home mode allows an empty device_ids: the bridges still
        # need OwnTone running with its fifo output selected so they can
        # read PCM. We accept the call and just disable every AirPlay
        # output (via _reconcile_outputs with empty enabled set), leaving
        # the fifo output enabled and the audio reader running.
        # Stereo mode rejects empty device_ids — the engine has no use
        # for OwnTone in that mode. Router.setActiveAirplayDevices is
        # responsible for not calling stream.start with empty ids in
        # stereo mode (it calls stream.stop instead).
        if not device_ids and self._mode != "whole_home":
            raise jsonrpc.RpcError(jsonrpc.INVALID_PARAMS, "device_ids empty")
        async with self._get_lock():
            missing = [d for d in device_ids if d not in self._devices]
            if missing:
                raise jsonrpc.RpcError(
                    jsonrpc.DEVICE_NOT_FOUND, f"unknown: {missing}",
                )
            await self._ensure_owntone()
            await self._reconcile_outputs(device_ids)
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
                # POST-TEE ARCHITECTURE (b0543d5+1):
                # The fifo OUTPUT enable + play_pipe priming below is a
                # belt-and-suspenders for AirPlay-capable receivers — it
                # keeps OwnTone's player loop active even with no AirPlay
                # receivers selected, so the AirPlay-bound input fifo
                # keeps draining and Swift's audioWriter doesn't back up.
                # The local LocalAirPlayBridge clients now receive PCM
                # via a direct tee from AudioSocketReader, NOT from
                # OwnTone's fifo OUTPUT module (which had unfixable
                # multi-reader / self-flushing problems — see
                # build/owntone-server/src/outputs/fifo.c patch).
                self._enable_fifo_output_unlocked()
                if self._owntone is not None:
                    try:
                        self._owntone.play_pipe()
                    except Exception:  # noqa: BLE001
                        logger.exception("play_pipe_priming_failed")
                # Wire the broadcaster tee. AudioSocketReader (which
                # already exists for AirPlay PCM forwarding to OwnTone)
                # will now also call broadcaster.feed(packet) for every
                # chunk it writes. Bridge clients receive Swift's
                # native 48 kHz s16le 2ch packets directly.
                if self._audio_reader is not None and self._broadcaster is not None:
                    self._audio_reader.set_broadcaster_tee(
                        self._broadcaster.feed
                    )
            else:  # stereo
                # Detach the tee BEFORE stopping the broadcaster — the
                # AudioSocketReader thread might still be in a recv()
                # holding the GIL and would call .feed() on a
                # half-stopped broadcaster otherwise.
                if self._audio_reader is not None:
                    self._audio_reader.set_broadcaster_tee(None)
                if self._broadcaster is not None:
                    try:
                        self._broadcaster.stop()
                    except Exception:  # noqa: BLE001
                        logger.exception("broadcaster_stop_failed")
                    self._broadcaster = None
            self._mode = mode
        return {"applied": True, "mode": self._mode}

    def _enable_fifo_output_unlocked(self) -> None:
        """Find OwnTone's `fifo` output via the REST `/api/outputs` list
        and enable it. Caches the output id on `self._fifo_output_id` so
        we only do the lookup once per OwnTone session.

        Caller must hold ``self._lock``. OwnTone must be alive.

        Idempotent: re-calling is a no-op once the id is cached.
        """
        if self._owntone is None:
            return
        if getattr(self, "_fifo_output_id", None) is not None:
            # Already located + enabled this session.
            try:
                self._owntone.set_output_enabled(self._fifo_output_id, True)
            except Exception:  # noqa: BLE001
                logger.exception("fifo_output_re_enable_failed")
            return
        try:
            outputs = self._owntone.list_outputs()
        except Exception:  # noqa: BLE001
            logger.exception("list_outputs_failed_in_set_mode")
            return
        for o in outputs:
            # OwnTone's REST surfaces fifo as type="fifo" (or
            # name == nickname-from-conf). Match either; the nickname is
            # set in owntone_backend._write_config.
            if o.get("type") == "fifo" or o.get("name") == "SyncCast Local Bridge":
                fid = str(o.get("id", ""))
                if not fid:
                    continue
                try:
                    self._owntone.set_output_enabled(fid, True)
                    self._fifo_output_id = fid
                    logger.info("fifo_output_enabled", extra={"output_id": fid})
                except Exception:  # noqa: BLE001
                    logger.exception("fifo_output_enable_failed", extra={"id": fid})
                return
        logger.warning("fifo_output_not_found_in_list",
                       extra={"output_count": len(outputs)})

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
                "delay_ms": self._local_fifo_delay_ms,
                "pending_packets": 0,
                "chunks_dropped_due_to_overflow": 0,
                "actual_delivery_lag_ms": 0.0,
            }
        diag = self._broadcaster.diagnostics()
        diag["running"] = True
        diag["mode"] = self._mode
        return diag

    def set_local_fifo_delay_ms(self, delay_ms: int) -> dict[str, Any]:
        """Adjust the broadcast-side delay at runtime.

        Stores the value on the device manager so future broadcaster
        constructions (e.g. mode toggle out and back to whole_home)
        pick it up automatically, AND, if a broadcaster is currently
        running, applies it live via ``LocalFifoBroadcaster.set_delay_ms``.

        Negative values clamp to 0. Returns the actually-applied value
        plus the running broadcaster's report so the caller can verify
        the in-flight queue depth after a delay change.
        """
        # Defense-in-depth: server.py also clamps, but treat untrusted
        # values as untrusted at every layer. Negative -> 0; absurd
        # positive values are capped to MAX_LOCAL_FIFO_DELAY_MS.
        applied = max(0, min(int(delay_ms), MAX_LOCAL_FIFO_DELAY_MS))
        self._local_fifo_delay_ms = applied
        if self._broadcaster is not None:
            try:
                applied = self._broadcaster.set_delay_ms(applied)
            except Exception:  # noqa: BLE001
                logger.exception("local_fifo_set_delay_failed")
        logger.info(
            "local_fifo_delay_set",
            extra={"delay_ms": applied, "running": self._broadcaster is not None},
        )
        return {"delay_ms": applied}

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
            # Same reasoning for the fifo output id we cached for
            # whole-home mode — it's per-OwnTone-process.
            self._fifo_output_id = None
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
            delay_ms=self._local_fifo_delay_ms,
        )
        broadcaster.start()
        # CRITICAL: wait until the broadcaster thread has finished the
        # blocking O_RDONLY open on output.fifo BEFORE we tell OwnTone
        # to enable the fifo output via REST.
        #
        # Why: OwnTone's fifo OUTPUT module (build/owntone-server/src/
        # outputs/fifo.c:201) opens the output fifo with
        # `O_WRONLY | O_NONBLOCK`. On macOS, that returns ENXIO if
        # there's no reader at the time of the open. If we enable the
        # fifo output before the broadcaster has its O_RDONLY fd, the
        # OwnTone open fails, OwnTone marks the output as failed, and
        # the player never produces a single byte for the bridges.
        # `lsof` confirmed the failure mode: OwnTone had output.fifo
        # open for READ (its own input_fd from line 193 of fifo.c) but
        # NOT for write — the write open had ENXIO'd.
        #
        # `broadcaster._fifo_ready` is set inside `_run_broadcaster`
        # after `_open_fifo_blocking` returns. The Event object is
        # idle-cheap to wait on. 5 s deadline matches the broadcaster's
        # own retry budget.
        if not broadcaster._fifo_ready.wait(timeout=5.0):
            logger.warning("broadcaster_fifo_open_timeout",
                           extra={"fifo": str(self._owntone.output_fifo_path)})
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
            # Already running. If we're in whole-home mode and the
            # broadcaster came up after the reader, attach the tee now
            # so feed() starts firing.
            if (
                self._mode == "whole_home"
                and self._broadcaster is not None
            ):
                self._audio_reader.set_broadcaster_tee(
                    self._broadcaster.feed
                )
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
        # Tee wiring: in whole-home mode, the audio reader's PCM also
        # needs to fan out to bridge clients. Set this here (vs in
        # set_mode) so the tee is correct regardless of which order
        # set_mode and stream.start arrive.
        if self._mode == "whole_home" and self._broadcaster is not None:
            reader.set_broadcaster_tee(self._broadcaster.feed)

    async def _reconcile_outputs(self, enabled_ids: list[str]) -> None:
        """Tell OwnTone which of its known outputs to send to.

        OwnTone's REST `/api/outputs` returns a list of receivers it has
        discovered; we match by host+name and enable/disable accordingly.

        Critical timing note (root cause of "Xiaomi never selected=True"):
          OwnTone discovers AirPlay receivers via its own mDNS scanner.
          That scan typically takes 1-3 seconds AFTER OwnTone starts to
          populate. start_stream is called ~milliseconds after we spawn
          OwnTone in whole-home mode, so the first list_outputs() call
          legitimately returns ONLY the always-present devices (LAN
          peers OwnTone learned at boot from cached state) and the local
          fifo. Devices like Xiaomi Sound that are slower to advertise
          via mDNS get missed entirely, and `_reconcile_outputs` would
          previously fall through with no match and never retry.
          User-visible: the menubar shows "Xiaomi enabled" but OwnTone
          REST `/api/outputs` shows `selected=False` forever.

        Fix: poll list_outputs() with a short backoff (up to ~3s total)
        until every enabled target has appeared, OR the budget is spent.
        For any target that STILL hasn't appeared, schedule a background
        polling task that keeps retrying for the lifetime of the stream
        (slow speakers can take 10+ seconds in the wild, especially on
        congested networks). The background task self-terminates when
        the device is unenabled, the stream stops, or it succeeds.

        Connection-state events: emits `connecting` before each REST call,
        `connected` on verified success (post-call REST poll confirms
        selected=True), `failed` on REST error or unverified state.
        Consumed by the Swift Router → AppModel → MainPopover for the
        per-device sync dot. See `proto/ipc-schema.md`.

        Diagnostic logging: every step is logged. Field reports tell us
        which step failed without re-running with extra flags.
        """
        if self._owntone is None:
            logger.warning("reconcile_outputs_no_owntone")
            return
        enabled_set = set(enabled_ids)

        # Phase 1: try to build the name → output mapping with a brief
        # retry budget. Most of the time the very first call succeeds
        # because OwnTone has cached its peer list from a prior session.
        # The retry loop is for cold-start AirPlay receivers that take
        # 1-3 seconds to advertise.
        outputs = self._owntone.list_outputs()
        by_name = self._index_outputs_by_name(outputs)
        unmatched_targets = [
            d for d in enabled_set
            if self._devices[d].name.lower() not in by_name
        ]
        # Backoff schedule: 250ms, 500ms, 1s, 1.25s — total budget ~3s.
        # Bounded so a slow device doesn't block the start_stream RPC
        # forever; remaining wait happens in the background reconcile.
        retry_delays = [0.25, 0.5, 1.0, 1.25]
        for delay in retry_delays:
            if not unmatched_targets:
                break
            await asyncio.sleep(delay)
            outputs = self._owntone.list_outputs()
            by_name = self._index_outputs_by_name(outputs)
            unmatched_targets = [
                d for d in enabled_set
                if self._devices[d].name.lower() not in by_name
            ]
            logger.info(
                "reconcile_outputs_retry",
                extra={
                    "delay": delay,
                    "still_unmatched": len(unmatched_targets),
                    "by_name_keys": list(by_name.keys()),
                },
            )
        # Diagnostic: dump the universe of inputs to the matching loop in
        # one log line. Field reports can compare device.name against
        # `by_name_keys` to spot locale/case/whitespace divergence.
        logger.info(
            "reconcile_outputs_begin",
            extra={
                "device_count": len(self._devices),
                "enabled_ids": list(enabled_set),
                "by_name_keys": list(by_name.keys()),
                "owntone_output_count": len(outputs),
            },
        )

        for dev_id, dev in self._devices.items():
            match = by_name.get(dev.name.lower())
            if match is None:
                # Diagnostic: this is the most likely failure mode for
                # Xiaomi-never-selected. Logging WHICH device missed
                # against WHICH set of OwnTone names removes guessing.
                logger.warning(
                    "reconcile_outputs_no_match",
                    extra={
                        "device_id": dev_id,
                        "device_name": dev.name,
                        "device_name_lower": dev.name.lower(),
                        "available_names": list(by_name.keys()),
                    },
                )
                # If this was a target the user wants enabled, emit
                # `connecting` (we're still trying via the deferred
                # reconcile task). The deferred task will flip this to
                # connected or failed based on what actually happens.
                if dev_id in enabled_set:
                    self._notify_conn_state(
                        dev_id, "connecting",
                        reason="awaiting OwnTone mDNS discovery",
                    )
                continue
            dev.owntone_output_id = str(match.get("id"))
            should_enable = dev_id in enabled_set
            await self._apply_output_state(
                dev_id=dev_id,
                dev=dev,
                output=match,
                should_enable=should_enable,
            )

        # Phase 2: spin up the deferred reconcile. It re-polls the list
        # for any enabled device that didn't get matched in phase 1.
        # Idempotent — replaces any previous task.
        if unmatched_targets:
            self._schedule_deferred_reconcile(set(unmatched_targets))

    def _index_outputs_by_name(
        self, outputs: list[dict[str, Any]],
    ) -> dict[str, dict[str, Any]]:
        """Build a case-insensitive name → output dict.

        Extracted from `_reconcile_outputs` so retry loops and the
        deferred-reconcile task share the same matching semantics.
        """
        return {str(o.get("name", "")).lower(): o for o in outputs}

    async def _apply_output_state(
        self,
        dev_id: str,
        dev: Device,
        output: dict[str, Any],
        should_enable: bool,
    ) -> None:
        """Issue the REST PUT to enable/disable a single output and emit
        the corresponding connection-state event.

        Verification: after a successful `set_output_enabled(true)` we
        re-fetch /api/outputs once after a short wait and confirm
        `selected=True` flipped. OwnTone is known to reject silently
        (HTTP 200 returned but the receiver ultimately stayed off — e.g.
        password-required, network unreachable, AirPlay rejection). The
        post-call verification turns that silent failure into a `failed`
        connection event the UI can surface.

        State events:
          - `connecting` before the REST call (so the UI can show a
            yellow dot during the round-trip).
          - `connected` on verified success.
          - `failed` on REST error OR unverified state after wait.
          - For disable calls (`should_enable=False`) we emit
            `disconnected` because the user opted out.
        """
        output_id = str(output.get("id", ""))
        try:
            if should_enable:
                self._notify_conn_state(dev_id, "connecting")
            self._owntone.set_output_enabled(output_id, should_enable)
            if should_enable:
                self._owntone.set_output_volume(output_id, dev.volume)
            logger.info(
                "reconcile_outputs_set",
                extra={
                    "device_id": dev_id,
                    "device_name": dev.name,
                    "owntone_output_id": output_id,
                    "enable": should_enable,
                },
            )
        except Exception as e:  # noqa: BLE001
            logger.exception(
                "owntone_reconcile_failed",
                extra={
                    "device_id": dev_id,
                    "device_name": dev.name,
                    "owntone_output_id": output_id,
                    "error_kind": type(e).__name__,
                },
            )
            if should_enable:
                self._notify_conn_state(
                    dev_id, "failed", reason=f"REST error: {e}",
                )
            return
        if not should_enable:
            self._notify_conn_state(dev_id, "disconnected")
            return
        # Verify the output actually flipped to selected=True. OwnTone
        # answers PUT /api/outputs/{id} synchronously even before the
        # receiver has acked the AirPlay setup; an unreachable / rejecting
        # receiver only surfaces in the next list_outputs() call.
        await asyncio.sleep(0.5)
        try:
            outputs = self._owntone.list_outputs()
        except Exception as e:  # noqa: BLE001
            logger.warning(
                "reconcile_outputs_verify_list_failed",
                extra={"device_id": dev_id, "error_kind": type(e).__name__},
            )
            self._notify_conn_state(
                dev_id, "failed", reason=f"verify list failed: {e}",
            )
            return
        for o in outputs:
            if str(o.get("id", "")) == output_id:
                if o.get("selected"):
                    self._notify_conn_state(dev_id, "connected")
                else:
                    self._notify_conn_state(
                        dev_id, "failed",
                        reason="OwnTone rejected: selected stayed False",
                    )
                return
        # Output disappeared from the list (rare — receiver dropped off
        # network in the half-second since the PUT). Treat as failure.
        self._notify_conn_state(
            dev_id, "failed", reason="output disappeared after enable",
        )

    def _notify_conn_state(
        self, device_id: str, state: str, reason: str | None = None,
    ) -> None:
        """Helper that emits the per-device connection-state notification.

        Wraps `event.device_state` with the same payload shape as the
        existing emitter but with a richer `state` enum. The old
        `added | streaming | connected` values are preserved; the new
        ones (`connecting`, `failed`, `disconnected`) describe the
        OwnTone-side wiring rather than the audio-data state.
        See `proto/ipc-schema.md` for the full enum.
        """
        params: dict[str, Any] = {"device_id": device_id, "state": state}
        if reason is not None:
            params["last_error"] = reason
        self._notify("event.device_state", params)

    def _schedule_deferred_reconcile(self, target_ids: set[str]) -> None:
        """Spin up a background task that retries reconciliation for
        devices that haven't appeared in OwnTone's outputs list yet.

        Why background: holding the device-manager lock while waiting
        10s for mDNS would freeze every other RPC (set_volume, mode.set,
        stop_stream). The deferred task acquires the lock for short
        windows only — a quick list_outputs() + maybe one set_output
        call per pass.

        Lifecycle: cancelled by `_stop_streaming_unlocked` when the
        stream stops. Self-terminates when every target has either
        succeeded or been disabled by the user.
        """
        # Cancel any prior task. start_stream calls _reconcile_outputs
        # whenever the user toggles a device, so multiple stacked tasks
        # would all fight for the lock and re-emit duplicate events.
        prior = getattr(self, "_deferred_reconcile_task", None)
        if prior is not None and not prior.done():
            prior.cancel()
        task = asyncio.create_task(
            self._deferred_reconcile_loop(set(target_ids)),
        )
        self._deferred_reconcile_task = task

    async def _deferred_reconcile_loop(self, targets: set[str]) -> None:
        """Loop body for the background reconcile.

        Polls OwnTone's outputs every ~1.5s for up to 30 seconds. When a
        target's output finally appears, takes the device-manager lock
        briefly, applies the enable, and removes the target from the
        watch set. Stops once the watch set is empty.
        """
        deadline = time.monotonic() + 30.0
        try:
            while targets and time.monotonic() < deadline:
                await asyncio.sleep(1.5)
                if self._owntone is None:
                    logger.info("deferred_reconcile_owntone_gone")
                    return
                # Short critical section: list + maybe enable. We
                # release between iterations so the main loop's
                # toggles aren't blocked.
                async with self._get_lock():
                    if not self._streaming:
                        logger.info("deferred_reconcile_stream_stopped")
                        return
                    outputs = self._owntone.list_outputs()
                    by_name = self._index_outputs_by_name(outputs)
                    matched: set[str] = set()
                    for dev_id in list(targets):
                        # User may have toggled the device off while
                        # we were waiting; skip it.
                        dev = self._devices.get(dev_id)
                        if dev is None:
                            matched.add(dev_id)
                            continue
                        match = by_name.get(dev.name.lower())
                        if match is None:
                            continue
                        dev.owntone_output_id = str(match.get("id"))
                        logger.info(
                            "deferred_reconcile_match",
                            extra={
                                "device_id": dev_id,
                                "device_name": dev.name,
                                "owntone_output_id": dev.owntone_output_id,
                            },
                        )
                        await self._apply_output_state(
                            dev_id=dev_id,
                            dev=dev,
                            output=match,
                            should_enable=True,
                        )
                        matched.add(dev_id)
                    targets -= matched
            if targets:
                # Timed out. Surface failure to the UI for any
                # still-unmatched device.
                logger.warning(
                    "deferred_reconcile_timeout",
                    extra={"remaining": list(targets)},
                )
                for dev_id in targets:
                    self._notify_conn_state(
                        dev_id, "failed",
                        reason="OwnTone never discovered receiver",
                    )
        except asyncio.CancelledError:
            # Expected on shutdown / re-schedule.
            raise
        except Exception:  # noqa: BLE001
            logger.exception("deferred_reconcile_crashed")

    async def _stop_streaming_unlocked(self) -> None:
        if not self._streaming:
            return
        # Cancel the deferred-reconcile task BEFORE we tear down audio
        # state. If it ran during teardown, it could re-enable an
        # output on an OwnTone that's about to die, leaving stale
        # selected=True flags in REST and confusing the next session.
        prior = getattr(self, "_deferred_reconcile_task", None)
        if prior is not None and not prior.done():
            prior.cancel()
        self._deferred_reconcile_task = None
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
