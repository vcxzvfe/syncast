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
from .owntone_backend import (
    OWNTONE_OFFSET_MAX_MS,
    OWNTONE_OFFSET_MIN_MS,
    OWNTONE_OUTPUT_BUFFER_DURATION_MS,
    clamp_output_offset_ms,
)

logger = log.get("sidecar.devices")

# Playout latency reported back to the menubar for a freshly-added AirPlay
# output. Derived from OwnTone's real output buffer duration (the anchor an
# AirPlay-2 receiver is PTP-locked to), NOT the former hardcoded 1800 ms
# guess. Purely informational today — no Swift consumer seeds a delay from
# it — but keeping it truthful and named avoids re-introducing a magic
# number the sync math might later be built on.
DEVICE_REPORTED_LATENCY_MS = OWNTONE_OUTPUT_BUFFER_DURATION_MS

# ---------------------------------------------------------------------------
# Whole-home residual offset (Layer 3)
# ---------------------------------------------------------------------------
# Layer 1 (broadcaster delay = 0) and Layer 2 (the Swift PLL that slaves the
# local device clock to OwnTone's fifo write rate) leave both legs departing
# OwnTone at the same instant and never drifting apart. What is left is a
# FIXED residual: the local leg's own pipeline latency `L_local`, the delay
# between a byte leaving OwnTone's output fifo and that audio leaving the
# local speaker.
#
#     L_local = PLL steady-state ring fill
#                 (LocalAirPlayBridge.baselineBackoffMs = 109 ms)
#             + one AUHAL render quantum (512 frames ≈ 11 ms at 48 kHz)
#             + broadcaster packet quantisation (352-frame packets, ~4 ms mean)
#             + the CoreAudio device's presentation latency
#                 (kAudioDevicePropertyLatency + safety offset + stream
#                  latency: single-digit ms built-in, tens of ms over DP/HDMI)
#
# The local leg cannot be advanced — the pipe cannot surrender a byte before
# OwnTone releases it — so the AirPlay leg is DELAYED by the same amount
# instead, using OwnTone's per-output `offset_ms` (positive = delay; see
# `OwnToneBackend.set_output_offset_ms` for the source citations).
#
# This constant is only the FALLBACK: 109 + 11 + 4 + ~6 ms of built-in device
# latency. The router measures the real thing per output device and pushes it
# via `sync.set_airplay_offset_ms`, which is what should normally be in force.
AIRPLAY_SYNC_OFFSET_DEFAULT_MS = 130

# Bounds for the offset knob. Identical to OwnTone's own accepted range so a
# field-tuning slider can use the full span without ever eliciting a 400.
AIRPLAY_SYNC_OFFSET_MIN_MS = OWNTONE_OFFSET_MIN_MS
AIRPLAY_SYNC_OFFSET_MAX_MS = OWNTONE_OFFSET_MAX_MS

# Per-output USER trim: how much the listener wants this one receiver held
# back relative to the others, to compensate its distance from where they sit
# (1 ms of air ~= 34 cm). Distinct from AIRPLAY_SYNC_OFFSET_DEFAULT_MS above,
# which is a SYSTEM correction cancelling the local leg's pipeline latency.
# The two ADD: an output carries `_airplay_offset_ms + trim`, and only the sum
# is clamped against OwnTone's own range, so a user trim can never push the
# composite outside what the REST layer accepts.
#
# The bound is on the NORMALISED value that crosses the wire, which is not
# the same number as the signed user range. `DeviceDelayTrim.rangeMs` on the
# Swift side is +-200 ms of signed intent; `DelayTrimNormalizer` slides the
# set up until the earliest speaker sits at 0, so the whole span can land on
# ONE output (-200 there, +200 here => 400 here). Bounding at 200 would have
# silently truncated exactly that case, moving a receiver 200 ms off what the
# user asked for with nothing logged — while the local leg, whose ring is
# sized for the full span (`LocalAirPlayBridge.defaultRingCapacityFrames`),
# honoured it.
#
# So: SPAN, not range. Still an ergonomic bound, not a safety bound —
# `clamp_output_offset_ms` remains the safety bound on the composite.
OUTPUT_TRIM_LIMIT_MS = 400

# Trim assumed for an output the user has never touched. Explicit so an
# unknown output id can never inherit a neighbour's value.
OUTPUT_TRIM_DEFAULT_MS = 0

# Offsets are latched when an output's session is constructed and OwnTone
# refuses to change a live one (player.c:2937-2944), so re-tuning mid-stream
# means disable → pause → enable. This is how long we wait between the two
# REST calls, long enough for OwnTone to tear the session down and short
# enough to stay an unremarkable dropout.
AIRPLAY_OFFSET_RELATCH_PAUSE_S = 0.4

# Where the in-force offset value came from, for diagnostics/UI. Not a
# free-form string: the menubar keys off these.
OFFSET_SOURCE_DEFAULT = "default"
OFFSET_SOURCE_MEASURED = "router_measured"
OFFSET_SOURCE_MANUAL = "manual"


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


def _normalize_airplay_device_id(raw: Any) -> str | None:
    """Canonicalise a Bonjour `deviceid` into colon-free uppercase hex.

    Mirrors `Device.normalizedAirplayDeviceID` on the Swift side so both ends
    agree on the key. Returns None for anything that is not hex.
    """
    if not raw:
        return None
    text = str(raw).replace(":", "").replace("-", "").strip().upper()
    if not text:
        return None
    try:
        int(text, 16)
    except ValueError:
        return None
    return text


def _owntone_output_id_for(airplay_device_id: str | None) -> str | None:
    """OwnTone's output id for a receiver, derived from its `deviceid`.

    OwnTone parses the Bonjour `deviceid` MAC into a uint64 and uses it
    verbatim as the output id and as the `speakers` table primary key, so this
    conversion is exact rather than heuristic:
    ``int("0200CAFE0001", 16) == 2202428899329``.
    """
    if not airplay_device_id:
        return None
    try:
        return str(int(airplay_device_id, 16))
    except ValueError:
        return None


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
    # Stable AirPlay identity from the Bonjour TXT `deviceid` record, in
    # canonical hex form (e.g. "0200CAFE0001"). OwnTone derives its own
    # output id from exactly this value (`int(hex, 16)`), which makes it the
    # only reliable way to match a device to an OwnTone output. Display names
    # are NOT reliable: the live OwnTone database already contains two
    # different machines sharing one name.
    airplay_device_id: str | None = None
    last_state_emit: float = field(default_factory=time.monotonic)

    @property
    def pairing_key(self) -> str:
        """Key the menubar and the pairing coordinator agree on."""
        if self.airplay_device_id:
            return f"ap:{self.airplay_device_id}"
        return f"name:{self.name}"


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
        self._active_stream_device_ids: tuple[str, ...] | None = None
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
        # Layer 3 (residual offset): how far the AirPlay leg is delayed so it
        # lands together with the local leg, which trails by `L_local`. Only
        # meaningful in whole-home mode — see AIRPLAY_SYNC_OFFSET_DEFAULT_MS.
        self._airplay_offset_ms: int = clamp_output_offset_ms(
            AIRPLAY_SYNC_OFFSET_DEFAULT_MS,
        )
        self._airplay_offset_source: str = OFFSET_SOURCE_DEFAULT
        # SyncCast device id -> user delay trim (ms), added to
        # `_airplay_offset_ms` for that one output. Keyed by device id (the
        # same id `device.add` / `device.set_volume` use) rather than by
        # OwnTone output id, because the router knows devices and the
        # device->output mapping is ours to make. Non-negative by
        # construction: the Swift side normalises the signed user intent
        # before it reaches the wire.
        self._output_trim_ms: dict[str, int] = {}
        # OwnTone output id → offset we last wrote to it. OwnTone persists
        # `speakers.offset_ms` across restarts, so this is a record of what WE
        # put there, used to zero exactly those rows again on the way out. It
        # is never treated as authoritative for what OwnTone currently holds.
        self._applied_output_offsets: dict[str, int] = {}
        # OwnTone output id → offset we know a LIVE session is carrying.
        #
        # Distinct from `_applied_output_offsets` on purpose. That one records
        # what we wrote into OwnTone's database; this one records what an
        # output's playing session actually latched, which is only knowable
        # when we ourselves caused the session to be built — a genuine
        # off→on transition, or a relatch. An output that was ALREADY selected
        # when we wrote its offset keeps whatever its session latched earlier
        # (outputs/airplay.c:1598 copies the value at session construction and
        # player.c:2937-2944 refuses to touch a live one), so it deliberately
        # does NOT appear here. Absence means "unknown", which every consumer
        # must treat as "must be re-latched", never as "already correct".
        self._latched_output_offsets: dict[str, int] = {}
        # OwnTone output ids whose offset write FAILED. Their persisted value
        # is whatever a previous session left behind, so they still have to be
        # visited by the rollback sweep even though nothing of ours landed.
        self._offset_write_failures: set[str] = set()
        self._owntone_binary = owntone_binary
        self._owntone_config_template = owntone_config_template
        self._state_dir = state_dir
        # Background asyncio.Task that retries OwnTone-output discovery
        # for any device that wasn't found in time during start_stream.
        # See `_schedule_deferred_reconcile` for lifetime details.
        # Stored as Optional and lazily created — keeps __init__ free
        # of asyncio primitives that must live inside the running loop.
        self._deferred_reconcile_task: asyncio.Task[None] | None = None
        # Watch set + deadline SHARED with the running loop (one task at a
        # time). A new schedule UNIONS into this set rather than cancelling and
        # replacing the task with only its own ids — otherwise a just-paired
        # device's retry would evict a slower second receiver the loop is still
        # waiting on. See `_schedule_deferred_reconcile`.
        self._deferred_reconcile_targets: set[str] = set()
        self._deferred_reconcile_deadline: float = 0.0
        # Optional PairingCoordinator, injected by the server after both
        # objects exist. None in tests and in any build without pairing.
        self._pairing: Any = None

    def _get_lock(self) -> asyncio.Lock:
        if self._lock is None:
            self._lock = asyncio.Lock()
        return self._lock

    async def shutdown(self) -> None:
        async with self._get_lock():
            await self._stop_streaming_unlocked()
            # Retire any Layer-3 offset while OwnTone is still answering
            # REST. It lives in `speakers.offset_ms` and outlives the
            # process, so leaving it set would silently skew the next
            # session (including a plain stereo one).
            self._clear_airplay_offsets_unlocked()
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
        airplay_device_id = _normalize_airplay_device_id(
            params.get("airplay_device_id"),
        )
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
                if airplay_device_id:
                    existing.airplay_device_id = airplay_device_id
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
                return {
                    "connected": True,
                    "reported_latency_ms": DEVICE_REPORTED_LATENCY_MS,
                }
            dev = Device(
                id=device_id,
                transport=transport,
                host=host,
                port=port,
                name=name,
                state="added",
                airplay_device_id=airplay_device_id,
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
                "device_id": device_id, "state": "added",
                "buffer_ms": DEVICE_REPORTED_LATENCY_MS,
            })
            return {
                "connected": True,
                "reported_latency_ms": DEVICE_REPORTED_LATENCY_MS,
            }

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
            requested_stream = tuple(sorted(device_ids))
            if (
                self._streaming
                and self._active_stream_device_ids == requested_stream
                and self._owntone is not None
                and self._audio_reader is not None
                and self._owntone.is_alive()
            ):
                logger.info(
                    "start_stream_noop",
                    extra={
                        "device_ids": list(requested_stream),
                        "reason": "same active set",
                    },
                )
                return {
                    "started": True,
                    "device_count": len(device_ids),
                    "noop": True,
                }
            await self._ensure_owntone()
            await self._reconcile_outputs(device_ids)
            await self._ensure_audio_reader(audio_socket)
            if self._broadcaster is not None:
                self._broadcaster.reset()
            self._owntone.play_pipe()
            self._active_stream_device_ids = requested_stream
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
                if self._broadcaster is not None:
                    self._broadcaster.reset()
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
                # Direction B: the broadcaster reads OwnTone's OUTPUT fifo
                # itself (`LocalFifoBroadcaster._run_broadcaster`), so there is
                # no pre-OwnTone tee to wire. The local leg therefore rides
                # OwnTone's single player clock, in lockstep with the AirPlay
                # outputs.
            else:  # stereo
                # Layer 3 rollback. The local leg leaves the fifo→bridge
                # chain here, so its `L_local` no longer exists and any
                # AirPlay delay compensating for it becomes pure error.
                # OwnTone persists the value, so it has to be retired
                # explicitly rather than left to expire with the session.
                self._clear_airplay_offsets_unlocked()
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

    # ---------- Layer 3: residual AirPlay offset ----------

    @staticmethod
    def _resolved_output_id(dev: Device) -> str | None:
        """The OwnTone output id a device is known to map to, or None.

        Two sources, in order of authority:

        1. `dev.owntone_output_id`, stamped by `_reconcile_outputs` from the
           output it ACTUALLY matched. That path falls back to name matching
           for receivers whose Bonjour record carried no `deviceid`
           (`_match_output`), so this is the only source that covers them.
        2. The `int(deviceid_hex, 16)` derivation, for a device that has a
           `deviceid` but has not been through a reconcile yet.

        Using (2) alone is what made a name-matched receiver's trim
        unreachable: it resolved to None, never equalled any output id, and
        the trim silently read back as 0 while every diagnostic reported it
        as in force.
        """
        if dev.owntone_output_id:
            return str(dev.owntone_output_id)
        return _owntone_output_id_for(dev.airplay_device_id)

    def _trim_ms_for_output(self, output_id: str) -> int:
        """The user's delay trim for the device behind an OwnTone output id.

        Returns ``OUTPUT_TRIM_DEFAULT_MS`` when no device claims the output,
        which is the honest answer for the fifo output and for anything
        discovered outside SyncCast. A trim that belongs to a device we cannot
        map to ANY output is a silent 0, so it is logged once per call site
        rather than swallowed.
        """
        unresolved: list[str] = []
        for dev_id, dev in self._devices.items():
            trim = self._output_trim_ms.get(dev_id)
            if trim is None:
                continue
            resolved = self._resolved_output_id(dev)
            if resolved is None:
                unresolved.append(dev_id)
                continue
            if resolved == output_id:
                return trim
        if unresolved:
            logger.warning(
                "output_trim_unresolved_device",
                extra={"device_ids": unresolved, "owntone_output_id": output_id},
            )
        return OUTPUT_TRIM_DEFAULT_MS

    def _target_airplay_offset_ms(self, output_id: str | None = None) -> int:
        """The offset an AirPlay output should be carrying right now.

        Only whole-home mode routes local audio through the fifo → broadcaster
        → bridge chain, so only whole-home mode has an `L_local` to cancel. In
        stereo mode the correct value is 0: delaying AirPlay there would skew
        an otherwise-fine AirPlay-only stream against nothing.

        With `output_id` given, the user's per-output trim is ADDED to the
        system correction and the SUM is clamped, so the composite always
        stays inside the range OwnTone's REST layer accepts. Without it the
        base correction alone is returned — that is the "what is the system
        asking for" number `airplay_offset_state` reports, and the reason the
        parameter is optional rather than required.
        """
        if self._mode != "whole_home":
            return 0
        if output_id is None:
            return self._airplay_offset_ms
        return clamp_output_offset_ms(
            self._airplay_offset_ms + self._trim_ms_for_output(output_id),
        )

    def _push_output_offset(self, output_id: str, offset_ms: int) -> bool:
        """Write one output's offset, recording what we wrote.

        Unconditional by design. The value is persisted in OwnTone's
        `speakers` table and survives a graceful restart, so we never infer it
        from a previous session — every enable rewrites it and every disable
        zeroes it. That makes the whole feature idempotent and self-cleaning.

        Returns True when the write landed. Failures are logged and reported,
        not raised: an output playing a few ms off is a far better outcome
        than an output that never gets enabled. A failed write is REMEMBERED
        (`_offset_write_failures`) rather than forgotten, because that output
        is precisely the one that may still be carrying a stale persisted
        offset — dropping it here would exclude it from the rollback sweep and
        leave that stale row behind forever.
        """
        if self._owntone is None:
            return False
        try:
            applied = self._owntone.set_output_offset_ms(output_id, offset_ms)
        except Exception:  # noqa: BLE001
            logger.exception(
                "airplay_offset_set_failed",
                extra={"owntone_output_id": output_id, "offset_ms": offset_ms},
            )
            self._offset_write_failures.add(output_id)
            self._applied_output_offsets.pop(output_id, None)
            # The session's value is now unknowable, so it must not be
            # reported as latched — see `_latched_output_offsets`.
            self._latched_output_offsets.pop(output_id, None)
            return False
        self._offset_write_failures.discard(output_id)
        if applied:
            self._applied_output_offsets[output_id] = applied
        else:
            self._applied_output_offsets.pop(output_id, None)
        logger.info(
            "airplay_offset_set",
            extra={
                "owntone_output_id": output_id,
                "offset_ms": applied,
                "source": self._airplay_offset_source,
                "mode": self._mode,
            },
        )
        return True

    def _clear_airplay_offsets_unlocked(self) -> None:
        """Zero every offset this process wrote. Caller holds the lock.

        The rollback path. Called on the way out of whole-home mode and on
        shutdown so a value computed for one session can never linger in
        OwnTone's database and silently skew the next one.

        Outputs whose write FAILED are swept too. They were never recorded as
        applied, but a failure is not evidence that the row is clean — it is
        evidence that we do not know what is in it.
        """
        for output_id in sorted(
            set(self._applied_output_offsets) | self._offset_write_failures
        ):
            self._push_output_offset(output_id, 0)
        self._applied_output_offsets.clear()
        self._offset_write_failures.clear()
        # Zeroing the database row does not rebuild a live session, so nothing
        # is known to be latched any more.
        self._latched_output_offsets.clear()

    def airplay_offset_state(self) -> dict[str, Any]:
        """Current Layer-3 offset state, for diagnostics and the UI."""
        return {
            "offset_ms": self._airplay_offset_ms,
            "effective_offset_ms": self._target_airplay_offset_ms(),
            "source": self._airplay_offset_source,
            "mode": self._mode,
            "min_offset_ms": AIRPLAY_SYNC_OFFSET_MIN_MS,
            "max_offset_ms": AIRPLAY_SYNC_OFFSET_MAX_MS,
            "default_offset_ms": AIRPLAY_SYNC_OFFSET_DEFAULT_MS,
            # Per-output USER trim (device id -> ms) and the composite it
            # produces (OwnTone output id -> ms). Both are diagnostics: the
            # first is what the human asked for, the second is what each
            # output should be carrying once the system correction is added.
            "output_trims_ms": dict(self._output_trim_ms),
            "effective_offset_by_output_ms": {
                output_id: self._target_airplay_offset_ms(output_id)
                for output_id in sorted(
                    set(self._applied_output_offsets)
                    | set(self._latched_output_offsets)
                )
            },
            "max_output_trim_ms": OUTPUT_TRIM_LIMIT_MS,
            "applied": dict(self._applied_output_offsets),
            # Per-output truth: what a LIVE session is known to carry. The
            # router seeds its "has anything changed?" deadband from this and
            # NOT from `effective_offset_ms`, which is only our intent — an
            # output that was already selected before we wrote its offset is
            # absent here, and that absence is what forces the re-latch.
            "latched": dict(self._latched_output_offsets),
            "write_failures": sorted(self._offset_write_failures),
        }

    async def set_airplay_offset_ms(
        self,
        offset_ms: int,
        source: str = OFFSET_SOURCE_MANUAL,
        relatch: bool = True,
    ) -> dict[str, Any]:
        """Set how far the AirPlay leg is delayed, and re-latch live outputs.

        `offset_ms` is `L_local`: how far the LOCAL leg trails, hence how far
        AirPlay must be held back to meet it. Positive delays AirPlay.

        OwnTone latches the offset when an output's session is built and
        refuses to change a playing one, so `relatch=True` cycles each
        currently-selected output (disable, brief pause, enable) to make the
        new value take. That costs a short dropout on the AirPlay receivers,
        which is why the caller can turn it off when it is about to enable the
        outputs anyway.

        Idempotent in effect as well as in value: an output already known to
        be carrying `target` in its live session is NOT cycled, because the
        relatch is an audible dropout on every receiver and re-sending the
        current value (a retried RPC, a UI refresh) must not cost one. An
        output we have no latched record for is cycled — absence means the
        session's value is unknown, not that it is already right.

        Call with 0 to retire the correction entirely.
        """
        applied = clamp_output_offset_ms(offset_ms)
        async with self._get_lock():
            self._airplay_offset_ms = applied
            self._airplay_offset_source = source
            relatched, unchanged = await self._reapply_output_offsets_unlocked(
                relatch=relatch,
            )
            state = self.airplay_offset_state()
        state["relatched"] = relatched
        state["unchanged"] = unchanged
        return state

    async def set_output_trims_ms(
        self,
        trims_ms: dict[str, int],
        relatch: bool = True,
    ) -> dict[str, Any]:
        """Replace the per-output user delay trims and re-latch what changed.

        `trims_ms` maps SyncCast device id -> milliseconds of extra delay for
        that one receiver. It is a FULL REPLACEMENT, not a patch: an id the
        caller omits goes back to `OUTPUT_TRIM_DEFAULT_MS`. That is what makes
        "reset all trims" a single call and makes the feature self-cleaning —
        there is no way to leave a forgotten trim behind by dropping a key.

        Values are non-negative by contract (the Swift side normalises signed
        user intent so the earliest speaker sits at 0 and nothing has to play
        early); a negative value is still accepted and clamped here rather
        than trusted, and the composite with `_airplay_offset_ms` is clamped
        again against OwnTone's own range.

        Idempotent: an output whose composite is unchanged is not cycled, so
        re-sending the current map costs nobody a dropout. Changing one costs
        that receiver a ~`AIRPLAY_OFFSET_RELATCH_PAUSE_S` gap, which is
        inherent to OwnTone latching the offset at session construction.
        """
        cleaned: dict[str, int] = {}
        for dev_id, raw in trims_ms.items():
            value = max(-OUTPUT_TRIM_LIMIT_MS, min(int(raw), OUTPUT_TRIM_LIMIT_MS))
            if value != OUTPUT_TRIM_DEFAULT_MS:
                cleaned[str(dev_id)] = value
        async with self._get_lock():
            self._output_trim_ms = cleaned
            relatched, unchanged = await self._reapply_output_offsets_unlocked(
                relatch=relatch,
            )
            state = self.airplay_offset_state()
        state["relatched"] = relatched
        state["unchanged"] = unchanged
        return state

    async def _reapply_output_offsets_unlocked(
        self, relatch: bool,
    ) -> tuple[list[str], list[str]]:
        """Write every selected AirPlay output's composite offset.

        Caller holds the lock. Returns (relatched, unchanged) output ids.

        The composite is recomputed PER OUTPUT because the user trim is
        per-output; the system correction it is added to is global. Writing is
        unconditional (see `_push_output_offset` — the database row is ours to
        own), but CYCLING is not: only an output whose live session is known
        to be carrying something other than the new composite is disturbed. An
        output with no latched record is cycled, because absence means "we do
        not know", never "already correct".
        """
        relatched: list[str] = []
        unchanged: list[str] = []
        if self._owntone is None:
            return relatched, unchanged
        for output_id in self._selected_airplay_output_ids_unlocked():
            target = self._target_airplay_offset_ms(output_id)
            latched = self._latched_output_offsets.get(output_id)
            self._push_output_offset(output_id, target)
            if not relatch:
                continue
            if latched == target:
                unchanged.append(output_id)
                continue
            await self._relatch_output_unlocked(output_id, target)
            relatched.append(output_id)
        return relatched, unchanged

    def _selected_airplay_output_ids_unlocked(self) -> list[str]:
        """OwnTone ids of the currently-selected non-fifo outputs.

        The fifo output is excluded on purpose: it is the LOCAL leg, and this
        knob only ever moves the AirPlay leg. Returns an empty list when the
        output list cannot be read — the caller then simply changes nothing.
        """
        if self._owntone is None:
            return []
        try:
            outputs = self._owntone.list_outputs()
        except Exception:  # noqa: BLE001
            logger.exception("airplay_offset_list_outputs_failed")
            return []
        ids: list[str] = []
        for o in outputs:
            if o.get("type") == "fifo":
                continue
            if not o.get("selected"):
                continue
            output_id = str(o.get("id", ""))
            if output_id:
                ids.append(output_id)
        return ids

    async def _relatch_output_unlocked(
        self, output_id: str, offset_ms: int,
    ) -> None:
        """Stop and restart one output so a new offset takes effect.

        Necessary because `player.c:2937-2944` will not apply a new offset to
        a session that is already playing; only a fresh session reads it
        (outputs/airplay.c:1598). Caller holds the lock.

        `offset_ms` is what the rebuilt session will latch, recorded on
        success. On failure the record is dropped instead of guessed at: a
        half-completed cycle leaves the session in a state we cannot name, and
        the next push must re-latch rather than skip.
        """
        if self._owntone is None:
            return
        try:
            self._owntone.set_output_enabled(output_id, False)
            await asyncio.sleep(AIRPLAY_OFFSET_RELATCH_PAUSE_S)
            self._owntone.set_output_enabled(output_id, True)
        except Exception:  # noqa: BLE001
            logger.exception(
                "airplay_offset_relatch_failed",
                extra={"owntone_output_id": output_id},
            )
            self._latched_output_offsets.pop(output_id, None)
            return
        self._latched_output_offsets[output_id] = offset_ms

    async def flush(self) -> dict[str, Any]:
        if self._broadcaster is not None:
            self._broadcaster.reset()
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
            if self._audio_reader is not None:
                self._audio_reader.stop()
                self._audio_reader = None
            if self._broadcaster is not None:
                try:
                    self._broadcaster.stop()
                except Exception:  # noqa: BLE001
                    logger.exception("broadcaster_stop_failed")
                self._broadcaster = None
            # Drop fd / state but don't await stop() — proc is already gone.
            self._owntone = None
            # Reset every device's owntone_output_id; OwnTone reassigns
            # them on each launch, so the cached IDs are stale.
            for dev in self._devices.values():
                dev.owntone_output_id = None
            # Same reasoning for the fifo output id we cached for
            # whole-home mode — it's per-OwnTone-process.
            self._fifo_output_id = None
            self._active_stream_device_ids = None
            self._streaming = False
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
        if self._mode == "whole_home":
            self._ensure_broadcaster()

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
        # Direction B: no tee. The broadcaster reads OwnTone's OUTPUT fifo
        # directly, so the reader only ever feeds OwnTone's input.

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

        by_id = self._index_outputs_by_owntone_id(outputs)
        for dev_id, dev in self._devices.items():
            match = self._match_output(dev, by_id, by_name)
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

        NOTE: names collide. The live OwnTone database on the development
        machine already holds two different speakers sharing one name, and a
        dict comprehension silently keeps whichever it saw last. Prefer
        `_index_outputs_by_owntone_id`; this remains as the fallback for
        endpoints whose Bonjour record carried no `deviceid`.
        """
        return {str(o.get("name", "")).lower(): o for o in outputs}

    def _index_outputs_by_owntone_id(
        self, outputs: list[dict[str, Any]],
    ) -> dict[str, dict[str, Any]]:
        """Build an OwnTone-output-id → output dict.

        Contrary to the older comment in `_ensure_owntone`, AirPlay output ids
        are NOT reassigned on each OwnTone launch: OwnTone derives them from
        the receiver's `deviceid` MAC and stores them as the `speakers` table
        primary key, so they are stable across restarts. (The fifo output is
        the exception — its id is a local counter.)
        """
        return {str(o.get("id", "")): o for o in outputs}

    def _match_output(
        self,
        dev: Device,
        by_id: dict[str, dict[str, Any]],
        by_name: dict[str, dict[str, Any]],
    ) -> dict[str, Any] | None:
        """Resolve a device to its OwnTone output, id first, name second."""
        owntone_id = _owntone_output_id_for(dev.airplay_device_id)
        if owntone_id is not None:
            match = by_id.get(owntone_id)
            if match is not None:
                return match
        return by_name.get(dev.name.lower())

    def resolve_pairing_output(self, device_key: str) -> tuple[str, bool] | None:
        """Map a pairing key to (owntone_output_id, needs_authorization).

        Returns None when the receiver is not currently visible to OwnTone,
        which the coordinator reports as a plain "not visible right now"
        rather than as a pairing failure.
        """
        dev = next(
            (d for d in self._devices.values() if d.pairing_key == device_key), None,
        )
        if dev is None or self._owntone is None:
            return None
        try:
            outputs = self._owntone.list_outputs()
        except Exception:
            logger.warning("pairing_resolve_list_failed")
            return None
        match = self._match_output(
            dev,
            self._index_outputs_by_owntone_id(outputs),
            self._index_outputs_by_name(outputs),
        )
        if match is None:
            return None
        return str(match.get("id", "")), bool(match.get("needs_auth_key", False))

    def schedule_pairing_retry(self, device_key: str) -> None:
        """Re-apply the output state for a receiver that just finished pairing.

        The original enable was refused because `needs_auth_key` was set, and
        that refusal returns before the device is added to any watch set — so
        neither the deferred-reconcile loop nor anything on the Swift side
        ever comes back to it. This is the only path that does.
        """
        dev_entry = next(
            (
                (dev_id, dev)
                for dev_id, dev in self._devices.items()
                if dev.pairing_key == device_key
            ),
            None,
        )
        if dev_entry is None:
            logger.info("pairing_retry_unknown_device", extra={"device_key": device_key})
            return
        dev_id, _dev = dev_entry
        # Reuse the existing deferred-reconcile machinery rather than issuing
        # REST calls from the pairing task: it already takes the manager lock,
        # re-lists OwnTone's outputs (needed, because `needs_auth_key` has
        # just changed) and gives up after a bounded wait.
        self._schedule_deferred_reconcile({dev_id})

    def set_pairing_coordinator(self, coordinator: Any) -> None:
        """Inject the pairing coordinator so reconcile can report that a
        receiver needs pairing. Optional: the manager works without it."""
        self._pairing = coordinator

    def _notify_pairing_required(self, dev: Device) -> None:
        coordinator = getattr(self, "_pairing", None)
        if coordinator is None:
            return
        coordinator.note_authorization_required(dev.pairing_key, True)

    @property
    def owntone_backend(self) -> Any:
        """The running OwnTone backend, or None when it has not started."""
        return self._owntone

    @property
    def owntone_pid(self) -> int | None:
        """pid of the OwnTone child process, if one is running."""
        if self._owntone is None:
            return None
        pid = getattr(self._owntone, "pid", None)
        return int(pid) if pid else None

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
        # OwnTone already tells us whether a receiver demands a credential we
        # do not hold (`needs_auth_key = requires_auth AND auth_key IS NULL`).
        # Enabling anyway makes OwnTone return HTTP 400, which used to surface
        # as an opaque "connection failed". Report it as what it is so the UI
        # can offer the pairing flow.
        if should_enable and bool(output.get("needs_auth_key", False)):
            self._notify_pairing_required(dev)
            self._notify_conn_state(
                dev_id, "failed", reason="this receiver needs to be paired first",
            )
            return
        try:
            if should_enable:
                self._notify_conn_state(dev_id, "connecting")
            # Layer 3: the offset MUST precede the enable. OwnTone copies
            # `device->offset_ms` into the session when it builds it
            # (outputs/airplay.c:1598) and refuses to change a live one
            # (player.c:2937-2944), so writing it afterwards would take
            # effect only on the NEXT enable. On the disable path we write 0
            # so a receiver the user turned off never keeps a correction it
            # is no longer part of — the value is persisted by OwnTone.
            target_offset_ms = (
                self._target_airplay_offset_ms(output_id) if should_enable else 0
            )
            was_selected = bool(output.get("selected", False))
            offset_written = self._push_output_offset(output_id, target_offset_ms)
            self._owntone.set_output_enabled(output_id, should_enable)
            # Only a genuine off→on transition builds a fresh session, and only
            # a fresh session reads the offset we just wrote. Enabling an
            # already-selected output is a no-op inside OwnTone, so its session
            # keeps whatever it latched earlier — record nothing, and the next
            # `set_airplay_offset_ms` will cycle it instead of assuming it is
            # already right. This is the case that used to leave a receiver
            # that was live before whole-home started ~L_local ahead of the
            # local leg for the whole session.
            if should_enable and offset_written and not was_selected:
                self._latched_output_offsets[output_id] = target_offset_ms
            else:
                self._latched_output_offsets.pop(output_id, None)
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
        # MERGE into the shared watch set rather than cancel+replace. An
        # in-flight loop reads `_deferred_reconcile_targets` in place, so
        # unioning here means a pairing retry (or a second toggle) ADDS its
        # device without evicting the ones already being watched. Previously
        # this cancelled the task and replaced its set with only the new ids,
        # so enabling Mac mini + Xiaomi together and finishing the mini's PIN
        # first silently dropped the slower Xiaomi's discovery retry.
        self._deferred_reconcile_targets |= set(target_ids)
        # (Re)extend the discovery window so late-added targets get a full
        # deadline rather than inheriting an almost-expired one.
        self._deferred_reconcile_deadline = time.monotonic() + 30.0
        prior = getattr(self, "_deferred_reconcile_task", None)
        if prior is not None and not prior.done():
            # The running loop will pick up the enlarged set on its next poll.
            return
        task = asyncio.create_task(self._deferred_reconcile_loop())
        self._deferred_reconcile_task = task

    async def _deferred_reconcile_loop(self) -> None:
        """Loop body for the background reconcile.

        Polls OwnTone's outputs every ~1.5s until the shared deadline. When a
        target's output finally appears, takes the device-manager lock briefly,
        applies the enable, and removes the target from the shared watch set
        (`_deferred_reconcile_targets`). Stops once the watch set is empty. The
        set and deadline are shared with `_schedule_deferred_reconcile` so a
        concurrent schedule can extend both without cancelling this task.
        """
        targets = self._deferred_reconcile_targets
        try:
            while targets and time.monotonic() < self._deferred_reconcile_deadline:
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
                for dev_id in list(targets):
                    self._notify_conn_state(
                        dev_id, "failed",
                        reason="OwnTone never discovered receiver",
                    )
                # Clear the timed-out ids from the shared set so a later
                # schedule starts from a clean slate rather than reviving them.
                targets.clear()
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
        # Drop the shared watch set so a fresh stream doesn't inherit ids from
        # the stopped session.
        self._deferred_reconcile_targets.clear()
        if self._audio_reader is not None:
            self._audio_reader.stop()
            self._audio_reader = None
        if self._broadcaster is not None:
            self._broadcaster.reset()
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
        self._active_stream_device_ids = None
