# ADR-007: Own the system volume with a virtual sink, not with an event tap

**Status**: Accepted · 2026-09-05 · supersedes the media-key half of the
2026-06-12 volume round (`docs/requirements_2026-06-12.md`)

## Context

SyncCast's local Stereo path plays one stereo stream on several real outputs
at once. macOS has no volume control for that arrangement:

- an aggregate / multi-output device exposes no
  `kAudioDevicePropertyVolumeScalar` — measured 2026-09-05 on both SyncCast's
  Direct Stereo aggregate and the user's own Audio MIDI Setup multi-output
  device (`has=false` on every element);
- so while Direct Stereo is the default output, the menu-bar slider is greyed
  out, F11/F12 produce the "forbidden" HUD, and third-party volume helpers
  have nothing to drive.

The 2026-06-12 round worked around this with `SystemVolumeKeyController`, a
`CGEventTap` that consumes the media keys and translates them into per-device
hardware/DDC writes. That works, but:

- it needs Accessibility permission, which the user must grant by hand;
- it takes the keys away from every other app for as long as SyncCast runs —
  concretely, LinearMouse's own volume HUD breaks while SyncCast is running;
- it only handles the KEYS. The menu-bar slider and the HUD stay dead, so the
  system's own volume UI still lies about what is happening.

The user's request was explicit: the macOS volume UI itself should control the
MacBook Pro speakers + ExternalDisplay playing together, not a key interceptor.

## Decision

Give macOS a device it *can* control, and re-apply the level ourselves.

1. **Sink**: a virtual HAL output device that has volume + mute controls
   becomes both `kAudioHardwarePropertyDefaultOutputDevice` and
   `kAudioHardwarePropertyDefaultSystemOutputDevice` while the path runs. Two
   are accepted, detected at runtime: our own `SyncCastAudio.driver`
   (`SyncCastAudio_UID`, preferred) and `BlackHole2ch_UID` (fallback, already
   installed on many machines).
2. **Capture**: a Core Audio Process Tap pinned to the sink
   (`CATapDescription.deviceUID`), excluding our own process.
3. **Output**: the existing chain — tap ring buffer → private aggregate → one
   AUHAL with per-channel-pair gain. Unchanged machinery, new producer.
4. **Volume law**: the sink's `VolumeScalar` IS the system volume. A property
   listener forwards it to the Router, which applies it per output: copy the
   scalar to devices with real hardware volume, VCP 0x62 percent to DDC
   displays, dB-converted amplitude in the render path to everything else.
5. **No event tap on this path.** `SystemVolumeKeyController` stays only for
   the legacy Direct Stereo path and for whole-home.

## Why this works — the two measurements it rests on

**The tap is pre-driver.** A Process Tap pinned to a device captures what
applications rendered, before the device's own volume control. Measured
2026-09-05: a 1 kHz tone into BlackHole, captured RMS `0.35355` at sink scalar
1.0, 0.5 and 0.0 alike (ratios 1.0000). So the sink's scalar is pure user
*intent*, free for us to reuse as the master volume, and BlackHole's own
dB-linear attenuation of its loopback data never touches what we capture.

**One dB law fits everything.** macOS's built-in speaker control is linear in
decibels over `[-63.5, 0] dB` (measured: 0.25→-47.6, 0.50→-31.8, 0.75→-15.9),
and BlackHole's is the same curve with a -64 dB floor. So copying the scalar
1:1 onto a hardware device reproduces exactly what macOS would have done
natively, and our own driver advertises the same range so its slider feels
identical to the built-in one.

## Alternatives considered

**Keep the event tap and add slider support.** Not possible: the menu-bar
slider and HUD are driven by the default device's HAL properties. Without a
volume-controllable default device there is nothing to drive, whatever we do
with keys.

**Publish a fake volume control on the aggregate.** `AudioObjectSetPropertyData`
on an aggregate's non-existent property fails; aggregates are built by
coreaudiod from a composition dictionary and we cannot add controls to one.

**One IOProc reading the tap and writing the outputs in the same aggregate**
(instead of tap → ring → separate AUHAL). Lower latency in principle, but it
merges two clock domains into one callback and throws away the drift
compensation and per-device delay machinery that already works. Rejected for
THIS round on reliability grounds — the ring-buffer chain is the same
structure the SCK path has run for months — but the measured budget below
(~71 ms added, target ≤30 ms) means latency is now a live argument for
revisiting it. The cheaper levers come first: the 50 ms scheduler margin is
the dominant term and a constant, and declaring the chain latency on the
driver would restore A/V sync without touching the audio path at all.

**Make whole-home share the sink observer.** Whole-home's default output is its
own silent aggregate and its master fader lives in `AudioSocketWriter` on
OwnTone's −30 dB curve — a different quantity in a different place. Mapping
between the two is real work with real failure modes; out of scope here, so
whole-home keeps its event tap. Stated as a known limitation rather than
silently half-done.

## Consequences

- The Sound menu shows "SyncCast" (or "BlackHole 2ch") as the output while the
  path runs. Deliberate and surfaced in the popover, but it IS a visible change
  and the thing a user is most likely to "fix" by picking their speakers again.
- Picking another output while running is treated as intent: SyncCast stops
  routing and stays stopped until told otherwise. It never re-asserts the
  default output on a timer — that would fight a deliberate choice (the same
  policy `WholeHomeSinkOutput` already documents).
- The system slider becomes the single source of truth for level. An external
  change to a downstream device (display OSD, Audio MIDI Setup) is overwritten
  on the next replan rather than mirrored back — that is what keeps the loop
  from oscillating.
- **The sink path costs latency that Direct Stereo does not.** Direct Stereo
  has apps render straight into the aggregate — no capture, no ring, ~0 added.
  The sink path pays the capture chain: measured on this machine (probe
  `--latency`, from device properties) 10.67 ms sink IO buffer + 10.67 ms
  output IO buffer + 50 ms of `Scheduler.plan(safetyMarginMs:)` ring pre-roll
  = ~71 ms added, against a ≤30 ms target. The dominant term is pre-existing
  and shared with the SCK capture path, not introduced here. Two levers exist
  and neither was pulled in this round: lowering the safety margin (trades
  dropout headroom, needs a listening test rather than a blind edit), and
  declaring the chain latency on the driver's `kAudioDevicePropertyLatency` so
  video players compensate. Until then, video is the case to judge by ear —
  the player believes audio lands at the sink's presentation time and does not
  know about the downstream chain.
- SyncCast now ships a kernel-adjacent component: a HAL plug-in installed to
  `/Library/Audio/Plug-Ins/HAL` with sudo, whose install restarts coreaudiod.
  The BlackHole fallback exists so the feature works before anyone types a
  password, and so a broken driver is never the only path.
- Without either sink installed, nothing changes: the legacy Direct Stereo path
  and its event tap run exactly as before.
