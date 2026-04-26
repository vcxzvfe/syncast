# Round 11 Acceptance Criteria

## Functional — Manual UX

- [ ] AirPlay delay slider step is **10ms** (was 25)
- [ ] Slider range is **0-5000ms**
- [ ] Slider value persists across app restart (UserDefaults `syncast.airplayDelayMs`)
- [ ] Lock button writes UserDefaults `syncast.airplayDelayLockedAt`
- [ ] Lock state pill shows "Unlocked" / "Locked at NNNN ms"
- [ ] Reset button restores 2200ms (default whole-home)
- [ ] ←/→ keyboard nudges ±10ms when popover focused (audition idle)
- [ ] Shift+←/→ nudges ±100ms
- [ ] Slider drag pushes new delay to sidecar in real-time

## Functional — A/B Audition

- [ ] "A/B test" button toggles audition mode
- [ ] On start: audition stores `auditionBaselineMs` = current `airplayDelayMs`
- [ ] Each round: 1.2s on side A (baseline - 150), 1.2s on side B (baseline + 150)
- [ ] User picks A or B (or ←/→ keyboard during running state)
- [ ] Picking A: baseline -= 75, advance round
- [ ] Picking B: baseline += 75, advance round
- [ ] After 4 rounds: returns to `.idle`, final value = sum of picks × 75 from baseline
- [ ] "Stop A/B" button restores original baseline and returns to `.idle`

## Functional — Demoted Auto

- [ ] "Estimate (rough)" button is in Advanced disclosure (collapsed by default)
- [ ] Description: "Best-effort algorithmic estimate. Use as rough start, fine-tune with the slider."
- [ ] Estimate result writes to `airplayDelayMs` only if `delayLockState == .unlocked` (does NOT overwrite locked value silently)

## Removed (must NOT exist after refactor)

- [ ] File `core/router/Sources/SyncCastRouter/PassiveCalibrator.swift`
- [ ] File `core/router/Sources/SyncCastRouter/HybridDriftTracker.swift`
- [ ] File `scripts/drift_test_v2.sh`
- [ ] File `docs/round10_drift_history.csv`
- [ ] JSON-RPC method `tracker.status` in CalibrationDiagnosticServer
- [ ] AppModel field `hybridTrackingEnabled`
- [ ] AppModel field `lastTrackerSample`
- [ ] AppModel field `hybridTrackerHistory`
- [ ] AppModel func `reconcileHybridTracker`
- [ ] Router methods `startHybridTracker / stopHybridTracker / lastHybridTrackerSample / hasFullCalibrationCache / injectChirpToRingForCalibration`
- [ ] Router deprecated section `passiveCalibrator` (lines 1402-1508 in old code)
- [ ] MainPopover Hybrid Tracking toggle
- [ ] MainPopover sparkline rendering
- [ ] MainPopover state pill (🔵🟡🟢🟠🔴)
- [ ] UserDefaults key `syncast.hybridTrackingEnabled`

## Bug fixes

- [ ] `broadcasterOverheadMs = 0` (was 200, fixed compensating bug)
- [ ] Across-device aggregator is `max`, not `medianInt` (delay-line must cover slowest device)
- [ ] `medianInt` correctly handles even N (averages two middle values)
- [ ] ActiveCalibrator has `muteAirplayBeforeLocalPhase` / `restoreAirplayAfterLocalPhase` closure params (default nil for backward compat)
- [ ] `setDelayMs` uses 30ms ramp to avoid audible click on A/B audition transitions

## Non-functional

- [ ] `swift build -c release` passes clean from `apps/menubar/` (with possibly 1 pre-existing `try?` warning in SyncCastApp.swift line 28)
- [ ] `swift build -c release` passes clean from `core/router/`
- [ ] `swift test` runs without compilation errors (new ManualCalibrationTests must pass)
- [ ] App launches in <2s
- [ ] Slider drag-to-audible-change latency <50ms

## Code quality

- [ ] No `import HybridDriftTracker` anywhere in source
- [ ] No reference to class `HybridDriftTracker` in any source file
- [ ] No reference to `PassiveCalibrator` in any source file
- [ ] AppModel has no `hybrid*` fields
- [ ] Router.swift no longer has Passive or Hybrid sections
- [ ] Net LOC delta: ~-1964 (deletions) + ~+400 (new manual UX) = **~-1564 LOC**

## Manual smoke test

1. Open SyncCast, switch to whole-home mode
2. Enable 2+ AirPlay devices + 2+ local outputs
3. Start playing music (Spotify / Apple Music / YouTube)
4. Drag slider — hear delay change in real-time, no clicks
5. Use ← to nudge -10ms, Shift+← to -100ms
6. Slider lands at 2300ms — hit "Lock 2300 ms"
7. Pill turns green "Locked at 2300 ms"
8. Quit SyncCast, reopen — slider at 2300, locked, music still in sync
9. Click "A/B test" — hear 1.2s of -150ms then 1.2s of +150ms, alternating
10. Pick A four times — baseline drops by 4 × 75 = 300ms (now at 2000)
11. Hit "Stop A/B" first time — restores to 2300 (test stop button)
12. Click "Estimate (rough)" — Auto-calibrate runs, value shown but NOT applied (locked)
13. Unlock — Estimate now offers Apply

## Pass / Fail

PASS: All checkboxes ticked + smoke test 1-13 succeeds
FAIL: Any checkbox unchecked or smoke test step fails
