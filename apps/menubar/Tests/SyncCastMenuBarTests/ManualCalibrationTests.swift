import XCTest
@testable import SyncCastMenuBar

/// Unit tests for the manual-calibration state machine on `AppModel`:
///   - `delayLockState`  (DelayLockState)
///   - `auditionState`   (AuditionState)
/// And the supporting public API:
///   - `lockAirplayDelay()`, `unlockAirplayDelay()`
///   - `nudgeAirplayDelay(by:)` (with clamp [0, 5000])
///   - `startAudition()`, `stopAudition()`
///   - `chooseAuditionA()`, `chooseAuditionB()`
///
/// These are deliberately UNIT tests — they exercise the in-memory state
/// machine and persistence contract directly, without touching the sidecar
/// IPC, the router, or the discovery service. The router/sidecar work
/// triggered from `AppModel.init()` runs as detached `Task`s, so we can
/// instantiate `AppModel` on the main actor and inspect its synchronous
/// state without awaiting any async bootstrap.
///
/// AppModel is `@MainActor`, so the test class itself is `@MainActor` to
/// avoid `await MainActor.run { ... }` boilerplate around every property
/// access.
@MainActor
final class ManualCalibrationTests: XCTestCase {
    // The same UserDefaults key AppModel uses for the persisted FIFO delay.
    // Tests reset this between cases so persistence doesn't leak state.
    private let airplayDelayMsKey = "syncast.airplayDelayMs"
    // Hypothetical persistence keys for the lock state. Cleared defensively
    // even if the implementation stores them under different names; the
    // round-trip test does not depend on the specific key.
    private let lockedKey = "syncast.airplayDelayLocked"
    private let lockedAtKey = "syncast.airplayDelayLockedAt"

    override func setUp() {
        super.setUp()
        clearPersistence()
    }

    override func tearDown() {
        clearPersistence()
        super.tearDown()
    }

    private func clearPersistence() {
        let d = UserDefaults.standard
        d.removeObject(forKey: airplayDelayMsKey)
        d.removeObject(forKey: lockedKey)
        d.removeObject(forKey: lockedAtKey)
    }

    private func makeModel() -> AppModel {
        // AppModel.init() spawns background Tasks for sidecar/discovery,
        // but the synchronous initial state we test here is set up before
        // those Tasks get scheduled, so we don't need to await anything.
        return AppModel()
    }

    // MARK: - DelayLockState

    func test_default_lock_state_is_unlocked() {
        let m = makeModel()
        XCTAssertEqual(m.delayLockState, .unlocked)
    }

    func test_lockAirplayDelay_sets_locked_with_current_value() {
        let m = makeModel()
        m.airplayDelayMs = 2100
        m.lockAirplayDelay()
        XCTAssertEqual(m.delayLockState, .locked(at: 2100))
    }

    func test_unlockAirplayDelay_returns_to_unlocked() {
        let m = makeModel()
        m.airplayDelayMs = 1500
        m.lockAirplayDelay()
        XCTAssertEqual(m.delayLockState, .locked(at: 1500))
        m.unlockAirplayDelay()
        XCTAssertEqual(m.delayLockState, .unlocked)
    }

    // MARK: - nudgeAirplayDelay clamping

    func test_nudge_increases_within_range() {
        let m = makeModel()
        m.airplayDelayMs = 1000
        m.nudgeAirplayDelay(by: 250)
        XCTAssertEqual(m.airplayDelayMs, 1250)
    }

    func test_nudge_clamps_at_zero() {
        let m = makeModel()
        m.airplayDelayMs = 50
        m.nudgeAirplayDelay(by: -500)
        XCTAssertEqual(m.airplayDelayMs, 0)
    }

    func test_nudge_clamps_at_5000() {
        let m = makeModel()
        m.airplayDelayMs = 4900
        m.nudgeAirplayDelay(by: 500)
        XCTAssertEqual(m.airplayDelayMs, 5000)
    }

    // MARK: - AuditionState

    func test_startAudition_from_idle_sets_running_round_1() {
        let m = makeModel()
        XCTAssertEqual(m.auditionState, .idle)
        m.airplayDelayMs = 1800
        m.startAudition()
        XCTAssertEqual(m.auditionState, .running(round: 1, side: .A))
    }

    func test_startAudition_when_already_running_is_noop() {
        let m = makeModel()
        m.airplayDelayMs = 1800
        m.startAudition()
        let snapshot = m.auditionState
        XCTAssertEqual(snapshot, .running(round: 1, side: .A))
        // Second call with no choose-A/B in between must not advance the
        // round counter or change the side.
        m.startAudition()
        XCTAssertEqual(m.auditionState, snapshot)
    }

    func test_chooseAuditionA_decreases_by_75() {
        let m = makeModel()
        m.airplayDelayMs = 1800
        m.startAudition()
        // After startAudition: baseline = 1800. A and B sides differ from
        // baseline by ±75. chooseAuditionA picks A → baseline -= 75 = 1725.
        m.chooseAuditionA()
        XCTAssertEqual(m.airplayDelayMs, 1725,
                       "chooseAuditionA must subtract 75 ms from the audition baseline")
    }

    func test_chooseAuditionB_increases_by_75() {
        let m = makeModel()
        m.airplayDelayMs = 1800
        m.startAudition()
        m.chooseAuditionB()
        XCTAssertEqual(m.airplayDelayMs, 1875,
                       "chooseAuditionB must add 75 ms to the audition baseline")
    }

    func test_audition_4_rounds_returns_to_idle() {
        let m = makeModel()
        m.airplayDelayMs = 1800
        m.startAudition()
        XCTAssertEqual(m.auditionState, .running(round: 1, side: .A))
        // Each round consumes one A/B decision. Four decisions total →
        // round 1, 2, 3, 4 → auditionState back to .idle.
        m.chooseAuditionA() // round 1 → 2
        XCTAssertNotEqual(m.auditionState, .idle,
                          "audition must still be running after 1 decision")
        m.chooseAuditionB() // round 2 → 3
        XCTAssertNotEqual(m.auditionState, .idle,
                          "audition must still be running after 2 decisions")
        m.chooseAuditionA() // round 3 → 4
        XCTAssertNotEqual(m.auditionState, .idle,
                          "audition must still be running after 3 decisions")
        m.chooseAuditionB() // round 4 → done
        XCTAssertEqual(m.auditionState, .idle,
                       "audition must return to idle after 4 decisions")
    }

    func test_stopAudition_restores_baseline() {
        let m = makeModel()
        m.airplayDelayMs = 2000
        m.startAudition()  // baseline = 2000
        m.chooseAuditionA() // 2000 - 75 = 1925
        XCTAssertEqual(m.airplayDelayMs, 1925)
        m.stopAudition()
        XCTAssertEqual(m.auditionState, .idle,
                       "stopAudition must reset auditionState to .idle")
        XCTAssertEqual(m.airplayDelayMs, 2000,
                       "stopAudition must restore the original baseline")
    }

    // MARK: - Persistence

    /// `lockAirplayDelay()` must persist BOTH the lock flag and the locked
    /// value so that a fresh `AppModel` (e.g. on next launch) restarts in
    /// `.locked(at: <value>)` rather than `.unlocked`.
    func test_persistence_lockedAt_round_trip() {
        // Simulate a previous run: dial the FIFO to 2300 ms and lock it.
        do {
            let m = makeModel()
            m.airplayDelayMs = 2300
            m.lockAirplayDelay()
            XCTAssertEqual(m.delayLockState, .locked(at: 2300))
        }
        // Synchronize UserDefaults so the persisted writes are observable
        // from a fresh AppModel instance built in-process.
        UserDefaults.standard.synchronize()

        // Reinstantiate. The new AppModel must re-load locked-at = 2300
        // straight from persistence, without any user action.
        let m2 = AppModel()
        XCTAssertEqual(m2.delayLockState, .locked(at: 2300))
    }
}
