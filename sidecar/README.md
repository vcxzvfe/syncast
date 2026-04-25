# SyncCast Sidecar

Python sidecar that streams audio to AirPlay 2 receivers on behalf of the Swift router.

## Why a sidecar?

The sidecar wraps two open-source projects so the Swift router doesn't need to:

- **`pyatv`** — used for AirPlay 2 receiver **discovery + pairing** (mDNS, HAP).
- **`owntone`** (forked-daapd) — used for the actual **multi-target AirPlay 2 streaming with PTP sync**. This is the only open-source sender today that can lock multiple AirPlay 2 receivers to a single PTP master. See [ADR-006](../docs/adr/ADR-006-owntone-streaming.md).

The sidecar runs OwnTone as its own subprocess, feeds it PCM via a FIFO pipe, and translates our JSON-RPC IPC to OwnTone's REST API. The Swift router sees only our IPC; OwnTone is an implementation detail.

## Run (dev)

```bash
cd sidecar
python3 -m venv .venv
source .venv/bin/activate
pip install -e '.[dev]'
syncast-sidecar --socket /tmp/syncast-$UID.sock --audio-socket /tmp/syncast-$UID.audio.sock --log-level info
```

## Protocol

See [../proto/ipc-schema.md](../proto/ipc-schema.md).

## Architecture

```
syncast_sidecar/
├── __main__.py        # entry point, arg parsing
├── server.py          # Unix-socket JSON-RPC server (asyncio)
├── audio_socket.py    # SOCK_SEQPACKET PCM reader thread
├── discovery.py       # mDNS scan via pyatv
├── device_manager.py  # tracks connected receivers + per-device queues
├── streamer.py        # per-device pyatv streaming coroutine
└── log.py             # structured logging
```
