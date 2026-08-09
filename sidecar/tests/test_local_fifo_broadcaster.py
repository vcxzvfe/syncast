"""Direction B: `LocalFifoBroadcaster` reads OwnTone's OUTPUT fifo and fans
the bytes to connected bridge clients.

These tests exercise the real reader thread against a real named pipe and a
real Unix socket — no OwnTone, no CoreAudio — so they prove the byte-level
plumbing (the O_RDONLY-before-writer open, the read loop, the fan-out, and the
EOF/reopen resync). They do NOT and cannot prove audio TIMING or drift, which
depend on OwnTone's player clock and the Mac output clock on real hardware.
"""

from __future__ import annotations

import os
import socket
import tempfile
import time
from pathlib import Path

from syncast_sidecar.audio_socket import LocalFifoBroadcaster

# Generous ceilings: these are wall-clock waits for background threads to
# accept a connection / deliver bytes, not performance assertions. Sized
# large so the suite stays green even when other tests load the machine.
_ACCEPT_TIMEOUT_S = 8.0
_DELIVER_TIMEOUT_S = 8.0
_POLL_S = 0.02


def _wait_for(predicate, timeout: float) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(_POLL_S)
    return predicate()


def _connect_client(socket_path: Path) -> socket.socket:
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(_DELIVER_TIMEOUT_S)
    assert _wait_for(
        lambda: _try_connect(client, socket_path), _ACCEPT_TIMEOUT_S
    ), "broadcaster never accepted the client socket"
    return client


def _try_connect(client: socket.socket, socket_path: Path) -> bool:
    try:
        client.connect(str(socket_path))
        return True
    except OSError:
        return False


def _recv_exactly(sock: socket.socket, n: int) -> bytes:
    chunks: list[bytes] = []
    got = 0
    deadline = time.monotonic() + _DELIVER_TIMEOUT_S
    while got < n and time.monotonic() < deadline:
        try:
            data = sock.recv(n - got)
        except socket.timeout:
            break
        if not data:
            break
        chunks.append(data)
        got += len(data)
    return b"".join(chunks)


def test_reader_forwards_output_fifo_bytes_to_a_connected_client() -> None:
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        fifo_path = tmp / "owntone.output.fifo"
        socket_path = tmp / "bcast.sock"
        os.mkfifo(fifo_path)

        # delay_ms=0: this test proves the byte-level forwarding mechanic, not
        # the delay line, so run the synchronous pass-through path — which is
        # also the corrected Direction-B default (see DEFAULT_LOCAL_FIFO_DELAY_MS).
        # A non-zero delay line is exercised by
        # test_feed_applies_broadcast_delay_and_reports_lag.)
        broadcaster = LocalFifoBroadcaster(
            socket_path=socket_path, fifo_path=fifo_path, delay_ms=0
        )
        broadcaster.start()
        writer_fd: int | None = None
        client: socket.socket | None = None
        try:
            # The reader opens O_RDONLY|O_NONBLOCK, so it is up as a reader
            # before any writer — our O_WRONLY open must therefore succeed.
            assert _wait_for(
                lambda: broadcaster._fifo_ready.is_set(), _ACCEPT_TIMEOUT_S
            ), "broadcaster never signalled _fifo_ready"
            writer_fd = os.open(str(fifo_path), os.O_WRONLY)

            client = _connect_client(socket_path)
            # Give the listener a beat to register the accepted client before
            # we push bytes, otherwise a no-client _broadcast() consumes them.
            assert _wait_for(
                lambda: _client_count(broadcaster) == 1,
                _ACCEPT_TIMEOUT_S,
            ), "broadcaster never registered the client"

            # <= PIPE_BUF (512 on macOS) so the write is atomic — no partial
            # frames to reassemble, which keeps the assertion deterministic.
            payload = bytes(range(256)) * 2  # 512 bytes of known data
            assert os.write(writer_fd, payload) == len(payload)

            received = _recv_exactly(client, len(payload))
            assert received == payload, (
                f"expected {len(payload)} bytes echoed from the fifo, "
                f"got {len(received)}"
            )
            assert broadcaster.bytes_broadcast >= len(payload)
        finally:
            if client is not None:
                client.close()
            if writer_fd is not None:
                os.close(writer_fd)
            broadcaster.stop()


def test_reader_resyncs_after_writer_eof() -> None:
    """When OwnTone closes its write end (mode change / flush), the reader
    drops to silence and reopens, resuming when a new writer appears."""
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        fifo_path = tmp / "owntone.output.fifo"
        socket_path = tmp / "bcast.sock"
        os.mkfifo(fifo_path)

        # delay_ms=0: EOF/resync is a plumbing property, not a timing one.
        broadcaster = LocalFifoBroadcaster(
            socket_path=socket_path, fifo_path=fifo_path, delay_ms=0
        )
        broadcaster.start()
        client: socket.socket | None = None
        try:
            assert _wait_for(
                lambda: broadcaster._fifo_ready.is_set(), _ACCEPT_TIMEOUT_S
            )
            client = _connect_client(socket_path)
            assert _wait_for(
                lambda: _client_count(broadcaster) == 1, _ACCEPT_TIMEOUT_S
            )

            first = b"\x11\x22\x33\x44" * 32  # 128 bytes, atomic
            writer_fd = os.open(str(fifo_path), os.O_WRONLY)
            assert os.write(writer_fd, first) == len(first)
            assert _recv_exactly(client, len(first)) == first
            # Writer closes: this is the EOF the reader must survive.
            os.close(writer_fd)

            # A new writer opens later; the reader should have reopened and
            # resumed forwarding.
            second = b"\x55\x66\x77\x88" * 32  # 128 bytes, atomic
            writer_fd2 = os.open(str(fifo_path), os.O_WRONLY)
            try:
                assert os.write(writer_fd2, second) == len(second)
                assert _recv_exactly(client, len(second)) == second, (
                    "reader did not resync after the writer's EOF"
                )
            finally:
                os.close(writer_fd2)
        finally:
            if client is not None:
                client.close()
            broadcaster.stop()


def test_feed_applies_broadcast_delay_and_reports_lag() -> None:
    """The delay line must actually hold packets before fan-out.

    Direction B: OwnTone releases the fifo byte on its player clock (~real
    time) but the AirPlay legs play ~1.8 s later, so a bridge that renders the
    byte immediately runs ahead — the broadcaster holds each packet for
    ``delay_ms`` to align them. Regression guard: a refactor once wired the
    fifo pump straight to ``_broadcast``, un-plugging the delay so the Sync
    slider changed nothing and ``actual_delivery_lag_ms`` stayed pinned at 0.
    """
    delay_ms = 250
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        fifo_path = tmp / "owntone.output.fifo"
        socket_path = tmp / "bcast.sock"
        os.mkfifo(fifo_path)

        broadcaster = LocalFifoBroadcaster(
            socket_path=socket_path, fifo_path=fifo_path, delay_ms=delay_ms
        )
        broadcaster.start()
        client: socket.socket | None = None
        try:
            assert _wait_for(
                lambda: broadcaster._fifo_ready.is_set(), _ACCEPT_TIMEOUT_S
            )
            client = _connect_client(socket_path)
            assert _wait_for(
                lambda: _client_count(broadcaster) == 1, _ACCEPT_TIMEOUT_S
            )

            payload = bytes(range(256)) * 2  # 512 bytes of known data
            started = time.monotonic()
            broadcaster.feed(payload)
            received = _recv_exactly(client, len(payload))
            elapsed_ms = (time.monotonic() - started) * 1000.0

            assert received == payload
            # Held for ~delay_ms rather than delivered instantly. Half the
            # configured delay is a generous lower bound that still fails hard
            # if the delay line is bypassed (which delivers in single-digit ms).
            assert elapsed_ms >= delay_ms * 0.5, (
                f"packet delivered in {elapsed_ms:.0f}ms; delay line not applied"
            )
            diag = broadcaster.diagnostics()
            assert diag["delay_ms"] == delay_ms
            assert diag["actual_delivery_lag_ms"] > 0.0, (
                "actual_delivery_lag_ms stayed 0 — delay line not on the path"
            )
        finally:
            if client is not None:
                client.close()
            broadcaster.stop()


def _client_count(broadcaster: LocalFifoBroadcaster) -> int:
    with broadcaster._clients_lock:
        return len(broadcaster._clients)


def test_only_one_caller_can_ever_claim_the_fifo_fd() -> None:
    """Ownership of the fifo fd transfers exactly once.

    `stop()` and the reader thread's unwind both close this descriptor, and
    they race on every reopen cycle (OwnTone sends EOF on each flush and mode
    change). A check-then-act let both close the same number, and once the
    listener's `accept()` had been handed that number it was an unrelated live
    socket that got closed — the broadcast listener or a connected bridge died
    with nothing in the log.
    """
    with tempfile.TemporaryDirectory() as tmp:
        broadcaster = LocalFifoBroadcaster(
            socket_path=Path(tmp) / "bcast.sock",
            fifo_path=Path(tmp) / "out.fifo",
        )
        # A real fd so a double close would be a real EBADF, not a fiction.
        read_fd, write_fd = os.pipe()
        try:
            broadcaster._fifo_fd = read_fd

            # The reader claims the fd it opened…
            assert broadcaster._take_fifo_fd(expected=read_fd) == read_fd
            # …and stop(), arriving second, gets nothing to close.
            assert broadcaster._take_fifo_fd() is None
            assert broadcaster._fifo_fd is None

            # A stale claim for a descriptor that has since been replaced must
            # not steal the new one.
            broadcaster._fifo_fd = write_fd
            assert broadcaster._take_fifo_fd(expected=read_fd) is None
            assert broadcaster._fifo_fd == write_fd
        finally:
            os.close(read_fd)
            os.close(write_fd)
