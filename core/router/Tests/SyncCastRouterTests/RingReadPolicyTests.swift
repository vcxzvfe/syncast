import XCTest
@testable import SyncCastRouter

/// The ring floor is added latency the user hears, and the read plan is what
/// decides whether a block glitches. Both are pure arithmetic, so both are
/// pinned here rather than left to a listening test.
final class RingFloorPolicyTests: XCTestCase {
    private let rate = 48_000.0

    // MARK: env-var validation

    func testUnsetUsesSinkDefaultWithoutWarning() {
        let resolved = RingFloorPolicy.resolveSinkFloorMs(rawValue: nil)
        XCTAssertEqual(resolved.ms, RingFloorPolicy.sinkDefaultFloorMs)
        XCTAssertNil(resolved.warning)
    }

    func testEmptyOrWhitespaceIsTreatedAsUnset() {
        for raw in ["", "   ", "\t"] {
            let resolved = RingFloorPolicy.resolveSinkFloorMs(rawValue: raw)
            XCTAssertEqual(resolved.ms, RingFloorPolicy.sinkDefaultFloorMs, "raw=\(raw.debugDescription)")
            XCTAssertNil(resolved.warning, "raw=\(raw.debugDescription)")
        }
    }

    func testValidValueIsAccepted() {
        let resolved = RingFloorPolicy.resolveSinkFloorMs(rawValue: " 45 ")
        XCTAssertEqual(resolved.ms, 45)
        XCTAssertNil(resolved.warning)
    }

    func testBoundariesAreInclusive() {
        XCTAssertEqual(
            RingFloorPolicy.resolveSinkFloorMs(rawValue: "\(RingFloorPolicy.minFloorMs)").ms,
            RingFloorPolicy.minFloorMs
        )
        XCTAssertEqual(
            RingFloorPolicy.resolveSinkFloorMs(rawValue: "\(RingFloorPolicy.maxFloorMs)").ms,
            RingFloorPolicy.maxFloorMs
        )
    }

    func testNonIntegerFallsBackAndWarns() {
        for raw in ["abc", "30.5", "30ms", "-", "1e3"] {
            let resolved = RingFloorPolicy.resolveSinkFloorMs(rawValue: raw)
            XCTAssertEqual(resolved.ms, RingFloorPolicy.sinkDefaultFloorMs, "raw=\(raw)")
            XCTAssertNotNil(resolved.warning, "raw=\(raw) should warn")
            XCTAssertTrue(resolved.warning?.contains(raw) ?? false, "warning should name the bad value: \(raw)")
        }
    }

    func testOutOfRangeFallsBackAndWarns() {
        for raw in ["0", "9", "501", "100000", "-30"] {
            let resolved = RingFloorPolicy.resolveSinkFloorMs(rawValue: raw)
            XCTAssertEqual(resolved.ms, RingFloorPolicy.sinkDefaultFloorMs, "raw=\(raw)")
            XCTAssertNotNil(resolved.warning, "raw=\(raw) should warn")
        }
    }

    func testEnvironmentDictionaryOverload() {
        XCTAssertEqual(
            RingFloorPolicy.resolveSinkFloorMs(environment: [:]).ms,
            RingFloorPolicy.sinkDefaultFloorMs
        )
        XCTAssertEqual(
            RingFloorPolicy.resolveSinkFloorMs(
                environment: [RingFloorPolicy.sinkFloorEnvVar: "80"]
            ).ms,
            80
        )
    }

    // MARK: frame conversion

    func testFrameConversionMatchesTheDocumentedBudget() {
        XCTAssertEqual(RingFloorPolicy.frames(ms: 100, sampleRate: rate), 4800)
        XCTAssertEqual(RingFloorPolicy.frames(ms: 30, sampleRate: rate), 1440)
        XCTAssertEqual(RingFloorPolicy.frames(ms: 0, sampleRate: rate), 0)
        XCTAssertEqual(RingFloorPolicy.frames(ms: -5, sampleRate: rate), 0)
        XCTAssertEqual(RingFloorPolicy.frames(ms: 30, sampleRate: 0), 0)
        XCTAssertEqual(
            RingFloorPolicy.milliseconds(frames: 1440, sampleRate: rate), 30, accuracy: 0.001
        )
    }

    func testClampKeepsTheFloorServiceableByTheRing() {
        XCTAssertEqual(LocalOutput.clampRingFloorFrames(1440, capacityFrames: 1 << 18), 1440)
        XCTAssertEqual(LocalOutput.clampRingFloorFrames(-1, capacityFrames: 1 << 18), 0)
        // Never more than half the ring: the rest has to hold the block plus
        // whatever the producer writes while we render.
        XCTAssertEqual(LocalOutput.clampRingFloorFrames(4096, capacityFrames: 4096), 2048)
    }
}

final class RingReadPlannerTests: XCTestCase {
    private let capacity = 1 << 18
    private let block = 512
    private let floor: Int64 = 1440           // 30 ms @ 48k
    private let driftLimit: Int64 = 12_000    // 250 ms @ 48k

    private func plan(writePosition: Int64, cursor: Int64, frames: Int? = nil) -> RingReadPlan {
        RingReadPlanner.plan(
            writePosition: writePosition,
            cursor: cursor,
            frames: frames ?? block,
            floorFrames: floor,
            compensationFrames: 0,
            capacityFrames: capacity,
            driftLimitFrames: driftLimit
        )
    }

    func testFirstRenderAnchorsOnTheFloor() {
        let result = plan(writePosition: 100_000, cursor: 0)
        XCTAssertTrue(result.didResync)
        XCTAssertEqual(result.startFrame, 100_000 - floor - Int64(block))
        XCTAssertEqual(result.underrunFrames, 0)
        // Water level after a resync is exactly floor + block.
        XCTAssertEqual(result.waterLevelFrames, floor + Int64(block))
    }

    func testSteadyStateKeepsTheCursorAndNeverResyncs() {
        var cursor: Int64 = 0
        var writePos: Int64 = 96_000
        // First render anchors; then producer and consumer both advance by one
        // block per tick, which is the no-glitch case.
        var result = plan(writePosition: writePos, cursor: cursor)
        cursor = result.startFrame + Int64(block)
        for tick in 0..<2000 {
            writePos += Int64(block)
            result = plan(writePosition: writePos, cursor: cursor)
            XCTAssertFalse(result.didResync, "resync at tick \(tick)")
            XCTAssertEqual(result.underrunFrames, 0, "underrun at tick \(tick)")
            XCTAssertEqual(result.startFrame, cursor)
            cursor = result.startFrame + Int64(block)
        }
        // The water level should sit at the floor, not drift away from it.
        XCTAssertEqual(result.waterLevelFrames, floor + Int64(block))
    }

    func testOneBlockOfProducerJitterDoesNotResync() {
        // Producer stalls for one block, then delivers two. With a 30 ms floor
        // there is ~3 blocks of slack, so neither tick may resync.
        var cursor: Int64 = 0
        var writePos: Int64 = 96_000
        var result = plan(writePosition: writePos, cursor: cursor)
        cursor = result.startFrame + Int64(block)
        // stall: producer writes nothing this tick
        result = plan(writePosition: writePos, cursor: cursor)
        XCTAssertFalse(result.didResync, "a single late producer block must not resync")
        XCTAssertEqual(result.underrunFrames, 0)
        cursor = result.startFrame + Int64(block)
        // catch-up: producer writes two blocks
        writePos += Int64(2 * block)
        result = plan(writePosition: writePos, cursor: cursor)
        XCTAssertFalse(result.didResync)
        XCTAssertEqual(result.underrunFrames, 0)
    }

    func testReadingPastTheWriteCursorIsAnUnderrunAndResyncs() {
        // Producer stalled long enough that the cursor has caught up with it.
        let writePos: Int64 = 96_000
        let cursor = writePos - 100   // less than one block of data left
        let result = plan(writePosition: writePos, cursor: cursor)
        XCTAssertTrue(result.didResync, "reading past the write head must re-anchor")
        // Re-anchored to target, which is floor+block behind — no underrun left.
        XCTAssertEqual(result.startFrame, writePos - floor - Int64(block))
        XCTAssertEqual(result.underrunFrames, 0)
    }

    func testColdStartUnderrunIsReportedNotHidden() {
        // The ring has only 100 frames in it; a 512-frame block cannot be
        // served. target clamps to 0 and the tail is zero-filled by RingBuffer.
        let result = plan(writePosition: 100, cursor: 0)
        XCTAssertTrue(result.didResync)
        XCTAssertEqual(result.startFrame, 0)
        XCTAssertEqual(result.underrunFrames, block - 100)
        XCTAssertEqual(result.waterLevelFrames, 100)
    }

    func testUnderrunNeverExceedsTheBlock() {
        let result = plan(writePosition: 0, cursor: 0)
        XCTAssertEqual(result.underrunFrames, block)
    }

    func testCursorOverwrittenByTheProducerResyncs() {
        let writePos = Int64(capacity) * 3
        let stale = writePos - Int64(capacity)   // exactly one lap behind
        let result = plan(writePosition: writePos, cursor: stale)
        XCTAssertTrue(result.didResync)
        XCTAssertEqual(result.startFrame, writePos - floor - Int64(block))
    }

    func testDriftBeyondTheLimitResyncsButNotBefore() {
        let writePos: Int64 = 5_000_000
        let target = writePos - floor - Int64(block)
        // Just inside the limit: the cursor lags but we ride it out.
        let inside = plan(writePosition: writePos, cursor: target - driftLimit)
        XCTAssertFalse(inside.didResync)
        XCTAssertEqual(inside.startFrame, target - driftLimit)
        // Just outside: re-anchor.
        let outside = plan(writePosition: writePos, cursor: target - driftLimit - 1)
        XCTAssertTrue(outside.didResync)
        XCTAssertEqual(outside.startFrame, target)
    }

    func testCompensationPushesTheReadPointFurtherBack() {
        let result = RingReadPlanner.plan(
            writePosition: 500_000,
            cursor: 0,
            frames: block,
            floorFrames: floor,
            compensationFrames: 800,
            capacityFrames: capacity,
            driftLimitFrames: driftLimit
        )
        XCTAssertEqual(result.startFrame, 500_000 - floor - 800 - Int64(block))
    }

    func testLegacyFloorProducesTheHistoricalTarget() {
        // The SCK paths must behave exactly as they did with the hardcoded
        // 4800-frame baseline.
        let result = RingReadPlanner.plan(
            writePosition: 1_000_000,
            cursor: 0,
            frames: 1024,
            floorFrames: Int64(RingFloorPolicy.frames(ms: RingFloorPolicy.legacyFloorMs, sampleRate: 48_000)),
            compensationFrames: 0,
            capacityFrames: capacity,
            driftLimitFrames: driftLimit
        )
        XCTAssertEqual(result.startFrame, 1_000_000 - 4800 - 1024)
    }
}
