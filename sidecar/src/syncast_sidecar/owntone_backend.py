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
  PUT  /api/outputs/{id}  {"volume": N}        set 0..100
  PUT  /api/outputs/{id}  {"pin": "1234"}      submit an AirPlay pairing PIN
  PUT  /api/outputs/{id}  {"offset_ms": N}     per-output playback offset
                                               (positive = delay; see
                                               `set_output_offset_ms`)
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
import sqlite3
import subprocess
import time
from pathlib import Path
from typing import Any
from urllib import error as urlerror
from urllib import request as urlrequest

from . import log

logger = log.get("sidecar.owntone")

# Default ceiling for a loopback REST round trip to our own OwnTone. Every
# ordinary endpoint answers in milliseconds; anything slower is a fault.
REST_TIMEOUT_S = 2.0
# PUT /api/outputs/{id} with a PIN is the one exception. OwnTone handles it
# SYNCHRONOUSLY: `player_speaker_authorize` blocks on `commands_exec_sync`
# while `airplay_device_authorize` runs a full AirPlay pair-setup (SRP plus
# three RTSP round trips), and OwnTone's own RTSP layer budgets 10 s to
# connect and 15 s per exchange. Holding this call to the ordinary 2 s cap
# aborts pairings that are proceeding normally — and the client then reports
# a correct PIN as rejected while the receiver may in fact have paired.
PAIRING_REST_TIMEOUT_S = 30.0

# OwnTone's output buffer duration (the `start_buffer_ms` default in
# owntone-server/src/conffile.c:79). This is the single most important
# timing anchor for whole-home sync: every output rides it. An AirPlay-2
# receiver (e.g. the Xiaomi Sound) plays each sample at
# `pts + OWNTONE_OUTPUT_BUFFER_DURATION_MS`, PTP-locked to the player
# clock; the fifo output module releases the SAME byte to the pipe at
# `pts + OWNTONE_OUTPUT_BUFFER_DURATION_MS + fifo_offset_ms`
# (outputs/fifo.c:262 `delay = outputs_buffer_duration_ms_get() +
# device->offset_ms`, verified against source). So with a zero broadcaster
# delay the local leg trails the AirPlay leg only by the local pipeline
# latency `L_local`; a NEGATIVE fifo offset advances it to close that gap.
OWNTONE_OUTPUT_BUFFER_DURATION_MS = 2250

# Local pipeline latency estimate `L_local`: the delay from the fifo pipe
# releasing a byte to that audio leaving the local speaker. It is the
# steady ring fill the Layer-2 PLL holds (backoff ≈ 109 ms) plus the AUHAL
# output presentation latency (device `kAudioDevicePropertyLatency` +
# buffer frames + safety offset, tens of ms). Determinate in origin, but
# device-dependent in exact value — TUNE against a cross-correlation of the
# two speakers' arrivals on real hardware (see the FinalGate checklist).
#
# SUPERSEDED as a control value. The residual is now cancelled by DELAYING
# the AirPlay leg through OwnTone's per-output `offset_ms` REST channel
# (`set_output_offset_ms` below, driven by
# `device_manager.AIRPLAY_SYNC_OFFSET_DEFAULT_MS` and by the router's own
# measurement). This constant survives as the historical estimate and as
# the basis for `LOCAL_FIFO_OFFSET_MS`.
LOCAL_PIPELINE_LATENCY_MS = 120

# Per-output fifo timing offset. NEGATIVE would advance the pipe release
# earlier so the local leg's mean offset lands near the AirPlay leg instead
# of `+L_local` behind it.
#
# NOT EMITTED ANYWHERE, and must not be: writing `offset_ms` into the
# `fifo {}` config block kills OwnTone outright on an unpatched build (see
# the warning in `_write_config`), and the shipped binary IS unpatched. The
# equivalent effect is available without that risk through the REST channel
# (`PUT /api/outputs/{fifo_id} {"offset_ms": -N}`), which any build honours.
# We nonetheless correct the residual on the AIRPLAY side instead: one
# receiver-independent value, no exposure to the unsigned-wraparound bug in
# `outputs/fifo.c:263`, and it leaves the local leg's timing untouched.
LOCAL_FIFO_OFFSET_MS = -LOCAL_PIPELINE_LATENCY_MS

# Hard range OwnTone's player enforces on a per-speaker playback offset.
# `speaker_offset_ms_set` (owntone-server/src/player.c:2930) rejects anything
# outside -2000..2000 outright, which the REST layer turns into an opaque
# HTTP 400. We clamp on this side so a tuning knob can never produce one.
OWNTONE_OFFSET_LIMIT_MS = 2000

# Floor for a NEGATIVE offset, tightened below the player's own limit for the
# fifo output's sake. `outputs/fifo.c:262-266` computes
# `uint64_t delay_ms = outputs_buffer_duration_ms_get(); delay_ms +=
# device->offset_ms;` — the guard on line 263 (`delay_ms + device->offset_ms
# < 0`) is DEAD CODE, because C promotes the signed `offset_ms` to uint64_t
# before the comparison. An offset more negative than the buffer duration
# therefore wraps to ~1.8e19 ms of delay and the local leg goes silent
# forever with nothing in the log. `min()` here means the player's ±2000
# limit is what actually binds today; the fifo term is kept explicit so the
# invariant survives a future change to either constant.
OWNTONE_OFFSET_MIN_MS = -min(
    OWNTONE_OFFSET_LIMIT_MS, OWNTONE_OUTPUT_BUFFER_DURATION_MS - 1,
)
OWNTONE_OFFSET_MAX_MS = OWNTONE_OFFSET_LIMIT_MS


def clamp_output_offset_ms(offset_ms: int) -> int:
    """Clamp a per-output offset into the range OwnTone will actually accept.

    Single source of truth for the bound, so the REST client, the device
    manager and the JSON-RPC layer cannot drift apart on it.
    """
    return max(OWNTONE_OFFSET_MIN_MS, min(OWNTONE_OFFSET_MAX_MS, int(offset_ms)))


class OwnToneError(RuntimeError):
    """A REST call to OwnTone failed.

    `code` carries the HTTP status when there was one, so callers can tell a
    genuine 4xx rejection apart from "the helper is not reachable" without
    parsing the message — and without importing this module.
    """

    def __init__(self, message: str, code: int | None = None) -> None:
        super().__init__(message)
        self.code = code


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
        # OwnTone's own database. It owns `speakers.auth_key`, which is where
        # a successful AirPlay pairing credential lives — and, as things
        # stand, the ONLY place it lives. Moving it would mean patching
        # OwnTone's C source, so instead the directory is kept owner-only
        # (see `_harden_state_dir`) rather than pretending a second copy
        # exists somewhere safer.
        self.db_path = self.state_dir / "songs.db"
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
        self._harden_state_dir()
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
        # Again, now that OwnTone has created `songs.db`. The first call could
        # only tighten what already existed, and on a first run the database
        # holding the pairing credentials is born 0644.
        self._harden_state_dir()
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

    @property
    def pid(self) -> int | None:
        """pid of the OwnTone child, or None when it is not running.

        Needed by the unified-clock-domain path: the capture tap must exclude
        every process in the SyncCast tree, not just the menubar app.
        """
        proc = self._proc
        if proc is None or proc.poll() is not None:
            return None
        return proc.pid

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
        written = 0
        view = memoryview(data)
        try:
            while written < len(data):
                n = os.write(fd, view[written:])
                if n <= 0:
                    break
                written += n
            return written
        except BrokenPipeError:
            logger.warning("fifo_broken_pipe")
            # Best-effort; if a concurrent caller already cleared this we
            # don't care.
            self._fifo_fd = None
            return written
        except OSError as e:
            # fd might have been reused by another part of the process; in
            # that case writes are silently sent elsewhere, but we cannot
            # detect it. The snapshot at the top minimizes the window.
            logger.warning("fifo_write_failed", extra={"errno": e.errno})
            return written

    # ---------- REST helpers ----------

    def list_outputs(self) -> list[dict[str, Any]]:
        return self._get("/api/outputs").get("outputs", [])

    def set_output_enabled(self, output_id: str, enabled: bool) -> None:
        self._put(f"/api/outputs/{output_id}", {"selected": enabled})

    def set_output_pin(self, output_id: str, pin: str) -> None:
        """Hand a pairing PIN to OwnTone for one output.

        Endpoint: PUT /api/outputs/{id} with body {"pin": "...."}. OwnTone
        routes that straight into ``player_speaker_authorize`` ->
        ``airplay_device_authorize``, which starts an AirPlay pair-setup
        sequence and, on success, persists the resulting credential in its
        own ``speakers.auth_key`` column.

        The PIN goes in the request BODY, never in the URL: OwnTone logs
        request paths at its default log level and that log file is
        world-readable inside Application Support.

        This call blocks for the whole pair-setup exchange, so it gets its
        own generous timeout rather than the ordinary REST ceiling.
        """
        self._put(
            f"/api/outputs/{output_id}",
            {"pin": pin},
            timeout_s=PAIRING_REST_TIMEOUT_S,
        )

    def _harden_state_dir(self) -> None:
        """Make the OwnTone state directory and database owner-only.

        `songs.db` holds long-lived AirPlay pairing credentials in cleartext,
        and OwnTone creates it 0644 inside a 0755 directory. Nothing else
        protects it, so tighten it on every start rather than relying on the
        enclosing `~/Library` being private.
        """
        for path, mode in ((self.state_dir, 0o700), (self.db_path, 0o600)):
            try:
                if path.exists():
                    path.chmod(mode)
            except OSError as e:
                logger.warning(
                    "state_dir_chmod_failed",
                    extra={"path": str(path), "error_kind": type(e).__name__},
                )

    def read_speaker_auth_key(self, output_id: str) -> str | None:
        """Read the stored AirPlay credential for one speaker.

        Returns None when there is none, when the database has not been
        created yet, or when it cannot be read. Callers must treat the value
        as a secret: it must never be logged, echoed in an error, or put on
        the wire in cleartext beyond the local 0600 control socket.
        """
        if not self.db_path.exists():
            return None
        try:
            with contextlib.closing(sqlite3.connect(str(self.db_path))) as conn:
                row = conn.execute(
                    "SELECT auth_key FROM speakers WHERE id = ?", (output_id,),
                ).fetchone()
        except sqlite3.Error as e:
            logger.warning(
                "speaker_auth_key_read_failed",
                extra={"error_kind": type(e).__name__},
            )
            return None
        if not row or not row[0]:
            return None
        return str(row[0])

    def set_output_volume(self, output_id: str, volume: float) -> None:
        # OwnTone uses 0..100; we accept 0.0..1.0.
        # Endpoint: PUT /api/outputs/{id} with body {volume: N}.
        # (Not /api/outputs/{id}/volume — that path returns HTTP 400.)
        v = max(0, min(100, int(round(volume * 100))))
        self._put(f"/api/outputs/{output_id}", {"volume": v})

    def set_output_offset_ms(self, output_id: str, offset_ms: int) -> int:
        """Set one output's playback offset. Returns the value actually sent.

        Endpoint: ``PUT /api/outputs/{id}`` with body ``{"offset_ms": N}``
        (httpd_jsonapi.c:1753-1757 → `player_speaker_offset_ms_set`; 204 on
        success, 400 on rejection). The JSON gate is `json_type_int`, so the
        value must be a real int — a float is silently ignored.

        SIGN — read off the source, not assumed:
          * docs/json-api.md: "positive value means delay", range -2000..2000.
          * fifo leg, outputs/fifo.c:262-266: `delay_ms =
            outputs_buffer_duration_ms_get(); delay_ms += device->offset_ms;`
            the pipe hands each byte over that much LATER.
          * AirPlay leg, outputs/airplay.c:1598 `session->offset_samples =
            device->offset_ms * rate / 1000` and outputs/airplay.c:2180
            `cur_stamp.pos -= session->offset_samples` inside
            `packets_sync_send`. The sync packet declares "RTP position `pos`
            happens at wall clock `ts`"; lowering `pos` while holding `ts`
            maps every sample to a LATER instant on the receiver.
        So POSITIVE delays an output and NEGATIVE advances it, consistently
        across output modules.

        LATCH TIMING: both modules copy `device->offset_ms` once, when their
        session is constructed, and player.c:2937-2944 explicitly declines to
        change a session that is already playing. Callers must therefore send
        the offset BEFORE the `selected: true` that starts the output;
        changing it afterwards requires a disable/enable cycle.

        PERSISTENCE: the value lands in the `speakers.offset_ms` column
        (db_init.c:157) on a graceful OwnTone shutdown (player.c:3924-3927),
        so it survives restarts. Never assume the stored value — always write
        the one you want, and write 0 to retire it.
        """
        applied = clamp_output_offset_ms(offset_ms)
        self._put(f"/api/outputs/{output_id}", {"offset_ms": applied})
        return applied

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
  # MUST be false. With autostart, OwnTone's pipe_watch_thread stamps
  # `pipe_autostart_id = pipe->id` and `inputs/pipe.c:play()` flags the
  # source as `is_autostarted=true`. On the first 0-byte read from
  # `audio.fifo` (cold-start race: AudioSocketWriter not connected yet,
  # or the source momentarily empty between SCK chunks) the player
  # autostops the source with `INPUT_FLAG_EOF` BEFORE the RAOP outputs
  # are spun up. Net effect: AirPlay session never starts even though
  # `set_output_enabled` succeeded on REST. Symptom: owntone.log shows
  # zero `raop` lines, AirPlay receivers play a single setup-burst
  # ("pop") and then go silent. We queue + start playback explicitly
  # via play_pipe(), so we don't need (and don't want) the library
  # scanner to autostart on its own.
  pipe_autostart = false
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
# NOTE: do NOT emit `offset_ms` here. OwnTone's `sec_fifo` option set
# (owntone-server/src/conffile.c) has no such key, and libconfuse treats an
# unknown option as FATAL, not as something to ignore:
#     config: [fifo:125] no such option 'offset_ms'
#     FATAL  config: Parse error in config file
#     FATAL  main: Config file errors; please fix your config
# OwnTone then exits before it even opens its logfile, so BOTH legs go
# silent (local and AirPlay) with no trace in owntone.log. Emitting this
# key is only valid against a patched OwnTone build that adds the option
# to sec_fifo and wires it into fifo_init; until such a build ships, the
# residual local-pipeline offset stays uncorrected (see
# LOCAL_FIFO_OFFSET_MS) and drift is handled by the Swift Layer-2 PLL.
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
        try:
            os.set_blocking(fd, True)
        except OSError:
            pass
        if getattr(self, "_fifo_logged_miss", False):
            logger.info("fifo_reader_attached")
            self._fifo_logged_miss = False

    def _url(self, path: str) -> str:
        return f"http://127.0.0.1:{self.rest_port}{path}"

    def _get(self, path: str) -> dict[str, Any]:
        return self._request("GET", path, None)

    def _post(self, path: str, body: Any) -> dict[str, Any]:
        return self._request("POST", path, body)

    def _put(
        self, path: str, body: Any, timeout_s: float | None = None,
    ) -> dict[str, Any]:
        return self._request("PUT", path, body, timeout_s=timeout_s)

    def _request(
        self, method: str, path: str, body: Any, timeout_s: float | None = None,
    ) -> dict[str, Any]:
        import json
        data = None if body is None else json.dumps(body).encode("utf-8")
        req = urlrequest.Request(
            self._url(path),
            data=data,
            method=method,
            headers={"Content-Type": "application/json"} if data else {},
        )
        try:
            with urlrequest.urlopen(  # noqa: S310
                req, timeout=timeout_s or REST_TIMEOUT_S,
            ) as resp:
                raw = resp.read()
                if not raw:
                    return {}
                return json.loads(raw)
        except urlerror.HTTPError as e:
            raise OwnToneError(f"owntone {method} {path}: {e}", code=e.code) from e
        except urlerror.URLError as e:
            raise OwnToneError(f"owntone {method} {path}: {e}") from e
        except TimeoutError as e:
            # urllib raises the read timeout from `getresponse()`, which sits
            # OUTSIDE its own OSError -> URLError conversion, so without this
            # clause a slow OwnTone escapes as a bare socket timeout that no
            # caller is written to expect.
            raise OwnToneError(f"owntone {method} {path}: timed out") from e

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
