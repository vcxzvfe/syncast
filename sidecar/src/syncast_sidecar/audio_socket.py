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
    """Fans OwnTone's output fifo bytes out to N Swift ``LocalAirPlayBridge``
    clients in lockstep with the AirPlay receivers.

    Lifecycle:

      * ``start()``  — open the listener Unix socket at ``socket_path``,
        open OwnTone's output fifo at ``fifo_path`` for read, spawn TWO
        threads:

          - ``listener``: blocking ``accept(2)`` loop; appends new
            ``_BroadcastClient`` instances to the registry.
          - ``broadcaster``: blocking ``read(2)`` from the OwnTone fifo,
            then non-blocking ``send(2)`` to every registered client
            with per-client backlog tracking.

      * ``stop()``  — closes the listener, closes the fifo fd (causing
        the broadcaster's read to return 0), joins both threads, then
        forcefully closes every still-connected client socket.

    The fifo is opened ``O_RDONLY`` *without* ``O_NONBLOCK``: OwnTone
    creates it as the writer and we want the read to BLOCK when no audio
    is queued, both because (a) busy-spinning a fifo read that never
    yields wedges a CPU at 100% and (b) we want the broadcast to flow at
    OwnTone's player-clock pace, not faster. The trade-off: ``stop()``
    has to close the fd to wake the read, which is what we do.

    Client-side broadcasting is non-blocking. We set ``SO_SNDBUF`` low
    on each client socket (``LOCAL_FIFO_CLIENT_SNDBUF``) so a slow
    Swift bridge surfaces as ``EAGAIN`` instead of a kernel-level
    multi-megabyte backlog the receiver would still try to render.
    """

    def __init__(self, socket_path: Path, fifo_path: Path) -> None:
        self._socket_path = socket_path
        self._fifo_path = fifo_path
        self._listen_sock: socket.socket | None = None
        self._fifo_fd: int | None = None
        self._listener_thread: threading.Thread | None = None
        self._broadcast_thread: threading.Thread | None = None
        self._stop_event = threading.Event()
        # Client registry. Mutated only under `_clients_lock`. The
        # broadcaster takes a *snapshot* (list copy) under the lock and
        # then sends without holding the lock — keeps accept() unblocked
        # by a slow send().
        self._clients: list[_BroadcastClient] = []
        self._clients_lock = threading.Lock()
        # Diagnostics — read from the IPC layer for `state.report` etc.
        self.bytes_broadcast: int = 0
        self.chunks_broadcast: int = 0
        self.fifo_open_failures: int = 0

    # ---------- diagnostics ----------

    @property
    def clients_connected(self) -> int:
        with self._clients_lock:
            return len(self._clients)

    def diagnostics(self) -> dict[str, object]:
        with self._clients_lock:
            per_client = [
                {"addr": str(c.addr), "chunks_dropped": c.chunks_dropped}
                for c in self._clients
            ]
        return {
            "bytes_broadcast": self.bytes_broadcast,
            "chunks_broadcast": self.chunks_broadcast,
            "clients_connected": len(per_client),
            "fifo_open_failures": self.fifo_open_failures,
            "per_client": per_client,
        }

    # ---------- lifecycle ----------

    def start(self) -> None:
        if self._listener_thread is not None and self._listener_thread.is_alive():
            return
        self._stop_event.clear()
        self._open_listener()
        self._open_fifo_blocking()
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
        self._listener_thread.start()
        self._broadcast_thread.start()

    def stop(self) -> None:
        self._stop_event.set()
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
        for t in (self._listener_thread, self._broadcast_thread):
            if t is not None:
                t.join(timeout=2.0)
        self._listener_thread = None
        self._broadcast_thread = None
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

    def _run_broadcaster(self) -> None:
        fd = self._fifo_fd
        if fd is None:
            return
        # Short reads are normal on fifos; we accumulate to one logical
        # OwnTone packet (LOCAL_FIFO_CHUNK_BYTES) before broadcasting so
        # every client receives whole packets. This matches the contract
        # documented at the head of this module.
        buf = bytearray()
        target = LOCAL_FIFO_CHUNK_BYTES
        while not self._stop_event.is_set():
            try:
                chunk = os.read(fd, target - len(buf))
            except OSError as e:
                if e.errno == errno.EINTR:
                    continue
                # Any other read failure → fifo gone. Log + bail; stop()
                # will reset state.
                logger.warning(
                    "local_fifo_read_failed",
                    extra={"errno": e.errno},
                )
                return
            if not chunk:
                # EOF: OwnTone closed the writer side, or stop() closed
                # our fd. Either way, bail.
                return
            buf.extend(chunk)
            if len(buf) < target:
                continue
            packet = bytes(buf)
            buf.clear()
            self._broadcast(packet)

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
