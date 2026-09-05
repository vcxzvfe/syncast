# SyncCast Architecture

> Last updated: 2026-09-05 · Status: living alpha document

## 1. Goals & non-goals

### Goals (in priority order)
1. **Preserve the stable local Stereo path**: local CoreAudio outputs must stay low-latency and reliable.
2. **Improve Local + AirPlay sync quality**: target ≤30 ms perceived offset at steady state. Since 2026-08-09 the only acceptance evidence is listening verification plus the ring-level drift logs — there is no acoustic measurement in the codebase.
3. **Per-device volume**: independent linear gain 0.0–1.0, plus mute, persisted across launches.
4. **Pluggable transports**: adding a new device class (Snapcast, generic RTP, Chromecast) should be a new module under `core/router/Transports/`, not a rewrite.
5. **Reliability**: a misbehaving AirPlay receiver must not stall the local outputs.
6. **Honest UX**: label AirPlay as experimental until automatic Local + AirPlay delay control is proven.

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
                   │ Capture backend             │
                   │ System Sink (tap pinned to  │
                   │ a volume-owning HAL device) │
                   │ · Direct Stereo · SCK/Tap   │
                   └─────────────┬──────────────┘
                                 │ system audio frames
                                 ▼
   ┌─────────────────────────────────────────────────────────┐
   │                  SyncCast Router (Swift)                 │
   │                                                          │
   │  Capture ─▶ RingBuffer ─▶ Scheduler ─▶ per-device read   │
   │                                                          │
   │  Transports:                                             │
   │   • CoreAudio AUHAL (one per local output)               │
   │   • AudioSocketWriter ─▶ Unix SOCK_SEQPACKET (PCM)       │
   │   • IpcClient JSON-RPC ─▶ Unix SOCK_STREAM (control)     │
   └─┬────────────────┬───────────────────┬──────────────────┘
     │                │                   │
   AUHAL            AUHAL                 │ Unix sockets
     │                │                   ▼
     ▼                ▼          ┌──────────────────────────────┐
  MBP built-in   Display          │   syncast-sidecar (Python)   │
                                  │   • pyatv (discover + pair)  │
                                  │   • AudioSocketReader thread │
                                  │   • OwnToneBackend (REST + FIFO)
                                  └──────────────┬───────────────┘
                                                 │ spawns + REST + FIFO pipe
                                                 ▼
                                       ┌─────────────────────┐
                                       │   OwnTone (GPL-2.0) │
                                       │   PTP + RTSP + ALAC │
                                       └────┬─────────────┬──┘
                                            │             │
                                            ▼             ▼
                                       Xiaomi Sound   Mac mini
                                                    (AirPlay Receiver)
```

> **Note**: Streaming is performed by OwnTone, spawned and orchestrated by
> the Python sidecar. pyatv is retained inside the sidecar for discovery
> and pairing only — see [ADR-006](adr/ADR-006-owntone-streaming.md).

## 3. Module map

| Module | Language | Responsibility |
|---|---|---|
| `core/discovery` | Swift Package | CoreAudio enumeration + Bonjour (`_airplay._tcp`) browsing. Produces stable `Device` records. |
| `core/router` | Swift Package | System capture, ring buffer, scheduler, local CoreAudio fan-out, the system-volume sink path, IPC client to sidecar, local AirPlay bridge + clock-following control loop. |
| `drivers/SyncCastAudio` | C (AudioServerPlugIn) | Output-only virtual HAL device named "SyncCast" with volume + mute controls. Discards audio; exists so macOS has something volume-controllable to make the default output. Installed to `/Library/Audio/Plug-Ins/HAL` by `scripts/install-driver.sh`. |
| `sidecar/` | Python | Lifecycle-manages OwnTone (multi-target AirPlay 2 sender) and proxies our IPC to OwnTone's REST + FIFO. Uses pyatv for discovery + pairing only. |
| `proto/` | Markdown + JSON Schema | IPC contract (`ipc-schema.md`). |
| `tools/syncast-discover` | Swift exec | CLI for inspecting discovery output (debugging + CI smoke). |
| `apps/menubar` | SwiftUI app | Menubar UI. Wraps the router, exposes Stereo and AirPlay experimental modes plus per-device controls, and owns the auto-connect rule engine (`AutoConnectProfile` / `AutoConnectCoordinator` / `AppModel+AutoConnect`). |

## 4. Audio data path

1. **Capture / local output**: local Stereo runs one of two paths, chosen by `StereoOutputPathPolicy` (see [ADR-007](adr/ADR-007-system-sink-volume.md)):
   - **System sink** (default when a virtual sink device is installed): a HAL device that HAS a volume control — SyncCast's own `SyncCastAudio.driver`, or BlackHole 2ch as fallback — becomes both the default output and the default *system* output, so the macOS volume UI controls SyncCast natively. A Process Tap pinned to that device (`CATapDescription.deviceUID`) feeds `RingBuffer`, and the ordinary aggregate/AUHAL fan-out plays it on the real speakers. The sink's `VolumeScalar` is the master volume; `SystemSinkVolumeLaw` turns it into a hardware scalar, a DDC/CI percent or a software gain per device.
   - **Direct Stereo** (no sink installed): a public CoreAudio aggregate becomes the system default and no capture happens at all. Aggregates expose no volume control, so this path still needs the media-key event tap.
   AirPlay and other capture-dependent paths write Float32 frames into `RingBuffer` through ScreenCaptureKit or a global Process Tap.
2. **Ring buffer**: SPSC-from-producer-side, MPSC-from-consumer-side, lock-free reads via stable per-consumer absolute frame cursors. Capacity 2¹⁸ frames ≈ 5.46 s @ 48 kHz — comfortable margin over AirPlay's ~1.8 s buffer.
3. **Scheduler**: takes the maximum end-to-end latency across enabled devices (`T_master`). Every consumer's read cursor is `writePos − backoff_i`, where `backoff_i = T_master − L_i + manualTrim_i` translated to frames.
4. **Local fan-out**: one AUHAL (`kAudioUnitSubType_HALOutput`) per physical output, bound to that output device. Render callback reads from the ring at the per-device cursor, applies the per-device gain, writes into AUHAL's output buffer.
5. **AirPlay fan-out**: `AudioSocketWriter` streams PCM packets (480 frames × 2 ch × s16le, ≈10 ms each) to the sidecar over a SOCK_SEQPACKET audio socket. The sidecar's `AudioSocketReader` thread forwards each packet straight into OwnTone's FIFO pipe. OwnTone owns the PTP-synced multi-target AirPlay 2 emission.

## 5. Sync model

See [research/sync-brief.md](research/sync-brief.md) for the full discussion. Headline:

- **Master clock**: `mach_absolute_time()` on the host. Wall-clock is not used — we are NTP-discipline-agnostic.
- **AirPlay receiver group**: multiple AirPlay receivers are delegated to the AirPlay/OwnTone timing domain. SyncCast should not invent per-receiver truth unless the evidence can distinguish them.
- **Local + AirPlay strategy**: both legs are driven from the same OwnTone clock domain (see below), so the local path follows AirPlay's playout rate rather than being padded to guess at it.
- **Timing evidence (2026-08-09)**: acoustic measurement has been retired. Both the active-probe path and the passive no-probe microphone path are removed from the codebase; SyncCast never opens the microphone. Alignment comes from the OwnTone clock domain instead:
  - **Layer 1** — the broadcaster adds no delay (`DEFAULT_LOCAL_FIFO_DELAY_MS = 0`); OwnTone's fifo output already releases each byte at `pts + outputs_buffer_duration_ms + offset_ms`.
  - **Layer 2** — `LocalAirPlayBridge` runs a PI control loop whose phase detector is the ring water level (`writePos - readCursor`), micro-resampling through `FractionalTrimResampler` so the local device clock follows OwnTone's fifo write rate.
  - **Layer 3** — the residual local pipeline latency is absorbed by delaying the AirPlay leg via OwnTone's per-output `offset_ms`.
  - **User trim (2026-08-09)** — on top of those three, each enabled output carries a user-settable millisecond trim compensating its distance from the listening position (1 ms ≈ 34 cm). It is a steady-state bias, deliberately NOT an input to Layer 2: the local leg applies it as a ring read-tap offset (`startFrame - trimFrames`) while `readCursor` keeps advancing untrimmed, so the PI loop's error signal is identical to a zero-trim run. Signed intent is normalised by `DelayTrimNormalizer` (the earliest speaker becomes the 0 reference) because neither leg can play early. The AirPlay half ADDS to the Layer-3 offset via `sync.set_output_trims_ms`; the sum, not the trim, is what gets clamped to OwnTone's range.
- **Route mutations**: AirPlay connection, route, delay, and volume changes bump an AirPlay timing epoch.

## 6. Concurrency model

| Thread / actor | Lives in | Access pattern |
|---|---|---|
| Capture callback thread | ScreenCaptureKit / Process Tap | Real-time-ish. Writes to `RingBuffer`; avoids blocking router work. |
| Per-device AUHAL render thread | CoreAudio | Real-time. Reads from `RingBuffer`. Holds its own read cursor. |
| `DiscoveryService` actor | Swift concurrency | Aggregates events from CoreAudio + Bonjour. UI reads via subscribe(). |
| `Router` actor | Swift concurrency | Owns Scheduler state, plans, IPC. Mutated only inside the actor. |
| IPC reader task | Swift concurrency | Reads sidecar JSON-RPC notifications, forwards to Router. |
| Sidecar asyncio loop | Python | Single-threaded. JSON-RPC + REST control. Blocking REST calls run on the executor thread pool. |
| Sidecar audio reader thread | Python (`AudioSocketReader`) | Blocking SEQPACKET reads → write into OwnTone FIFO. Snapshot fd under GIL. |
| OwnTone process | C | Owns PTP, RTSP, ALAC encode, multi-target sync. We treat as a black box. |

## 7. IPC

See [proto/ipc-schema.md](../proto/ipc-schema.md). Two sockets:

- **Control**: `SOCK_STREAM`, newline-delimited JSON-RPC 2.0.
- **Audio**: `SOCK_SEQPACKET`, raw PCM s16le @ 48 kHz stereo, 480-frame packets (10 ms each).

Two sockets keeps audio out of the JSON parser and lets us tune kernel buffers separately.

## 8. Persistence

| Data | Location | Why |
|---|---|---|
| Whole-home local member selection | `UserDefaults` key `syncast.wholeHome.localMemberUIDs` | Keyed by CoreAudio UID so it survives replug |
| Global local-fifo delay + lock | `UserDefaults` keys `syncast.airplayDelayMs`, `syncast.airplayDelayLockedAt` | Survives launches |
| Per-device volume / balance | `UserDefaults` key `syncast.deviceVolumes`, a `[deviceID: percent]` map. On the sink path this value is a BALANCE composed with the system volume in the dB domain, not an absolute level. |
| Sink device level | Owned by macOS (the sink's own `VolumeScalar`), and by the driver's own storage for `SyncCastAudio.driver`. SyncCast never writes it. |
| Per-speaker delay trim | `UserDefaults` key `syncast.deviceDelayTrimMs`, a `[persistenceKey: rawMs]` map | Keyed by `Device.persistenceKey` (`ca:<UID>` / `ap:<hex deviceid>`), never by `Device.id`, which is re-minted every process. Stores RAW signed intent, never the normalised output — normalisation depends on which devices are present, so persisting it would drift each session. A device that is absent keeps its entry, same rule as the member store. |
| Auto-connect rules | `UserDefaults` key `syncast.autoConnect.profiles.v1`, JSON-encoded array of `AutoConnectProfile` | Keyed by CoreAudio UID for the same reason as the member store: the office display must never trigger the home rule. Validated on load (`AutoConnectProfileStore.decode`) — absent, unreadable and nonsensical all collapse to "no rules", because a half-applied rule would move the user's audio somewhere they never asked for. |

Note: earlier revisions of this document described a `~/Library/Application Support/SyncCast/devices.json` routing store. No such file exists or has ever been written; per-device routing is rebuilt from discovery on each launch, and only the keys above are persisted.

## 8a. Auto-connect (2026-09-05)

"When the home monitor shows up, play on the laptop speakers AND the monitor,
in local Stereo" — expressed as a user-editable rule rather than as a hard-coded
behaviour, because other people have other monitors and this laptop also meets
an office display that must trigger nothing.

- **Identity**: a rule stores a `triggerUID` and `memberUIDs`, all CoreAudio
  device UIDs. Never `Device.id` (re-minted per process) and never names (not
  unique across two panels from the same vendor).
- **Decision** (`AutoConnectCoordinator`, pure + clock-injected): presence is
  debounced 1.5 s, because a DisplayPort monitor waking from DPMS adds and
  removes its audio device several times inside a second. It fires at most once
  per "trigger presence episode", and any manual toggle or mode change while the
  trigger is present suppresses the rule until the trigger leaves and returns
  (or until 「重新应用规则」). Launching into the already-correct state claims the
  episode silently.
- **Effects** (`AppModel+AutoConnect`): activation is `setMode(.stereo)` plus
  `setDeviceEnabled` on exactly the member UIDs — no new audio path. Disconnect
  stops the engine, then optionally points the macOS default output back at the
  built-in speakers and forces their hardware level. That level is a LINEAR
  scalar (`percent / 100`, the macOS slider position), deliberately not
  `VolumeCurve`, whose 0 % is -30 dB rather than silence.
- **Evaluation points**: every discovery event, 3 s after launch, and after
  wake. `SYNCAST_AUTOCONNECT_SIMULATE_ABSENT=<uid>[,<uid>]` hides a UID from the
  coordinator only, so the disconnect branch is reachable without unplugging.
- Full rationale: [requirements_2026-09-05-auto-connect.md](requirements_2026-09-05-auto-connect.md).

## 9. Build & distribution

- Swift Packages built with the Xcode 15+ toolchain (`swift build`).
- Python sidecar bundled inside the .app via PyInstaller into a single binary; no system-Python dependency.
- Notarized via `xcrun notarytool`. Distributed as a `.pkg` from GitHub Releases.
- No BlackHole bootstrap is required for the current alpha. Local Stereo prefers the system-sink path when a sink device is installed and falls back to Direct Stereo otherwise; Process Tap is the intended replacement for ScreenCaptureKit on capture-dependent paths.
- `drivers/SyncCastAudio` is built by its own `build.sh` (clang, universal, ad-hoc or "SyncCast Dev" signed) and installed with sudo. It is NOT part of the .app bundle: HAL plug-ins must live in `/Library/Audio/Plug-Ins/HAL`.

## 10. ADRs

- [ADR-001: Capture via IOProc on BlackHole, not AVAudioEngine](adr/ADR-001-capture-strategy.md)
- [ADR-002: One AUHAL per local output](adr/ADR-002-fanout-strategy.md)
- [ADR-003: Python sidecar for AirPlay 2 (pyatv)](adr/ADR-003-airplay-sidecar.md)
- [ADR-004: Pad-the-fast-path sync](adr/ADR-004-sync-strategy.md)
- [ADR-005: MenuBarExtra + @Observable for UI](adr/ADR-005-ui-stack.md)
- [ADR-006: OwnTone for AirPlay 2 streaming](adr/ADR-006-owntone-streaming.md)
- [ADR-007: Own the system volume with a virtual sink, not an event tap](adr/ADR-007-system-sink-volume.md)
