import XCTest
@testable import SyncCastRouter

/// The publish/adopt protocol and the window bookkeeping `LocalOutput.render()`
/// leans on. Everything here is what the render thread would do, minus the
/// CoreAudio device.
final class PairDelayBankTests: XCTestCase {
    private let rate = 48_000.0

    private func makeBank(pairs: Int = 2) -> PairDelayBank {
        PairDelayBank(pairCount: pairs, sampleRate: rate)
    }

    // MARK: - Default is invisible

    func testUntouchedBankIsSettledAtZero() {
        let bank = makeBank()
        let first = bank.adoptPublishedChanges()
        XCTAssertEqual(first.window, 0)
        XCTAssertEqual(first.cursorShift, 0)
        XCTAssertTrue(bank.isSettledAtZero)
        XCTAssertEqual(bank.readLeadFrames(pair: 0), 0)
        XCTAssertEqual(bank.readLeadFrames(pair: 1), 0)
    }

    func testRepublishingTheSameMapCostsNothing() {
        let bank = makeBank()
        XCTAssertTrue(bank.setOffsets([1: 480]))
        XCTAssertFalse(bank.setOffsets([1: 480]))
        // Absent pairs are zero, so this really is the same map.
        XCTAssertFalse(bank.setOffsets([0: 0, 1: 480]))
        XCTAssertTrue(bank.setOffsets([1: 481]))
    }

    func testOutOfRangePairsAreIgnoredNotFatal() {
        let bank = makeBank(pairs: 2)
        XCTAssertTrue(bank.setOffsets([0: 96, 7: 4_800, -3: 100]))
        XCTAssertEqual(bank.requestedOffsets(), [96, 0])
    }

    func testNegativeOffsetsAreClampedAway() {
        let bank = makeBank()
        bank.setOffsets([0: -900, 1: 240])
        XCTAssertEqual(bank.requestedOffsets(), [0, 240])
    }

    // MARK: - Window and lead

    func testWindowIsTheLargestOffsetAndLeadsAreMeasuredDownFromIt() {
        let bank = makeBank(pairs: 3)
        bank.setOffsets([0: 0, 1: 480, 2: 120])
        let adopted = bank.adoptPublishedChanges()
        XCTAssertEqual(adopted.window, 480)
        XCTAssertFalse(bank.isSettledAtZero)
        // The most-delayed pair reads at the cursor itself; the earliest reads
        // a full window above it.
        XCTAssertEqual(bank.readLeadFrames(pair: 1), 0)
        XCTAssertEqual(bank.readLeadFrames(pair: 0), 480)
        XCTAssertEqual(bank.readLeadFrames(pair: 2), 360)
    }

    /// The invariant that keeps an untouched speaker from clicking when its
    /// neighbour is adjusted: absolute read position = cursor + window − offset,
    /// so a window change has to be paid for by the cursor.
    func testCursorShiftCancelsAWindowChangeForUntouchedPairs() {
        let bank = makeBank(pairs: 2)
        var cursor: Int64 = 1_000_000

        bank.setOffsets([:])
        var step = bank.adoptPublishedChanges()
        cursor += step.cursorShift
        let pair0Before = cursor + bank.readLeadFrames(pair: 0)

        bank.setOffsets([1: 480])
        step = bank.adoptPublishedChanges()
        cursor += step.cursorShift
        let pair0After = cursor + bank.readLeadFrames(pair: 0)

        XCTAssertEqual(step.cursorShift, -480)
        XCTAssertEqual(pair0After, pair0Before, "pair 0 must not move when pair 1 does")
    }

    func testWindowShrinksBackAfterAFadeCompletes() {
        let bank = makeBank(pairs: 2)
        bank.setOffsets([1: 480])
        XCTAssertEqual(bank.adoptPublishedChanges().window, 480)
        bank.advance(frames: bank.fadeFrames)

        bank.setOffsets([:])
        let shrinking = bank.adoptPublishedChanges()
        // Still 480 while the crossfade back to zero runs: both read positions
        // are live and the ring has to serve both.
        XCTAssertEqual(shrinking.window, 480)
        bank.advance(frames: bank.fadeFrames)
        let settled = bank.adoptPublishedChanges()
        XCTAssertEqual(settled.window, 0)
        XCTAssertEqual(settled.cursorShift, 480)
        XCTAssertTrue(bank.isSettledAtZero)
    }

    // MARK: - Crossfade

    func testAChangeStartsAFadeFromTheOldPosition() {
        let bank = makeBank(pairs: 2)
        bank.setOffsets([1: 960])
        _ = bank.adoptPublishedChanges()
        XCTAssertEqual(bank.fadeRemainingFrames(pair: 1), bank.fadeFrames)
        XCTAssertEqual(bank.fadeRemainingFrames(pair: 0), 0)
        // Fading out of "no delay" — which is a lead of a full window.
        XCTAssertEqual(bank.previousReadLeadFrames(pair: 1), 960)
        XCTAssertEqual(bank.readLeadFrames(pair: 1), 0)
    }

    func testFadeDrainsBlockByBlockAndThenSettles() {
        let bank = makeBank(pairs: 2)
        bank.setOffsets([1: 240])
        _ = bank.adoptPublishedChanges()
        var remaining = bank.fadeFrames
        while remaining > 0 {
            XCTAssertEqual(bank.fadeRemainingFrames(pair: 1), remaining)
            bank.advance(frames: 512)
            remaining = max(0, remaining - 512)
        }
        XCTAssertEqual(bank.fadeRemainingFrames(pair: 1), 0)
        // Settled: the outgoing position has collapsed onto the audible one.
        XCTAssertEqual(
            bank.previousReadLeadFrames(pair: 1), bank.readLeadFrames(pair: 1)
        )
    }

    func testFadeWeightWalksZeroToOneAcrossTheFade() {
        let fade = 960
        XCTAssertEqual(
            PairDelayBank.fadeWeight(remaining: fade, index: 0, fadeFrames: fade), 0
        )
        XCTAssertEqual(
            PairDelayBank.fadeWeight(remaining: fade, index: fade / 2, fadeFrames: fade),
            0.5, accuracy: 1e-6
        )
        XCTAssertEqual(
            PairDelayBank.fadeWeight(remaining: 1, index: 8, fadeFrames: fade), 1
        )
        // A block that starts mid-fade continues from where the last one left.
        XCTAssertEqual(
            PairDelayBank.fadeWeight(remaining: fade - 512, index: 0, fadeFrames: fade),
            Float(512) / Float(fade), accuracy: 1e-6
        )
    }

    func testWeightIsBoundedForAbsurdInputs() {
        XCTAssertEqual(PairDelayBank.fadeWeight(remaining: 0, index: 0, fadeFrames: 0), 1)
        XCTAssertEqual(
            PairDelayBank.fadeWeight(remaining: 10_000, index: 0, fadeFrames: 960), 0
        )
    }

    // MARK: - Restart

    func testResetRenderStateDropsAFadeButKeepsTheUsersOffsets() {
        let bank = makeBank(pairs: 2)
        bank.setOffsets([1: 480])
        _ = bank.adoptPublishedChanges()
        XCTAssertGreaterThan(bank.fadeRemainingFrames(pair: 1), 0)

        bank.resetRenderState()
        XCTAssertEqual(bank.fadeRemainingFrames(pair: 1), 0)
        XCTAssertEqual(bank.window, 480)
        XCTAssertEqual(bank.requestedOffsets(), [0, 480])
        XCTAssertFalse(bank.isSettledAtZero)
    }
}
