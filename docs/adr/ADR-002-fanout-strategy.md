# ADR-002: One AUHAL per local output, not a Multi-Output Aggregate

**Status**: Accepted · 2026-04-25

## Context

For local fan-out (built-in speakers, USB DAC, HDMI/DP display speakers), macOS offers two choices:

1. Create an **Aggregate Device** with `kAudioAggregateDeviceIsStackedKey = 1` (Multi-Output Device) and let CoreAudio drive all sub-devices from one render.
2. Open **one AUHAL (`kAudioUnitSubType_HALOutput`) per physical output**, all reading from a single ring filled by the BlackHole capture, and apply per-device gain & delay in our render callback.

## Decision

Use **option 2: one AUHAL per local output**.

## Rationale

- Multi-Output Device hides the per-leg control we need:
  - No per-sub-device volume slider (the OS-level one is global to the aggregate).
  - No per-sub-device delay/trim. AirPlay 2 receivers have ~1.8 s end-to-end latency; without per-leg delay, the local outputs play 1.8 s ahead of the AirPlay ones.
- One AUHAL per output gives us a render callback per device, where we trivially:
  - apply per-device gain,
  - read at a per-device offset on the ring buffer (= per-device delay),
  - emit per-device sync metrics.
- Drift correction (PI loop nudging by ±1 sample) is straightforward inside that callback.

## Consequences

- We hand-write the render callback. CoreAudio expects it to be RT-safe; same constraints as the capture IOProc.
- Per-device sample-rate mismatch becomes our problem: we need to handle a USB DAC at 96 kHz vs. built-in at 48 kHz. v1 forces all outputs to the master 48 kHz; mismatched devices are flagged with a UI warning. v2 may add per-output ASRC.

## Alternatives considered

- **System Multi-Output Device + AppleScript glue** — half the integration with none of the per-device control. Rejected.
- **Aggregate Device only as a sample-clock sync source** (drive all local outputs from one master clock) — doesn't actually buy us anything because we're not sample-synchronous between local and AirPlay anyway, and within local outputs the Mac's clock domain is shared.
