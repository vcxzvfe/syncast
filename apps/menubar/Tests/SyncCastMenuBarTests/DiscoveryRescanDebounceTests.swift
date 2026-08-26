import XCTest
import SyncCastDiscovery
@testable import SyncCastMenuBar

/// Unit tests for the manual "rescan devices" gate.
///
/// The transitions are exercised through `DiscoveryRescanGate` rather than
/// through `AppModel`, because the only interesting cases are separated by
/// wall-clock seconds and because accepting a scan spins up a real
/// `NWBrowser`. The `AppModel` cases below therefore cover only what is
/// observable synchronously: the first request is accepted, and a second one
/// on its heels is refused.
final class DiscoveryRescanDebounceTests: XCTestCase {
    private let cooldown: TimeInterval = 3.0
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    // MARK: - Gate transitions

    func test_first_request_is_accepted() {
        let state = DiscoveryRescanGate.State()
        XCTAssertEqual(
            DiscoveryRescanGate.decide(state: state, now: t0, cooldown: cooldown),
            .start
        )
    }

    func test_request_while_in_flight_is_dropped() {
        let started = DiscoveryRescanGate.started(
            from: DiscoveryRescanGate.State(), at: t0
        )
        XCTAssertTrue(started.inFlight)
        // Even long after the cooldown, an unfinished scan blocks: two
        // concurrent browser restarts are exactly the storm to avoid.
        XCTAssertEqual(
            DiscoveryRescanGate.decide(
                state: started,
                now: t0.addingTimeInterval(60),
                cooldown: cooldown
            ),
            .dropInFlight
        )
    }

    func test_mashing_the_button_yields_exactly_one_scan() {
        var state = DiscoveryRescanGate.State()
        var accepted = 0
        // 20 presses over 2 seconds — a determined double-click user.
        for i in 0..<20 {
            let now = t0.addingTimeInterval(Double(i) * 0.1)
            if DiscoveryRescanGate.decide(
                state: state, now: now, cooldown: cooldown
            ) == .start {
                accepted += 1
                state = DiscoveryRescanGate.started(from: state, at: now)
            }
        }
        XCTAssertEqual(accepted, 1)
    }

    func test_request_within_cooldown_after_finish_is_dropped() {
        var state = DiscoveryRescanGate.started(
            from: DiscoveryRescanGate.State(), at: t0
        )
        state = DiscoveryRescanGate.finished(from: state)
        XCTAssertFalse(state.inFlight)
        XCTAssertEqual(
            DiscoveryRescanGate.decide(
                state: state,
                now: t0.addingTimeInterval(cooldown - 0.5),
                cooldown: cooldown
            ),
            .dropCoolingDown
        )
    }

    func test_request_after_cooldown_is_accepted() {
        var state = DiscoveryRescanGate.started(
            from: DiscoveryRescanGate.State(), at: t0
        )
        state = DiscoveryRescanGate.finished(from: state)
        XCTAssertEqual(
            DiscoveryRescanGate.decide(
                state: state,
                now: t0.addingTimeInterval(cooldown),
                cooldown: cooldown
            ),
            .start
        )
    }

    /// The cooldown is measured from the START of the previous scan, not
    /// from when its feedback window closed, so the two windows overlap
    /// instead of stacking.
    func test_cooldown_runs_from_scan_start_not_from_finish() {
        var state = DiscoveryRescanGate.started(
            from: DiscoveryRescanGate.State(), at: t0
        )
        state = DiscoveryRescanGate.finished(from: state)
        XCTAssertEqual(state.lastStartedAt, t0)
    }

    // MARK: - Configuration invariant

    /// A press that is silently ignored while the button still looks live
    /// is the worst outcome for this control. As configured, the feedback
    /// window (during which the button is replaced by a spinner) is never
    /// shorter than the cooldown, so `dropCoolingDown` cannot be reached
    /// from the UI. The cooldown is the floor that keeps this true if the
    /// removal-grace window is later tuned down against real mDNS
    /// measurements — but if someone tunes it below the cooldown, this
    /// fails rather than shipping an inert button.
    @MainActor
    func test_feedback_window_covers_the_cooldown() {
        XCTAssertGreaterThanOrEqual(
            AppModel.discoveryRescanFeedbackSeconds,
            AppModel.discoveryRescanCooldownSeconds
        )
    }

    /// The spinner must not clear before the discovery layer stops
    /// suppressing removals: while removals are suppressed the device list
    /// is deliberately not yet trustworthy.
    @MainActor
    func test_feedback_window_matches_removal_grace() {
        XCTAssertEqual(
            AppModel.discoveryRescanFeedbackSeconds,
            AirPlayDiscovery.rescanRemovalGraceSeconds
        )
    }

    // MARK: - AppModel wiring

    @MainActor
    func test_model_marks_rescan_in_flight() {
        let m = AppModel()
        XCTAssertFalse(m.discoveryRescanInFlight)
        m.rescanDevices()
        XCTAssertTrue(m.discoveryRescanInFlight)
    }

    /// Re-entrancy at the model level: the flag stays set and no second
    /// scan is armed. (Discovery is not started in this test, so the
    /// underlying transports are no-ops — see `AirPlayDiscovery.rescan`.)
    @MainActor
    func test_model_ignores_repeat_requests_while_in_flight() {
        let m = AppModel()
        m.rescanDevices()
        for _ in 0..<10 { m.rescanDevices() }
        XCTAssertTrue(m.discoveryRescanInFlight)
    }
}
