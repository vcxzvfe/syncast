# SyncCast Goal Completion Audit

> Date: 2026-05-13
> Updated: 2026-05-15
> Verdict: not complete

## Objective Restated As Deliverables

SyncCast should become a reliable macOS menubar app that routes system audio to multiple outputs without breaking normal media playback.

Concrete success criteria:

1. Preserve user-verified local Stereo and screen-sleep/wake recovery.
2. Make Local + AirPlay alignment reliable after routine AirPlay interruptions, device changes, and volume/mute changes.
3. Use deployed Logitech mic evidence without audible autonomous probes.
4. Replace or bypass ScreenCaptureKit for normal media playback, especially DRM video.
5. Install and verify local builds before asking for subjective listening validation.

## Prompt-To-Artifact Checklist

| Requirement | Evidence | Status |
|---|---|---|
| Preserve local Stereo | User previously verified Stereo and sleep/wake stable. Latest app installed locally after Swift build/package/install. | Partially covered. Needs user regression check after 2026-05-13 install. |
| Avoid audible autonomous calibration | Active acoustic calibration is default-disabled at runtime. UI active controls, event-driven active calibration, and active diagnostic socket methods require both `SYNCAST_ENABLE_ACTIVE_CALIBRATION=1` and `SYNCAST_ALLOW_AUDIBLE_PROBES=1`; passive methods stay available. The shared `ActiveAcousticDiagnosticsGate` implementation is covered by `SyncCastRouterTimingCheck`. Tap helper audio remains disabled by default. | Covered for default runtime policy. |
| Passive no-probe estimator robustness | `scripts/passive_delay_estimator_tests.py` covers default background-only rejection, loud-background delayed signal recovery, sparse-match rejection, bimodal fail-closed, and multi-path reporting. | Covered offline. |
| Passive capture context safety | `scripts/passive_capture_estimate_tests.py` covers missing context, preflight/capture mismatch, rejected-cycle context mutation, mid-capture context mutation, inactive AirPlay, mic timing metadata rejection, and consensus gates. Swift build passes with enriched metadata. | Covered offline/compile. |
| Passive long-session audit safety | `scripts/passive_drift_monitor_tests.py`, `scripts/passive_session_audit_tests.py`, and safe-fail runs at `/private/tmp/syncast-passive-safefail-20260513-0020` and `/private/tmp/syncast-passive-autostart-safefail-20260513b` prove capture-failed reports and control reports are produced before mic/audio access when socket is missing. Session audit now also refuses accepted samples without valid passive mic timing metadata. | Covered for safe-fail path and offline timing gate. |
| Passive autonomous setup harness | `scripts/passive_drift_session.sh` now has optional `SYNCAST_PASSIVE_AUTO_START_TARGETS=display,xiaomi` to relaunch SyncCast into Whole-home, select local+AirPlay targets, guard against a separate Multi-Output default, unset active probe flags, optionally force Tap/SCK capture backend, wait for passive readiness, and then run the no-probe/no-write drift workflow. It also defaults to `SYNCAST_PASSIVE_APPLY_MODE=dry-run`, so a repeat-confirmed candidate gets an app-side runtime dry-run via `passive_apply_candidate` and records `passive_apply.json`; `off` skips that. `passive_control_report.py` marks gate-ready dry-run sessions incomplete if that artifact is missing. Syntax and fail-fast checks passed; live auto-start/runtime dry-run was not run in this session because it launches the GUI app, changes CoreAudio default output, and opens the passive mic path. | Improved but live validation missing. |
| Real Logitech mic passive evidence | No live `passive_capture` / `passive_drift_session` corpus has succeeded in this environment. | Missing. |
| Passive reference/mic timing origin | `PassiveCapture.swift` now warms the mic before arming, drops pre-arm mic frames, zero-pads the mic WAV for the arm-to-first-sample gap, and records mic timing metadata. `SyncCastRouterTimingCheck` covers the pure Swift frame-alignment edge cases without XCTest. `passive_capture_estimate.py` and `passive_session_audit.py` reject accepted evidence with missing or inconsistent timing metadata. | Covered offline; live validation still missing. |
| AirPlay timing-domain changes | Router emits `airplayTimingEpoch` and passive evidence carries it through status/capture/monitor/decision/baseline store. Route context now also includes per-device `manualDelayMs`, so timing trims cannot reuse stale passive baselines. Offline tests reject changed epochs during capture, monitor, baseline comparison, and passive correction repeat-confirmation. `scripts/passive_correction_gate.py` now explicitly requires route context, capture backend, `delayLocked=false`, enabled AirPlay count, and AirPlay timing epoch to match before two passive recommendations can become an apply candidate. | Covered offline; live validation still missing. |
| Local + AirPlay automatic correction | Passive baseline/finalizer/correction-gate scripts remain no-write until a candidate is repeat-confirmed. `PassiveApplyGuard`, diagnostic RPC `passive_apply_candidate`, and `scripts/passive_apply_candidate.py` now provide a default-dry-run app-side write bridge for `ready_for_apply_candidate` sessions, with runtime re-checks for delay lock, current delay, route context, enabled/active AirPlay count, AirPlay timing epoch, capture backend, bounds, and max 20ms step. `passive_delay_decision.py` now also rejects missing/changed/locked delay-lock evidence before baseline initialization or correction recommendations, and the baseline/gate/apply artifacts carry `delayLocked=false`. `passive_control_report.py` reports `dry_run_ready`, `applied`, or runtime rejection from `passive_apply.json`; the offline regression covers ready session -> dry-run RPC -> `passive_apply.json` -> control report `dry_run_ready`, and rejects stale finalize/gate/apply artifacts, missing-gate-field, contradictory, wrong-delay, or manifest/apply-mode-conflicting artifacts across every key request-context binding. No live passive candidate has been collected or applied, and no autonomous in-app loop is enabled. | Improved but not complete. |
| AirPlay interruption/device/volume long-session reliability | Historical active-probe single-Xiaomi evidence exists, but no passive multi-hour Local + AirPlay corpus after 2026-05-13 hardening. | Not complete. |
| DRM-safe normal playback | Direct Stereo path exists and local Stereo now defaults to Direct Stereo via `StereoOutputPathPolicy`; `SYNCAST_STEREO_PATH=capture` / `sck` remains a fallback. 2026-05-13 hardening tightened stale Direct aggregate cleanup against PID reuse and restricted fallback default-output selection to known local outputs. Installed `bash scripts/direct_stereo_smoke_test.sh --default-path mbp 60` passed with `SYNCAST_STEREO_PATH` unset, `stereoPath=direct`, `driver=directStereo`, no forbidden SCK/Screen Recording lines, default output restored, no SyncCast process left running, and launchctl test env vars unset afterward. Netflix/Prime/Apple TV+ validation has not run. | Improved but not complete. |
| Read-only DRM path audit | `scripts/drm_path_audit.py` can audit `launch.log` for Direct Stereo/Tap evidence and forbidden SCK/Screen Recording lines without launching the app. `scripts/drm_manual_session.py` records a pre-test offset and audits only new lines after a manual DRM playback attempt. Recent 20KB log audit passed for Direct Stereo evidence. | Tooling covered; real DRM playback still missing. |
| Public/product truth | README, Chinese README, architecture doc, landing page, and app permission strings now describe Stereo as stable, Local + AirPlay as experimental, SCK as a DRM blocker, and active probes as lab-only/default-disabled. Startup logs now report the active-diagnostics gate state. | Covered for docs/runtime evidence; product behavior still needs live validation. |
| External review honesty | Codex reviewer found and re-reviewed the passive apply/control-report false-ready fixes with no blockers after hardening. Claude Code CLI is installed, but a non-interactive review attempt failed with `Not logged in`; no Claude review coverage should be claimed. | Codex review covered; Claude review missing. |
| GitHub updated | Local workspace has substantial uncommitted Goal work. `origin/main` remains `d955eb7`. | Not complete. |

## Verification Evidence From 2026-05-13

Passed:

- `python3 scripts/passive_delay_estimator_tests.py`
- `python3 scripts/passive_capture_estimate_tests.py`
- `python3 scripts/passive_drift_monitor_tests.py`
- `python3 scripts/passive_session_audit_tests.py`
- `python3 scripts/passive_drift_summary_tests.py`
- `python3 scripts/passive_delay_decision_tests.py`
- `python3 scripts/passive_baseline_store_tests.py`
- `python3 scripts/passive_session_finalize_tests.py`
- `bash -n scripts/passive_drift_session.sh` after optional passive auto-start harness
- invalid passive auto-start timeout/backend fail-fast checks
- `bash scripts/passive_drift_session.sh 1 0 1 /private/tmp/syncast-passive-autostart-safefail-20260513b` -> `capture_failed` before mic/audio/delay actions
- `python3 scripts/passive_correction_gate_tests.py`
- `python3 scripts/passive_control_report_tests.py`
- `python3 scripts/passive_delay_decision_tests.py`
- `python3 scripts/passive_delay_estimator.py --self-test`
- `PYTHONPYCACHEPREFIX=/private/tmp/syncast-pycache python3 -m py_compile ...`
- `bash -n scripts/passive_capture_snapshot.sh scripts/passive_drift_session.sh scripts/tap_capture_smoke_test.sh scripts/direct_stereo_smoke_test.sh scripts/calibration_interrupt_test.sh`
- `swift build --package-path core/router`
- `swift build --package-path apps/menubar`
- `git diff --check`
- `bash scripts/package-app.sh`
- `bash scripts/install-app.sh`
- `bash scripts/package-app.sh` after defaulting local Stereo to Direct Stereo
- `bash scripts/install-app.sh`
- `bash scripts/passive_drift_session.sh 1 0 1 /private/tmp/syncast-passive-safefail-20260513-0020`
- `python3 scripts/drm_path_audit_tests.py`
- `python3 scripts/drm_path_audit.py --mode direct-stereo --tail-bytes 20000`
- `python3 scripts/drm_manual_session_tests.py`
- `python3 scripts/drm_manual_session.py start --session-root /private/tmp/syncast-drm-manual-safetest-20260513 --mode direct-stereo`
- `python3 scripts/drm_manual_session.py finish /private/tmp/syncast-drm-manual-safetest-20260513`
- `python3 scripts/passive_capture_estimate_tests.py` after adding capture-harness `--preflight-only`
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
- `bash scripts/package-app.sh` after permission/product-truth text update
- `bash scripts/install-app.sh`
- Installed `Info.plist` verification
- `pgrep -fl syncast` returned no running SyncCast process after install
- `bash -n scripts/event_resync_test.sh scripts/event_mutation_test.sh scripts/calibration_interrupt_test.sh` after second audible-probe arming flag
- `swift build --package-path core/router`
- `swift build --package-path apps/menubar`
- `swift build --package-path core/router --product SyncCastRouterTimingCheck`
- `core/router/.build/arm64-apple-macosx/debug/SyncCastRouterTimingCheck` -> `Router timing and active-diagnostics gate checks passed (10)`
- `python3 scripts/passive_capture_estimate.py --preflight-only --output-root /private/tmp/syncast-passive-preflight-20260513-2324` -> `capture_failed` with missing diagnostic socket, before mic/audio/delay actions.
- `bash scripts/package-app.sh`
- `bash scripts/install-app.sh`
- `bash -n scripts/direct_stereo_smoke_test.sh`
- `bash scripts/direct_stereo_smoke_test.sh --default-path mbp 60` -> default policy selected Direct Stereo without SCK/Screen Recording and restored the previous default output.
- `python3 scripts/passive_correction_gate_tests.py` after repeat-confirmation context hardening
- `python3 scripts/passive_control_report_tests.py`
- `python3 scripts/passive_baseline_store_tests.py`
- `python3 scripts/passive_session_finalize_tests.py`
- `python3 scripts/passive_apply_candidate_tests.py`
- `PYTHONPYCACHEPREFIX=/private/tmp/syncast-pycache python3 -m py_compile scripts/passive_apply_candidate.py scripts/passive_apply_candidate_tests.py`
- `swift build --package-path core/router --product SyncCastRouterTimingCheck`
- `core/router/.build/arm64-apple-macosx/debug/SyncCastRouterTimingCheck` -> `Router timing and active-diagnostics gate checks passed (14)`
- `swift build --package-path core/router`
- `swift build --package-path apps/menubar`
- `python3 scripts/passive_apply_candidate.py /private/tmp/syncast-passive-autostart-safefail-20260513b --socket /tmp/nonexistent-syncast.sock --output /private/tmp/syncast-passive-autostart-safefail-20260513b/passive_apply.json` -> refused a not-ready `capture_failed` session before RPC delay write
- `python3 scripts/passive_control_report_tests.py` after passive apply dry-run report integration
- `bash -n scripts/passive_drift_session.sh` after passive apply dry-run integration
- `SYNCAST_PASSIVE_APPLY_MODE=bad bash scripts/passive_drift_session.sh 1 0 1 /private/tmp/syncast-passive-invalid-apply-mode-check` -> fail-fast invalid apply mode before mic/audio/delay actions
- `bash scripts/passive_drift_session.sh 1 0 1 /private/tmp/syncast-passive-apply-integrated-safefail-20260514` -> `capture_failed` at preflight with default dry-run mode before mic/audio/delay actions
- `python3 scripts/passive_control_report_tests.py` after missing dry-run artifact hardening
- `PYTHONPYCACHEPREFIX=/private/tmp/syncast-pycache python3 -m py_compile scripts/passive_control_report.py scripts/passive_control_report_tests.py`
- `python3 scripts/passive_apply_candidate_tests.py` after helper precondition hardening; 7 tests including ready session -> mocked dry-run RPC -> `passive_apply.json` -> final control report `dry_run_ready`, plus refusal when `--apply` tries to use the dry-run missing-artifact exception
- `python3 scripts/passive_control_report_tests.py` after apply artifact binding hardening; 20 tests including stale/mismatched `passive_apply.json`, stale finalize/gate rejection, full request-context binding, missing required gate fields, contradictory dry-run artifact rejection, wrong applied-delay rejection, and manifest dry-run mode rejecting applied artifacts
- `PYTHONPYCACHEPREFIX=/private/tmp/syncast-pycache python3 -m py_compile scripts/passive_apply_candidate.py scripts/passive_apply_candidate_tests.py scripts/passive_control_report.py scripts/passive_control_report_tests.py`
- `python3 scripts/passive_delay_decision_tests.py` after delay-lock hardening; 16 tests including missing/changed/locked delay-lock rejection
- `python3 scripts/passive_baseline_store_tests.py`, `python3 scripts/passive_session_finalize_tests.py`, `python3 scripts/passive_correction_gate_tests.py`, `python3 scripts/passive_session_audit_tests.py`, and `python3 scripts/passive_control_report_tests.py` after delay-lock hardening
- `bash scripts/package-app.sh`
- `bash scripts/install-app.sh`

Installed:

- `/Applications/SyncCast.app/Contents/MacOS/SyncCastMenuBar`
- Timestamp `2026-05-14 00:05:05 CEST`
- Size `3380624`

## Missing Before Completion

1. Run a real passive Logitech-mic capture in Whole-home with real program audio and at least one local + one AirPlay output.
2. Validate passive capture timing metadata on a real Logitech capture before trusting passive delay values for baselines or correction.
3. Establish a `ready_for_baseline` passive session for a known-good Local + AirPlay alignment.
4. Prove repeated same-route passive sessions can reach `pending_confirmation` and `ready_for_apply_candidate` without audible probes.
5. Live-validate the new default-dry-run `passive_apply_candidate` bridge only after no-write passive evidence reaches `ready_for_apply_candidate`; then decide whether to enable an app-side loop.
6. Run Direct Stereo DRM playback validation and decide whether/when Direct Stereo can become default local Stereo.
7. Push a reviewed branch or PR when the local work is ready to share.

## Conclusion

Do not call the Goal complete. The latest work improves the passive/no-probe evidence pipeline and installs a safer local app, but the actual product goal still lacks live room evidence, automatic passive correction, DRM validation, and GitHub publication.
