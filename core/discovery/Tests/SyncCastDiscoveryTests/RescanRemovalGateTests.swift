import XCTest
@testable import SyncCastDiscovery

/// Specification for the post-rescan removal grace window.
///
/// The bug these pin is not a crash: the window used to DROP suppressed
/// removals rather than defer them, and because `NWBrowser` only calls back
/// when the result set changes, a receiver powered off inside the window could
/// produce its one and only "it's gone" callback there and never be reported
/// missing at all. It stayed listed, stayed enabled, and in whole-home mode
/// stayed registered as an OwnTone output for the rest of the session.
///
/// Clock-injected on purpose: `Set<NWBrowser.Result>` cannot be constructed in
/// a test, so anything left inside `handleResults` is only reachable with live
/// Bonjour traffic — which is precisely how the drop-instead-of-defer bug got
/// through review.
final class RescanRemovalGateTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    // MARK: - No window open

    func test_without_a_rescan_removals_emit_immediately() {
        var gate = RescanRemovalGate()
        XCTAssertEqual(gate.observe(keys: ["a"], now: t0), .emitNow)
        XCTAssertFalse(gate.recheckScheduled)
    }

    // MARK: - Inside the window

    func test_inside_the_window_the_first_callback_defers_rather_than_drops() {
        var gate = RescanRemovalGate()
        gate.suppressRemovals(until: t0.addingTimeInterval(6))

        let action = gate.observe(keys: ["a"], now: t0.addingTimeInterval(2))
        XCTAssertEqual(action, .deferBy(4))
        XCTAssertTrue(gate.recheckScheduled)
    }

    /// A burst of partial callbacks from a restarted browser must queue ONE
    /// timer, not one per callback.
    func test_further_callbacks_inside_the_window_do_not_queue_more_timers() {
        var gate = RescanRemovalGate()
        gate.suppressRemovals(until: t0.addingTimeInterval(6))

        XCTAssertEqual(gate.observe(keys: ["a"], now: t0.addingTimeInterval(1)), .deferBy(5))
        XCTAssertEqual(gate.observe(keys: ["a"], now: t0.addingTimeInterval(2)), .alreadyScheduled)
        XCTAssertEqual(gate.observe(keys: ["a"], now: t0.addingTimeInterval(3)), .alreadyScheduled)
    }

    /// The keys the deferred pass will diff against must be the LATEST the
    /// browser reported, not the ones from the callback that opened the defer.
    func test_deferred_pass_uses_the_most_recent_key_set() {
        var gate = RescanRemovalGate()
        gate.suppressRemovals(until: t0.addingTimeInterval(6))

        _ = gate.observe(keys: ["stale"], now: t0.addingTimeInterval(1))
        _ = gate.observe(keys: ["fresh-a", "fresh-b"], now: t0.addingTimeInterval(2))
        XCTAssertEqual(gate.lastBrowserKeys, ["fresh-a", "fresh-b"])
    }

    // MARK: - The window closing

    /// The whole point: a departure observed inside the window is still
    /// emitted afterwards, with no further browser callback required.
    func test_recheck_after_the_window_emits_the_deferred_removals() {
        var gate = RescanRemovalGate()
        gate.suppressRemovals(until: t0.addingTimeInterval(6))

        // The Xiaomi was powered off 2 s into the window: this callback no
        // longer lists it, and no further callback will ever arrive.
        XCTAssertEqual(gate.observe(keys: [], now: t0.addingTimeInterval(2)), .deferBy(4))
        XCTAssertEqual(gate.recheckFired(now: t0.addingTimeInterval(6)), .emitNow)
        XCTAssertEqual(gate.lastBrowserKeys, [])
        XCTAssertFalse(gate.recheckScheduled)
    }

    /// A second rescan while the re-check is pending pushes the deadline out,
    /// and the gate must re-arm rather than emit against a key set the newest
    /// browser has not refreshed yet.
    func test_a_second_rescan_extends_the_window_and_rearms() {
        var gate = RescanRemovalGate()
        gate.suppressRemovals(until: t0.addingTimeInterval(6))
        XCTAssertEqual(gate.observe(keys: [], now: t0.addingTimeInterval(1)), .deferBy(5))

        gate.suppressRemovals(until: t0.addingTimeInterval(10))
        XCTAssertEqual(gate.recheckFired(now: t0.addingTimeInterval(6)), .deferBy(4))
        XCTAssertTrue(gate.recheckScheduled)
        XCTAssertEqual(gate.recheckFired(now: t0.addingTimeInterval(10)), .emitNow)
    }

    /// An EARLIER deadline must never shorten an open window — the newest
    /// browser is the one whose first callbacks are incomplete.
    func test_suppression_deadline_never_moves_backwards() {
        var gate = RescanRemovalGate()
        gate.suppressRemovals(until: t0.addingTimeInterval(6))
        gate.suppressRemovals(until: t0.addingTimeInterval(2))
        XCTAssertEqual(gate.suppressedUntil, t0.addingTimeInterval(6))
    }

    /// Once the window has closed the gate must be reusable: a later rescan
    /// has to be able to defer again, which a stuck `recheckScheduled` would
    /// block forever.
    func test_gate_is_reusable_after_the_window_closes() {
        var gate = RescanRemovalGate()
        gate.suppressRemovals(until: t0.addingTimeInterval(6))
        _ = gate.observe(keys: [], now: t0.addingTimeInterval(1))
        XCTAssertEqual(gate.recheckFired(now: t0.addingTimeInterval(6)), .emitNow)

        gate.suppressRemovals(until: t0.addingTimeInterval(20))
        XCTAssertEqual(gate.observe(keys: [], now: t0.addingTimeInterval(15)), .deferBy(5))
    }
}
