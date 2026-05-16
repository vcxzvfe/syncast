# SyncCast Requirements Report

> Date: 2026-05-06
> Source: user field feedback, active Codex Goal, local build/test loop, and Codex agent reviews.
> Superseded by: `docs/requirements_2026-05-07.md` for the latest installed binary, stricter apply thresholds, unhealthy long-run evidence, and local/unpushed VCS status.

## Executive Summary

SyncCast is still a Stereo-first product. Local Stereo and screen sleep/wake recovery are user-verified stable and must not regress.

Whole-home/AirPlay is useful but not reliable yet. The user confirmed that AirPlay devices can all produce sound, but the unsolved problem is not AirPlay receiver-to-receiver sync. The unsolved problem is Local CoreAudio speakers versus the AirPlay group. AirPlay session latency changes between runs, interruptions, device switches, and volume changes, so SyncCast must not ask the user to find a fixed delay number.

DRM playback is now a first-class requirement. The default local Stereo path must avoid ScreenCaptureKit so Netflix, Amazon Prime Video, Apple TV+, Disney+, and similar apps see normal CoreAudio output instead of a screen/audio recorder.

## Current Truth

Stable:

- Local Stereo mode works well.
- Stereo screen sleep/wake recovery is resolved.
- Stable CoreAudio UID remains the persistence key; transient `AudioDeviceID` must never be cached across sessions/wake.

Experimental:

- Whole-home/AirPlay can produce sound on selected devices.
- Manual Local + AirPlay delay can align a session, but the correct value is route/session dependent.
- Automatic acoustic calibration can align in some runs but is not reliable enough to trust blindly.

Blocked:

- Default SCK capture path can trigger DRM playback blocks.
- Automatic calibration lacks a complete final quality model: single-run confidence is not enough to decide whether to apply.

## Requirements

### R1: Preserve Local Stereo

Acceptance:

- Two or more local CoreAudio outputs stay synchronized in normal use.
- Playback resumes after natural screen sleep/wake.
- Default behavior remains unchanged unless an explicit experimental flag is set.
- Any Direct Stereo or Tap work can be disabled without breaking the known-good capture Stereo path.

### R2: Make Default Stereo DRM-Safe

Strategy:

- Short term: `SYNCAST_STEREO_PATH=direct` creates a public CoreAudio output or aggregate and temporarily makes it the macOS default output. Apps render directly to CoreAudio; SyncCast does not capture audio in this mode.
- Medium term: `SYNCAST_CAPTURE_BACKEND=tap` replaces SCK for capture-dependent paths using Core Audio Process Tap on macOS 14.2+.
- Long term fallback: a DriverKit/AudioServerPlugIn virtual device if Process Tap cannot satisfy DRM or reliability constraints.

Acceptance:

- Starting local Stereo does not request Screen Recording.
- DRM video playback continues while SyncCast routes local outputs.
- Previous macOS default output is restored on stop/quit when SyncCast's direct output is still current.
- Direct aggregate cleanup never destroys the current system default output and never removes aggregates owned by a live SyncCast process.
- Multi-output Direct Stereo fails closed if CoreAudio exposes an unsafe channel layout that ordinary stereo apps cannot mirror to every subdevice.

### R3: Treat AirPlay As One High-Latency Timing Domain

Strategy:

- Let AirPlay/OwnTone handle AirPlay receiver-to-receiver synchronization.
- SyncCast aligns local CoreAudio speakers to the AirPlay group by delaying the local bridge path.
- Per-AirPlay-device acoustic identity is out of scope unless SyncCast can run TDMA mute/unmute probes or send receiver-specific streams.

Acceptance:

- UI and docs say `Local + AirPlay Delay`, not "sync AirPlay speakers."
- AirPlay-only group playback is monitored, not manually re-synchronized by SyncCast.
- Local + AirPlay mixed mode uses measured current route state, not a fixed remembered magic number.

### R4: Fail Closed On Acoustic Auto-Calibrate

Required control-loop changes:

- Require repeated agreement for all non-trivial automatic applies; reduce or remove single-run auto-apply.
- Add a final `CalibrationQuality` model covering local MAD/range, AirPlay MAD/range/slope, second-peak ambiguity, transport changes, route health, and delta uncertainty.
- Reject any run where routes, volumes, mute state, AirPlay connection state, writer packet flow, bridge drift/resync counters, or OwnTone stream epoch changed during measurement.
- Make continuous calibration observe-only or highly conservative until full-route calibration quality is proven.

Acceptance:

- A bad measurement does nothing.
- Delay lock always prevents writes.
- Diagnostic no-apply paths never persist changes.
- Automatic apply only happens when repeated measurements agree in the same route/mic/volume context.

### R5: Make Calibration Less Audible And More Robust

Strategy:

- Prefer high-band continuous-phase coded probes over low repeating tones.
- Add adaptive probe-band selection from a local frequency-response test.
- Use matched filtering plus second-peak ambiguity gates, not raw frequency detection.
- If the mic/speaker path cannot support inaudible or near-inaudible probes, disable auto-apply and leave manual/observe mode.

Acceptance:

- Probe audibility is explicitly tested on Xiaomi/AirPlay speakers and local speakers.
- The app can report "not enough acoustic quality to auto-apply" without treating that as a failure.
- Calibration remains possible during real playback only after overlay delivery acknowledgement and SNR gates prove the probe can be detected without corrupting content.

### R6: Own The Evidence Loop

Acceptance:

- `scripts/drift_test.sh --summarize-csv` remains the offline gate for applied error, confidence, uncertainty, and high-latency spread when independent receiver data exists.
- Event-driven calibration tests include post-apply no-apply drift checks.
- Long-session AirPlay tests log delay target, applied delay, receiver state, stream epoch, packet drops, bridge drift/resync count, and recovery events.
- User subjective validation is requested only after objective gates pass.

## Current Implementation Status

Implemented locally in this Codex session:

- Visible `Auto Calibrate` button in Whole-home `Local + AirPlay Delay`.
- Drift summary hardening with health flags and malformed JSON rejection.
- Compile-time Direct Stereo prototype behind `SYNCAST_STEREO_PATH=direct`.
- Direct Stereo review fixes:
  - transactional startup for public aggregates;
  - restore previous output by UID when possible;
  - do not clobber user-changed default output on stop;
  - skip current-default and live-PID direct aggregates during orphan sweep;
  - fail closed on unsafe aggregate channel layout;
  - fail startup/rebuild when Direct Stereo has no enabled local outputs;
  - preserve Direct Stereo restore state if a stop attempt cannot safely restore/fallback.
- Automatic calibration apply hardening:
  - single-run auto-apply is capped at `50ms` instead of `250ms`;
  - UI and diagnostic `calibrate_apply` both reject automatic writes when per-device uncertainty/MAD is missing or above `15ms`;
  - larger corrections still require repeat agreement in the same route/mic/volume context before writing.
- Calibration transport-health guard:
  - full AirPlay calibration now snapshots `AudioSocketWriter` packet/underrun/partial-send counters before and after the run;
  - local bridge packet, render tick, and drift-resync counters are also checked;
  - calibration fails closed if the writer sends no packets, partial-sends, changes error state, a local bridge stops advancing, or a local bridge has an underrun / repeated / large resync during measurement;
  - writer underruns alone are not a hard calibration failure because no-program-audio tests can legitimately send clock-preserving silence while the probe is mixed as an overlay;
  - a single small startup `overrun`, `drift`, or `first` bridge anchor is allowed and then judged by the normal uncertainty/MAD gates.
- Transport-health testability:
  - transport counter checks live in the pure helper `CalibrationTransportHealth`;
  - `CalibrationTransportHealthTests` covers healthy transport, missing writer, writer underrun allowed, writer partial-send failure, and local bridge stall/resync.
- Event + drift proof after the resync-reason refinement:
  - `bash scripts/event_resync_test.sh display,xiaomi 280 2 15` passed on the live Logitech mic / Xiaomi AirPlay setup;
  - event-driven Auto Calibrate applied `2152ms` from a measured `2145ms` target, with confidence `3.26` and uncertainty `3ms`;
  - after a 20s settle, two no-apply drift cycles returned `2149ms -> 2150ms`, total drift `+1ms`, max applied error `3ms`, max uncertainty `5ms`, and `Health flags: none`.
- Local/AirPlay robustness iteration after a longer failed run:
  - `bash scripts/event_resync_test.sh display,xiaomi 900 6 60` produced useful data but failed health because one no-apply cycle had an invalid local phase; the five OK cycles were still stable (`2148ms -> 2129ms`, drift `-19ms`, max applied error `14ms`, max uncertainty `4ms`);
  - root cause was a single local tau outlier (`77ms`) plus two stable local taus (`28ms`, `12ms`), so local phase now uses the same dominant-cluster filter as AirPlay before MAD/range/confidence gates;
  - `LocalAirPlayBridge` now reconnects after sidecar/broadcaster socket EOF instead of rendering permanent silence; a follow-up event smoke passed and applied `2154ms` from measured `2155ms` with confidence `3.31`;
  - a short drift run after that showed two healthy no-apply cycles (`2147ms -> 2141ms`, max applied error `9ms`) before exposing writer-underrun false positives in no-program-audio calibration; the transport gate now treats writer underruns as nonfatal when packets continue to send.
- Latest attempted hardware wrapper after the writer-underrun gate change did not reach calibration: `router.start FAILED: no display available` from ScreenCaptureKit, then event calibration aborted because preconditions changed. This is SCK availability evidence, not an AirPlay acoustic failure, and reinforces replacing SCK for always-on paths.
- `scripts/event_resync_test.sh` now treats `reconcile: router.start FAILED` as a distinct backend/infrastructure block and exits `3`; `no display available` is called out as ScreenCaptureKit display availability so it is not misclassified as an acoustic synchronization failure.
- The menubar app now logs the active runtime path as `Direct Stereo`, `Process Tap capture`, or `SCK capture` during reconcile. Direct/Tap runtime paths avoid Screen Recording preflight/polling while they are active; if the user switches into a runtime path that needs SCK, the TCC status is refreshed and logged at that transition. This keeps DRM-safe validation auditable from `~/Library/Logs/SyncCast/launch.log`.
- New `scripts/direct_stereo_smoke_test.sh` launches the installed app with `SYNCAST_STEREO_PATH=direct`, toggles local outputs through `SYNCAST_AUTO_TEST`, and verifies that Screen Recording preflight was skipped, `reconcile` used `Direct Stereo`, and diagnostics reported `driver=directStereo`.
- Direct Stereo hardware evidence:
  - `bash scripts/direct_stereo_smoke_test.sh mbp 60` passed: Screen Recording preflight was skipped, `reconcile` used `Direct Stereo`, `router.start OK`, and the 1s diagnostic showed `driver=directStereo directStereo=single` with SCK counters at zero.
  - Initial two-local-output smoke `display,mbp` failed closed because the public aggregate exposed `streams=2 ch=[2,2] total=4`; that is unsafe for ordinary apps because SyncCast's AUHAL splat logic is not in the path.
  - Direct Stereo public aggregates now use the CoreAudio Multi-Output aggregate flavor (`kAudioAggregateDeviceIsStackedKey = 1`) while the proven private SyncCast aggregate remains unchanged.
  - After that change, `bash scripts/direct_stereo_smoke_test.sh display,mbp 80` passed: diagnostics showed `driver=directStereo directStereo=aggregate ... uids=2`, Screen Recording preflight skipped, and SCK counters remained zero.
- Latest Local + AirPlay event/drift evidence after the Direct Stereo work:
  - `bash scripts/event_resync_test.sh display,xiaomi 260` passed: event Auto Calibrate measured local `0ms`, AirPlay group `2147ms`, uncertainty `1ms`, confidence `3.87`, and applied `2147ms` from the prior `2145ms`.
  - `bash scripts/event_resync_test.sh display,xiaomi 280 2 15` passed: event Auto Calibrate applied `2152ms` with confidence `3.47` and uncertainty `1ms`; after 20s settle, two no-apply drift cycles returned `2152ms -> 2151ms`, total drift `-1ms`, max applied error `1ms`, max uncertainty `2ms`, confidence min `3.1`, and `Health flags: none`.

Hardware test setup rule:

- For Whole-home / Local + AirPlay calibration, do not manually switch macOS output to a user-created Multi-Output device while testing SyncCast. Let SyncCast own the selected local CoreAudio outputs and AirPlay receivers; a separate system Multi-Output path can add an uncontrolled second playback timeline.
- For Direct Stereo validation, the experimental path itself changes the macOS default output to `SyncCast Direct Stereo Output` and restores the previous default on stop/quit. During that test, do not change System Settings output by hand unless the test is specifically checking user-output-change protection.
- Keep other audio sources quiet during microphone calibration unless the test is explicitly measuring calibration under real program audio.

Verified locally:

- `swift build --package-path core/router`
- `swift build --package-path apps/menubar`
- `swift test --package-path core/router` attempted after escalation; blocked by local toolchain missing `XCTest` module, same environment limitation as prior sessions.
- `bash -n scripts/drift_test.sh scripts/event_resync_test.sh scripts/calibration_apply_test.sh scripts/calibration_test.sh`
- `bash -n scripts/direct_stereo_smoke_test.sh`
- `PYTHONPYCACHEPREFIX=/private/tmp/syncast_pycache python3 -m py_compile scripts/drift_summary.py`
- `PYTHONPYCACHEPREFIX=/private/tmp/syncast_pycache python3 -m compileall -q sidecar/src`
- `git diff --check`
- `bash scripts/package-app.sh`
- `bash scripts/install-app.sh`

Installed locally:

- `/Applications/SyncCast.app/Contents/MacOS/SyncCastMenuBar` timestamp `2026-05-06 21:42`, size `2896576` bytes.
- App was installed but not relaunched automatically.
- After transport-health helper/test refactor, reinstalled binary timestamp `2026-05-06 21:57`, size `2923536` bytes.
- After the resync-reason refinement and settle-time harness update, reinstalled binary timestamp `2026-05-06 22:53`, size `2925472` bytes.
- After local dominant-cluster, LocalAirPlayBridge reconnect, and writer-underrun gate updates, reinstalled binary timestamp `2026-05-06 23:29`, size `2947824` bytes.
- After backend-block script classification and runtime-path logging, reinstalled binary timestamp `2026-05-06 23:37`, size `2949616` bytes.
- After dynamic Screen Recording status refresh for mode changes, reinstalled binary timestamp `2026-05-06 23:43`, size `2950320` bytes.
- After Direct Stereo public aggregate Multi-Output fix, reinstalled binary timestamp `2026-05-06 23:54`, size `2950320` bytes.

Not yet verified:

- Direct Stereo runtime behavior now has smoke coverage for one local output and two local outputs, but not yet subjective playback quality or default-output restore under forced failures.
- DRM playback under Direct Stereo.
- Process Tap runtime capture behavior and DRM behavior.
- Long-session Local + AirPlay reliability beyond short smoke/drift windows.

## Next Concrete Iterations

1. Run longer Local + AirPlay drift sessions after routine AirPlay events, using the new health gates rather than subjective delay values.
2. Runtime-test Direct Stereo with one local output, then two local outputs, while watching default-output restore.
3. Test DRM playback only after Direct Stereo default-output lifecycle is safe.
4. Continue Process Tap hardening for AirPlay/capture-dependent paths.
5. Add a group start barrier and explicit late-join/resync state before calling multi-AirPlay reliable.
