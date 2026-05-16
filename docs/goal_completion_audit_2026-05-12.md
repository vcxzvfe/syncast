# SyncCast Goal Completion Audit

> Date: 2026-05-12
> Verdict: **not complete**. The active Goal remains open.

## Objective Restatement

Build SyncCast into a reliable macOS menubar app that routes system audio to multiple outputs without breaking normal media playback.

Concrete success criteria:

- Preserve verified local Stereo and screen-sleep / wake recovery.
- Make Local + AirPlay alignment reliable without manual delay babysitting after routine AirPlay/route/volume events.
- Use robust acoustic calibration: coded probes, matched filtering, repeated trials, outlier rejection, confidence/uncertainty gates, hysteresis, and resync triggers.
- Use deployed Logitech mic and hardware for autonomous diagnostics where doing so is non-disruptive.
- Stop ScreenCaptureKit from breaking normal DRM media playback in the default useful path.
- Install and verify local builds before asking the user for listening validation.

## Prompt-to-Artifact Checklist

| Requirement | Current artifact / evidence | Coverage | Gap |
| --- | --- | --- | --- |
| Preserve local Stereo | User reports local Stereo is excellent; Round 12 sleep/wake recovery is user-verified; docs/HANDOFF.md and docs/GOAL.md keep this as P0 | Strong for existing default behavior | Needs regression check before release after every large local-output change |
| Screen sleep/wake recovery | Round 12 fix chain is in `origin/main`; user confirmed recovery works | Strong | No new natural-DPMS run after the large local Goal workspace |
| Local + AirPlay manual control | Delay slider now pushes `airplayDelay applied: ...ms`; multiple event/drift harnesses recorded successful single-Xiaomi alignment | Good for single-AirPlay Xiaomi + local display route | Manual slider is not a reliability solution; multi-AirPlay automatic apply disabled |
| Automatic acoustic calibration robustness | `ActiveCalibrator` uses continuous-phase high-band FSK, repeated cycles, matched filtering, dominant-cluster selection, confidence/MAD/range gates, route-context revision protection, transport-health gates, post-apply validation, and probe-profile-bound AirPlay cache validation; `calibration_log_summary.py` now gives read-only failure/evidence summaries | Good implementation and short/medium single-AirPlay evidence | No live `comfort-21k` acoustic pass yet; no 2+ hour multi-AirPlay matrix; no per-receiver contribution proof |
| Passive/non-intrusive calibration path | `scripts/passive_delay_estimator.py` estimates delay from ordinary reference WAV + microphone WAV without launching SyncCast or emitting probes, and now reports diagnostic `path_candidates` for stable multi-path peaks from score-qualified windows even when the main verdict is inconclusive; synthetic self-test recovered `382.0ms` with `0.0ms` MAD; `PassiveCapture.swift` + `passive_capture` can write live reference/mic WAVs without emitting probes, rejects captures longer than the ring can preserve, binds the mic AU context before start, releases the mic promptly if a parent capture is cancelled, records current delay/context metadata plus start/end ring/tick counters, and the diagnostic server fails closed if route context/current delay/lock/AirPlay counts change before the capture returns; `passive_status` reports route/delay/backend context, active AirPlay count, and capture tick/write-position metadata without opening the mic, while `passive_capture` refuses to open the mic unless every enabled AirPlay receiver is connected; `scripts/passive_capture_estimate.py` defaults to 3 captures, gates cross-cycle consensus/range/MAD, rejects cycle-level and start/end capture context changes when metadata is present, fails closed on ambiguous strong multi-peak evidence, reports strong aggregate peaks without applying delay, and requires a hard no-mic readiness gate before every capture cycle; `scripts/passive_drift_monitor.py` repeats accepted passive estimates to detect long-session drift without applying delay, has `--preflight-only`, re-checks readiness before every normal passive capture cycle, persists final/partial JSON plus JSONL evidence, and refuses stable verdicts across route/delay/backend/AirPlay-count context changes; `scripts/passive_drift_session.sh` orchestrates manifest/preflight/monitor/summary/decision/audit/finalize/correction-gate/control-report for the next live run and audits partial failures; `scripts/passive_session_audit.py` enforces manifest safety flags and now fails closed on missing preflight or invalid/mismatched sample JSONL; `scripts/passive_baseline_store.py`, `scripts/passive_session_finalize.py`, and `scripts/passive_correction_gate.py` persist audited relative baselines, emit later no-write correction decisions, and require fresh different-session same-current-delay repeat agreement before any apply candidate; `scripts/passive_control_report.py` produces one final no-write session status; `scripts/passive_delay_decision.py` provides a no-write relative-baseline decision layer that holds/recommends/rejects without treating acoustic delay as an absolute `airplayDelayMs` target | Early live-data bridge and offline control policy installed with stricter fail-closed gates | `passive_capture` has not produced a live room corpus; decision policy not wired into AppModel control loop; no real room WAV corpus yet |
| Resync after routine route/volume/mute events | `event_resync_test.sh`, `event_mutation_test.sh`, and `calibration_interrupt_test.sh` exist; prior installed SCK route-interrupt run passed fail-closed then recovery apply; all three harnesses now require `mic_ready first_host=` and `probe_anchor=` before accepting trusted acoustic evidence | Good for tested single-AirPlay cases | Latest mic-ready-gated build has not been live acoustic-tested because audible disruption was avoided |
| Do not surprise user with calibration sounds | Tap helper audio disabled by default in `tap_capture_smoke_test.sh` and `calibration_interrupt_test.sh`; helper child cleanup kills `afplay`; mic-ready gate prevents probe emission before trusted mic timestamp; no additional live probe was run after the user reported audibility | Improved | Core acoustic probes are still explicit high-band probes; possible speaker intermodulation remains a product caveat |
| Process Tap no-SCK capture | `TapCapture.swift`, `SystemAudioCapture.swift`, and `tap_capture_smoke_test.sh`; previous Tap smoke passed with non-silent program audio and no Screen Recording | Promising but partial | Tap-backed AirPlay calibration not proven; silent/no-program-audio Tap has zero callbacks |
| Direct Stereo DRM-safe path | `DirectStereoOutput.swift` and `direct_stereo_smoke_test.sh`; installed `display,mbp` smoke passed on 2026-05-12 after termination/default-restore hardening, with Screen Recording skipped and default output restored; Router now sweeps stale Direct aggregates on every launch | Promising but partial | DRM playback validation still missing; Direct path remains hidden flag |
| ScreenCaptureKit / DRM blocker | Docs correctly state SCK remains blocker; Direct Stereo and Tap are experimental alternatives | Honest status | Normal default path still can use SCK; DRM-safe default not shipped |
| Installed local build | `/Applications/SyncCast.app/Contents/MacOS/SyncCastMenuBar` timestamp `2026-05-13 00:01:28 CEST`, size `3223808`; no `SyncCastMenuBar` process left running after install | Current local install done | GitHub/origin still `d955eb7`; local work is uncommitted |
| Verification commands | `swift build --package-path core/router`, `swift build --package-path apps/menubar`, `bash scripts/package-app.sh`, `bash scripts/install-app.sh`, `bash -n` checks for event/mutation/interrupt/Tap/passive harnesses, `python3 scripts/passive_capture_estimate_tests.py`, Python compile checks, and `git diff --check` passed | Good build/static coverage | `swift test --package-path core/router` blocked by missing `XCTest`; live acoustic tests not rerun after mic-ready gate |
| Use reviewer feedback honestly | Codex reviewers found mic pre-roll, Tap false-positive, helper-cleanup, stale Direct aggregate sweep, and probe-profile test-environment issues; fixes were applied where practical. Claude Code CLI exists locally but is not logged in, so no Claude Code review was claimed. | Good | Direct Stereo still lacks focused unit/fake-CoreAudio coverage for restore-failure/user-changed-default branches |

## Missing Requirements

- Multi-AirPlay reliability is not proven. Automatic writes remain disabled for multiple AirPlay receivers, which is correct but incomplete.
- The latest mic-ready-gated calibration build has not yet passed a live acoustic route-interrupt or drift run.
- Direct Stereo has not been DRM-validated with Netflix / Apple TV+ / Amazon / Disney+.
- Process Tap has not been validated for DRM, sleep/wake, or AirPlay calibration replacement.
- `origin/main` does not contain the Goal work.
- XCTest remains unavailable locally, so unit-test coverage cannot be reported green.

## Next Concrete Work

1. Extend Direct Stereo restore tests to abnormal-exit/stale-aggregate, failed-start, and user-changed-default cases, then run DRM playback validation.
2. Run Tap smoke only when real program audio is already present and helper probes remain disabled.
3. Run a non-disruptive live acoustic pass only when the room/audio context is appropriate; the harnesses now require mic-ready-gate logs before passing.
4. Keep AirPlay labeled experimental until a multi-hour, multi-AirPlay matrix passes with clean health flags.
