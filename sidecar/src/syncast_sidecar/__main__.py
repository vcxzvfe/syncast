"""Entry point for the SyncCast sidecar.

Spawned by the Swift router. Two Unix sockets:

  * control socket  — newline-delimited JSON-RPC 2.0
  * audio socket    — SOCK_SEQPACKET, raw PCM s16le @ 48 kHz stereo, 480-frame packets

See ../../../proto/ipc-schema.md for the wire protocol.
"""

from __future__ import annotations

import argparse
import asyncio
import os
import signal
import sys
from pathlib import Path

from syncast_sidecar import __version__, log
from syncast_sidecar.server import ControlServer


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(prog="syncast-sidecar")
    parser.add_argument("--socket", required=True, type=Path,
                        help="Path to the JSON-RPC control Unix socket")
    parser.add_argument("--audio-socket", required=True, type=Path,
                        help="Path to the SOCK_SEQPACKET audio Unix socket")
    parser.add_argument("--owntone-binary", type=Path, default=None,
                        help="Explicit path to the owntone executable. "
                             "Defaults to PATH lookup.")
    parser.add_argument("--owntone-config-template", type=Path, default=None,
                        help="owntone.conf template to copy on first launch. "
                             "Used when shipping owntone inside an app bundle.")
    parser.add_argument("--state-dir", type=Path, default=None,
                        help="Where owntone stores its config / cache / FIFO. "
                             "Defaults to ~/Library/Application Support/SyncCast/owntone.")
    parser.add_argument("--log-level", default="info",
                        choices=["debug", "info", "warning", "error"])
    parser.add_argument("--version", action="version",
                        version=f"syncast-sidecar {__version__}")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    log.configure(args.log_level)
    logger = log.get("sidecar")
    logger.info("starting", extra={"version": __version__, "pid": os.getpid()})

    server = ControlServer(
        control_socket=args.socket,
        audio_socket=args.audio_socket,
        owntone_binary=args.owntone_binary,
        owntone_config_template=args.owntone_config_template,
        state_dir=args.state_dir,
    )

    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)

    def shutdown(signame: str) -> None:
        logger.info("signal", extra={"signal": signame})
        loop.create_task(server.shutdown())

    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, shutdown, sig.name)

    try:
        loop.run_until_complete(server.run())
    except Exception:  # noqa: BLE001
        logger.exception("fatal")
        return 1
    finally:
        loop.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
