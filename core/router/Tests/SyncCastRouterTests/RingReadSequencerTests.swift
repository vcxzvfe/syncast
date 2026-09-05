import XCTest
@testable import SyncCastRouter

/// The state machine that separates "nobody is playing anything" from "we
/// dropped audio".
///
/// Before it existed, a system-sink run over ~35 s containing ~4 s of audio
/// reported ticks 2808 / resync 2437 / underrun 2436 / minWater 0 ms. Every one
/// of those glitches was silence. The counters exist to judge the 30 ms ring
/// floor, so a column that fills up when nothing is playing is worse than no
/// column at all.
///
/// Each test drives a synthetic producer through the sequencer exactly the way
/// `LocalOutput.render` does: plan, record, advance the cursor to
/// `startFrame + frames` — except on an idle block, where the cursor stays put.
final class RingReadSequencerTests: XCTestCase {
    private let block = 512
    private let floor: Int64 = 1_440           // 30 ms at 48 kHz, the sink floor
    private let capacity = 48_000 * 4
    private let driftLimit: Int64 = 250 * 48_000 / 1_000

    /// One consumer plus a synthetic producer, folded exactly as the render
    /// callback folds them.
    private struct Rig {
        var sequencer = RingReadSequencer()
        var tally = GlitchTally()
        var cursor: Int64 = 0
        var writePos: Int64 = 0
        var renders = 0
        let block: Int
        let floor: Int64
        let capacity: Int
        let driftLimit: Int64

        /// Advance the producer by `producedFrames` (0 = it is silent), then
        /// render one block.
        @discardableResult
        mutating func render(producing producedFrames: Int) -> RingReadPlan {
            writePos += Int64(producedFrames)
            let plan = sequencer.plan(
                writePosition: writePos,
                cursor: cursor,
                frames: block,
                floorFrames: floor,
                compensationFrames: 0,
                capacityFrames: capacity,
                driftLimitFrames: driftLimit
            )
            // LocalOutput skips the very first render: the cursor is 0 by
            // construction, so it always resyncs.
            if renders > 0 { tally.record(plan) }
            renders += 1
            if !plan.producerIdle {
                cursor = plan.startFrame + Int64(block)
            }
            return plan
        }

        /// The producer feeds one consumed block per render — steady state.
        mutating func burst(blocks: Int) {
            for _ in 0..<blocks { render(producing: block) }
        }

        mutating func silence(blocks: Int) {
            for _ in 0..<blocks { render(producing: 0) }
        }
    }

    /// `primedFrames` is how much the producer had already written before the
    /// AUHAL opened. It matters: a ring that starts empty never establishes
    /// the floor (the read target clamps at 0), so a test that skips this is
    /// measuring warm-up, not steady state.
    private func makeRig(primedFrames: Int64 = 96_000) -> Rig {
        var rig = Rig(
            block: block, floor: floor, capacity: capacity, driftLimit: driftLimit
        )
        rig.writePos = primedFrames
        return rig
    }

    // MARK: - The regression this exists for

    /// The measured failure, reproduced: a long silence used to fill both
    /// glitch columns. It must now fill only `idleBlocks`.
    func testLongSilenceCountsAsIdleAndNothingElse() {
        var rig = makeRig()
        rig.silence(blocks: 2_400)
        XCTAssertEqual(rig.tally.resyncCount, 0)
        XCTAssertEqual(rig.tally.underrunCount, 0)
        // Of 2400 renders: the first is not recorded (LocalOutput skips it),
        // the next two are served from the audio the 1440-frame floor was
        // holding, and the remaining 2397 are silence.
        XCTAssertEqual(rig.tally.idleBlocks, 2_397)
        XCTAssertEqual(
            rig.tally.minWaterLevelFrames, 928,
            "the two floor-covered blocks ARE samples: they show the floor draining"
        )
    }

    /// The full shape of the measured run: silence, a burst, silence, another
    /// burst. Nothing here is a dropout.
    func testSilenceBurstSilenceBurstYieldsNoGlitches() {
        var rig = makeRig()
        rig.silence(blocks: 600)
        rig.burst(blocks: 400)
        rig.silence(blocks: 900)
        rig.burst(blocks: 400)
        XCTAssertEqual(rig.tally.resyncCount, 0, "silence is not a resync")
        XCTAssertEqual(rig.tally.underrunCount, 0, "silence is not an underrun")
        // Each silence spends its first blocks on the audio the floor held
        // (three at the start of the run, where one render is also unrecorded;
        // two after the burst rebuilt it), and the rest is idle.
        XCTAssertEqual(rig.tally.idleBlocks, (600 - 3) + (900 - 2))
        XCTAssertEqual(rig.tally.recordedRenders, UInt64(600 + 400 + 900 + 400 - 1))
    }

    // MARK: - What must still be counted

    /// A producer that keeps writing but falls behind what the AUHAL consumes
    /// drains the floor and eventually starves. That is a real dropout and it
    /// must still show up.
    func testProducerFallingBehindMidBurstStillCounts() {
        var rig = makeRig()
        rig.burst(blocks: 200)
        XCTAssertEqual(rig.tally.resyncCount, 0, "precondition: steady state is clean")
        // Producing less than it consumes: the floor drains, then starves.
        for _ in 0..<40 { rig.render(producing: block / 4) }
        XCTAssertGreaterThan(
            rig.tally.resyncCount, 0,
            "a producer that cannot keep up is a glitch, not an idle producer"
        )
        XCTAssertEqual(rig.tally.idleBlocks, 0, "the producer never stopped writing")
    }

    /// Steady state stays clean — the property the whole counter set exists to
    /// certify.
    func testSteadyStateStaysClean() {
        var rig = makeRig()
        rig.burst(blocks: 5 * 60 * 48_000 / block)
        XCTAssertEqual(rig.tally.resyncCount, 0)
        XCTAssertEqual(rig.tally.underrunCount, 0)
        XCTAssertEqual(rig.tally.idleBlocks, 0)
        XCTAssertEqual(rig.tally.minWaterLevelFrames, floor + Int64(block))
    }

    // MARK: - Regime transitions

    /// A pause the ring floor covers is NOT idle: there are still written
    /// frames to play, which is exactly what the floor was bought for.
    func testPauseCoveredByTheFloorIsNotIdle() {
        var rig = makeRig()
        rig.burst(blocks: 100)
        // The floor is 1440 frames ≈ 2.8 blocks, so two silent renders are
        // still served from written audio.
        let first = rig.render(producing: 0)
        let second = rig.render(producing: 0)
        XCTAssertFalse(first.producerIdle)
        XCTAssertFalse(second.producerIdle)
        XCTAssertEqual(rig.tally.idleBlocks, 0)
        XCTAssertEqual(rig.tally.resyncCount, 0)
        XCTAssertEqual(rig.tally.underrunCount, 0)
    }

    func testFirstBlockAfterIdleReAnchorsAndIsNotCounted() {
        var rig = makeRig()
        rig.burst(blocks: 100)
        rig.silence(blocks: 300)
        let resume = rig.render(producing: block)
        XCTAssertTrue(resume.didResync, "the floor has to be rebuilt after a silence")
        XCTAssertTrue(resume.resumedFromIdle)
        XCTAssertFalse(resume.producerIdle)
        XCTAssertEqual(rig.tally.resyncCount, 0, "the re-anchor after silence is expected")
        XCTAssertEqual(rig.tally.underrunCount, 0)
    }

    /// The re-anchor puts the cursor a full floor behind the write head again,
    /// so the blocks after a resume are not marginal.
    func testResumeRebuildsTheFloor() {
        var rig = makeRig()
        rig.burst(blocks: 100)
        rig.silence(blocks: 300)
        let resume = rig.render(producing: block)
        XCTAssertEqual(resume.waterLevelFrames, floor + Int64(block))
        rig.burst(blocks: 50)
        XCTAssertEqual(rig.tally.underrunCount, 0)
        XCTAssertEqual(rig.tally.resyncCount, 0)
    }

    /// During a silence the cursor must stay put. If it advanced, a 900-block
    /// silence would leave it ~460 k frames past the write head and the
    /// recovery from that would be a genuine, counted resync.
    func testCursorDoesNotRunAwayDuringSilence() {
        var rig = makeRig()
        rig.burst(blocks: 100)
        let before = rig.cursor
        rig.silence(blocks: 5_000)
        // The first blocks of the silence still play what the floor was
        // holding, so the cursor moves a little; after that it must stop dead.
        // Had it kept advancing it would sit 5000 × 512 = 2.56 M frames past
        // the write head, and climbing out of that IS a counted resync.
        XCTAssertLessThanOrEqual(rig.cursor - before, Int64(2 * block))
        XCTAssertGreaterThanOrEqual(rig.cursor, before)
    }

    /// A producer that has never written anything is idle, not broken. This is
    /// the state the measured run spent most of its 35 s in: write position 0,
    /// which must not be mistaken for a stalled producer on the FIRST render
    /// (there is no previous observation to compare against yet).
    func testProducerThatNeverWroteIsIdleFromTheSecondRender() {
        var rig = makeRig(primedFrames: 0)
        let first = rig.render(producing: 0)
        XCTAssertFalse(first.producerIdle, "nothing to compare the write cursor against yet")
        let second = rig.render(producing: 0)
        XCTAssertTrue(second.producerIdle)
        XCTAssertEqual(rig.tally.resyncCount, 0)
        XCTAssertEqual(rig.tally.underrunCount, 0)
        XCTAssertEqual(rig.tally.idleBlocks, 1)
    }

    func testResetClearsTheCrossRenderState() {
        var sequencer = RingReadSequencer()
        _ = sequencer.plan(
            writePosition: 96_000, cursor: 90_000, frames: block,
            floorFrames: floor, compensationFrames: 0,
            capacityFrames: capacity, driftLimitFrames: driftLimit
        )
        sequencer.reset()
        XCTAssertEqual(sequencer, RingReadSequencer())
        XCTAssertFalse(sequencer.producerIsIdle)
    }

    // MARK: - Tally bookkeeping

    func testIdlePlansAreNotWaterLevelSamples() {
        var tally = GlitchTally()
        tally.record(RingReadPlan(
            startFrame: 0, didResync: false, underrunFrames: 0,
            waterLevelFrames: 1_952
        ))
        tally.record(RingReadPlan(
            startFrame: 0, didResync: false, underrunFrames: 0,
            waterLevelFrames: -400_000, producerIdle: true
        ))
        XCTAssertEqual(tally.minWaterLevelFrames, 1_952)
        XCTAssertEqual(tally.idleBlocks, 1)
        XCTAssertEqual(tally.recordedRenders, 2, "idle blocks are folded in, just not as glitches")
    }

    func testResetClearsIdleBlocks() {
        var tally = GlitchTally()
        tally.record(RingReadPlan(
            startFrame: 0, didResync: false, underrunFrames: 0,
            waterLevelFrames: 0, producerIdle: true
        ))
        XCTAssertEqual(tally.idleBlocks, 1)
        tally.reset()
        XCTAssertEqual(tally, GlitchTally())
        XCTAssertEqual(tally.idleBlocks, 0)
    }
}
