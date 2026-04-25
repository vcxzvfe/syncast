# ADR-001: Capture via IOProc on BlackHole, not AVAudioEngine

**Status**: Accepted · 2026-04-25

## Context

SyncCast needs to capture system audio from BlackHole (a virtual audio driver users install) and re-emit it to many physical/network outputs. macOS offers three ways to read audio from a CoreAudio device:

1. **`AVAudioEngine` `installTap` on the inputNode**
2. **`AudioUnit` (`kAudioUnitSubType_HALOutput`) configured for input**
3. **`AudioDeviceCreateIOProcIDWithBlock` directly on the device**

## Decision

Use **`AudioDeviceCreateIOProcIDWithBlock`** directly on BlackHole.

## Rationale

- `AVAudioEngine` cannot bind input and output to *different* non-default devices. Our app runs while the system's default output is BlackHole; we want to capture from BlackHole and output to other devices simultaneously. This is unsupported by AVAudioEngine.
- Direct IOProc is the lowest-overhead path: a single block runs on a real-time CoreAudio thread, no AVF graph in the middle, no format conversions we don't ask for.
- Format is predictable: BlackHole always advertises Float32 non-interleaved at the device's nominal sample rate. We lock to 48 kHz at startup.

## Consequences

- The IOProc runs on a real-time thread; we must not allocate or take ordinary locks inside it. The `RingBuffer` uses `OSAllocatedUnfairLock` (bounded-wait, RT-safe at this granularity).
- Sample-rate mismatch is silent in CoreAudio; we explicitly assert nominal rate at start and surface a setup error if BlackHole isn't configured to 48 kHz.
- We need `NSMicrophoneUsageDescription` in Info.plist even though BlackHole is virtual (TCC treats it as audio input).

## Alternatives considered

- **AVAudioEngine** — rejected because of the dual-device limitation above.
- **AUHAL for input** — works but adds an AudioUnit graph layer with no benefit when we already manage the output side ourselves. We use AUHAL on the *output* side (ADR-002).
- **ScreenCaptureKit system audio (Sequoia)** — interesting because it removes the BlackHole dependency entirely. Tracked as a v2 candidate; v1 sticks with BlackHole because it's well-understood and works on Sonoma.
