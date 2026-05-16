# SyncCast Requirements Report

> Date: 2026-05-13
> Updated: 2026-05-15
> Source: active Codex Goal, user feedback, six-agent review, offline tests, and local Swift builds.

## Current Product Truth

- Local Stereo remains the stable product core. Preserve local CoreAudio sync and screen-sleep / wake recovery.
- Local + AirPlay remains unsolved as a reliable product. Manual delay values are not useful because the Local + AirPlay offset can change after AirPlay/device/volume events.
- AirPlay receiver-to-receiver sync should be treated as AirPlay's timing domain for now. SyncCast's near-term target is aligning local Mac/display/CoreAudio speakers to the AirPlay group.
- Active high-frequency probes are not acceptable for autonomous/default Goal runs because the user can still hear them. They are explicit lab diagnostics only.
- Passive no-probe measurement using real program audio is now the preferred calibration R&D path.
- ScreenCaptureKit remains a DRM blocker. Direct Stereo is the preferred default local Stereo replacement because it avoids capture entirely; Process Tap is only a candidate for capture-dependent paths.

## Updated Requirements

### R1: Preserve Stereo

Acceptance:

- Two or more local CoreAudio outputs stay synchronized.
- Screen sleep/wake resumes audio without reselection.
- Device persistence uses stable CoreAudio UID, not `AudioDeviceID`.
- Experimental AirPlay/Tap/passive work can be disabled without harming Stereo.

### R2: Make Stereo DRM-Safe

Acceptance:

- Default local Stereo must not require ScreenCaptureKit or Screen Recording.
- Direct Stereo must pass normal quit/default-output restore, abnormal-exit/stale-aggregate, failed-start restore, user-changed-default, and DRM playback checks before becoming default.
- Process Tap must not be treated as the local Stereo DRM solution; it is still capture.

### R3: Make Local + AirPlay Evidence Fail-Closed

Acceptance:

- Passive captures emit no audio, change no routes, and apply no delay.
- Every accepted passive sample must have consistent preflight/start/end context: route signature, real sidecar FIFO delay, lock state, backend, enabled AirPlay count, and active AirPlay count.
- Every accepted passive sample must include valid microphone timing metadata: sample rate, mic arm timestamp, first-sample timestamp, start padding, and warm-up drop count.
- Estimator-inconclusive cycles still count for context pollution; a route change in a rejected cycle invalidates the sample.
- Passive estimator must reject unrelated/background-only mic audio and sparse matches, and must avoid turning weak secondary peaks into control-blocking multi-path evidence.
- Passive session audit must reject missing, malformed, row-count mismatched, or same-count stale/swapped JSONL evidence.

### R4: Convert Passive Evidence Into Control Only After Baseline + Repeat Agreement

Acceptance:

- First stable single-path report initializes a relative baseline: `measured_delay_ms - currentDelayMs`.
- Later corrections are bounded relative corrections, not absolute microphone delay writes.
- Multi-AirPlay, multi-path, changed-context, changed-delay, unstable, or stale evidence rejects.
- A future apply candidate requires a second independent matching session.

### R5: Prove Before Productizing

Acceptance before calling Local + AirPlay reliable:

- At least one real passive Logitech-mic session reaches `ready_for_baseline`.
- Later same-route sessions reach `pending_confirmation` and then `ready_for_apply_candidate` without audible probes.
- Multi-hour Local + AirPlay sessions cover AirPlay interruption, device switching, volume/mute changes, sleep/wake, sidecar/OwnTone restart, and network disturbance.

## 2026-05-13 Implementation Delta

- Added estimator `peak_z` and accepted-window-fraction gates.
- Added default-noise, loud-background, and sparse-match estimator regressions.
- Filtered low-quality secondary path candidates.
- Hardened passive capture consensus to require preflight/start/end context across every cycle.
- Made passive status require active AirPlay count, current FIFO delay metadata, and delay-lock metadata before mic capture.
- Persisted richer passive capture metadata: mic device ID, active AirPlay count, device list, AirPlay connection states, and context-stability status.
- On passive capture end-context failure, metadata is rewritten with `contextStableDuringCapture=false` and a failure reason so abandoned WAV directories are not silently plausible.
- Passive snapshots now use router-side connection state and sidecar FIFO delay diagnostics instead of only UI-cached state.
- Passive monitor now writes capture-failed reports for `KeyboardInterrupt`.
- Passive session wrapper audits on INT/TERM after manifest creation and avoids creating an output directory for early invalid baseline env configuration.
- Passive session audit now compares JSONL row content against `monitor.json`, not only row count.
- `scripts/passive_capture_estimate.py` now has `--preflight-only`, which validates args, diagnostic-socket reachability, and the hard `passive_status` readiness gate, then exits before microphone access, audio emission, or delay application.
- Active acoustic calibration is now disabled by default. UI `Diagnostic Calibrate`/`Continuous`, event-driven active calibration, `calibrate`, `calibrate_apply`, and `freqresponse` require launching SyncCast with both `SYNCAST_ENABLE_ACTIVE_CALIBRATION=1` and `SYNCAST_ALLOW_AUDIBLE_PROBES=1`; passive diagnostic methods remain available.
- The lab acoustic harnesses that intentionally play probes now set and restore both active-tone environment flags explicitly.
- Passive microphone capture now has an explicit armed start point: the AUHAL input starts in warm-up/drop mode, waits for real callbacks, then the passive capture arms the mic and snapshots the reference ring start. Callback frames before the arm point are discarded, and the mic WAV is zero-padded by the measured arm-to-first-sample gap. Metadata records `microphoneArmedAtNs`, `microphoneFirstSampleAtNs`, `microphoneStartPaddingFrames`, and `microphoneWarmupFramesDropped`.
- `scripts/passive_capture_estimate.py` and `scripts/passive_session_audit.py` now reject accepted evidence that lacks that mic timing metadata, has a first sample before the arm point, or reports padding inconsistent with arm-to-first-sample timing.
- Passive evidence now carries an `airplayTimingEpoch`. Router increments it when AirPlay active set, connection state, measured latency, mode, AirPlay volume changes, and the route context now includes per-device `manualDelayMs` so timing trims cannot silently reuse stale passive baselines. `passive_status`, `passive_capture`, passive monitor rows, the decision layer, and the baseline store all include the timing epoch, so a same-route report after an AirPlay timing-domain change cannot silently reuse a stale baseline.
- Passive correction repeat-confirmation now explicitly compares route context, capture backend, enabled AirPlay count, and AirPlay timing epoch before promoting two no-write recommendations to `ready_for_apply_candidate`. A changed timing domain replaces the pending candidate instead of confirming it, even if a baseline key is reused.
- Passive delay decisions now require stable `delay_locked=false` evidence. Missing delay-lock metadata, changed delay-lock state across accepted samples, or a locked manual delay state rejects before baseline initialization, stored-baseline decisions, correction gate promotion, or apply requests. Baseline entries store the delay-lock state and include it in their identity. This aligns the passive no-write policy with the app-side `PassiveApplyGuard` and active `calibrate_apply` lock behavior.
- `scripts/passive_drift_session.sh` can now optionally prepare its own no-probe Whole-home test session with `SYNCAST_PASSIVE_AUTO_START_TARGETS=display,xiaomi`. The auto-start path quits/relaunches SyncCast into Whole-home, selects the requested local+AirPlay outputs, uses the CoreAudio default-output guard to avoid an uncontrolled Multi-Output playback timeline, unsets both active-audible-probe flags, optionally sets `SYNCAST_PASSIVE_AUTO_CAPTURE_BACKEND=tap|sck`, waits for passive readiness, and then runs the existing no-write passive drift workflow. This is a harness step toward autonomous Logitech-mic diagnostics; it does not apply delay or emit calibration audio.
- Added no-probe passive apply plumbing. `PassiveApplyGuard` validates repeat-confirmed passive candidates against current runtime context, delay lock, current delay, enabled/active AirPlay count, AirPlay timing epoch, capture backend, delay bounds, and max 20ms passive step. The new diagnostic RPC `passive_apply_candidate` defaults to dry-run and is separate from active `calibrate_apply`, so it does not emit probes. `scripts/passive_apply_candidate.py` consumes a passive session directory and refuses to call the RPC unless `passive_control_report.py` returns `ready_for_apply_candidate`; it only writes delay with `--apply`. `scripts/passive_drift_session.sh` now runs that helper automatically in default dry-run mode after a correction gate reaches `ready_for_apply_candidate`, writing `passive_apply.json`; set `SYNCAST_PASSIVE_APPLY_MODE=off` to skip the app-side runtime check.
- 2026-05-15/16 update: the passive apply helper/control-report loop is now explicit. For outside readers, a gate-ready dry-run session with no `passive_apply.json` is incomplete; for `scripts/passive_apply_candidate.py`, that exact incomplete/apply state is accepted as the helper's own dry-run precondition so it can call the default dry-run RPC and create the missing artifact. The exception is dry-run-only, so `--apply` cannot bypass the missing-artifact gate. `scripts/passive_control_report.py` now validates `finalize.json` against the current audit/monitor features, validates `correction_gate.json` against the stored-baseline decision, and validates `passive_apply.json` against the current session root, target/current delay, route context, delay-lock state, enabled AirPlay count, AirPlay timing epoch, capture backend, baseline key, dry-run state, result semantics, actual applied delay, and manifest apply mode before reporting `dry_run_ready` or `applied`. Regression coverage proves ready session -> dry-run RPC result -> `passive_apply.json` -> `dry_run_ready`, rejects stale/mismatched or contradictory dry-run artifacts, covers every key request-context binding field, rejects missing gate fields required to validate an apply artifact, rejects stale finalize/gate artifacts, rejects wrong-delay applied artifacts, and rejects applied artifacts in manifest dry-run sessions.
- Review status: Codex reviewer found the dry-run `--apply` bypass, stale `passive_apply.json`, and contradictory dry-run artifact risks; after fixes, the same reviewer reported no blockers. Claude Code CLI was attempted for an external review, but the installed CLI returned `Not logged in`, so there is no Claude review evidence yet.
- Added `SyncCastRouterTimingCheck`, a Swift executable verifier for the passive mic alignment plan. It runs without XCTest and covers fully pre-arm callbacks, callbacks that straddle the arm point, post-arm callbacks that require front padding, and capacity-limited copies.
- Updated public/product truth in `README.md`, `README.zh-CN.md`, `docs/ARCHITECTURE.md`, `docs/landing/index.html`, and the app `Info.plist`: local Stereo is the stable path, Local + AirPlay is experimental, ScreenCaptureKit remains a DRM blocker, passive no-probe measurement is the default R&D direction, and normal playback does not use the microphone or play calibration tones.
- Startup logging now records whether active acoustic diagnostics are disabled or explicitly lab-enabled, so future reports of audible tones can be checked against `launch.log` instead of guessed.
- Added a second audible-probe arming flag, `SYNCAST_ALLOW_AUDIBLE_PROBES=1`, so a leaked or stale `SYNCAST_ENABLE_ACTIVE_CALIBRATION=1` alone cannot enable active test tones.
- Moved the active acoustic diagnostics gate into `ActiveAcousticDiagnosticsGate` so Router and AppModel share one implementation. `SyncCastRouterTimingCheck` now verifies the passive mic timing plan and the dual-flag active-diagnostics gate without XCTest.
- Local Stereo now selects Direct Stereo by default via `StereoOutputPathPolicy`; `SYNCAST_STEREO_PATH=capture` or `sck` remains an explicit fallback. Unknown stereo path values fall forward to Direct Stereo instead of SCK. This moves the default local path away from ScreenCaptureKit / Screen Recording, while AirPlay/capture-dependent paths still require separate validation.
- `SyncCastRouterTimingCheck` now also verifies Direct Stereo default selection, explicit capture/SCK opt-out, and unknown-value fallback to Direct Stereo.
- Added `scripts/drm_path_audit.py`, a read-only launch.log auditor for manual DRM checks. It does not launch SyncCast, change routes, open the mic, emit audio, or apply delay; it reports whether Direct Stereo or Process Tap evidence appears without forbidden SCK/Screen Recording lines.
- Added `scripts/drm_manual_session.py`, a passive two-step wrapper for manual DRM playback checks. `start` records the current `launch.log` byte offset and safety manifest; `finish` audits only new log lines and writes `drm_audit.json`.
- Direct Stereo stale aggregate cleanup is stricter after six-agent review: a live PID embedded in a stale Direct UID is only trusted when the executable still looks like SyncCast, so PID reuse by another app no longer protects a stale Direct aggregate. Default-output fallback selection now prefers selected known-local targets and otherwise only known local output transports with real output channels, not arbitrary CoreAudio devices.

## Verification Snapshot

Passed locally:

- `python3 scripts/passive_delay_estimator_tests.py`
- `python3 scripts/passive_capture_estimate_tests.py`
- `python3 scripts/passive_drift_monitor_tests.py`
- `python3 scripts/passive_session_audit_tests.py`
- `python3 scripts/passive_baseline_store_tests.py`
- `python3 scripts/passive_delay_decision_tests.py`
- `python3 scripts/passive_session_finalize_tests.py`
- `python3 scripts/passive_control_report_tests.py`
- `python3 scripts/passive_correction_gate_tests.py` after pending-confirmation context hardening
- `python3 scripts/passive_control_report_tests.py` after pending-confirmation context hardening
- `python3 scripts/passive_baseline_store_tests.py` after pending-confirmation context hardening
- `python3 scripts/passive_session_finalize_tests.py` after pending-confirmation context hardening
- `bash -n scripts/passive_drift_session.sh` after optional passive auto-start harness
- `SYNCAST_PASSIVE_AUTO_START_TARGETS=display,xiaomi SYNCAST_PASSIVE_AUTO_START_TIMEOUT_SEC=5 bash scripts/passive_drift_session.sh 1 0 1 /private/tmp/syncast-passive-invalid-timeout-check` -> fail-fast invalid timeout before launch/mic/audio/delay actions
- `SYNCAST_PASSIVE_AUTO_START_TARGETS=display,xiaomi SYNCAST_PASSIVE_AUTO_CAPTURE_BACKEND=bad bash scripts/passive_drift_session.sh 1 0 1 /private/tmp/syncast-passive-invalid-backend-check` -> fail-fast invalid backend before launch/mic/audio/delay actions
- `bash scripts/passive_drift_session.sh 1 0 1 /private/tmp/syncast-passive-autostart-safefail-20260513b` -> `capture_failed` at preflight with no socket, before mic/audio/delay actions
- `python3 scripts/passive_apply_candidate_tests.py`
- `PYTHONPYCACHEPREFIX=/private/tmp/syncast-pycache python3 -m py_compile scripts/passive_apply_candidate.py scripts/passive_apply_candidate_tests.py`
- `swift build --package-path core/router --product SyncCastRouterTimingCheck` after passive apply guard
- `core/router/.build/arm64-apple-macosx/debug/SyncCastRouterTimingCheck` -> `Router timing and active-diagnostics gate checks passed (14)`
- `swift build --package-path core/router`
- `swift build --package-path apps/menubar`
- `python3 scripts/passive_apply_candidate.py /private/tmp/syncast-passive-autostart-safefail-20260513b --socket /tmp/nonexistent-syncast.sock --output /private/tmp/syncast-passive-autostart-safefail-20260513b/passive_apply.json` -> refused not-ready `capture_failed` session before RPC delay write
- `python3 scripts/passive_control_report_tests.py` after passive apply dry-run report integration
- `bash -n scripts/passive_drift_session.sh` after passive apply dry-run integration
- `SYNCAST_PASSIVE_APPLY_MODE=bad bash scripts/passive_drift_session.sh 1 0 1 /private/tmp/syncast-passive-invalid-apply-mode-check` -> fail-fast invalid apply mode before mic/audio/delay actions
- `bash scripts/passive_drift_session.sh 1 0 1 /private/tmp/syncast-passive-apply-integrated-safefail-20260514` -> `capture_failed` at preflight with default `apply mode : dry-run`, before mic/audio/delay actions
- `python3 scripts/passive_control_report_tests.py` after missing dry-run artifact hardening
- `PYTHONPYCACHEPREFIX=/private/tmp/syncast-pycache python3 -m py_compile scripts/passive_control_report.py scripts/passive_control_report_tests.py`
- `python3 scripts/passive_apply_candidate_tests.py` after the helper precondition fix; 7 tests including ready session -> mocked dry-run RPC -> `passive_apply.json` -> final control report `dry_run_ready`, plus refusal when `--apply` tries to use the dry-run missing-artifact exception
- `python3 scripts/passive_control_report_tests.py` after artifact binding hardening; 20 tests including stale/mismatched `passive_apply.json`, stale finalize/gate rejection, full request-context binding, missing required gate fields, contradictory dry-run artifact rejection, wrong applied-delay rejection, and manifest dry-run mode rejecting applied artifacts
- `python3 scripts/passive_delay_decision_tests.py` after delay-lock hardening; 16 tests including missing/changed/locked delay-lock rejection
- `python3 scripts/passive_baseline_store_tests.py`, `python3 scripts/passive_session_finalize_tests.py`, `python3 scripts/passive_correction_gate_tests.py`, `python3 scripts/passive_session_audit_tests.py`, and `python3 scripts/passive_control_report_tests.py` after delay-lock hardening
- `PYTHONPYCACHEPREFIX=/private/tmp/syncast-pycache python3 -m py_compile scripts/passive_apply_candidate.py scripts/passive_apply_candidate_tests.py scripts/passive_control_report.py scripts/passive_control_report_tests.py`
- `python3 scripts/passive_delay_estimator.py --self-test`
- `PYTHONPYCACHEPREFIX=/private/tmp/syncast-pycache python3 -m py_compile scripts/passive_delay_estimator.py scripts/passive_capture_estimate.py scripts/passive_drift_monitor.py scripts/passive_session_audit.py`
- `bash -n scripts/passive_drift_session.sh`
- `swift build --package-path core/router`
- `swift build --package-path apps/menubar`
- `git diff --check`
- `bash scripts/package-app.sh`
- `bash scripts/install-app.sh`
- Safe-fail no-socket passive session:
  `bash scripts/passive_drift_session.sh 1 0 1 /private/tmp/syncast-passive-safefail-20260513-0020`
- `python3 scripts/drm_path_audit_tests.py`
- `PYTHONPYCACHEPREFIX=/private/tmp/syncast-pycache python3 -m py_compile scripts/drm_path_audit.py scripts/drm_path_audit_tests.py`
- Read-only recent-log audit:
  `python3 scripts/drm_path_audit.py --mode direct-stereo --tail-bytes 20000`
- `python3 scripts/drm_manual_session_tests.py`
- `PYTHONPYCACHEPREFIX=/private/tmp/syncast-pycache python3 -m py_compile scripts/drm_manual_session.py scripts/drm_manual_session_tests.py`
- Passive manual-session no-new-log check:
  `python3 scripts/drm_manual_session.py start --session-root /private/tmp/syncast-drm-manual-safetest-20260513 --mode direct-stereo`
  then `python3 scripts/drm_manual_session.py finish /private/tmp/syncast-drm-manual-safetest-20260513`
- `python3 scripts/passive_capture_estimate_tests.py` after adding passive capture `--preflight-only`
- `python3 scripts/passive_drift_monitor_tests.py`
- `PYTHONPYCACHEPREFIX=/private/tmp/syncast-pycache python3 -m py_compile scripts/passive_capture_estimate.py scripts/passive_capture_estimate_tests.py`
- `swift build --package-path core/router` after default-disabling active acoustic calibration
- `swift build --package-path apps/menubar`
- `bash -n scripts/event_resync_test.sh scripts/event_mutation_test.sh scripts/calibration_interrupt_test.sh`
- `bash scripts/package-app.sh`
- `bash scripts/install-app.sh`
- `swift build --package-path core/router` after passive microphone arm/padding timing fix
- `swift build --package-path apps/menubar`
- `python3 scripts/passive_capture_estimate_tests.py`
- `python3 scripts/passive_drift_monitor_tests.py`
- `bash -n scripts/passive_capture_snapshot.sh scripts/passive_drift_session.sh`
- `swift build --package-path core/router --product SyncCastRouterTimingCheck`
- `core/router/.build/arm64-apple-macosx/debug/SyncCastRouterTimingCheck`
- `swift build --package-path core/router` after Direct Stereo stale-cleanup/fallback hardening
- `swift build --package-path apps/menubar`
- `swift build --package-path core/router` after AirPlay timing epoch passive metadata
- `swift build --package-path apps/menubar`
- `plutil -lint apps/menubar/Resources/Info.plist`
- `bash -n scripts/event_resync_test.sh scripts/event_mutation_test.sh scripts/calibration_interrupt_test.sh` after adding the second audible-probe arming flag
- `swift build --package-path core/router` after adding the second audible-probe arming flag
- `swift build --package-path apps/menubar` after adding the second audible-probe arming flag
- `swift build --package-path core/router --product SyncCastRouterTimingCheck` after adding `ActiveAcousticDiagnosticsGate`
- `core/router/.build/arm64-apple-macosx/debug/SyncCastRouterTimingCheck` -> `Router timing and active-diagnostics gate checks passed (10)`
- `swift build --package-path core/router --product SyncCastRouterTimingCheck` after defaulting Stereo to Direct Stereo
- `swift build --package-path apps/menubar`
- `python3 scripts/passive_capture_estimate.py --preflight-only --output-root /private/tmp/syncast-passive-preflight-20260513-2324` safely returned `capture_failed` because no diagnostic socket was present; this confirms the no-app preflight path fails before microphone access or audio emission.
- `bash scripts/package-app.sh` after permission/product-truth text update
- `bash scripts/install-app.sh`
- `bash scripts/package-app.sh` after defaulting local Stereo to Direct Stereo
- `bash scripts/install-app.sh`
- Installed `Info.plist` verified: microphone text now says normal playback and Stereo mode do not use the microphone or play calibration tones.
- `pgrep -fl syncast` after install returned no running SyncCast processes.

Installed locally:

- `/Applications/SyncCast.app/Contents/MacOS/SyncCastMenuBar`
- Timestamp: `2026-05-14 00:05:05 CEST`
- Size: `3380624` bytes

Safe-fail artifact:

- `/private/tmp/syncast-passive-safefail-20260513-0020/control_report.json`
- Verdict: `capture_failed`
- Safety: `emitsAudio=false`, `appliesDelay=false`, `manifestMicAfterPreflight=true`

Recent-log Direct Stereo audit:

- Verdict: `pass`
- Evidence: `direct_start=true`, `direct_driver=true`, `screen_preflight_skipped=true`, `router_start_ok=true`
- Forbidden SCK/Screen Recording lines: none in the audited 20KB log window

Installed default-policy Direct Stereo smoke:

- Command: `bash scripts/direct_stereo_smoke_test.sh --default-path mbp 60`
- Verdict: `pass`
- Evidence: `SYNCAST_STEREO_PATH` was unset for launch; launch.log reported `stereoPath=direct`, `reconcile: starting router (Direct Stereo)`, `reconcile: router.start OK`, and `driver=directStereo`.
- Safety: no forbidden SCK/Screen Recording lines appeared, the previous default output was restored, no `SyncCastMenuBar` process remained afterward, and launchctl test env vars were unset after cleanup.

Manual DRM session helper safe check:

- `/private/tmp/syncast-drm-manual-safetest-20260513/drm_audit.json`
- Verdict: `inconclusive`
- Reason: no new log lines after `start`; this is expected because no manual DRM playback/app run occurred.
- Safety: `emitsAudio=false`, `opensMicrophone=false`, `changesRoutes=false`, `appliesDelay=false`

Not run in this iteration:

- Live microphone passive corpus, because current sandbox Unix-socket access has previously failed and the user requested no further permission prompts.
- DRM playback validation.
- Live passive capture timing-origin validation. The code now records mic arm/first-sample/padding metadata, but a real Logitech capture should still verify that these fields behave as expected before using passive evidence for automatic correction.
