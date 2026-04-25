"""Audio socket reader.

Spins up a SOCK_SEQPACKET Unix socket that accepts a single connection from
the Swift router and forwards every PCM packet into the OwnTone FIFO.

Each packet is exactly 480 frames × 2 channels × 2 bytes = 1920 bytes
(s16le @ 48 kHz). OwnTone expects ALAC-friendly PCM at 44.1 kHz / 16-bit;
the resampling step is intentionally not in v1 — we'll wire a CoreAudio-based
resampler on the Swift side once end-to-end audio works.
"""

from __future__ import annotations

import os
import socket
import threading
from pathlib import Path
from typing import Callable

from . import log

logger = log.get("sidecar.audio_socket")

PACKET_BYTES = 480 * 2 * 2  # 480 frames × 2 channels × 2 bytes


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

    def _listen(self) -> None:
        if self._path.exists():
            try:
                self._path.unlink()
            except OSError:
                pass
        s = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
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
