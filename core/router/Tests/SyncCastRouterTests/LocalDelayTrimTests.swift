import XCTest
@testable import SyncCastRouter

/// The arithmetic that turns "this display sounds 30 ms late" into the frame
/// offsets `LocalOutput.render()` applies. Pure, so the specification is here
/// rather than in a listening test.
final class LocalDelayTrimTests: XCTestCase {
    private let rate = 48_000.0
    /// Comfortably larger than anything these cases ask for, so a clamp that
    /// fires is a real finding and not the fixture.
    private let headroom = 48_000

    // MARK: - Range and conversion

    func testClampHoldsTheUserRange() {
        XCTAssertEqual(LocalDelayTrim.clamp(0), 0)
        XCTAssertEqual(LocalDelayTrim.clamp(45), 45)
        XCTAssertEqual(LocalDelayTrim.clamp(-45), -45)
        XCTAssertEqual(LocalDelayTrim.clamp(9_999), LocalDelayTrim.rangeMs.upperBound)
        XCTAssertEqual(LocalDelayTrim.clamp(-9_999), LocalDelayTrim.rangeMs.lowerBound)
    }

    /// The whole-home trim is a different correction on a different leg; this
    /// one is deliberately the narrower of the two. A change that quietly
    /// widened it would put more backlog on the stereo ring than the floor
    /// was sized for.
    func testLocalRangeIsNarrowerThanTheWholeHomeTrim() {
        XCTAssertLessThan(
            LocalDelayTrim.rangeMs.upperBound, DeviceDelayTrim.rangeMs.upperBound
        )
        XCTAssertGreaterThan(
            LocalDelayTrim.rangeMs.lowerBound, DeviceDelayTrim.rangeMs.lowerBound
        )
    }

    func testMillisecondsToFramesRoundTrip() {
        XCTAssertEqual(LocalDelayTrim.frames(ms: 10, sampleRate: rate), 480)
        XCTAssertEqual(LocalDelayTrim.frames(ms: -10, sampleRate: rate), -480)
        XCTAssertEqual(LocalDelayTrim.frames(ms: 0, sampleRate: rate), 0)
        XCTAssertEqual(
            LocalDelayTrim.milliseconds(frames: 480, sampleRate: rate), 10, accuracy: 1e-9
        )
    }

    func testZeroSampleRateIsRefusedRatherThanDividedBy() {
        XCTAssertEqual(LocalDelayTrim.frames(ms: 10, sampleRate: 0), 0)
        XCTAssertEqual(LocalDelayTrim.milliseconds(frames: 480, sampleRate: 0), 0)
    }

    // MARK: - Planner: the default is silence about itself

    func testNothingDialledInProducesNoOffsets() {
        let offsets = LocalDelayTrimPlanner.offsetFrames(
            pairCount: 3, seedFrames: [:], userMs: [:],
            sampleRate: rate, headroomFrames: headroom
        )
        XCTAssertEqual(offsets, [0, 0, 0])
    }

    func testSinglePairIsAlwaysZeroBecauseThereIsNothingToAlignAgainst() {
        let offsets = LocalDelayTrimPlanner.offsetFrames(
            pairCount: 1, seedFrames: [0: -2_400], userMs: [0: 75],
            sampleRate: rate, headroomFrames: headroom
        )
        XCTAssertEqual(offsets, [0])
    }

    // MARK: - Planner: relative intent, non-negative result

    func testOnlyTheDifferenceBetweenPairsSurvives() {
        // "+20 ms on pair 1" and "−20 ms on pair 0" are the same edit.
        let holdLater = LocalDelayTrimPlanner.offsetFrames(
            pairCount: 2, seedFrames: [:], userMs: [1: 20],
            sampleRate: rate, headroomFrames: headroom
        )
        let bringForward = LocalDelayTrimPlanner.offsetFrames(
            pairCount: 2, seedFrames: [:], userMs: [0: -20],
            sampleRate: rate, headroomFrames: headroom
        )
        XCTAssertEqual(holdLater, [0, 960])
        XCTAssertEqual(bringForward, holdLater)
    }

    func testEveryResultIsNonNegativeAndAtLeastOneIsZero() {
        let offsets = LocalDelayTrimPlanner.offsetFrames(
            pairCount: 4,
            seedFrames: [0: -100, 1: -900, 2: 0, 3: -50],
            userMs: [0: -30, 1: 12, 2: -7, 3: 100],
            sampleRate: rate, headroomFrames: headroom
        )
        XCTAssertTrue(offsets.allSatisfy { $0 >= 0 })
        XCTAssertTrue(offsets.contains(0))
    }

    /// The seed is the NEGATIVE of reported latency, so the device that
    /// reports the most latency needs the least hold — that is the whole
    /// point of seeding, and getting the sign backwards would double the skew
    /// instead of removing it.
    func testHonestlyReportedLatencyLinesUpWithoutUserInput() {
        // Pair 0 reports 1 ms (48 frames), pair 1 reports 11 ms (528 frames).
        let offsets = LocalDelayTrimPlanner.offsetFrames(
            pairCount: 2, seedFrames: [0: -48, 1: -528], userMs: [:],
            sampleRate: rate, headroomFrames: headroom
        )
        // The slow device is already late; the fast one is held back to match.
        XCTAssertEqual(offsets, [480, 0])
    }

    func testUserTrimStacksOnTopOfTheSeed() {
        let seedOnly = LocalDelayTrimPlanner.offsetFrames(
            pairCount: 2, seedFrames: [0: -48, 1: -528], userMs: [:],
            sampleRate: rate, headroomFrames: headroom
        )
        // The panel's undeclared processing: hold pair 0 back another 5 ms.
        let withUser = LocalDelayTrimPlanner.offsetFrames(
            pairCount: 2, seedFrames: [0: -48, 1: -528], userMs: [0: 5],
            sampleRate: rate, headroomFrames: headroom
        )
        XCTAssertEqual(seedOnly, [480, 0])
        XCTAssertEqual(withUser, [720, 0])
    }

    // MARK: - Planner: bounds

    func testUserValuesAreClampedIntoRangeBeforeUse() {
        let sane = LocalDelayTrimPlanner.offsetFrames(
            pairCount: 2, seedFrames: [:],
            userMs: [1: LocalDelayTrim.rangeMs.upperBound],
            sampleRate: rate, headroomFrames: headroom
        )
        let absurd = LocalDelayTrimPlanner.offsetFrames(
            pairCount: 2, seedFrames: [:], userMs: [1: 100_000],
            sampleRate: rate, headroomFrames: headroom
        )
        XCTAssertEqual(absurd, sane)
    }

    func testHeadroomCapsTheOffsetEvenWhenTheIntentIsLarger() {
        let offsets = LocalDelayTrimPlanner.offsetFrames(
            pairCount: 2, seedFrames: [:], userMs: [1: 100],
            sampleRate: rate, headroomFrames: 1_000
        )
        XCTAssertEqual(offsets, [0, 1_000])
    }

    /// A device reporting nonsense (seconds of latency) must not park the read
    /// cursor arbitrarily far behind the producer.
    func testAWildSeedIsCappedByTheAbsoluteCeiling() {
        let ceiling = LocalDelayTrim.frames(
            ms: LocalDelayTrim.maxOffsetMs, sampleRate: rate
        )
        let offsets = LocalDelayTrimPlanner.offsetFrames(
            pairCount: 2, seedFrames: [0: 0, 1: -48_000 * 30], userMs: [:],
            sampleRate: rate, headroomFrames: headroom
        )
        XCTAssertEqual(offsets, [ceiling, 0])
    }

    func testNoHeadroomDisablesTheFeatureEntirely() {
        let offsets = LocalDelayTrimPlanner.offsetFrames(
            pairCount: 2, seedFrames: [0: -5_000], userMs: [1: 60],
            sampleRate: rate, headroomFrames: 0
        )
        XCTAssertEqual(offsets, [0, 0])
    }

    func testEmptyPairSetIsEmpty() {
        XCTAssertEqual(
            LocalDelayTrimPlanner.offsetFrames(
                pairCount: 0, seedFrames: [:], userMs: [:],
                sampleRate: rate, headroomFrames: headroom
            ),
            []
        )
    }

    // MARK: - Headroom derivation

    func testHeadroomIsWhatTheRingHasLeftBehindTheFloor() {
        XCTAssertEqual(
            LocalDelayTrimPlanner.headroomFrames(capacityFrames: 1 << 18, floorFrames: 4_800),
            131_072 - 4_800
        )
    }

    func testHeadroomNeverGoesNegative() {
        XCTAssertEqual(
            LocalDelayTrimPlanner.headroomFrames(capacityFrames: 1_024, floorFrames: 100_000),
            0
        )
        XCTAssertEqual(
            LocalDelayTrimPlanner.headroomFrames(capacityFrames: 0, floorFrames: 0), 0
        )
    }
}
