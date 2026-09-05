import XCTest
@testable import SyncCastRouter

/// `PhaseTimer` exists so a future 108 s stall names its own phase. The clock
/// is injectable precisely so that claim can be tested rather than timed.
final class PhaseTimerTests: XCTestCase {
    private final class Clock {
        var nanos: UInt64 = 0
        func advance(ms: Double) { nanos &+= UInt64(ms * 1_000_000) }
    }

    private func makeTimer(
        scope: String = "[Router] test"
    ) -> (timer: PhaseTimer, clock: Clock, lines: () -> [String]) {
        let clock = Clock()
        let box = NSMutableArray()
        let timer = PhaseTimer(
            scope: scope,
            now: { clock.nanos },
            emit: { box.add($0) }
        )
        return (timer, clock, { box.compactMap { $0 as? String } })
    }

    func testEachPhaseReportsItsOwnDurationAndTheRunningTotal() {
        var (timer, clock, lines) = makeTimer()
        clock.advance(ms: 12)
        timer.mark("sink takeover")
        clock.advance(ms: 30)
        timer.mark("tap start")
        XCTAssertEqual(lines(), [
            "[Router] test: sink takeover 12.0 ms (total 12.0 ms)",
            "[Router] test: tap start 30.0 ms (total 42.0 ms)",
        ])
    }

    /// The point of the whole thing: the phase that ate the wall clock is
    /// marked, and the ones around it are not.
    func testSlowPhaseIsFlaggedAndFastOnesAreNot() {
        var (timer, clock, lines) = makeTimer()
        clock.advance(ms: 5)
        timer.mark("preflight")
        clock.advance(ms: 108_000)
        timer.mark("tap start")
        clock.advance(ms: 3)
        timer.mark("output open")
        let captured = lines()
        XCTAssertFalse(captured[0].hasSuffix("SLOW"))
        XCTAssertTrue(captured[1].hasSuffix("SLOW"))
        XCTAssertTrue(captured[1].contains("tap start 108000.0 ms"))
        XCTAssertFalse(captured[2].hasSuffix("SLOW"))
    }

    func testThresholdIsInclusive() {
        var (timer, clock, lines) = makeTimer()
        clock.advance(ms: PhaseTimer.slowPhaseMs)
        timer.mark("borderline")
        XCTAssertTrue(lines()[0].hasSuffix("SLOW"))
    }

    func testMarkReturnsThePhaseDuration() {
        var (timer, clock, _) = makeTimer()
        clock.advance(ms: 7.5)
        XCTAssertEqual(timer.mark("a"), 7.5, accuracy: 0.001)
        clock.advance(ms: 2.5)
        XCTAssertEqual(timer.mark("b"), 2.5, accuracy: 0.001)
    }

    /// A monotonic clock should not go backwards, but a duration is never
    /// allowed to be negative even if one did.
    func testNonAdvancingClockYieldsZero() {
        var (timer, _, lines) = makeTimer()
        timer.mark("instant")
        XCTAssertEqual(lines(), ["[Router] test: instant 0.0 ms (total 0.0 ms)"])
        XCTAssertEqual(timer.totalMs, 0)
    }
}
