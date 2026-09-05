import XCTest
@testable import SyncCastRouter

/// The LAN link's arithmetic: the ring→time model, the NTP reduction, the
/// per-tick send plan, and the alignment budget. All pure, so all of it is
/// pinned here rather than by listening to two Macs.
final class LanClockAndPlannerTests: XCTestCase {

    private let nominalNsPerFrame = 1_000_000_000.0 / 48_000.0

    // MARK: - Ring write clock

    func testAnUnanchoredClockAnchorsOnItsFirstObservation() {
        var clock = RingWriteClock()
        XCTAssertFalse(clock.isAnchored)
        XCTAssertTrue(clock.observe(writePosition: 1_000, nowNs: 5_000_000_000))
        XCTAssertTrue(clock.isAnchored)
        XCTAssertEqual(clock.timeNs(forFrame: 1_000), 5_000_000_000)
    }

    func testTimeAdvancesByExactlyOnePacketPerPacketAtNominalRate() {
        var clock = RingWriteClock()
        clock.observe(writePosition: 0, nowNs: 1_000_000_000)
        var previous = clock.timeNs(forFrame: 0)
        for index in 1...500 {
            let frame = Int64(index * LanPcmWire.framesPerPacket)
            let now = clock.timeNs(forFrame: frame)
            XCTAssertEqual(
                now - previous, LanPcmWire.packetDurationNs,
                "packet \(index) is not exactly 5 ms after its predecessor"
            )
            previous = now
        }
    }

    func testAProducerAtExactlyNominalRateNeverMovesTheEstimate() {
        // The deadband's whole job: an honest producer must not make the model
        // dither around the truth, because the packet spacing is derived from
        // it and a dithering rate would show up as jitter on the wire.
        var clock = RingWriteClock()
        let start: UInt64 = 10_000_000_000
        clock.observe(writePosition: 0, nowNs: start)
        for tick in 1...(RingWriteClock.observationsPerWindow * 3) {
            let frame = Int64(tick * LanPcmWire.framesPerPacket)
            let now = start + UInt64(Double(frame) * nominalNsPerFrame)
            clock.observe(writePosition: frame, nowNs: now)
        }
        XCTAssertEqual(clock.nsPerFrame, nominalNsPerFrame, accuracy: 1e-12)
        XCTAssertEqual(clock.rateDeviationPpm, 0, accuracy: 1e-6)
        XCTAssertEqual(clock.reanchorCount, 0)
    }

    func testTheModelTracksAProducerRunningFast() {
        // A producer 100 ppm fast: frames arrive sooner than nominal, so the
        // observed time runs BELOW the prediction and `nsPerFrame` has to come
        // down. One window is a partial correction by design (rateGain is
        // small); several windows must move it in the right direction.
        var clock = RingWriteClock()
        let start: UInt64 = 1_000_000_000
        let actualNsPerFrame = nominalNsPerFrame * (1 - 100e-6)
        clock.observe(writePosition: 0, nowNs: start)
        for tick in 1...(RingWriteClock.observationsPerWindow * 40) {
            let frame = Int64(tick * LanPcmWire.framesPerPacket)
            let now = start + UInt64(Double(frame) * actualNsPerFrame)
            clock.observe(writePosition: frame, nowNs: now)
        }
        XCTAssertLessThan(clock.nsPerFrame, nominalNsPerFrame)
        XCTAssertLessThan(clock.rateDeviationPpm, 0)
        XCTAssertEqual(clock.reanchorCount, 0, "a 100 ppm drift is tracked, not re-anchored")
    }

    func testTheRateEstimateIsClampedToASaneBand() {
        XCTAssertEqual(
            RingWriteClock.clampRate(1e9, nominal: nominalNsPerFrame),
            nominalNsPerFrame * (1 + RingWriteClock.maximumRateDeviationPpm / 1e6),
            accuracy: 1e-6
        )
        XCTAssertEqual(
            RingWriteClock.clampRate(.nan, nominal: nominalNsPerFrame),
            nominalNsPerFrame
        )
    }

    func testAHugeJumpReanchorsRatherThanGliding() {
        var clock = RingWriteClock()
        clock.observe(writePosition: 0, nowNs: 1_000_000_000)
        // The producer stalled for a second: `now` has run far past where the
        // frame count says it should be.
        clock.observe(writePosition: 480, nowNs: 2_000_000_000)
        XCTAssertEqual(clock.reanchorCount, 1)
        XCTAssertEqual(clock.timeNs(forFrame: 480), 2_000_000_000)
    }

    func testTheMinimumFilterIgnoresLateObservations() {
        // Half the observations are delayed by 3 ms (a scheduling hiccup) and
        // half are on time. The estimate must follow the on-time ones.
        var clock = RingWriteClock()
        let start: UInt64 = 1_000_000_000
        clock.observe(writePosition: 0, nowNs: start)
        for tick in 1...(RingWriteClock.observationsPerWindow * 4) {
            let frame = Int64(tick * LanPcmWire.framesPerPacket)
            let honest = start + UInt64(Double(frame) * nominalNsPerFrame)
            let now = tick % 2 == 0 ? honest + 3_000_000 : honest
            clock.observe(writePosition: frame, nowNs: now)
        }
        XCTAssertEqual(clock.nsPerFrame, nominalNsPerFrame, accuracy: 1e-12)
    }

    // MARK: - NTP reduction

    func testOffsetAndRoundTripMatchTheTextbookFormula() {
        // Receiver clock is 1 s ahead; the trip takes 4 ms each way and the
        // receiver spends 2 ms turning the ping around.
        let sample = LanClockSample.fromTimestamps(
            t1: 1_000_000_000,
            t2: 2_004_000_000,
            t3: 2_006_000_000,
            t4: 1_010_000_000
        )
        let value = try? XCTUnwrap(sample)
        XCTAssertEqual(value?.offsetNs ?? 0, 1_000_000_000, accuracy: 1)
        XCTAssertEqual(value?.roundTripNs ?? 0, 8_000_000, accuracy: 1)
    }

    func testASymmetricTripWithNoOffsetReducesToZero() {
        let sample = LanClockSample.fromTimestamps(
            t1: 1_000, t2: 1_500, t3: 1_500, t4: 2_000
        )
        XCTAssertEqual(sample?.offsetNs, 0)
        XCTAssertEqual(sample?.roundTripNs, 1_000)
    }

    func testImpossibleQuadruplesAreRejected() {
        // t4 before t1 on a monotonic clock, and a receiver that claims to
        // have answered before it was asked.
        XCTAssertNil(LanClockSample.fromTimestamps(t1: 100, t2: 200, t3: 300, t4: 50))
        XCTAssertNil(LanClockSample.fromTimestamps(t1: 100, t2: 300, t3: 200, t4: 400))
    }

    func testTheEstimatorPrefersTheLowestRoundTripSample() {
        var estimator = LanClockOffsetEstimator()
        // A queued sample with a wildly wrong offset, then clean ones. The
        // minimum filter picks the clean sample's offset as the target; the
        // EMA then walks the reported figure onto it over a few pings rather
        // than jumping, so the check is convergence, not one step.
        estimator.add(LanClockSample(offsetNs: 50_000_000, roundTripNs: 40_000_000))
        for _ in 0..<40 {
            estimator.add(LanClockSample(offsetNs: 1_000_000, roundTripNs: 500_000))
        }
        XCTAssertEqual(estimator.smoothedOffsetNs, 1_000_000, accuracy: 1_000)
        XCTAssertEqual(estimator.bestRoundTripNs, 500_000)
        XCTAssertEqual(estimator.latestRoundTripNs, 500_000)
    }

    func testTheEstimatorSmoothsAfterItsFirstAnswer() {
        var estimator = LanClockOffsetEstimator()
        estimator.add(LanClockSample(offsetNs: 0, roundTripNs: 1_000))
        // A better sample arrives with a different offset: the report moves
        // part of the way, not all of it.
        estimator.add(LanClockSample(offsetNs: 1_000_000, roundTripNs: 500))
        XCTAssertEqual(
            estimator.smoothedOffsetNs,
            LanClockOffsetEstimator.smoothing * 1_000_000,
            accuracy: 1
        )
    }

    func testTheWindowSlides() {
        var estimator = LanClockOffsetEstimator()
        // Fill the window with a low-RTT sample, then push it out.
        estimator.add(LanClockSample(offsetNs: 7, roundTripNs: 1))
        for _ in 0..<LanClockOffsetEstimator.windowSize {
            estimator.add(LanClockSample(offsetNs: 100, roundTripNs: 1_000))
        }
        XCTAssertEqual(estimator.bestRoundTripNs, 1_000, "the old best must have aged out")
    }

    // MARK: - Send planner

    private func plan(
        writePosition: Int64,
        cursor: Int64?,
        lagFrames: Int64 = 1_440
    ) -> LanSendPlan {
        LanSendPlanner.plan(
            writePosition: writePosition,
            cursor: cursor,
            lagFrames: lagFrames,
            capacityFrames: 1 << 18,
            driftLimitFrames: 12_000
        )
    }

    func testTheFirstTickAnchorsOnePacketBelowTheCeiling() {
        let result = plan(writePosition: 100_000, cursor: nil)
        XCTAssertTrue(result.didReanchor)
        XCTAssertEqual(result.packets, 1)
        XCTAssertEqual(result.startFrame, 100_000 - 1_440 - 240)
        XCTAssertEqual(result.nextCursor, 100_000 - 1_440)
    }

    func testATickWithNothingNewSendsNothingAndHoldsTheCursor() {
        let cursor: Int64 = 100_000 - 1_440
        let result = plan(writePosition: 100_000, cursor: cursor)
        XCTAssertEqual(result.packets, 0)
        XCTAssertEqual(result.nextCursor, cursor)
        XCTAssertFalse(result.didReanchor)
    }

    func testALateTickSendsTwoPackets() {
        let cursor: Int64 = 100_000 - 1_440
        let result = plan(writePosition: 100_480, cursor: cursor)
        XCTAssertEqual(result.packets, 2)
        XCTAssertEqual(result.startFrame, cursor)
        XCTAssertEqual(result.nextCursor, cursor + 480)
    }

    func testTheBurstIsCapped() {
        let cursor: Int64 = 10_000
        // 5000 frames of backlog is ~20 packets' worth; only the cap goes out.
        let result = plan(writePosition: 10_000 + 1_440 + 5_000, cursor: cursor)
        XCTAssertEqual(result.packets, LanSendPlanner.maximumPacketsPerTick)
    }

    func testAStalledTimerReanchorsRatherThanPlayingStaleAudio() {
        let cursor: Int64 = 10_000
        // Two seconds of write happened while we were asleep, far past the
        // 250 ms drift limit.
        let writePosition: Int64 = 10_000 + 96_000
        let result = plan(writePosition: writePosition, cursor: cursor)
        XCTAssertTrue(result.didReanchor)
        XCTAssertEqual(result.startFrame, writePosition - 1_440 - 240)
    }

    func testACursorTheRingHasOverwrittenIsDiscarded() {
        let result = LanSendPlanner.plan(
            writePosition: 500_000,
            cursor: 1_000,
            lagFrames: 1_440,
            capacityFrames: 4_096,
            driftLimitFrames: .max
        )
        XCTAssertTrue(result.didReanchor)
    }

    func testAColdRingSendsNothing() {
        let result = plan(writePosition: 100, cursor: nil)
        XCTAssertEqual(result.packets, 0)
    }

    func testTheCursorNeverMovesBackwards() {
        // Which is what makes `play_at_ns` monotonic by construction.
        var cursor: Int64? = nil
        var writePosition: Int64 = 100_000
        for _ in 0..<200 {
            let result = plan(writePosition: writePosition, cursor: cursor)
            if let previous = cursor {
                XCTAssertGreaterThanOrEqual(result.nextCursor, previous)
            }
            cursor = result.nextCursor
            // Producer advances a little less than one packet per tick, so the
            // planner alternates between one packet and none.
            writePosition += 230
        }
    }

    // MARK: - Alignment

    func testTheLocalLegsAreHeldBackByTheDifferenceOnly() {
        // 30 ms sink floor (1440 frames) + 512-frame block + 20 ms of device
        // latency (960 frames) = 2912 frames ≈ 60.7 ms of local budget.
        let hold = LanAlignmentPlanner.localHoldFrames(
            targetMs: 90,
            ringFloorFrames: 1_440,
            maximumDeviceLatencyFrames: 960,
            sampleRate: 48_000
        )
        XCTAssertEqual(hold, 4_320 - 2_912)
    }

    func testATargetBelowTheLocalBudgetAsksForNoHold() {
        // Nothing can be played early, so the answer is zero rather than a
        // negative that would reverse the trim stack's sign.
        let hold = LanAlignmentPlanner.localHoldFrames(
            targetMs: 30,
            ringFloorFrames: 4_800,
            maximumDeviceLatencyFrames: 960,
            sampleRate: 48_000
        )
        XCTAssertEqual(hold, 0)
    }

    func testTheReportedLagIsWhicheverLegIsSlowest() {
        XCTAssertEqual(
            LanAlignmentPlanner.totalLagMs(
                targetMs: 90, ringFloorFrames: 1_440,
                maximumDeviceLatencyFrames: 960, sampleRate: 48_000
            ),
            90, accuracy: 1e-9
        )
        // A 100 ms ScreenCaptureKit floor already exceeds a 30 ms target.
        XCTAssertEqual(
            LanAlignmentPlanner.totalLagMs(
                targetMs: 30, ringFloorFrames: 4_800,
                maximumDeviceLatencyFrames: 960, sampleRate: 48_000
            ),
            LocalDelayTrim.milliseconds(frames: 4_800 + 512 + 960, sampleRate: 48_000),
            accuracy: 1e-9
        )
    }

    func testTheAlignmentHoldSurvivesTheTrimPlannersCeiling() {
        // The worst case the UI can produce: the top of the target slider with
        // the smallest local budget, plus the full user range on one pair.
        let hold = LanAlignmentPlanner.localHoldFrames(
            targetMs: LanPcmWire.targetRangeMs.upperBound,
            ringFloorFrames: 1_440,
            maximumDeviceLatencyFrames: 0,
            sampleRate: 48_000
        )
        let offsets = LocalDelayTrimPlanner.offsetFrames(
            pairCount: 2,
            seedFrames: [:],
            userMs: [0: -100, 1: 100],
            sampleRate: 48_000,
            headroomFrames: 1 << 17,
            extraHoldFrames: hold
        )
        let ceiling = LocalDelayTrim.frames(
            ms: LocalDelayTrim.maxOffsetMs, sampleRate: 48_000
        )
        XCTAssertEqual(offsets[0], hold, "the earliest pair carries the hold and nothing else")
        XCTAssertEqual(offsets[1], hold + 9_600)
        XCTAssertLessThan(
            offsets[1], ceiling,
            "the worst case must not reach the clamp, or alignment is silently lost"
        )
    }

    func testNoLanLegLeavesTheTrimArithmeticUnchanged() {
        let withHold = LocalDelayTrimPlanner.offsetFrames(
            pairCount: 2, seedFrames: [0: -100], userMs: [1: 20],
            sampleRate: 48_000, headroomFrames: 100_000, extraHoldFrames: 0
        )
        let original = LocalDelayTrimPlanner.offsetFrames(
            pairCount: 2, seedFrames: [0: -100], userMs: [1: 20],
            sampleRate: 48_000, headroomFrames: 100_000
        )
        XCTAssertEqual(withHold, original)
        XCTAssertTrue(original.contains(0))
    }

    // MARK: - Peer validation

    func testOnlyPrivateAddressesAreAccepted() {
        XCTAssertTrue(LanReceiverLink.isPrivateIPv4([10, 0, 0, 5]))
        XCTAssertTrue(LanReceiverLink.isPrivateIPv4([192, 168, 8, 42]))
        XCTAssertTrue(LanReceiverLink.isPrivateIPv4([172, 16, 0, 1]))
        XCTAssertTrue(LanReceiverLink.isPrivateIPv4([172, 31, 255, 254]))
        XCTAssertTrue(LanReceiverLink.isPrivateIPv4([169, 254, 3, 4]))
        XCTAssertTrue(LanReceiverLink.isPrivateIPv4([127, 0, 0, 1]))

        XCTAssertFalse(LanReceiverLink.isPrivateIPv4([203, 0, 113, 5]))
        XCTAssertFalse(LanReceiverLink.isPrivateIPv4([172, 32, 0, 1]))
        XCTAssertFalse(LanReceiverLink.isPrivateIPv4([192, 0, 2, 1]))
        XCTAssertFalse(LanReceiverLink.isPrivateIPv4([8, 8, 8, 8]))
        XCTAssertFalse(LanReceiverLink.isPrivateIPv4([10, 0, 0]))
    }

    func testIPv6PrivateRanges() {
        var loopback = [UInt8](repeating: 0, count: 16)
        loopback[15] = 1
        XCTAssertTrue(LanReceiverLink.isPrivateIPv6(loopback))

        var uniqueLocal = [UInt8](repeating: 0, count: 16)
        uniqueLocal[0] = 0xFD
        XCTAssertTrue(LanReceiverLink.isPrivateIPv6(uniqueLocal))

        var linkLocal = [UInt8](repeating: 0, count: 16)
        linkLocal[0] = 0xFE
        linkLocal[1] = 0x80
        XCTAssertTrue(LanReceiverLink.isPrivateIPv6(linkLocal))

        var mapped = [UInt8](repeating: 0, count: 16)
        mapped[10] = 0xFF; mapped[11] = 0xFF
        mapped[12] = 192; mapped[13] = 168; mapped[14] = 1; mapped[15] = 9
        XCTAssertTrue(LanReceiverLink.isPrivateIPv6(mapped))
        mapped[12] = 8; mapped[13] = 8; mapped[14] = 8; mapped[15] = 8
        XCTAssertFalse(LanReceiverLink.isPrivateIPv6(mapped))

        var global = [UInt8](repeating: 0, count: 16)
        global[0] = 0x20; global[1] = 0x01
        XCTAssertFalse(LanReceiverLink.isPrivateIPv6(global))
    }
}
