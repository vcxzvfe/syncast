# ADR-003: Python sidecar (pyatv) for AirPlay 2

**Status**: Partially superseded by [ADR-006](ADR-006-owntone-streaming.md) · 2026-04-25

> Note: the **sidecar process model** decided here is still in force.
> The streaming backend changed from pyatv to OwnTone — see ADR-006 for the
> revised picture. pyatv is retained for discovery and pairing only.

## Context

AirPlay 2 is a closed Apple protocol. Implementing the RTSP / ALAC / PTP stack in Swift from scratch is a multi-month effort. The most mature open-source AirPlay 2 client is **pyatv** (Python). Other senders: `owntone` (forked-daapd, C, Linux-first), `shairport-sync` (receiver only).

## Decision

- Run **pyatv in a child Python process** (the "sidecar").
- Communicate via two Unix domain sockets (control + audio).
- Bundle the sidecar with the app via PyInstaller — no system-Python dependency.

## Rationale

- pyatv is actively maintained, has end-to-end AirPlay 2 streaming, and hides the protocol details we don't want to implement.
- Process isolation insulates the Swift main app from pyatv crashes, GIL stalls, and any future protocol breakage.
- IPC overhead is acceptable: we're shipping ~1.5 Mbit/s of PCM. A Unix socket with `SOCK_SEQPACKET` handles that without straining the CPU.
- A native Swift port of the AirPlay 2 stack is a v3 candidate, not v1.

## Consequences

- App bundle is larger (PyInstaller + pyatv ≈ 30–50 MB).
- We own the lifecycle: spawn on first stream, terminate on app quit, restart on crash with exponential backoff.
- Protocol versioning is explicit: every JSON-RPC message carries `"v": 1`. Future sidecar revisions must support both versions during a transition window.
- pyatv API churn is a real risk. We pin the version in `sidecar/pyproject.toml` and gate upgrades behind the IPC integration tests.

## Alternatives considered

- **owntone fork** — better sync quality reputation, but C codebase, Linux-first, requires significant porting work.
- **Private Apple frameworks** (CoreUtils / MediaPlayer private symbols) — fragile, breaks across macOS updates, hostile to open source.
- **Reimplement in Swift** — too much for v1.
