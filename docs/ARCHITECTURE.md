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
| `core/discovery` | Swift Package | CoreAudio enumeration + Bonjour browsing (`_airplay._tcp`, `_raop._tcp`, and `_synccast-pcm._udp` for LAN receivers). Produces stable `Device` records. |
| `core/router` | Swift Package | System capture, ring buffer, scheduler, local CoreAudio fan-out, the system-volume sink path, the per-device equalizer (`EqualizerSettings` + `EqualizerBank`), the per-device stereo image (`StereoImageSettings` + `StereoImageProcessor`), the per-device local delay compensation (`LocalDelayTrim` + `PairDelayBank`), the per-device channel assignment (`ChannelMatrixSettings` + `ChannelMatrixBank`), the LAN PCM link (`LanPcmProtocol` + `LanClockModel` + `LanReceiverLink` + `LanReceiverOutput`), IPC client to sidecar, local AirPlay bridge + clock-following control loop. |
| `drivers/SyncCastAudio` | C (AudioServerPlugIn) | Output-only virtual HAL device named "SyncCast" with volume + mute controls. Discards audio; exists so macOS has something volume-controllable to make the default output. Installed to `/Library/Audio/Plug-Ins/HAL` by `scripts/install-driver.sh`. |
| `sidecar/` | Python | Lifecycle-manages OwnTone (multi-target AirPlay 2 sender) and proxies our IPC to OwnTone's REST + FIFO. Uses pyatv for discovery + pairing only. |
| `proto/` | Markdown + JSON Schema | IPC contract (`ipc-schema.md`) and the LAN PCM link's wire format (`lan-pcm-link.md`, implemented by both this repo and the receiver daemon). |
| `tools/syncast-discover` | Swift exec | CLI for inspecting discovery output (debugging + CI smoke). |
| `apps/menubar` | SwiftUI app | Menubar UI. Wraps the router, exposes Stereo and AirPlay experimental modes plus per-device controls (volume, delay trim, equalizer, stereo image, local delay compensation), and owns the auto-connect rule engine (`AutoConnectProfile` / `AutoConnectCoordinator` / `AppModel+AutoConnect`), the per-device equalizer store (`DeviceEqualizerStore` / `AppModel+Equalizer` / `EqualizerSection`), the per-device stereo-image store (`DeviceStereoImageStore` / `AppModel+StereoImage` / `StereoImageSection`), the per-device channel-assignment store (`DeviceChannelMatrixStore` / `AppModel+ChannelMatrix` / `ChannelMatrixSection`) and the LAN receiver rows plus their keychain-backed token store (`LanReceiverTokenStore` / `AppModel+LanReceiver` / `LanReceiverSection` / `LanTokenWindowController`). |

## 4. Audio data path

1. **Capture / local output**: local Stereo runs one of two paths, chosen by `StereoOutputPathPolicy` (see [ADR-007](adr/ADR-007-system-sink-volume.md)):
   - **System sink** (default when a virtual sink device is installed): a HAL device that HAS a volume control — SyncCast's own `SyncCastAudio.driver`, or BlackHole 2ch as fallback — becomes both the default output and the default *system* output, so the macOS volume UI controls SyncCast natively. A Process Tap pinned to that device (`CATapDescription.deviceUID`) feeds `RingBuffer`, and the ordinary aggregate/AUHAL fan-out plays it on the real speakers. The sink's `VolumeScalar` is the master volume; `SystemSinkVolumeLaw` turns it into a hardware scalar, a DDC/CI percent or a software gain per device. Once the sink is the default output the path MUST have somewhere to render, or macOS is pointed at a silent device with nothing playing it — `SystemSinkOutputPolicy` is that check, and it counts LAN receiver legs alongside CoreAudio outputs, so a LAN receiver on its own is a complete output set.
   - **Direct Stereo** (no sink installed): a public CoreAudio aggregate becomes the system default and no capture happens at all. Aggregates expose no volume control, so this path still needs the media-key event tap. `SystemVolumeKeyEligibility` holds the whole mode × sink × path matrix for when that tap may exist — it is only justified where macOS itself cannot carry the keys.
   AirPlay and other capture-dependent paths write Float32 frames into `RingBuffer` through ScreenCaptureKit or a global Process Tap.
   - **Whole-home sink**: whole-home also needs the default output to be silent, so system audio lands somewhere harmless while ScreenCaptureKit feeds OwnTone. `WholeHomeSinkSelection` picks between two owners:
     - **direct** (SyncCast's own driver installed): `SystemSinkDevice` puts that device in as the default output — the same type, takeover, restore, ownership claim and stale-default sweep the stereo sink path uses. The device is already named "SyncCast", so no wrapper is needed for the Sound menu to read sensibly, and it brings a real `VolumeScalar` with it: **the macOS volume UI works natively in whole-home**, and its scalar becomes the master gain in `AudioSocketWriter` (`SystemSinkVolumeLaw.wholeHomeMasterAmplitude` — the sink's own dB law, NOT `VolumeCurve`'s −30 dB OwnTone curve, which would compress ~64 dB of slider travel into 30). The media-key event tap stands down here.
     - **wrapped** (BlackHole only): the legacy public aggregate named 「AirPlay 全屋」 (`WholeHomeSinkOutput`). BlackHole cannot be renamed in place, so the wrapper is what keeps the Sound menu from reading "BlackHole 2ch". An aggregate exposes no volume control, so this flavour keeps the panel's own master fader and the media-key event tap.
     Either way whole-home never opens the device: SCK taps system audio above the HAL, so the sink's own sample rate and attenuation are not in the signal path — the direct owner deliberately does NOT pin it to 48 kHz (that would re-rate a shared device system-wide) and the aggregate inherits its subdevice's rate. Both are resolved through the same `SystemSinkDevice.candidates` preference order as the stereo sink path, so **BlackHole is optional in every mode**.
     Displacement — the user picking another output in the Sound menu — is ONE condition with one policy across every default-output owner (`Router.systemSinkDisplaced`): stop routing, restore nothing, offer 「继续」. SyncCast never re-asserts the default output on a timer.
2. **Ring buffer**: SPSC-from-producer-side, MPSC-from-consumer-side, lock-free reads via stable per-consumer absolute frame cursors. Capacity 2¹⁸ frames ≈ 5.46 s @ 48 kHz — comfortable margin over AirPlay's ~1.8 s buffer.
3. **Scheduler**: takes the maximum end-to-end latency across enabled devices (`T_master`). Every consumer's read cursor is `writePos − backoff_i`, where `backoff_i = T_master − L_i + manualTrim_i` translated to frames.
4. **Local fan-out**: one AUHAL (`kAudioUnitSubType_HALOutput`) per physical output, bound to that output device. Render callback reads from the ring at the per-device cursor, splats the source stereo into every output channel pair, reads that pair at its own **delay offset** when one is dialled in (`PairDelayBank`, see §8c), applies that pair's **equalizer** (`EqualizerBank`, see §8b), then its **stereo image** (`StereoImageProcessor`, see §8b-2), then its **channel assignment** (`ChannelMatrixBank`, see §8d), then the per-device gain, and writes into AUHAL's output buffer. Everything sits before the gain stage so the volume slider stays the last attenuator; a pair with nothing dialled in takes a fast path at every stage that leaves the buffer byte-identical.
5. **LAN receiver fan-out** (local Stereo only, see §8e): `LanReceiverOutput` is the same shape one stage further out — a 5 ms `DispatchSourceTimer` reads 240 frames from the same ring at a cursor held a constant distance behind the producer, runs the same equalizer → stereo image → channel matrix → balance chain, converts to Int16 and sends a 984-byte UDP packet stamped `play_at_ns = ringTime(frame) + target_ms`. The timestamp is derived from the RING frame number (`RingWriteClock`), not from the send timer, which is what rate-locks the receiver to the audio source rather than to a timer on either machine.
6. **AirPlay fan-out**: `AudioSocketWriter` streams PCM packets (480 frames × 2 ch × s16le, ≈10 ms each) to the sidecar over a SOCK_SEQPACKET audio socket. The sidecar's `AudioSocketReader` thread forwards each packet straight into OwnTone's FIFO pipe. OwnTone owns the PTP-synced multi-target AirPlay 2 emission.

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
| Per-device equalizer curve | `UserDefaults` key `syncast.deviceEqualizer.v1`, JSON-encoded array of `DeviceEqualizerProfile` | Keyed by CoreAudio UID (never `Device.id`, never the name) so the curve belongs to the speaker and comes back on every connect. Validated on load: gains and trim clamped, non-finite bands dropped, chain capped at 16 sections, unreadable data collapses to "no curves". A bypassed record keeps its curve. |
| Per-device stereo image | `UserDefaults` key `syncast.deviceStereoImage.v1`, JSON-encoded array of `DeviceStereoImageProfile` | Keyed by CoreAudio UID, like the equalizer curve, because the setting describes a cabinet and the seat in front of it. Validated on load: width, corner, attenuation, strength, geometry and band edges clamped and snapped to the UI grid, non-finite values replaced by their defaults, an inverted band re-ordered, unreadable data collapses to "no settings". The feedback coefficient is clamped below 1 here as well as in the processor — a value of 1 or more would be a runaway, not merely a wrong setting. A bypassed record keeps its setting. |
| Per-device local delay | `UserDefaults` key `syncast.localDelayTrimMs.v1`, JSON-encoded array of `LocalDelayTrimProfile` | Keyed by CoreAudio UID so the value belongs to the speaker (a display's panel adds its latency every time it is plugged in). Separate from `syncast.deviceDelayTrimMs` above: same unit, different correction, different leg, half the range — see §8c. Validated on load: UIDs trimmed, duplicates and zeros dropped, values clamped to ±100 ms. |
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

## 8b. Per-device equalizer (2026-09-05)

"这个音响的低音太厉害" — a per-speaker tone control in dB that is remembered on
the device and re-applied on every connect.

- **Where**: `EqualizerBank` inside `LocalOutput.render()`, one independent
  chain per output channel pair (= per physical subdevice in aggregate mode),
  after the splat and before the gain stage.
- **Filters**: RBJ Audio EQ Cookbook biquads. Default layout is a ten-band ISO
  graphic EQ (31.5 Hz … 16 kHz, peaking, Q = 1.41, ±12 dB in 0.5 dB steps) plus
  a ±12 dB pre-gain trim. The band record is fully parametric, so a parametric
  editor would need no store migration.
- **RT safety**: no allocation on the render thread; coefficients are computed
  on the app thread and published through a staging buffer plus a
  generation-counted atomic, so the render thread takes a lock only on the
  block that adopts a change. A flat pair returns after two atomic loads.
- **Smoothing**: two coefficient banks per pair with a 20 ms linear crossfade,
  rather than interpolating coefficients (which has no stability guarantee).
  Filter state carries over when the chain shape is unchanged, so moving one
  slider does not restart the other nine sections.
- **Clip protection**: hard clamp to ±1.0 with a lock-free count, surfaced as
  `eqClip:<n>` in the diagnostic line (only when non-zero) and as a live
  warning in the editor.
- **Scope**: every leg whose samples this process renders — the `localOutputs`
  pairs in Local Stereo, and in whole-home each `LocalAirPlayBridge` (same UID
  key, same bank, same position on the signal) plus ONE group curve for all
  AirPlay receivers together, applied in `AudioSocketWriter` upstream of
  OwnTone's fan-out under a reserved pseudo-UID. NOT Direct Stereo (the HAL
  renders straight into the public aggregate); the UI hides the control there
  and annotates a stored curve that is not being applied.
- **Re-application**: the Router holds the whole UID → curve map and re-applies
  it at the end of every `reconcileLocalDriver` and every `replan()`, both
  idempotent. That, not the UI, is what makes "每次连接都默认这样" true across a
  replug or an aggregate rebuild.
- Full rationale and the measured ten-band response table:
  [requirements_2026-09-05-equalizer.md](requirements_2026-09-05-equalizer.md).

## 8b-2. Per-device stereo image (2026-09-05)

Better left/right separation on a compact stereo speaker whose two tweeters sit
a few centimetres apart above a shared mono woofer. Two stages, each
individually switchable, plus one A/B bypass for the module.

- **Where**: `StereoImageProcessor`, immediately after `EqualizerBank` and
  before the gain stage, in both `LocalOutput.render()` (per channel pair) and
  `LocalAirPlayBridge.render()` (one pair).
- **Stage 1 — mid/side width**: `S' = S + (width−1)·HP(S)` with a second-order
  Butterworth high-pass on the side signal (default corner 1500 Hz), plus an
  optional −1…0 dB mid trim. Mono-compatible by construction: `L'+R'` is
  independent of `width`. Width applies only above the corner, because below
  the cabinet's own crossover there is no side signal to widen.
- **Stage 2 — recursive crosstalk cancellation (RACE)**: `L' = L − a·z^(−τ)·R'`,
  `R' = R − a·z^(−τ)·L'`, band-limited to `[lowHz, highHz]` (default
  1500–7000 Hz) by splitting `band = LP(HP(x))` and carrying `rest = x − band`
  around the stage, so the split sums back exactly. τ is derived from geometry
  (`span·0.15/distance/343`, ≈114 µs ≈ 5.5 samples at 48 kHz for the defaults)
  and read through a **linear fractional-delay interpolator** — chosen because
  its magnitude is ≤ 1, so loop stability needs no argument beyond `|a| < 1`;
  the cost is ≈0.95 dB of HF loss at 7 kHz on the crosstalk path.
- **Stability**: `a` is clamped below 1 at the load boundary, τ to at least one
  whole sample (the recursion reads its own past output), and the feedback path
  carries a per-sample finite check, denormal flush and magnitude ceiling.
- **Colouration**: the recursion inherently boosts centred content by `1/(1−a)`
  at `1/(2τ)` (+12 dB at full strength, hence the 60 % default). Printed in the
  panel next to the sliders rather than left to be discovered by ear.
- **RT safety / smoothing / clip protection**: identical to the equalizer's —
  no allocation, generation-counted publish, two parameter banks with a 20 ms
  crossfade (delay line and filter state carried over), hard clamp to ±1 with a
  lock-free count surfaced as `imgClip:<n>` in the diagnostic line.
- **Scope**: the `localOutputs` pairs in Local Stereo and each
  `LocalAirPlayBridge` in whole-home, under the same CoreAudio UID key. NOT the
  AirPlay group (crosstalk cancellation describes one cabinet and one seat, so
  there is nothing sensible to share across receivers) and NOT Direct Stereo.
- **Re-application**: `Router.applyStereoImages()` alongside `applyEqualizers()`
  in every `reconcileLocalDriver` and `replan()`; store is
  `syncast.deviceStereoImage.v1`.
- Full rationale, the fractional-delay error analysis and the sweet-spot
  caveats: [requirements_2026-09-05-stereo-image.md](requirements_2026-09-05-stereo-image.md).

## 8c. Per-device delay compensation, local Stereo (2026-09-05)

A display's panel applies its own audio processing after the HAL hands the
samples over and declares none of it, so it plays tens of milliseconds behind
the built-in output with nothing in the system aware of the gap. This is the
per-device millisecond control that closes it, remembered on the device.

- **Where**: a per-channel-pair read offset in `LocalOutput.render()` — pair
  `p` reads the ring at `startFrame + window − offset(p)`, so a larger offset
  means older audio and a later-sounding speaker. Offsets are non-negative
  holds (nothing can be played early) and are normalised so the earliest output
  sits at 0, which preserves every pairwise difference and adds no latency to
  the earliest speaker.
- **Ring budget**: `RingReadPlanner`/`RingReadSequencer` take a
  `readWindowFrames` and deepen the floor by it, so the pair reading highest
  still has `floor + block` frames ahead of it; underrun and water level are
  judged at the top of the window. A window change is compensated by an equal
  and opposite shift of the shared cursor, so adjusting one device does not
  move any other. `readWindowFrames: 0` is the original arithmetic exactly.
- **Automatic seed**: each device starts at the negative of the latency it does
  report (`kAudioDevicePropertyLatency` + safety offset + stream latency, plus
  the aggregate's per-subdevice extra latency), so honest hardware lines up
  before the user touches anything and the control only has to cover what
  nothing reports. Probed when the covered set changes, logged once per value,
  capped against the ring's headroom so a broken probe cannot mute a speaker.
- **RT safety**: `PairDelayBank` — no allocation, generation-counted publish,
  and a fast path that keeps the original single-read splat while every offset
  is 0 (bit-identical output for anyone who never touches it).
- **Smoothing**: 20 ms linear crossfade between the outgoing and incoming read
  positions, because the control is a slider and a resync per commit would be a
  click per 50 ms of drag.
- **Scope**: the `localOutputs` render path only, exactly as §8b. NOT Direct
  Stereo, and NOT whole-home — that path has its own per-output trim
  (`DeviceDelayTrim`, §5 "User trim"), which is a different correction on a
  different leg and is stored separately.
- **Re-application**: the Router holds the whole UID → milliseconds map and
  re-applies it at the end of every `reconcileLocalDriver` and every
  `replan()`, both idempotent.
- Full rationale:
  [requirements_2026-09-05-local-delay-trim.md](requirements_2026-09-05-local-delay-trim.md).

## 8d. Per-device channel assignment (2026-09-05)

Which source channel each output plays, as a 2×2 gain matrix per channel pair.

- **Where**: `ChannelMatrixBank`, immediately after `StereoImageProcessor` and
  before the gain stage, in `LocalOutput.render()` (per pair),
  `LocalAirPlayBridge.render()` (one pair) and `LanReceiverOutput`'s producer.
- **Presets**: 立体声 `[[1,0],[0,1]]`, 左 `[[1,0],[1,0]]`, 右 `[[0,1],[0,1]]`,
  单声道 `[[.5,.5],[.5,.5]]`, plus 自定义 with four −∞…+6 dB sliders. 左/右 put
  the chosen channel on BOTH output channels: the target is one cabinet with
  two drivers, not half a pair. 单声道 sums at exactly 0.5 so correlated full
  scale lands at full scale rather than clipping.
- **RT safety**: no allocation, generation-counted publish, and a fast path at
  立体声 that leaves the buffer byte-identical.
- **Smoothing**: a 20 ms **coefficient ramp**, not two parallel chains. The
  operator is memoryless and linear, so interpolating the matrix is exactly
  equivalent to crossfading two chains' outputs — unlike a biquad or a delay
  line, where it is not.
- **Clip protection**: hard clamp to ±1 with a lock-free count, surfaced as
  `matClip:<n>` in the diagnostic line.
- **Scope**: one leg WIDER than the stereo imager's — the `localOutputs` pairs,
  the `localBridges`, AND the LAN receiver legs. NOT the whole-home AirPlay
  group (one stream, so one assignment for the whole house) and NOT Direct
  Stereo.
- **Re-application**: `Router.applyChannelMatrices()` alongside
  `applyEqualizers()` in every `reconcileLocalDriver` and `replan()`; store is
  `syncast.deviceChannelMatrix.v1`, keyed by output UID (`ca:`/`lan:`).
- Full rationale:
  [requirements_2026-09-05-channel-matrix.md](requirements_2026-09-05-channel-matrix.md).

## 8e. LAN receiver output (2026-09-05)

A second Mac running the `synccast-receiver` daemon, playing as one leg of the
local Stereo path at ≤ 100 ms rather than AirPlay's ~1.8 s.

- **Discovery**: `LanReceiverDiscovery` browses `_synccast-pcm._udp` and
  produces `Device` records with `transport == .lanReceiver`, identified by
  their Bonjour instance name (`persistenceKey` = `lan:<instance name>`).
- **Wire format**: [`proto/lan-pcm-link.md`](../proto/lan-pcm-link.md) — TCP
  newline-JSON control, UDP audio, 240 frames of Int16 LE per 5 ms packet
  behind a 24-byte header.
- **Timing**: `RingWriteClock` maps ring frames to sender monotonic ns with a
  minimum-filtered, deadbanded PI loop; `LanSendPlanner` holds the cursor a
  constant distance behind the producer and sends whole packets. The receiver
  closes its own DAC-clock difference with a water-level PI loop and a
  fractional resampler.
- **Alignment**: `LanAlignmentPlanner` computes how far the local CoreAudio
  legs must be held back to land with the receiver, and it is applied as
  `LocalDelayTrimPlanner`'s `extraHoldFrames` — after normalisation, because a
  constant added to every per-device seed would cancel to nothing.
  `LocalDelayTrim.maxOffsetMs` went 500 → 800 ms so the hold cannot reach the
  clamp at the top of the target slider.
- **Volume**: the sink master travels as a `gain` control message so the
  receiver can use its own hardware volume; the per-device balance and the
  render chain are applied on the sender before packetising.
- **Security**: RFC1918/link-local/loopback peers only, a shared token in the
  **keychain** (`syncast.lanReceiverTokens.v1`), never logged.
- **Scope**: local Stereo only, and not on Direct Stereo (no capture ring to
  read). Never whole-home.
- Full rationale, timing model and honest latency expectations:
  [requirements_2026-09-05-lan-receiver.md](requirements_2026-09-05-lan-receiver.md).

## 9. Build & distribution

- Swift Packages built with the Xcode 15+ toolchain (`swift build`).
- Python sidecar bundled inside the .app via PyInstaller into a single binary; no system-Python dependency.
- Notarized via `xcrun notarytool`. Distributed as a `.pkg` from GitHub Releases.
- No BlackHole bootstrap is required for the current alpha. Local Stereo prefers the system-sink path when a sink device is installed and falls back to Direct Stereo otherwise; whole-home prefers the same sink device and falls back to BlackHole. With `SyncCastAudio.driver` installed, BlackHole can be uninstalled entirely (`sudo rm -rf /Library/Audio/Plug-Ins/HAL/BlackHole2ch.driver && sudo killall coreaudiod`). `scripts/bootstrap.sh` installs BlackHole only when neither sink is present. Process Tap is the intended replacement for ScreenCaptureKit on capture-dependent paths.
- `drivers/SyncCastAudio` is built by its own `build.sh` (clang, universal, ad-hoc or "SyncCast Dev" signed) and installed with sudo. It is NOT part of the .app bundle: HAL plug-ins must live in `/Library/Audio/Plug-Ins/HAL`.

## 10. ADRs

- [ADR-001: Capture via IOProc on BlackHole, not AVAudioEngine](adr/ADR-001-capture-strategy.md)
- [ADR-002: One AUHAL per local output](adr/ADR-002-fanout-strategy.md)
- [ADR-003: Python sidecar for AirPlay 2 (pyatv)](adr/ADR-003-airplay-sidecar.md)
- [ADR-004: Pad-the-fast-path sync](adr/ADR-004-sync-strategy.md)
- [ADR-005: MenuBarExtra + @Observable for UI](adr/ADR-005-ui-stack.md)
- [ADR-006: OwnTone for AirPlay 2 streaming](adr/ADR-006-owntone-streaming.md)
- [ADR-007: Own the system volume with a virtual sink, not an event tap](adr/ADR-007-system-sink-volume.md)
