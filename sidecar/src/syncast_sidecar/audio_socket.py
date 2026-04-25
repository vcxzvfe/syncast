"""Audio socket reader.

Two responsibilities live in this module:

1. **Inbound (Swift → OwnTone)**: ``AudioSocketReader`` accepts a single
   connection from the Swift router on a SOCK_STREAM Unix socket, reads
   1920-byte packets (480 frames × 2ch × 2B s16le @ 48 kHz), and forwards
   them straight into OwnTone's INPUT fifo (`audio.fifo`).

2. **Outbound (OwnTone → Swift bridges)**: ``LocalFifoBroadcaster`` reads
   OwnTone's OUTPUT fifo (configured via ``fifo {}`` in owntone.conf —
   44.1 kHz s16le 2ch, 1408-byte packets per
   ``owntone-server/src/outputs/fifo.c:41``) and fans the bytes out to N
   concurrently-connected Swift ``LocalAirPlayBridge`` clients on a
   broadcast Unix socket (multi-listen SOCK_STREAM). This is the
   "whole-home AirPlay mode" data plane: every local CoreAudio output
   AND every AirPlay receiver gets the same player-clock-driven PCM, so
   they all stay in lockstep.

   Backpressure policy: each client owns its OS send buffer. If a client
   falls behind (send buffer fills → ``EAGAIN``), the broadcaster drops
   chunks for *that client only* and bumps a per-client counter. Other
   clients are unaffected. This matches the snapcast / pulseaudio
   tunnel-sink approach: lockstep is maintained by the source clock
   (OwnTone's player), individual sinks may temporarily de-sync if the
   OS dispatches them late but the average rate keeps them aligned.
"""

from __future__ import annotations

import collections
import errno
import os
import socket
import threading
import time
from pathlib import Path
from typing import Callable

from . import log

logger = log.get("sidecar.audio_socket")

# Inbound packet size: matches AudioSocketWriter (Swift) — 480 frames
# stereo s16le. See core/router/Sources/SyncCastRouter/AudioSocketWriter.swift:14.
PACKET_BYTES = 480 * 2 * 2

# Outbound packet size: OwnTone's fifo output writes one packet at a time
# at this size. Hardcoded in owntone-server/src/outputs/fifo.c:41 as
# "352 samples/packet * 16 bit/sample * 2 channels". We mirror it here so
# every broadcast send corresponds to exactly one OwnTone packet boundary.
LOCAL_FIFO_CHUNK_BYTES = 352 * 2 * 2  # 1408

# Per-client SO_SNDBUF target. Sized for ~50 ms of 44.1 kHz s16le stereo
# (~8800 bytes), rounded up to a kernel-friendly boundary. Smaller buffers
# make us notice slow clients faster (drop chunks rather than building a
# multi-second backlog the receiver would still try to play); larger
# buffers tolerate occasional render-thread hiccups but mask real problems.
LOCAL_FIFO_CLIENT_SNDBUF = 16 * 1024

# Default broadcast-side delay for whole-home mode. AirPlay receivers
# play ~1800 ms behind capture (PTP-anchored playout); local CoreAudio
# bridges play ~50 ms behind. We hold each PCM packet inside the
# broadcaster for `default_delay_ms - bridge_latency` so both paths emit
# the SAME audio at the SAME wall-clock instant. Tuned empirically.
DEFAULT_LOCAL_FIFO_DELAY_MS = 1750

# Overflow tolerance: if the delay queue accumulates more than
# `delay + this margin` worth of pending audio, drop the OLDEST packets.
# At 100 pkt/s input this should never trip; it's purely a safety valve
# against a stuck pump thread (e.g. clock skew, GIL starvation under
# extreme load) creating unbounded memory growth.
LOCAL_FIFO_OVERFLOW_MARGIN_S = 0.5

# Pump-thread wait cap. We sleep until the next item is due, but never
# longer than this — keeps `stop_event` responsiveness sub-100ms even
# when the queue is empty or the next due-time is far in the future.
LOCAL_FIFO_PUMP_WAIT_CAP_S = 0.1


class AudioSocketReader:
    """Reads PCM packets from a SOCK_SEQPACKET socket on a worker thread."""

    def __init__(
        self,
        socket_path: Path,
        sink: Callable[[bytes], int],
        packet_bytes: int = PACKET_BYTES,
    ) -> None:
        self._path = socket_path
        self._sink = sink
        self._packet_bytes = packet_bytes
        # Optional tee callback the device manager can install when
        # whole-home mode is active; receives every PCM chunk just
        # after the OwnTone fifo write. None in stereo mode.
        self._broadcaster_tee: Callable[[bytes], None] | None = None
        self._thread: threading.Thread | None = None
        self._stop_event = threading.Event()
        self._listen_sock: socket.socket | None = None

    def start(self) -> None:
        if self._thread is not None and self._thread.is_alive():
            return
        self._stop_event.clear()
        self._listen()
        self._thread = threading.Thread(
            target=self._run, name="syncast-audio-socket", daemon=True,
        )
        self._thread.start()

    def set_broadcaster_tee(
        self, tee: Callable[[bytes], None] | None
    ) -> None:
        """Install or remove the whole-home broadcaster tee callback.

        Called by `device_manager.set_mode("whole_home")` after
        constructing a `LocalFifoBroadcaster`, with `tee=broadcaster.feed`.
        On switch back to stereo, called with `tee=None` to remove the
        link cleanly. The reader thread reads `_broadcaster_tee` once
        per recv and invokes it (if non-None); race-free because Python
        attribute writes are atomic w.r.t. the GIL.
        """
        self._broadcaster_tee = tee

    def stop(self) -> None:
        self._stop_event.set()
        sock = self._listen_sock
        self._listen_sock = None
        if sock is not None:
            try:
                sock.close()
            except OSError:
                pass
        if self._thread is not None:
            self._thread.join(timeout=2.0)
            self._thread = None
        # Mirror _listen()'s startup cleanup: remove the socket file we
        # bound to. Otherwise a re-start in the same sidecar process
        # would fail with EADDRINUSE on bind, AND a subsequent restart
        # of the whole sidecar would inherit a stale path that confuses
        # the Swift router's connect attempts.
        Path(self._path).unlink(missing_ok=True)

    def _listen(self) -> None:
        if self._path.exists():
            try:
                self._path.unlink()
            except OSError:
                pass
        # macOS does NOT support SOCK_SEQPACKET on Unix domain sockets
        # ([Errno 43] Protocol not supported). Use SOCK_STREAM and frame
        # by reading exact packet sizes — the producer side sends
        # `packet_bytes`-sized chunks, and we recv that many bytes per
        # iteration.
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.bind(str(self._path))
        os.chmod(self._path, 0o600)
        s.listen(1)
        self._listen_sock = s

    def _run(self) -> None:
        listen = self._listen_sock
        if listen is None:
            return
        listen.settimeout(1.0)
        client: socket.socket | None = None
        while not self._stop_event.is_set():
            if client is None:
                try:
                    client, _ = listen.accept()
                    client.settimeout(1.0)
                    logger.info("audio_client_connected")
                except socket.timeout:
                    continue
                except OSError:
                    return
            try:
                data = client.recv(self._packet_bytes * 4)
            except socket.timeout:
                continue
            except OSError:
                logger.info("audio_client_disconnected")
                client = None
                continue
            if not data:
                client = None
                continue
            written = self._sink(data)
            if written < len(data):
                logger.debug("fifo_short_write",
                             extra={"received": len(data), "written": written})
            # Tee the same PCM to the whole-home broadcaster (if any).
            # This is the post-b0543d5 architecture: bridges no longer
            # read OwnTone's fifo OUTPUT module (which had unfixable
            # multi-reader / self-flushing problems). Instead we deliver
            # Swift's native PCM straight to the bridges from here. Both
            # paths get the same bytes; AirPlay receivers go through
            # OwnTone (their PTP-anchored playout naturally aligns the
            # network destinations), bridges go through this tee.
            #
            # NB: this means local-bridge audio is roughly real-time
            # (~50 ms behind capture) while AirPlay receivers are ~1.8 s
            # behind. They're NOT in lockstep. Synchronization across
            # local + AirPlay in whole-home mode requires a separate
            # delay-line in the broadcaster (TODO P2). For now: bridges
            # get audio reliably, which is the user's primary ask.
            tee = self._broadcaster_tee
            if tee is not None:
                try:
                    tee(data)
                except Exception:  # noqa: BLE001
                    # Never let a broadcaster failure kill the OwnTone
                    # pipe writer — that would silence AirPlay too.
                    logger.exception("broadcaster_tee_failed")


class _BroadcastClient:
    """One connected ``LocalAirPlayBridge`` from the Swift side.

    Holds the per-client backlog counter and the negotiated send-buffer
    fd state. We deliberately keep this minimal — the broadcaster owns
    the transport, this struct is just the bookkeeping surface.
    """

    __slots__ = ("sock", "addr", "chunks_dropped", "last_drop_log_ns")

    def __init__(self, sock: socket.socket, addr: object) -> None:
        self.sock = sock
        self.addr = addr
        self.chunks_dropped: int = 0
        # We log the FIRST drop per client and then once every ~5 s so a
        # persistently-slow client doesn't spam the log at 31 packets/sec
        # (44.1 kHz / 1408 bytes-per-packet ≈ 31 Hz).
        self.last_drop_log_ns: int = 0


class LocalFifoBroadcaster:
    """Fans Swift PCM packets out to N ``LocalAirPlayBridge`` clients in
    lockstep with the AirPlay receivers.

    Lifecycle:

      * ``start()``  — open the listener Unix socket at ``socket_path``,
        spawn three threads:

          - ``listener``: blocking ``accept(2)`` loop; appends new
            ``_BroadcastClient`` instances to the registry.
          - ``broadcaster``: legacy placeholder thread (post-tee
            architecture; see ``_run_broadcaster`` for the long story).
          - ``delay-pump``: pops items from the delay queue when
            their wall-clock due-time arrives and calls
            ``_broadcast(packet)``. Always spawned so a runtime
            ``set_delay_ms(N)`` from a 0 baseline works without
            having to start a thread mid-flight; idle when the
            queue is empty (cheap condition wait).

      * ``stop()``  — closes the listener, closes the fifo fd, drains
        the delay queue, joins all threads (within 2 s), then
        forcefully closes every still-connected client socket.

    Client-side broadcasting is non-blocking. We set ``SO_SNDBUF`` low
    on each client socket (``LOCAL_FIFO_CLIENT_SNDBUF``) so a slow
    Swift bridge surfaces as ``EAGAIN`` instead of a kernel-level
    multi-megabyte backlog the receiver would still try to render.

    Delay line (whole-home wall-clock alignment):

      Local-bridge playback (Swift ``LocalAirPlayBridge`` → AUHAL)
      sits ~50 ms behind capture, while AirPlay receivers play ~1800 ms
      behind (PTP-anchored playout). Without compensation, bridges are
      ~1.7 s AHEAD of receivers — clearly audible echo across the room.
      We hold each packet inside the broadcaster for ``delay_ms`` (default
      1750 ms) before fanning out to bridges, so the same audio reaches
      both paths at the same wall-clock instant.

      The delay queue is bounded: if pending audio exceeds
      ``delay + LOCAL_FIFO_OVERFLOW_MARGIN_S`` (= 2.25 s by default) we
      drop the OLDEST packets and bump
      ``chunks_dropped_due_to_overflow``. That should never happen at
      steady state (input is 100 pkt/s, queue drains at the same rate);
      it's a safety valve against a stuck pump thread or clock skew.

      ``delay_ms == 0`` is the cheap path: ``feed()`` calls
      ``_broadcast`` synchronously and the pump thread doesn't run.
    """

    def __init__(
        self,
        socket_path: Path,
        fifo_path: Path,
        delay_ms: int = DEFAULT_LOCAL_FIFO_DELAY_MS,
    ) -> None:
        self._socket_path = socket_path
        self._fifo_path = fifo_path
        self._listen_sock: socket.socket | None = None
        self._fifo_fd: int | None = None
        self._listener_thread: threading.Thread | None = None
        self._broadcast_thread: threading.Thread | None = None
        self._delay_pump_thread: threading.Thread | None = None
        self._stop_event = threading.Event()
        # Set by the broadcaster thread once the OwnTone fifo open
        # succeeds (or fails). `start()` does NOT wait on this — see
        # docstring on start() for why we want non-blocking start.
        # Diagnostic readers can poll `is_set()` to learn whether the
        # broadcaster is actually pumping bytes yet.
        self._fifo_ready = threading.Event()
        # Client registry. Mutated only under `_clients_lock`. The
        # broadcaster takes a *snapshot* (list copy) under the lock and
        # then sends without holding the lock — keeps accept() unblocked
        # by a slow send().
        self._clients: list[_BroadcastClient] = []
        self._clients_lock = threading.Lock()
        # Delay-line state. Items are tuples of
        # (due_monotonic_s, enqueued_monotonic_s, packet_bytes). The
        # condition variable is signaled by `feed()` when a new item
        # arrives or by `stop()` when shutdown begins. Mutations to
        # `_delay_queue` and `_delay_seconds` happen under the
        # condition's underlying lock.
        self._delay_seconds = max(0.0, delay_ms / 1000.0)
        self._delay_cond = threading.Condition()
        self._delay_queue: collections.deque[tuple[float, float, bytes]] = (
            collections.deque()
        )
        # Diagnostics — read from the IPC layer for `state.report` etc.
        self.bytes_broadcast: int = 0
        self.chunks_broadcast: int = 0
        self.fifo_open_failures: int = 0
        # Counter for packets dropped by the bounded-queue safety valve
        # when pending audio exceeds `delay + overflow margin`.
        self.chunks_dropped_due_to_overflow: int = 0
        # Sliding scalar: time-from-feed-to-_broadcast for the most
        # recently delivered packet, in milliseconds. Lets the user (or
        # an automated check) verify that the delay is actually being
        # applied to within tens of milliseconds of `delay_ms`.
        self._actual_delivery_lag_ms: float = 0.0

    # ---------- diagnostics ----------

    @property
    def clients_connected(self) -> int:
        with self._clients_lock:
            return len(self._clients)

    @property
    def delay_ms(self) -> int:
        """Currently configured broadcast delay in milliseconds."""
        return int(round(self._delay_seconds * 1000.0))

    def set_delay_ms(self, delay_ms: int) -> int:
        """Update the broadcast delay at runtime.

        Negative values clamp to 0 (the synchronous cheap path).
        Returns the actually-applied value (after clamping).

        Switching to 0 *while* packets are queued causes those packets
        to drain naturally at their original due-times — we don't
        retroactively flush them, since flushing 1.7 s of audio at
        once would punch a transient through whatever bridge clients
        have. Switching FROM 0 to a positive value applies to all
        future ``feed()`` calls; in-flight packets (none, since the 0
        path is synchronous) are not affected.

        Thread-safe: takes the condition's underlying lock so the pump
        thread sees a consistent value on its next iteration. Wakes
        the pump so it re-evaluates its sleep budget against the new
        delay.
        """
        applied = max(0, int(delay_ms))
        with self._delay_cond:
            self._delay_seconds = applied / 1000.0
            self._delay_cond.notify_all()
        return applied

    def diagnostics(self) -> dict[str, object]:
        with self._clients_lock:
            per_client = [
                {"addr": str(c.addr), "chunks_dropped": c.chunks_dropped}
                for c in self._clients
            ]
        with self._delay_cond:
            pending_packets = len(self._delay_queue)
            delay_ms = int(round(self._delay_seconds * 1000.0))
            actual_lag_ms = self._actual_delivery_lag_ms
        return {
            "bytes_broadcast": self.bytes_broadcast,
            "chunks_broadcast": self.chunks_broadcast,
            "clients_connected": len(per_client),
            "fifo_open_failures": self.fifo_open_failures,
            "per_client": per_client,
            "delay_ms": delay_ms,
            "pending_packets": pending_packets,
            "chunks_dropped_due_to_overflow": (
                self.chunks_dropped_due_to_overflow
            ),
            "actual_delivery_lag_ms": actual_lag_ms,
        }

    # ---------- lifecycle ----------

    def start(self) -> None:
        """Spin up the listener + broadcaster threads. Non-blocking.

        The OwnTone output-fifo open used to happen synchronously here,
        but `start()` is called from `device_manager.set_mode("whole_home")`
        while the device manager holds its asyncio lock. The fifo open
        has a 5-second deadline (in case OwnTone has crashed), and
        blocking the asyncio task for 5 s freezes every other JSON-RPC
        request the sidecar is handling. We now defer the open into the
        broadcaster thread's first iteration. `start()` returns as soon
        as the threads have been spawned; readers that need to know
        whether the open succeeded can poll `_fifo_ready`.
        """
        if self._listener_thread is not None and self._listener_thread.is_alive():
            return
        self._stop_event.clear()
        self._fifo_ready.clear()
        self._open_listener()
        self._listener_thread = threading.Thread(
            target=self._run_listener,
            name="syncast-localfifo-listener",
            daemon=True,
        )
        self._broadcast_thread = threading.Thread(
            target=self._run_broadcaster,
            name="syncast-localfifo-broadcast",
            daemon=True,
        )
        # The delay-pump thread runs unconditionally — it cheaply waits
        # on the condition variable when the queue is empty (whether
        # because delay==0 or just because nothing has been fed yet).
        # Spawning it always keeps `set_delay_ms()` race-free (no need
        # to start a thread mid-flight if delay is bumped from 0 to >0).
        self._delay_pump_thread = threading.Thread(
            target=self._run_delay_pump,
            name="syncast-localfifo-delay-pump",
            daemon=True,
        )
        self._listener_thread.start()
        self._broadcast_thread.start()
        self._delay_pump_thread.start()

    def stop(self) -> None:
        self._stop_event.set()
        # Wake the pump so it sees stop_event flipped and exits its
        # condition wait promptly. We also drain the queue here under
        # the same lock to avoid leaking 1+ seconds of pending audio
        # bytes; if we left them, GC would still free them when the
        # broadcaster is dropped, but explicit draining keeps the leak
        # bounded even if a caller stashes a reference.
        with self._delay_cond:
            self._delay_queue.clear()
            self._delay_cond.notify_all()
        listen = self._listen_sock
        self._listen_sock = None
        if listen is not None:
            try:
                listen.close()
            except OSError:
                pass
        # Closing the fifo fd unblocks a blocking read in the broadcaster
        # thread (read returns 0, treated as EOF, loop exits).
        fd = self._fifo_fd
        self._fifo_fd = None
        if fd is not None:
            try:
                os.close(fd)
            except OSError:
                pass
        for t in (
            self._listener_thread,
            self._broadcast_thread,
            self._delay_pump_thread,
        ):
            if t is not None:
                t.join(timeout=2.0)
        self._listener_thread = None
        self._broadcast_thread = None
        self._delay_pump_thread = None
        # Forcefully drop any clients still connected.
        with self._clients_lock:
            for c in self._clients:
                try:
                    c.sock.close()
                except OSError:
                    pass
            self._clients.clear()
        # Mirror _open_listener's startup cleanup: remove the broadcaster
        # listening-socket file. Otherwise a stop()/start() cycle in the
        # same sidecar process re-binds via _open_listener (which already
        # unlinks at start), but a clean shutdown leaves the path on disk
        # — which we want to avoid because it litters /tmp and confuses
        # anything that lists the directory.
        Path(self._socket_path).unlink(missing_ok=True)

    # ---------- internals ----------

    def _open_listener(self) -> None:
        if self._socket_path.exists():
            try:
                self._socket_path.unlink()
            except OSError:
                pass
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.bind(str(self._socket_path))
        os.chmod(self._socket_path, 0o600)
        # Backlog of 4 is plenty: there's at most one bridge per
        # CoreAudio output, and the menubar typically toggles them one at
        # a time.
        s.listen(8)
        s.settimeout(1.0)
        self._listen_sock = s

    def _open_fifo_blocking(self) -> None:
        """Open OwnTone's output fifo for reading.

        We use a brief retry: OwnTone creates the fifo at startup, but
        if the broadcaster is asked to start before OwnTone has finished
        booting, the path may not yet exist as a fifo. The
        ``OwnToneBackend`` already pre-creates it during its own
        ``_ensure_fifo`` so this is just defence-in-depth.
        """
        deadline = time.monotonic() + 5.0
        last_err: Exception | None = None
        while time.monotonic() < deadline and not self._stop_event.is_set():
            try:
                # O_RDONLY (blocking). On macOS opening a fifo for read
                # blocks until at least one writer has it open — that's
                # OwnTone, and it always opens its end at startup, so
                # this returns near-immediately. If OwnTone has crashed,
                # the open hangs and `stop()`'s socket close is what
                # ultimately bails us out. A 5s deadline is the safety net.
                fd = os.open(str(self._fifo_path), os.O_RDONLY)
                self._fifo_fd = fd
                return
            except OSError as e:
                last_err = e
                time.sleep(0.1)
        self.fifo_open_failures += 1
        logger.warning(
            "local_fifo_open_failed",
            extra={"path": str(self._fifo_path), "err": str(last_err)},
        )

    def _run_listener(self) -> None:
        listen = self._listen_sock
        if listen is None:
            return
        while not self._stop_event.is_set():
            try:
                client_sock, addr = listen.accept()
            except socket.timeout:
                continue
            except OSError:
                # Listener was closed by stop(); exit cleanly.
                return
            try:
                # Smallish send buffer so a slow client surfaces as EAGAIN
                # quickly rather than building a multi-second backlog.
                client_sock.setsockopt(
                    socket.SOL_SOCKET, socket.SO_SNDBUF,
                    LOCAL_FIFO_CLIENT_SNDBUF,
                )
            except OSError as e:
                logger.warning(
                    "local_fifo_setsockopt_failed",
                    extra={"errno": e.errno},
                )
            client_sock.setblocking(False)
            client = _BroadcastClient(sock=client_sock, addr=addr)
            with self._clients_lock:
                self._clients.append(client)
            logger.info(
                "local_fifo_client_connected",
                extra={"clients": len(self._clients)},
            )

    def feed(self, packet: bytes) -> None:
        """Push one PCM chunk into the delay queue (or directly to
        bridge clients if ``delay_ms == 0``).

        Called by `AudioSocketReader` immediately after writing the
        chunk to OwnTone's input fifo (the AirPlay-bound copy). This
        is the post-b0543d5 architecture: bridges receive Swift's
        native PCM directly, NOT via OwnTone's fifo OUTPUT module
        (which had unfixable multi-reader semantics — see fifo.c
        patch in build/owntone-server/src/outputs/fifo.c).

        Delay path (``delay_seconds > 0``):
          enqueue (due_time, enqueued_time, packet) and signal the
          pump. The pump pops items whose due-time has arrived and
          calls ``_broadcast(packet)``. Wall-clock alignment with
          AirPlay receivers (which play ~1.8 s behind capture) is
          maintained by holding the packet for ``delay_ms`` here.

        Synchronous path (``delay_seconds == 0``):
          ``_broadcast`` is called directly on the caller's thread
          for zero-overhead pass-through.

        Thread-safe: ``_broadcast`` does its own locking. Any chunk
        size is acceptable — bridge clients accumulate to their own
        packet boundary on the receive side.
        """
        if self._stop_event.is_set():
            return
        # Snapshot delay under the cond lock so we react to a recent
        # `set_delay_ms(0)` without a race window where one packet
        # leaks past the pump.
        now = time.monotonic()
        with self._delay_cond:
            delay = self._delay_seconds
            if delay <= 0.0:
                # Cheap path: no queueing, dispatch synchronously.
                # Fall through to the synchronous _broadcast call
                # outside the lock so a slow client send can't block
                # an unrelated thread that's holding the cond.
                pass
            else:
                due = now + delay
                # Bound the queue. Steady-state we expect ~100 packets
                # at a delay of 1750 ms (input is 100 pkt/s); the cap
                # is `delay + LOCAL_FIFO_OVERFLOW_MARGIN_S` worth of
                # packets, computed from input rate. We measure pending
                # audio in WALL-CLOCK seconds (oldest due-time vs newest
                # due-time) rather than packet count: that's both more
                # accurate (handles variable packet sizes) and self-
                # adapting to the configured delay.
                if self._delay_queue:
                    oldest_due = self._delay_queue[0][0]
                    pending_seconds = due - oldest_due
                    cap_seconds = delay + LOCAL_FIFO_OVERFLOW_MARGIN_S
                    while (
                        self._delay_queue
                        and pending_seconds > cap_seconds
                    ):
                        self._delay_queue.popleft()
                        self.chunks_dropped_due_to_overflow += 1
                        if self._delay_queue:
                            oldest_due = self._delay_queue[0][0]
                            pending_seconds = due - oldest_due
                self._delay_queue.append((due, now, packet))
                self._delay_cond.notify()
                return
        # Synchronous path (delay <= 0): release-on-fall-through above.
        try:
            self._broadcast(packet)
        except Exception:  # noqa: BLE001
            logger.exception("local_fifo_broadcast_failed")
        # Update the lag scalar even on the synchronous path so the
        # diagnostic dict is meaningful when delay is toggled at runtime.
        self._actual_delivery_lag_ms = (time.monotonic() - now) * 1000.0

    def _run_broadcaster(self) -> None:
        """Idle thread placeholder.

        Pre-tee architecture: this thread opened OwnTone's output fifo
        and read packets in a loop. Post-tee (b0543d5+1): bridges
        receive Swift's PCM directly via `feed()` from
        AudioSocketReader; the OwnTone fifo OUTPUT module is no longer
        consulted (its multi-reader / self-flushing semantics made it
        unusable for our broadcast use case).

        We keep the thread spawned so `start()` / `stop()` ordering and
        `_fifo_ready` semantics are preserved for callers; it just
        sleeps until stop. A future cleanup can drop the thread entirely.
        """
        self._fifo_ready.set()
        while not self._stop_event.is_set():
            self._stop_event.wait(timeout=1.0)

    def _run_delay_pump(self) -> None:
        """Drain the delay queue, releasing packets to ``_broadcast``
        when their wall-clock due-time arrives.

        Wait policy:
          * Empty queue → wait on the condition with a 100 ms cap so
            ``stop_event`` flips are noticed promptly.
          * Non-empty queue → wait until the next due-time, capped at
            100 ms. ``feed()`` notifies the condition when a new
            (potentially-earlier) item arrives, so an empty-→full
            transition doesn't sit on the cap.

        We do NOT busy-wait. We do NOT call ``time.sleep`` in a tight
        loop. Every wait happens via ``threading.Condition.wait`` on a
        bounded timeout, so the thread parks the kernel scheduler and
        only re-runs when it should.

        Drift handling: if the system clock jumps or the GIL stalls
        for several seconds, we may emerge from a wait with multiple
        items past due. We pop them all in one pass before sleeping
        again, so the queue catches up rather than holding stale audio.
        """
        while True:
            with self._delay_cond:
                if self._stop_event.is_set():
                    return
                now = time.monotonic()
                # Drain every item whose due-time has arrived.
                ready: list[tuple[float, float, bytes]] = []
                while self._delay_queue and self._delay_queue[0][0] <= now:
                    ready.append(self._delay_queue.popleft())
                # Determine the next wake budget. If the queue is
                # empty we wait the cap (so we still notice stop_event
                # within ~100 ms even with no traffic). If the queue
                # has a future item, sleep until that item is due,
                # again capped.
                if not ready:
                    if self._delay_queue:
                        sleep_for = max(
                            0.0,
                            min(
                                LOCAL_FIFO_PUMP_WAIT_CAP_S,
                                self._delay_queue[0][0] - now,
                            ),
                        )
                    else:
                        sleep_for = LOCAL_FIFO_PUMP_WAIT_CAP_S
                    # Wait for either: stop_event flip, feed() notify
                    # or the time-until-due to elapse. Returning early
                    # from a notify is fine — we re-loop and check.
                    if sleep_for > 0:
                        self._delay_cond.wait(timeout=sleep_for)
                    continue
            # Releasable items are dispatched outside the cond lock so
            # a slow `_broadcast` send doesn't block `feed()`.
            for due, enq, packet in ready:
                try:
                    self._broadcast(packet)
                except Exception:  # noqa: BLE001
                    logger.exception("local_fifo_broadcast_failed")
                # Lag = how long the packet actually spent in flight,
                # from feed() to here. Should be very close to the
                # configured delay_ms in steady state.
                self._actual_delivery_lag_ms = (
                    time.monotonic() - enq
                ) * 1000.0

    def _broadcast(self, packet: bytes) -> None:
        """Send one OwnTone packet to every connected client.

        Drops happen *per-client*: a slow consumer's send buffer fills,
        ``EAGAIN`` propagates back, we increment ``chunks_dropped`` for
        that client only. Fast peers continue receiving. Disconnected
        clients (``EPIPE`` / ``ECONNRESET``) are removed from the
        registry so their fd doesn't leak.
        """
        with self._clients_lock:
            snapshot = list(self._clients)
        if not snapshot:
            # No listeners — common in stereo mode. We still need to
            # *consume* the bytes (caller already did) so OwnTone's pipe
            # never fills up and blocks the player thread. Maintain
            # diagnostics anyway so a "stuck pipe" stands out.
            self.bytes_broadcast += len(packet)
            self.chunks_broadcast += 1
            return
        dead: list[_BroadcastClient] = []
        for c in snapshot:
            try:
                # send() with the default 0 flags returns the number of
                # bytes accepted by the kernel buffer. With SO_SNDBUF
                # capped at LOCAL_FIFO_CLIENT_SNDBUF and a non-blocking
                # socket, the typical outcome is full-acceptance during
                # normal flow, EAGAIN under backpressure.
                c.sock.send(packet)
            except BlockingIOError:
                # Buffer full — client is behind. Drop this packet for
                # this client. Other clients still see it.
                c.chunks_dropped += 1
                self._maybe_log_drop(c)
            except (BrokenPipeError, ConnectionResetError):
                dead.append(c)
            except OSError as e:
                # ENOTCONN, EPIPE under unusual conditions, or ECONNREFUSED
                # if the peer sent RST. All are terminal for the client.
                logger.info(
                    "local_fifo_client_send_failed",
                    extra={"errno": e.errno, "addr": str(c.addr)},
                )
                dead.append(c)
        self.bytes_broadcast += len(packet)
        self.chunks_broadcast += 1
        if dead:
            with self._clients_lock:
                for c in dead:
                    try:
                        c.sock.close()
                    except OSError:
                        pass
                    try:
                        self._clients.remove(c)
                    except ValueError:
                        pass

    def _maybe_log_drop(self, client: _BroadcastClient) -> None:
        # Throttle drop logs to once every 5 s per client.
        now_ns = time.monotonic_ns()
        if now_ns - client.last_drop_log_ns < 5_000_000_000:
            return
        client.last_drop_log_ns = now_ns
        logger.warning(
            "local_fifo_client_drop",
            extra={
                "addr": str(client.addr),
                "total_dropped": client.chunks_dropped,
            },
        )
