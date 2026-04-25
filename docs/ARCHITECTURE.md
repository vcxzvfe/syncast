# SyncCast Architecture

> Last updated: 2026-04-25 · Status: living document, P0–P3 design phase

## 1. Goals & non-goals

### Goals (in priority order)
1. **Sync quality**: ≤30 ms perceived offset across all enabled outputs at steady state.
2. **Per-device volume**: independent linear gain 0.0–1.0, plus mute, persisted across launches.
3. **Pluggable transports**: adding a new device class (Snapcast, generic RTP, Chromecast) should be a new module under `core/router/Transports/`, not a rewrite.
4. **Reliability**: a misbehaving AirPlay receiver must not stall the local outputs. Network glitches recover within 1 s.
5. **Usable UX**: one-click "Whole-house mode" that "just works" once devices are added.

### Non-goals (for v1)
- Multi-zone audio (different streams to different rooms). One source, fanned out.
- Bit-perfect audiophile output. We resample to 48 kHz Float32 internally.
- Sandboxed Mac App Store distribution. We ship a notarized .pkg from GitHub Releases.
- Windows / Linux clients. macOS only.

## 2. Top-level diagram

```
                    Music App / Spotify / Browser
                                │
                                ▼
                   ┌────────────────────────────┐
                   │   BlackHole 2ch (kext)     │ ← system default output
                   └─────────────┬──────────────┘
                                 │ CoreAudio IOProc
                                 ▼
   ┌────────────────────────────────────────────────────────┐
   │                  SyncCast Router (Swift)                │
   │                                                          │
   │  Capture ─▶ RingBuffer ─▶ Scheduler ─▶ per-device read   │
   │                                                          │
   │  Transports:                                             │
   │   • CoreAudio AUHAL (one per local output)               │
   │   • IPC bridge ─▶ pyatv sidecar (one stream per AP recv) │
   └─┬────────────────┬─────────────────┬────────────────────┘
     │                │                 │
   AUHAL            AUHAL          Unix socket (control + audio)
     │                │                 │
     ▼                ▼                 ▼
  MBP built-in   Display speaker   ┌──────────────────────────┐
                                   │  syncast-sidecar (Py)    │
                                   │  pyatv ▶ AirPlay 2 RTSP  │
                                   └─┬────────────┬───────────┘
                                     ▼            ▼
                                Xiaomi Sound   Mac mini (AirPlay Recv)
```

## 3. Module map

| Module | Language | Responsibility |
|---|---|---|
| `core/discovery` | Swift Package | CoreAudio enumeration + Bonjour (`_airplay._tcp`) browsing. Produces stable `Device` records. |
| `core/router` | Swift Package | Capture from BlackHole, ring buffer, scheduler, AUHAL fan-out, IPC client to sidecar. |
| `sidecar/` | Python | Multi-target AirPlay 2 streamer using pyatv. Lives in a child process. |
| `proto/` | Markdown + JSON Schema | IPC contract (`ipc-schema.md`). |
| `tools/syncast-discover` | Swift exec | CLI for inspecting discovery output (debugging + CI smoke). |
| `apps/menubar` | SwiftUI app | Menubar UI. Wraps the router, exposes "Whole-house mode" + per-device controls. |

## 4. Audio data path

1. **Capture (real-time thread, CoreAudio IOProc)**: BlackHole 2ch delivers Float32 non-interleaved frames at the system sample rate (we lock 48 kHz). Capture writes them into `RingBuffer`.
2. **Ring buffer**: SPSC-from-producer-side, MPSC-from-consumer-side, lock-free reads via stable per-consumer absolute frame cursors. Capacity 2¹⁸ frames ≈ 5.46 s @ 48 kHz — comfortable margin over AirPlay's ~1.8 s buffer.
3. **Scheduler**: takes the maximum end-to-end latency across enabled devices (`T_master`). Every consumer's read cursor is `writePos − backoff_i`, where `backoff_i = T_master − L_i + manualTrim_i` translated to frames.
4. **Local fan-out**: one AUHAL (`kAudioUnitSubType_HALOutput`) per physical output, bound to that output device. Render callback reads from the ring at the per-device cursor, applies the per-device gain, writes into AUHAL's output buffer.
5. **AirPlay fan-out**: the IPC client streams PCM packets to the Python sidecar over a SOCK_SEQPACKET audio socket. Sidecar dispatches per-device streams to pyatv.

## 5. Sync model

See [research/sync-brief.md](research/sync-brief.md) for the full discussion. Headline:

- **Master clock**: `mach_absolute_time()` on the host. Wall-clock is not used — we are NTP-discipline-agnostic.
- **Strategy**: pad-the-fast-path. The local AUHAL renders are pre-rolled by `T_master − L_local` so they line up with AirPlay's late delivery.
- **Latency probe**: at session start, the sidecar reports each AirPlay receiver's RTSP-derived latency and updates it via `event.measured_latency`. The router re-plans when the worst-case latency moves by >20 ms.
- **Drift**: a slow PI loop monitors per-device buffer fill and inserts/drops one local sample per ~30 s if needed. Handled inside the AUHAL render callback, no resampling required.

## 6. Concurrency model

| Thread / actor | Lives in | Access pattern |
|---|---|---|
| BlackHole IOProc thread | CoreAudio | Real-time. Allocations forbidden. Only writes to `RingBuffer`. |
| Per-device AUHAL render thread | CoreAudio | Real-time. Reads from `RingBuffer`. Holds its own read cursor. |
| `DiscoveryService` actor | Swift concurrency | Aggregates events from CoreAudio + Bonjour. UI reads via subscribe(). |
| `Router` actor | Swift concurrency | Owns Scheduler state, plans, IPC. Mutated only inside the actor. |
| IPC reader task | Swift concurrency | Reads sidecar JSON-RPC notifications, forwards to Router. |
| Sidecar asyncio loop | Python | Single-threaded. PCM read thread pushes frames via `loop.call_soon_threadsafe`. |

## 7. IPC

See [proto/ipc-schema.md](../proto/ipc-schema.md). Two sockets:

- **Control**: `SOCK_STREAM`, newline-delimited JSON-RPC 2.0.
- **Audio**: `SOCK_SEQPACKET`, raw PCM s16le @ 48 kHz stereo, 480-frame packets (10 ms each).

Two sockets keeps audio out of the JSON parser and lets us tune kernel buffers separately.

## 8. Persistence

| Data | Location | Why |
|---|---|---|
| Per-device routing (`enabled`, `volume`, `mute`, `manualDelayMs`) | `~/Library/Application Support/SyncCast/devices.json` | Survives launches |
| Stable device IDs | same file | Map from CoreAudio UID / AirPlay device key → SyncCast UUID |
| Last calibration result per AirPlay receiver | same file | Skip re-calibration unless user requests |

Atomic writes via temp-file + `rename`. No SQLite — overkill at this scale.

## 9. Build & distribution

- Swift Packages built with the Xcode 15+ toolchain (`swift build`).
- Python sidecar bundled inside the .app via PyInstaller into a single binary; no system-Python dependency.
- Notarized via `xcrun notarytool`. Distributed as a `.pkg` from GitHub Releases.
- BlackHole bootstrap: app detects missing BlackHole and runs `installer -pkg /path/to/BlackHole2ch.pkg -target /` after admin auth (or hands off to a bundled .pkg).

## 10. ADRs

- [ADR-001: Capture via IOProc on BlackHole, not AVAudioEngine](adr/ADR-001-capture-strategy.md)
- [ADR-002: One AUHAL per local output](adr/ADR-002-fanout-strategy.md)
- [ADR-003: Python sidecar for AirPlay 2 (pyatv)](adr/ADR-003-airplay-sidecar.md)
- [ADR-004: Pad-the-fast-path sync](adr/ADR-004-sync-strategy.md)
- [ADR-005: MenuBarExtra + @Observable for UI](adr/ADR-005-ui-stack.md)
