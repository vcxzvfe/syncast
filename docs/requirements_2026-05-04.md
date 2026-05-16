# SyncCast Requirements Report

> Date: 2026-05-05
> Source: user field feedback, real Goal state, six Codex review agents, local build/test loop.

## Executive Summary

SyncCast remains a Stereo-first product.

Stereo local mode is user-verified stable, including screen sleep / wake recovery. AirPlay / Whole-home is experimental: all selected devices can produce sound, and manual Local + AirPlay delay can be tuned, but automatic microphone calibration has not been reliable enough for long-session use.

This iteration changes the AirPlay calibration requirement from "estimate and apply" to "measure, reject bad data, and preserve known-good manual settings." A wrong automatic calibration must do nothing.

User correction on 2026-05-04: the product must not ask the user to find a fixed AirPlay delay number. AirPlay group latency can vary between sessions, route changes, interruptions, and tests. Reliable SyncCast behavior means measuring the current route state, repeating the measurement when the correction is large, and applying only when the measurements agree.

## Current Truth

Stable:

- Stereo local CoreAudio mode works well in daily use.
- Stereo screen sleep / wake recovery is resolved.
- Device persistence must continue to use stable CoreAudio UID, never transient `AudioDeviceID`.

Working but experimental:

- Whole-home / AirPlay can make selected AirPlay and local devices play.
- The Local + AirPlay delay slider now applies `local_fifo.set_delay_ms`, persists the result, and logs `airplayDelay applied: ...ms`.
- Manual Local + AirPlay alignment can work, but it is not long-session reliability.
- AirPlay receiver-to-receiver sync should be treated as the AirPlay sender/receiver clock domain's job. SyncCast's immediate job is Local CoreAudio vs AirPlay group alignment.

Unreliable:

- Automatic microphone calibration can produce false peaks or unstable delay targets.
- AirPlay route changes, volume changes, receiver interruptions, and OwnTone restarts can change the effective Local + AirPlay latency.
- Continuous local-only calibration cannot safely apply against stale AirPlay latency data.

Separate blocker:

- ScreenCaptureKit remains a DRM blocker for Netflix, Apple TV+, Disney+, and similar apps. DRM-safe Stereo should be solved through Direct Stereo Output and Process Tap work, not by conflating it with AirPlay sync.

## Requirements

### R1: Preserve Stereo

Stereo is the reliable product baseline.

Acceptance:

- Two local outputs play together.
- Natural display sleep / wake resumes playback.
- Stereo remains usable if AirPlay is hidden, disabled, or broken.
- Future Tap, Direct Stereo, and AirPlay changes cannot regress this path.

### R2: Make Stereo DRM-Safe

Default Stereo should not depend on ScreenCaptureKit.

Acceptance:

- Direct Stereo Output drives local devices without Screen Recording.
- Previous default output is restored on stop or quit.
- DRM playback keeps working while SyncCast drives local output.
- Process Tap remains for capture-dependent paths and must not request Screen Recording.

### R3: Treat AirPlay as Experimental Until Measured

AirPlay reliability requires evidence, not subjective one-time alignment.

Architecture assumption:

- AirPlay/AirPlay 2 already has a multi-receiver timing model: source timestamps, receiver buffering, clock sync, and receiver-side rate correction.
- This is designed for reliable synchronized playback, not low latency. Public AirPlay implementations report classic AirPlay latency around 2.0-2.25s and AirPlay 2 paths as shorter but still buffered.
- SyncCast should not try to independently synchronize AirPlay receivers to each other in the short term. It should treat the AirPlay group as one high-latency clock domain and delay local CoreAudio outputs to match it.
- Per-AirPlay-device acoustic offsets are only valid in explicit TDMA calibration where other AirPlay devices are muted, or in a future architecture that can send a different stream/pilot per receiver.

Acceptance:

- AirPlay UI/docs/release notes keep experimental wording.
- Repeated start/state pushes do not restart OwnTone playback for the same active set.
- AirPlay route, volume, connection, stream, and OwnTone epoch changes invalidate calibration state.
- Long-session tests record delay, drift, packet drops, receiver state, and recovery events.

### R4: Protect Manual Local + AirPlay Delay

Manual delay is currently the user's reliable control surface.

Acceptance:

- Locking the delay prevents automatic calibration from applying changes.
- A single large calibration jump is not applied automatically.
- Large automatic corrections require repeated agreement in the same route, volume, mute, and microphone context.
- Background calibration stops while delay is locked.
- No-apply diagnostic calibration never writes the delay; the explicit `calibrate_apply` diagnostic path may write only after the same safety gates pass.

### R5: Fail Closed On Acoustic Calibration

The calibration algorithm must reject suspect measurements instead of returning plausible but wrong delay values.

Acceptance:

- Local probes run repeated cycles and report MAD.
- AirPlay probes require multiple valid cycles, reject edge peaks, and reject high MAD/range/slope.
- Per-device confidence and uncertainty are exposed through the diagnostic socket.
- A calibration with missing or low-confidence devices fails instead of applying `0ms` or a partial target.

### R6: Keep AirPlay And Local Audio On The Same PCM Epoch

Sidecar transport must not let AirPlay and local bridges receive different PCM bytes.

Acceptance:

- The sidecar frames Swift audio socket data into exact 10ms PCM packets.
- Local bridge tee happens only after OwnTone accepts the same complete packet.
- Local socket short sends reconnect that bridge instead of leaving a byte-shifted stream alive.
- Broadcaster delay queues reset on stream/mode/flush/OwnTone epoch changes.

## Current Iteration Deliverables

Implemented in this iteration:

- Automatic calibration apply gate in `AppModel`.
- Delay lock enforcement for manual and background calibration.
- Continuous calibration hysteresis and per-cycle max step.
- AirPlay calibration cache with route/volume/age validation.
- AirPlay mute/restore hooks during local measurement.
- Repeated local calibration cycles with MAD gates.
- Stricter AirPlay multi-cycle gates.
- High-band coded FSK acoustic fingerprint for Local + AirPlay diagnostic calibration. The current installed probe is continuous-phase FSK at `19.05/19.35/19.65/19.95/20.25kHz`, 48 symbols, 1152ms, no inter-symbol gaps, matched-filter detection. This replaced the earlier `18.2-19.9kHz` gapped symbol train after user audibility feedback.
- AirPlay diagnostic calibration now measures selected AirPlay receivers as one `airplay-group` and aligns local CoreAudio output against that group, instead of assuming SyncCast should independently solve receiver-to-receiver AirPlay sync.
- AirPlay group aggregation uses a dominant-cluster selector before MAD/range/slope gates, so isolated matched-filter false peaks are dropped only when the remaining cluster is tight.
- UI Auto-calibrate now runs an automatic verification pass for large corrections and applies only when the repeated target agrees; the user no longer needs to manually report which slider value sounds closest.
- Diagnostic `calibrate_apply` now also respects the manual delay lock: when locked it returns `reason=delay_locked` and does not emit probes or alter `syncast.airplayDelayMs`.
- Calibration fails closed unless at least one local output and one AirPlay output are enabled, and unless enabled AirPlay receivers are active, unmuted, non-zero-volume, and not in a failed/disconnected state.
- Diagnostic socket now reports per-device confidence, uncertainty, and `applied=false`.
- Sidecar audio framing, local short-send handling, and broadcaster reset.
- Probe buffer lifetime fixes in `LocalAirPlayBridge`: no Swift array ownership in the AUHAL render callback, identity-guarded probe cursor persistence, non-RT retired-buffer drain, and deinit cleanup.

Verification so far:

- `swift build -c debug` passes for `core/router`.
- `swift build -c debug` passes for `apps/menubar`.
- `python3 -m compileall -q sidecar/src` passes.
- `git diff --check` passes.
- `swift test` is blocked by the local toolchain missing `XCTest`, same environment limitation as before.
- Local install completed at `/Applications/SyncCast.app`.
- No-apply diagnostic calibration preserved the user's `airplayDelayMs=2436`.
- The new gates correctly accepted stable local inliers (`145/145ms`, MAD `0ms`) and rejected AirPlay cycles with monotonic drift (`2684/2766/2851/2973/3092ms`, MAD `122ms`, slope about `102ms/cycle`).
- Latest installed build at `/Applications/SyncCast.app` uses high-band coded probes and passed a no-apply diagnostic run: local `+13ms` with confidence `3.10` / MAD `12ms`; AirPlay `+2150ms` with confidence `19.37` / MAD `4ms`; recommended target `2137ms`; `Applied: False`; persisted delay remained `2436ms`.
- Group-mode run passed: local `+15ms`; `airplay-group +2154ms` with confidence `19.40` / MAD `1ms`; recommended target `2139ms`; `Applied: False`; persisted delay remained `2436ms`.
- Clustered false-peak run passed: raw AirPlay candidates included outliers `2512ms` and `1918ms`; selector kept `2149/2163/2157ms`, returned `airplay-group +2157ms` with MAD `6ms`, recommended target `2155ms`, and preserved `airplayDelayMs=2436`.
- Short drift test passed: `bash scripts/drift_test.sh 3 10` recorded targets `2149/2159/2141ms`, total drift `-8ms`, AirPlay group tau stdev `2.1ms`, verdict `STABLE`, and preserved `airplayDelayMs=2436`.
- Latest installed smoke test passed after safety-gate fixes: local `+0ms`; `airplay-group +2156ms` with confidence `22.20` / MAD `1ms`; recommended target `2156ms`; `Applied: False`; persisted delay remained `2436ms`.
- Protected apply test passed: `bash scripts/calibration_apply_test.sh` ran two measurements (`2144ms` then `2141ms`), applied `2141ms` with reason `verified_large_jump`, and persisted `syncast.airplayDelayMs=2141`.
- Post-apply no-apply check passed: diagnostic recommended `2144ms` with AirPlay group MAD `2ms`, `Applied: False`, and preserved persisted delay `2141ms`.
- Latest local install evidence: protected apply made a small session correction from `2141ms` to `2152ms` with confidence `3.14` and reason `small_jump`; a manual-lock regression returned `reason=delay_locked`, `Applied: False`, and preserved `2152ms`; a subsequent no-apply diagnostic recommended `2159ms`, `Applied: False`, and preserved `2152ms`.
- Latest short drift test: `bash scripts/drift_test.sh 3 10` recorded targets `2136/2158/2148ms`, total drift `+12ms`, AirPlay group tau drift `+1ms`, AirPlay group tau stdev `3.8ms`, verdict `STABLE`, and preserved `airplayDelayMs=2152`.
- Post-review hardening: diagnostic provider now refuses one-sided routes, `calibrate_apply` re-reads route/delay state immediately before applying and returns `context_changed` or `delay_changed` instead of overwriting newer user changes, UI auto-apply waits for the router delay commit before reporting `applied=true`, and auto-apply thresholds/range are shared between UI and diagnostic paths.
- Latest post-hardening smoke: protected apply moved `2152ms` to `2147ms` (`confidence=3.20`, `reason=small_jump`); lock regression returned `reason=delay_locked`, `Applied: False`; no-apply diagnostic recommended `2154ms`, `Applied: False`, and preserved `2147ms`.
- UI discoverability fix: the automatic acoustic calibration control is now truthfully labeled `Auto Calibrate`; the previous advanced `Estimate (rough)` label was misleading, and the footer `Calibrate` button was a no-op. The footer now calls the same calibration path and is disabled outside Whole-home mode. The inactive footer `Settings` button was also removed to avoid another fake affordance.
- Event-driven resync update: when `Continuous` is enabled, Whole-home is running, a local output and AirPlay receiver are both enabled, the mic is authorized, and delay is unlocked, route/volume/mute/AirPlay-connected events now schedule a guarded full `Auto Calibrate` after a 10s settle delay with a 90s cooldown. This converts AirPlay interruption/device-change recovery from "remember to click the button" into an opt-in automatic control loop.
- Event-driven resync evidence: with `Continuous` temporarily enabled for testing, Xiaomi reconnect scheduled `autoCalib event running reason=AirPlay receiver connected ...`; full calibration measured local `0ms`, `airplay-group 2159ms`, uncertainty `3ms`, confidence `3.83`, and applied `2159ms` from the previous `2147ms` target. After the test, `syncast.bgCalibrationEnabled` was restored to `0`.
- Event-driven resync review hardening: cooldown events are now deferred instead of dropped, events that arrive during an active calibration are coalesced and rescheduled after the current attempt, duplicate `Auto Calibrate` starts are ignored, successful full calibration attempts refresh the cooldown, disabling `Continuous` cancels any pending event task, the slider range now comes from `AppModel.airplayDelayMsRange`, and the `Continuous` help text describes the actual local-interval + event-full-calibration behavior. Codex re-check reported no findings after the first hardening pass.
- Repro harness: `scripts/event_resync_test.sh` now verifies the opt-in event-driven path by backing up defaults, temporarily enabling `Continuous`, launching Whole-home with `SYNCAST_AUTO_TEST`, watching for `autoCalib event running`, `[ActiveCalib] DONE`, and a trusted `airplayDelay applied` / `autoCalib: applied` result, then restoring defaults/app state on exit with typed `UserDefaults` writes.
- Event-resync failure analysis: one test run exposed an AirPlay group false negative where accepted taus `[2152, 2157]` were joined by three marginal-but-clustered cycles rejected early on `second_ratio ~= 1.03-1.07`, producing `valid_cycles=2/5`. The AirPlay group gate now keeps marginal physical candidates (`second_ratio >= 1.0`) for the dominant-cluster/MAD/range/slope gates instead of discarding them before clustering.
- Post-fix event harness evidence: `bash scripts/event_resync_test.sh display,xiaomi 150` passed. Xiaomi reconnect triggered event calibration; the run measured local `0ms`, `airplay-group 2157ms`, uncertainty `1ms`, confidence `4.54`, applied `2157ms` during the test, then restored defaults to `airplayDelayMs=2159`, `syncast.airplayDelayLockedAt=0`, `syncast.bgCalibrationEnabled=0`.
- Continuous-FSK event harness evidence: after installing the continuous-phase high-band probe, `bash scripts/event_resync_test.sh display,xiaomi 190` passed the new stricter gate. Xiaomi reconnect triggered event calibration; the run measured local median `3ms`, `airplay-group 2154ms`, uncertainty `2ms`, confidence `3.39`, clustered AirPlay candidates `[2154, 2156, 2116]` and dropped `[2205, 2083]`, then applied `2151ms` from the integer persisted `2159ms` baseline.
- Harness bug fixed: previous restore logic wrote `syncast.airplayDelayMs` back as a string, which made Swift `object(forKey:) as? Int` fail and silently load default `1750ms`. The harness now restores delay/lock as integers and Continuous as a boolean.
- Review hardening after the continuous-FSK pass: AirPlay search now pads the raw correlation window by the edge guard, preserving the documented 1500-3500ms accepted range; per-device FSK codebooks are seeded so local device indexes 0 and 5 do not repeat; `scripts/event_resync_test.sh` reads logs incrementally, treats failure before success, and waits for `autoCalib: applied`; and UI event calibration waits for an enabled AirPlay receiver to be `.connected` before scheduling. Final evidence: `bash scripts/event_resync_test.sh display,xiaomi 220` passed after first logging `waiting for connected AirPlay receiver`, then applying `2172ms` with local `0ms`, `airplay-group 2172ms`, uncertainty `5ms`, confidence `3.60`.
- Event + drift validation wrapper: `scripts/event_resync_test.sh` accepts optional `drift_cycles` and `drift_interval_sec`; after a trusted event-driven apply it runs no-apply `drift_test.sh` against the same live Whole-home route before restoring defaults. Short evidence: `bash scripts/event_resync_test.sh display,xiaomi 240 2 15` applied `2155ms`, then drift cycles recommended `2141ms` and `2129ms`; total drift `-12ms`, AirPlay group tau drift `-3ms`, verdict `STABLE`, and restored defaults to Continuous `0`, delay `2159`, lock `0`.

Next validation:

- User subjective check: in Whole-home diagnostic calibration, is the continuous-phase high-band coded probe less intrusive than the previous low repeating tone, and does Xiaomi still produce audible byproducts?
- If subjective audibility is acceptable, use UI Auto-calibrate once and verify that the app's two-pass confirmation applies a current target automatically; do not ask the user to choose a fixed delay number.
- Do not enable automatic apply until repeated runs agree and a large-jump gate can show two or more consistent recommendations.
