# SyncCast vNext Requirements Report

> Date: 2026-05-03
> Inputs: user field feedback, six-agent review, local code audit, and AirPlay / CoreAudio research.

## Executive Summary

SyncCast should now be treated as a Stereo-first product with an experimental AirPlay track.

The user-verified stable path is Stereo local CoreAudio output. The screen-sleep / wake recovery issue is resolved. The two remaining blockers are:

- DRM playback breaks under ScreenCaptureKit.
- AirPlay can output on all selected devices, but Local + AirPlay alignment is the immediate unresolved problem: local playback and AirPlay playback must have a working, user-controllable delay.

The next product direction is:

1. Protect Stereo and make it DRM-safe.
2. Stop treating AirPlay as solved; turn it into a measured experimental mode.
3. Implement low-risk AirPlay stabilization before attempting larger protocol work.

## Current Product Facts

### Stable

- Stereo local mode is very stable in real use.
- Stereo screen-sleep / wake recovery now resumes audio normally.
- CoreAudio UID must remain the persistence key.

### Not Stable

- AirPlay / Whole-home can make all devices produce sound, but Local + AirPlay alignment needs a working control path.
- Broader AirPlay long-session reliability is still not solved.

### Blocking

- ScreenCaptureKit carries Screen Recording semantics.
- DRM services can refuse playback or show black video while SyncCast is running.
- This blocks the "always-on menubar utility" product promise.

## Requirements

### R1: Stereo Must Stay Stable

Stereo is the product core, not a fallback.

Acceptance:

- Two local outputs play together.
- Natural display sleep / wake recovers automatically.
- Device disappearance/reappearance resolves by CoreAudio UID.
- Changes for Tap, Direct Stereo, or AirPlay cannot regress this path.

### R2: Default Stereo Must Avoid SCK

Stereo should not require Screen Recording. The preferred path is Direct Stereo Output: SyncCast creates/manages a public CoreAudio aggregate or multi-output device and makes it the system default output while active.

Acceptance:

- No Screen Recording prompt.
- No System Audio Recording prompt for the direct path.
- Netflix / Apple TV+ / Disney+ can play while SyncCast drives two local outputs.
- Previous default output is restored on stop/quit.

### R3: Tap Capture Must Be Hardened For Capture-Dependent Paths

Process Tap remains important for AirPlay, calibration, and future routing.

Acceptance:

- `SYNCAST_CAPTURE_BACKEND=tap` does not trigger Screen Recording.
- Startup cannot hang forever waiting for tapped audio.
- Aggregate input stream and actual format are validated.
- Callback state is real-time safe.
- Backend death or coreaudiod restart surfaces through `onUnexpectedStop`.

### R4: Local + AirPlay Delay Must Be Controllable

Whole-home mode must let the user tune local playback against AirPlay playback.

Acceptance:

- The UI slider calls `setAirplayDelay()`, not a local-only assignment.
- `local_fifo.set_delay_ms` receives the applied delay.
- The applied value persists in UserDefaults.
- `~/Library/Logs/SyncCast/launch.log` records `airplayDelay applied: ...ms`.
- The user can move local playback earlier or later relative to AirPlay by changing the value.

### R5: AirPlay Must Become Measurement-Driven

AirPlay is experimental until measured.

Acceptance:

- `stream.start` is idempotent for the same active set.
- New groups start with a barrier: resolve outputs, enable exact targets, verify selected state, then start pipe playback once.
- Late joins are explicit, not silent timeline mixing.
- OwnTone `offset_ms` can be set from measured stable offsets.
- Long-session tests record skew, drift, packet/buffer health, and recovery.

## Milestones

### M1: Lock Stereo Baseline

Deliver:

- Archive pass logs for Stereo dual-output and sleep/wake.
- Add Stereo smoke steps to the release gate.

### M2: DRM-Safe Stereo Prototype

Deliver:

- `SYNCAST_STEREO_PATH=direct`.
- Public aggregate / multi-output lifecycle.
- Default output switch and restore.
- DRM negative/positive test report.

### M3: Tap Runtime Hardening

Deliver:

- SCK-only Screen Recording prompt gating.
- Tap startup health gate.
- Format conversion or explicit unsupported-format failure.
- RT-safe callback counters and diagnostics.

### M4: AirPlay First Stabilization

Deliver:

- Idempotent `stream.start`.
- Group generation logs.
- Group barrier design.
- OwnTone output state / `offset_ms` diagnostics.

### M5: AirPlay Reliability Decision

Deliver:

- 2+ receiver, 2+ hour test report.
- Recovery matrix: sleep/wake, receiver restart, network drop, sidecar restart, OwnTone restart.
- Decision: keep OwnTone, replace sender, or keep AirPlay hidden/experimental.

## Non-Goals For The Next Iteration

- Claiming AirPlay is reliable based only on "all devices have sound".
- Building a native AirPlay 2 sender before measuring OwnTone's actual limits.
- Shipping a DriverKit or HAL plug-in unless Direct Stereo Output and Process Tap fail.
- Reworking the stable Stereo path before its regression tests are in place.

## Immediate Execution Plan

1. Update Goal and docs with this truth reset.
2. Implement sidecar `stream.start` idempotency. Status: landed locally on 2026-05-03.
3. Gate Screen Recording prompts to SCK mode only. Status: landed locally on 2026-05-03.
4. Design the Direct Stereo Output prototype.
5. Ask the user to run two manual tests after the next local build: Stereo regression and AirPlay two-device sync with logs.
