# SyncCast Roadmap

> Last updated: 2026-05-16. See `docs/GOAL.md` for the active Goal loop and product truth.

## Current Reality

- **Working core:** Stereo mode with local CoreAudio outputs is user-verified as very stable.
- **Resolved:** Stereo screen-sleep / wake recovery now resumes playback normally per user verification.
- **Blocking:** ScreenCaptureKit capture triggers Screen Recording semantics and breaks DRM playback. Local Stereo now defaults to Direct Stereo, but real DRM playback checks are still pending.
- **Experimental:** Whole-home / AirPlay devices can all output sound, but SyncCast has not proven reliable Local CoreAudio vs AirPlay-group alignment over long sessions. AirPlay receiver-to-receiver timing is treated as the AirPlay/OwnTone timing domain unless future evidence says otherwise.
- **Active measurement path:** passive no-probe capture/monitor is the preferred AirPlay reliability path after audible probe reports. It now uses dual waveform/envelope agreement and drift-slope evidence, but no successful live Logitech passive corpus has been promoted to automatic apply.
- **Local-only VCS state:** current Goal work is installed locally but not pushed to GitHub/origin.

## Milestone 1: Freeze Stereo Stability

- [x] Verify Round 12 v4 on real screen sleep/wake with local Stereo output.
- [ ] Capture and archive a representative pass log sequence from `~/Library/Logs/SyncCast/launch.log`.
- [ ] Keep device persistence and recovery keyed by CoreAudio UID, never `AudioDeviceID`.
- [ ] Preserve AggregateDevice + AUHAL behavior while changing capture and output paths.

## Milestone 2: DRM-Safe Local Stereo

- [x] Add `SYNCAST_STEREO_PATH=direct` prototype for a public CoreAudio aggregate / multi-output default device.
- [x] Smoke-test Direct Stereo for one local output and two local outputs without SCK startup or Screen Recording preflight.
- [x] Block app termination if Direct Stereo cannot safely restore/move the macOS default output.
- [ ] Runtime-validate Direct Stereo default-output restore under quit, failed start, user-changed default output, and stale public aggregate cleanup.
- [ ] Add a reproducible SCK DRM-block test and Direct Stereo DRM pass checklist.
- [ ] Verify Netflix / Apple TV+ / Disney+ playback while two local outputs are active.
- [ ] Decide whether Direct Stereo Output becomes the default Stereo path.

## Milestone 3: Capture Without Screen Recording

- [x] Document the Core Audio Process Tap API in `docs/research/process_tap_api.md`.
- [x] Introduce a `SystemAudioCapture` abstraction so Router does not hard-code `SCKCapture`.
- [x] Add `NSAudioCaptureUsageDescription`.
- [x] Gate Screen Recording prompts to SCK mode only.
- [x] Add installed-app smoke harness for Process Tap path (`scripts/tap_capture_smoke_test.sh`).
- [x] Fail closed when Tap is explicitly requested on an unsupported macOS instead of falling back to SCK.
- [ ] Runtime-harden `TapCapture.swift`: startup timeout, aggregate input validation, format/SRC handling, RT-safe callback state, and death callbacks.
- [ ] Validate Tap mode for capture-dependent paths: AirPlay, calibration, and future routing.
- [ ] Keep SCK as fallback for unsupported OS versions or Tap startup failure.

## Milestone 4: AirPlay Truth And Measurement

- [ ] Label Whole-home / AirPlay mode experimental in docs and UI until proven reliable.
- [x] Fix Local + AirPlay delay slider so it pushes `local_fifo.set_delay_ms` instead of only changing UI state.
- [x] Make sidecar `stream.start` idempotent so repeated pushes do not clear/restart OwnTone playback.
- [ ] Add a group start barrier and explicit late-join / resync behavior.
- [ ] Use OwnTone `offset_ms` only for measured stable per-device bias.
- [x] Disable automatic delay writes for multi-AirPlay group measurements until per-receiver evidence exists.
- [x] Add passive no-probe estimator/capture/monitor scaffolding with fail-closed context gates.
- [x] Add dual waveform/envelope estimator agreement and drift-slope evidence.
- [ ] Collect a live passive Logitech corpus for Local + AirPlay with ordinary program audio.
- [ ] Keep passive apply in dry-run until two independent same-context sessions pass audit/finalize/correction gates.
- [ ] Build a long-session AirPlay test protocol: 2+ receivers, 2+ hours, skew/drift logs.
- [ ] Rerun long Local + AirPlay drift after the 2026-05-07 retry/threshold/mic host-time changes; the last `display,xiaomi 900 6 60` run failed health gates despite several stable-looking cycles.
- [ ] Capture recovery behavior for sleep/wake, receiver restart, network drop, sidecar restart, and OwnTone restart.
- [ ] Add diagnostics for sidecar/OwnTone buffer health, receiver state, packet timing, and local bridge lag.
- [x] Add drift health gates for applied error, confidence, uncertainty/MAD, malformed JSON, and transport-counter failures.

## Milestone 5: Product Readiness

- [ ] Package and install loop remains one-command and TCC-stable.
- [ ] Release notes clearly separate stable Stereo mode from experimental AirPlay mode.
- [ ] Add a first-run flow that explains Direct Stereo, Tap, and SCK permissions accurately.
- [ ] Add persistent routing by stable device identity across restarts.
- [ ] Define a release gate: build, tests, package, install, local Stereo smoke, DRM smoke, sleep/wake smoke, and AirPlay drift smoke when AirPlay code changes.

## Deferred / Future

- Native Swift AirPlay 2 sender, if OwnTone cannot meet SyncCast's sync/recovery requirements.
- AudioServerPlugIn / DriverKit virtual audio device fallback, if Direct Stereo Output and Process Tap do not satisfy DRM or routing requirements.
- Multi-zone streams.
- Snapcast or generic RTP transports.
