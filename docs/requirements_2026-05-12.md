# SyncCast Requirements Report

> Date: 2026-05-12
> Source: active Codex Goal, user field feedback, local hardware runs, installed-app smoke tests, and current workspace state.

## Executive Summary

SyncCast remains a Stereo-first product. Local Stereo mode and screen-sleep / wake recovery are user-verified stable and must not regress.

The unresolved product problem is Local + AirPlay alignment. AirPlay receivers should be treated as one buffered AirPlay timing domain for now; SyncCast must delay and re-calibrate the local Mac/display/CoreAudio outputs against that AirPlay group. Asking the user for one best manual delay is not meaningful because the Local + AirPlay offset changes between sessions, receiver events, and volume/route changes.

The DRM blocker is also still real. Default media playback must stop depending on ScreenCaptureKit. Direct Stereo is the safest path for local Stereo because it avoids capture entirely. Process Tap is promising for capture-dependent paths, but it is not yet a proven AirPlay/calibration replacement.

## Current Truth

Stable:

- Local Stereo output is user-verified as excellent.
- Stereo display sleep / wake recovery is user-verified as fixed.
- Stable CoreAudio UID remains the required persistence key; transient `AudioDeviceID` must not be cached.

Improved but experimental:

- Single-AirPlay Xiaomi + one local display output has repeated successful historical active-probe Auto Calibrate evidence with repeat agreement, post-apply validation, route/volume/mute recovery, and route-interrupt fail-closed recovery. After the user reported audible probes, this evidence remains useful history but is no longer the preferred autonomous Goal path.
- Whole-home / AirPlay can output sound on selected devices.
- Multiple AirPlay receivers are diagnostic-only for automatic apply because the current `airplay-group` acoustic measurement can be dominated by one audible receiver.
- Direct Stereo and Process Tap exist behind flags, but neither is the default shipping path yet.

Still not solved:

- Multi-hour, multi-AirPlay interruption reliability has not passed.
- Tap-backed AirPlay calibration is not a clean pass. A 2026-05-12 Tap attempt started without Screen Recording but produced `backend=tap seen=0 written=0 ticks=0` without external program audio.
- The temporary Tap helper sound was audible to the user. Tap smoke/calibration harnesses now disable auxiliary audio by default.
- DRM playback under Direct Stereo and Process Tap still needs honest runtime validation.
- GitHub/origin remains at `d955eb7`; this Goal iteration is local unless explicitly committed and pushed.

## Requirements

### R1: Preserve Local Stereo

Acceptance:

- Two or more local CoreAudio outputs stay synchronized in normal use.
- Playback resumes after natural screen sleep/wake.
- Default behavior remains unchanged unless an explicit experimental flag is set.
- New AirPlay, Direct Stereo, Tap, or calibration work can be disabled without breaking local Stereo.

### R2: Make Default Stereo DRM-Safe

Acceptance:

- Local Stereo can route to local outputs without ScreenCaptureKit.
- No Screen Recording preflight or prompt is touched in the default DRM-safe Stereo path.
- Netflix / Apple TV+ / Amazon / Disney+ playback continues while SyncCast is active.
- SyncCast restores the previous macOS default output when it still owns the output on stop/quit.

Current implementation direction:

- Use `SYNCAST_STEREO_PATH=direct` Direct Stereo for local DRM-safe output.
- Keep SCK as fallback until Direct Stereo restore and DRM tests pass.
- Do not use Process Tap for default local Stereo unless Direct Stereo fails, because Tap is still system-audio capture.

### R3: Make Local + AirPlay Calibration Conservative

Acceptance:

- Automatic delay writes never happen while delay lock is active.
- No-apply diagnostics never write `syncast.airplayDelayMs`.
- Single-run automatic writes are capped to tiny corrections.
- Larger corrections require repeat agreement in the same route, mic, volume, mute, and connection context.
- Route changes, volume/mute changes, missing Tap/SCK capture, unhealthy writer/bridge counters, insufficient confidence, and missing/high uncertainty fail closed.
- Multiple AirPlay receiver routes remain diagnostic-only until per-receiver contribution evidence exists.

Current 2026-05-12 additions:

- In-flight route/volume events are deferred instead of canceling an active calibration.
- Mid-calibration route mutation must log `calibration route context changed during measurement` and then recover with a fresh trusted calibration.
- Active calibration now waits up to 2000ms for trusted mic host-time callbacks before emitting/injecting local or AirPlay probes. After readiness, it keeps a 600ms noise-floor pre-roll and 1000ms extra capture-deadline slack. If mic readiness never arrives, calibration fails closed before emitting/injecting a probe.
- After user feedback that high-band probes were still audible, autonomous Goal runs should prefer passive no-probe real-program evidence. `comfort-21k` (`20.85/21.20/21.55/21.90/22.25kHz`, 64 symbols, 1536ms, local amplitude `0.014`, AirPlay amplitude `0.018`) is an explicit lab/diagnostic active-probe profile only, not a default background behavior. The old `19.05-20.25kHz` field profile is opt-in via `SYNCAST_CALIBRATION_PROBE_PROFILE=legacy`.
- Continuous local-only calibration must reject any cached AirPlay group tau measured under a different active probe profile.
- Passive calibration R&D now has an offline no-audio estimator (`scripts/passive_delay_estimator.py`) that works from WAV files before any live microphone/app integration is attempted. It now exposes peak z-score, accepted-window fraction, and filtered path candidates so loud background content and spurious secondary peaks fail closed instead of becoming control evidence.
- The Router diagnostic socket now has a no-probe `passive_capture` method plus `scripts/passive_capture_snapshot.sh` for collecting real reference/microphone WAV pairs. This opens the microphone but emits no audio; live use should be deliberate. Capture duration must stay within the capture ring capacity; the snapshot script defaults to 4s and now runs the same no-mic `passive_status` preflight first, so stale sockets, sandbox-blocked sockets, unavailable capture backends, or disconnected enabled AirPlay receivers fail before any mic capture.
- `scripts/passive_capture_estimate.py` is the next passive diagnostic harness. It defaults to 3 no-probe captures with a 2-of-3 consensus requirement, runs the offline estimator, reports strong aggregate peaks, and requires cross-cycle consensus/range/MAD gates before returning an accepted passive delay. Before every passive capture cycle it now requires a hard no-mic `passive_status` readiness gate: `ok`, `passiveCaptureAvailable`, explicit `inProgress == false`, supported backend (`sck`/`tap`), enabled and active AirPlay counts, current applied FIFO delay metadata, delay-lock metadata, and non-empty route context. All cycles, including estimator-inconclusive cycles, now fail the whole sample if preflight/start/end route context, applied delay, AirPlay count, backend, or lock state is missing or changes. The diagnostic server also re-checks a fresh AppModel/router snapshot after capture and refuses to return a usable capture if route context, the real sidecar FIFO delay, lock state, enabled AirPlay count, or active AirPlay count changed mid-recording. Single-cycle runs are diagnostic-only unless explicitly overridden, and ambiguous strong multi-peak evidence fails closed. It does not emit audio, change routes, or apply `airplayDelayMs`; it is evidence collection for the future automatic path.
- `scripts/passive_drift_monitor.py` repeatedly runs the passive consensus harness over a longer real-program-audio session and summarizes accepted delay drift. It is the next no-probe diagnostic for AirPlay interruption/device/volume drift. It fails closed on trailing inconclusive samples by default, refuses a stable verdict when accepted samples change route context/applied delay/AirPlay count/backend/lock state, has a `--preflight-only` mode that validates args, diagnostic-socket reachability, and the hard no-mic `passive_status` readiness gate before any capture or mic access, re-checks the same gate before every normal passive capture cycle, can persist final JSON plus per-sample JSONL evidence, writes a partial `capture_failed` report if a later capture fails, and it does not launch SyncCast, emit audio, change routes, or apply `airplayDelayMs`.
- `scripts/passive_drift_session.sh` runs the no-probe live evidence workflow end to end: safety manifest, preflight-only readiness, passive drift monitor, summary, no-write delay decision, session audit, optional baseline finalization/correction gate, and final `control_report.json`. It writes all artifacts into one output directory, exits before mic access if the preflight gate fails, and still writes audit/report artifacts for partial/failed sessions.
- `scripts/passive_drift_summary.py` summarizes passive drift monitor JSON or per-sample JSONL into compact text/JSON evidence, including verdict counts, accepted delay range, context-gate failures, top inconclusive reasons, and strong multi-peak flags. `.jsonl` inputs are auto-detected and recomputed with configurable monitor gates so interrupted long runs can still be analyzed.
- The passive estimator now emits `path_candidates`, stable multi-path delay candidates seen across score-qualified windows, so live corpora can reveal possible Local/AirPlay/reflection paths even when the dominant delay verdict remains inconclusive.
- `scripts/passive_delay_decision.py` converts stable passive monitor evidence into no-write control decisions. It uses a known-good baseline offset (`measured_delay_ms - current_delay_ms`) and recommends only bounded relative corrections from that baseline; it rejects unstable, multi-path, changed-context, baseline/current route mismatch, changed-delay, and multi-AirPlay evidence by default. This avoids treating passive acoustic delay as a direct absolute `airplayDelayMs` target.
- `scripts/passive_baseline_store.py` records audited `ready_for_baseline` sessions into a JSON store keyed by route context/backend/AirPlay count, then reruns no-write decisions for later matching sessions using the stored relative baseline. It rejects missing baselines and unsafe manifests.
- `scripts/passive_session_finalize.py` connects session artifacts to the baseline store. In `auto` mode it records the first safe baseline for a route/backend/AirPlay context and emits stored-baseline no-write decisions for later matching sessions. `passive_drift_session.sh` runs it when `SYNCAST_PASSIVE_BASELINE_STORE` is set.
- `scripts/passive_correction_gate.py` requires repeat agreement before a future automatic apply candidate exists. One eligible stored-baseline recommendation becomes pending; a second non-expired different-session same-baseline/same-current-delay/same-direction/similar-target recommendation becomes `ready_for_apply_candidate`. It still emits no audio and applies no delay, and replaying the same `finalize.json` cannot fake confirmation.
- `scripts/passive_session_audit.py` audits a passive session output directory, checks manifest safety flags plus artifact presence and JSONL/report consistency, and classifies the corpus as `ready_for_baseline`, `ready_for_correction`, `hold`, `not_applicable`, `capture_failed`, or `incomplete`. Missing preflight, missing/malformed samples, row-count mismatch, and same-count stale/swapped JSONL content now fail closed.
- `scripts/passive_control_report.py` folds audit/finalize/correction-gate artifacts into one final no-write status such as `capture_failed`, `ready_for_baseline`, `baseline_recorded`, `pending_confirmation`, or `ready_for_apply_candidate`.
- Tap-related harnesses no longer play auxiliary audio by default.
- When `calibration_interrupt_test.sh` is run with `SYNCAST_TEST_CAPTURE_BACKEND=tap`, it now refuses to report a Tap-specific pass unless Tap diagnostics show nonzero callback/write/tick counters.
- `event_resync_test.sh`, `event_mutation_test.sh`, and `calibration_interrupt_test.sh` now require `mic_ready first_host=` plus `probe_anchor=` logs before accepting trusted acoustic calibration evidence.

### R4: Prove AirPlay With Long-Session Evidence

Acceptance before calling AirPlay reliable:

- At least two AirPlay receivers plus one local output run for 2+ hours.
- Logs include target delay, applied delay, confidence, uncertainty/MAD, writer packet flow, bridge render/resync counters, stream epoch, receiver state, volume/mute state, and recovery events.
- Matrix covers receiver restart, AirPlay interruption, route switch, volume change, mute/unmute, display sleep/wake, sidecar restart, OwnTone restart, and network disruption.
- `drift_test` health flags are clean, not merely final `Verdict: STABLE`.

Current proven scope:

- Single Xiaomi AirPlay + one local display output has repeated short/medium hardware evidence.
- AirPlay remains experimental beyond that proven scope.

### R5: Replace SCK For Capture-Dependent Paths

Acceptance:

- Process Tap starts without Screen Recording.
- Tap feeds the existing `SystemAudioCapture -> RingBuffer` contract.
- Tap survives route changes and sleep/wake, or fails over cleanly.
- Capture-dependent AirPlay/calibration paths work without SCK.
- DRM behavior under Tap is measured, not assumed.

Current status:

- Tap smoke previously passed with non-silent program audio and no Screen Recording.
- Tap does not produce useful callbacks when no non-SyncCast audio is playing.
- Tap-backed AirPlay calibration remains pending.
- Future deterministic Tap probes must be explicit, quiet/high-band, and lab-only; default Goal runs must not surprise the user with audible sounds. If an opt-in helper is used, the harness now terminates the active `afplay` child during cleanup instead of only killing the wrapper loop.

## Verification Snapshot

Passed locally on 2026-05-12:

- `swift build --package-path core/router`
- `swift build --package-path apps/menubar`
- `bash scripts/package-app.sh`
- `bash scripts/install-app.sh`
- `bash -n scripts/calibration_interrupt_test.sh`
- `bash -n scripts/tap_capture_smoke_test.sh`
- `bash -n scripts/event_resync_test.sh`
- `bash -n scripts/event_mutation_test.sh`
- `PYTHONPYCACHEPREFIX=/private/tmp/syncast-pycache python3 -m py_compile scripts/passive_delay_estimator.py`
- `python3 scripts/passive_delay_estimator.py --self-test`
- `python3 scripts/passive_delay_estimator_tests.py`
- `python3 scripts/passive_capture_estimate_tests.py`
- `python3 scripts/passive_drift_monitor_tests.py`
- `python3 scripts/passive_drift_summary_tests.py`
- `python3 scripts/passive_delay_decision_tests.py`
- `python3 scripts/passive_baseline_store_tests.py`
- `python3 scripts/passive_session_finalize_tests.py`
- `python3 scripts/passive_correction_gate_tests.py`
- `python3 scripts/passive_session_audit_tests.py`
- `python3 scripts/passive_control_report_tests.py`
- `PYTHONPYCACHEPREFIX=/private/tmp/syncast-pycache python3 -m py_compile scripts/passive_capture_estimate.py scripts/passive_capture_estimate_tests.py scripts/passive_drift_monitor.py scripts/passive_drift_monitor_tests.py scripts/passive_drift_summary.py scripts/passive_drift_summary_tests.py scripts/passive_delay_decision.py scripts/passive_delay_decision_tests.py scripts/passive_baseline_store.py scripts/passive_baseline_store_tests.py scripts/passive_session_finalize.py scripts/passive_session_finalize_tests.py scripts/passive_correction_gate.py scripts/passive_correction_gate_tests.py scripts/passive_session_audit.py scripts/passive_session_audit_tests.py scripts/passive_control_report.py scripts/passive_control_report_tests.py scripts/passive_delay_estimator.py scripts/calibration_log_summary.py scripts/drift_summary.py`
- `bash -n scripts/passive_capture_snapshot.sh`
- `bash -n scripts/passive_drift_session.sh`
- `git diff --check`

Installed locally:

- `/Applications/SyncCast.app/Contents/MacOS/SyncCastMenuBar`
- Timestamp: `2026-05-13 00:01:28 CEST`
- Size: `3223808` bytes

Blocked / pending:

- `swift test --package-path core/router` is still blocked by this local toolchain missing `XCTest`.
- SCK-backed route-interrupt test passed before script tightening, but reruns were blocked by SCK `Code=-3818` / no-display capture failures.
- Tap-backed route-interrupt calibration is pending because silent/no-program-audio Tap produces no callbacks.
- `direct_stereo_smoke_test.sh` now compiles its CoreAudio default-output helper to a per-process temp path and removes it during cleanup, avoiding stale helper reuse while checking default-output restore.
- Installed `bash scripts/direct_stereo_smoke_test.sh display,mbp 100` passed after fixing termination registration and UID-based active-default detection. It proved Direct Stereo can start without Screen Recording/SCK and restore the previous default output to `多输出设备`.
- `Router.init` now sweeps stale public SyncCast Direct aggregates on every launch, not only when `SYNCAST_STEREO_PATH=direct` is active.
- `scripts/calibration_log_summary.py` provides a read-only, no-audio summary of recent launch.log calibration evidence before deciding whether a live acoustic run is warranted.

## Next Concrete Iterations

1. Keep Tap and calibration harnesses non-disruptive by default; no audible helper probes in autonomous Goal runs.
2. Extend Direct Stereo default-output restore coverage to abnormal-exit/stale-aggregate, failed-router-start, and user-changed default-output cases.
3. Run DRM playback validation under Direct Stereo now that normal quit/default restore passed.
4. Runtime-test Process Tap with real program audio, sleep/wake, and DRM playback before using it as the SCK replacement for AirPlay/calibration.
5. Add a multi-AirPlay long-session matrix where automatic apply remains disabled until per-receiver evidence exists.
6. Add per-receiver contribution telemetry or a future per-receiver stream/mute protocol before enabling automatic writes on multi-AirPlay routes.
