# ADR-006: OwnTone for AirPlay 2 multi-target streaming, pyatv for discovery only

**Status**: Accepted (supersedes the streaming part of ADR-003) · 2026-04-25

## Context

ADR-003 picked **pyatv** as the AirPlay 2 sender. Deeper research (see `docs/research/airplay2-brief.md`) shows this was wrong:

- pyatv's "multi-room" API (`set_output_devices`) is a remote-control command sent to an *existing* Apple-made leader (Apple TV / HomePod). pyatv itself cannot grandmaster a PTP session for multiple AirPlay 2 receivers.
- pyatv's actual streaming path silently falls back to AirPlay 1 (RAOP). Modern HomePods, Xiaomi Sound (post-firmware-update), and other AP2-only receivers reject AirPlay 1.
- The only open-source AirPlay 2 sender that does PTP-synced multi-target streaming today is **OwnTone** (formerly forked-daapd, GPL-2.0, actively maintained).

## Decision

- **Streaming**: spawn an **OwnTone** server as a subprocess, feed it PCM via a FIFO pipe, control it via its HTTP REST API.
- **Discovery & pairing**: keep `pyatv` because its mDNS handling and pairing UX are well-tested and OwnTone's are more bare.
- The Python sidecar from ADR-003 stays — its role becomes: lifecycle-manage OwnTone, translate our JSON-RPC IPC to OwnTone REST calls, feed audio frames into the FIFO.

## Why a wrapper sidecar instead of Swift → OwnTone direct?

- We keep the IPC abstraction in `proto/ipc-schema.md`. The router doesn't know OwnTone is involved — only that "AirPlay 2 transport, ask the sidecar." This preserves the pluggable transport guarantee.
- OwnTone's config and DB live in user space; the sidecar provides a clean install/teardown that the Swift app shouldn't have to know about.
- We can replace OwnTone with a Rust/Swift port in the future without changing the IPC.

## Licensing

- OwnTone is **GPL-2.0**. We invoke it as a separate executable over IPC (REST + FIFO). This is the canonical "aggregate" boundary — our SyncCast code is not a derivative work and remains MIT.
- We **bundle the OwnTone binary** in the SyncCast .app, alongside its own LICENSE and source-availability notice. README must include attribution and a link to OwnTone's source.
- Distribution implication: every release must include an "OwnTone source" tarball or a clear pointer to the upstream tag we built from. Documented in `scripts/release.md` (TODO).

## Sidecar internals (revised)

```
syncast_sidecar/
├── __main__.py          (unchanged)
├── server.py            (unchanged)
├── jsonrpc.py           (unchanged)
├── log.py               (unchanged)
├── device_manager.py    (unchanged interface)
├── airplay2.py          (now: discovery via pyatv only; streaming methods delegate)
├── owntone_backend.py   (NEW: spawn/control OwnTone, REST + FIFO)
└── audio_socket.py      (NEW: SOCK_SEQPACKET reader → FIFO writer)
```

## Consequences

- App bundle adds the OwnTone binary (~5 MB on macOS, plus a few dylib deps).
- OwnTone's first launch creates a small SQLite DB under `~/Library/Application Support/SyncCast/owntone/`. We pre-seed `owntone.conf` so it doesn't try to scan the user's Music library.
- ~2.5 s end-to-end latency budget when a Mac AirPlay Receiver is in the group (vs. ~1.8 s with HomePod-only). Scheduler `safetyMarginMs` raised from 50 to 200.
- Codec lock: ALAC 44.1 kHz / 16-bit stereo (lowest common denominator across HomePod, Xiaomi, Mac receiver). Internal pipeline stays 48 kHz; we resample at the FIFO boundary.

## Plan B (if OwnTone proves unworkable)

- Fork `outputs/airplay.c` from OwnTone into a small C library and FFI it. Keeps our license MIT-clean (we'd be the GPL component owner) but is significant work. Tracked in `docs/ROADMAP.md`.
