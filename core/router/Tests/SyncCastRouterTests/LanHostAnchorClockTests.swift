import XCTest
@testable import SyncCastRouter

/// The packet timeline built from the capture hardware's own timestamps.
///
/// Everything here is pure arithmetic over synthetic anchor sequences, so the
/// property that matters — `timeNs(forFrame:)` is the truth to within tens of
/// microseconds, whatever shape the blocks arrive in — is pinned without two
/// machines and a stopwatch.
final class LanHostAnchorClockTests: XCTestCase {

    private let nominalNsPerFrame = 1_000_000_000.0 / 48_000.0
    private let epoch: UInt64 = 1_000_000_000_000

    /// The truth this test is measuring against: a device running `ppm` off
    /// nominal, whose frame `n` was captured at `epoch + n · nsPerFrame`.
    private func trueTimeNs(frame: Int64, ppm: Double) -> Double {
        Double(epoch) + Double(frame) * nominalNsPerFrame * (1 + ppm * 1e-6)
    }

    private func anchor(frame: Int64, ppm: Double) -> CaptureAnchor {
        CaptureAnchor(frame: frame, hostNs: UInt64(trueTimeNs(frame: frame, ppm: ppm).rounded()))
    }

    /// Worst error over a run, in microseconds, for a given delivery shape.
    ///
    /// - Parameter blockSizes: the block sizes delivered, cycled through. A
    ///   single value is a regular device; a repeating pattern with a large
    ///   entry is a bursty one.
    private func worstErrorMicroseconds(
        ppm: Double,
        blockSizes: [Int],
        seconds: Double,
        settleSeconds: Double = 12
    ) -> Double {
        var clock = HostAnchoredRingClock()
        var frame: Int64 = 0
        var index = 0
        var worst = 0.0
        let totalFrames = Int64(seconds * 48_000)
        let settleFrames = Int64(settleSeconds * 48_000)
        while frame < totalFrames {
            let block = Int64(blockSizes[index % blockSizes.count])
            index += 1
            clock.observe(anchor(frame: frame, ppm: ppm))
            frame += block
            guard frame > settleFrames else { continue }
            // Ask about the frames the LAN producer actually asks about: a
            // ring floor (~35 ms) behind the newest block.
            for lag in stride(from: Int64(0), to: Int64(1_680), by: 240) {
                let asked = frame - lag
                let predicted = Double(clock.timeNs(forFrame: asked))
                worst = max(worst, abs(predicted - trueTimeNs(frame: asked, ppm: ppm)) / 1_000)
            }
        }
        return worst
    }

    // MARK: - Accuracy

    func testARegularDeviceIsTrackedToWithinFiftyMicroseconds() {
        XCTAssertLessThan(worstErrorMicroseconds(ppm: 0, blockSizes: [512], seconds: 60), 50)
    }

    func testAHundredPpmDeviceIsTrackedToWithinFiftyMicroseconds() {
        // The whole point: the device's rate is READ from its stamps, so a
        // 100 ppm crystal is not an error to be servo'd away — it is the
        // answer. Over a minute, 100 ppm unmodelled would be 6 ms.
        XCTAssertLessThan(worstErrorMicroseconds(ppm: 100, blockSizes: [512], seconds: 60), 50)
    }

    func testBurstyDeliveryDoesNotMoveTheTimeline() {
        // Three blocks back to back after a long gap — the tap does this when
        // the system is loaded. Each anchor carries its own host time, so the
        // burst is invisible to the fit.
        XCTAssertLessThan(
            worstErrorMicroseconds(ppm: 100, blockSizes: [128, 128, 128, 4_096], seconds: 60),
            50)
    }

    func testTheFittedRateMatchesTheDevice() {
        var clock = HostAnchoredRingClock()
        var frame: Int64 = 0
        for _ in 0..<4_000 {
            clock.observe(anchor(frame: frame, ppm: -37))
            frame += 512
        }
        XCTAssertEqual(clock.rateDeviationPpm, -37, accuracy: 0.5)
        XCTAssertEqual(clock.reanchorCount, 0)
    }

    // MARK: - Shape of the model

    func testAnUnanchoredClockAnchorsOnItsFirstAnchor() {
        var clock = HostAnchoredRingClock()
        XCTAssertFalse(clock.isAnchored)
        XCTAssertTrue(clock.observe(CaptureAnchor(frame: 1_000, hostNs: 5_000_000_000)))
        XCTAssertTrue(clock.isAnchored)
        XCTAssertEqual(clock.timeNs(forFrame: 1_000), 5_000_000_000)
    }

    func testBeforeTheFitTheNominalRateIsUsed() {
        var clock = HostAnchoredRingClock()
        clock.observe(CaptureAnchor(frame: 0, hostNs: epoch))
        XCTAssertEqual(clock.nsPerFrame, nominalNsPerFrame, accuracy: 1e-12)
        XCTAssertEqual(clock.rateDeviationPpm, 0, accuracy: 1e-9)
        // One packet later is exactly one packet later.
        XCTAssertEqual(clock.timeNs(forFrame: Int64(LanPcmWire.framesPerPacket)) - epoch,
                       LanPcmWire.packetDurationNs)
    }

    func testAnAnchorAtAFrameAlreadySeenIsIgnored() {
        // The producer polls at 200 Hz and blocks arrive at ~90 Hz, so most
        // polls see the same anchor twice.
        var clock = HostAnchoredRingClock()
        clock.observe(CaptureAnchor(frame: 512, hostNs: epoch))
        XCTAssertFalse(clock.observe(CaptureAnchor(frame: 512, hostNs: epoch + 1_000_000)))
        XCTAssertEqual(clock.timeNs(forFrame: 512), epoch)
    }

    func testADiscontinuityReanchorsRatherThanDraggingTheFitThroughIt() {
        var clock = HostAnchoredRingClock()
        var frame: Int64 = 0
        for _ in 0..<200 {
            clock.observe(anchor(frame: frame, ppm: 0))
            frame += 512
        }
        XCTAssertEqual(clock.reanchorCount, 0)
        // The capture device restarted: same frame numbering, host time a
        // second further on than the model expects.
        let jumped = CaptureAnchor(frame: frame, hostNs: UInt64(trueTimeNs(frame: frame, ppm: 0)) + 1_000_000_000)
        clock.observe(jumped)
        XCTAssertEqual(clock.reanchorCount, 1)
        XCTAssertEqual(clock.timeNs(forFrame: frame), jumped.hostNs)
        XCTAssertEqual(clock.nsPerFrame, nominalNsPerFrame, accuracy: 1e-12,
                       "a re-anchor must drop the old fit, not keep its slope")
    }

    func testTheRateIsClampedToASaneBand() {
        XCTAssertEqual(
            HostAnchoredRingClock.clampRate(1e9, nominal: nominalNsPerFrame),
            nominalNsPerFrame * (1 + HostAnchoredRingClock.maximumRateDeviationPpm / 1e6),
            accuracy: 1e-6)
        XCTAssertEqual(
            HostAnchoredRingClock.clampRate(.nan, nominal: nominalNsPerFrame),
            nominalNsPerFrame)
    }

    func testTheHistoryIsBoundedButStillSpansTheWindow() {
        var clock = HostAnchoredRingClock()
        var frame: Int64 = 0
        // Two minutes of blocks: the retained set must stay small and must
        // not grow with the session.
        for _ in 0..<11_000 {
            clock.observe(anchor(frame: frame, ppm: 20))
            frame += 512
        }
        XCTAssertLessThanOrEqual(clock.fittedAnchorCount, 110)
        XCTAssertGreaterThanOrEqual(clock.fittedAnchorCount,
                                    HostAnchoredRingClock.minimumAnchorsForRate)
        XCTAssertEqual(clock.rateDeviationPpm, 20, accuracy: 0.5)
    }

    func testTheFitRejectsDegenerateInput() {
        XCTAssertNil(HostAnchoredRingClock.fit([]))
        XCTAssertNil(HostAnchoredRingClock.fit([CaptureAnchor(frame: 1, hostNs: 1)]))
        // Every anchor at the same frame: no slope exists.
        XCTAssertNil(HostAnchoredRingClock.fit(
            (0..<8).map { CaptureAnchor(frame: 4, hostNs: UInt64(100 + $0)) }))
    }

    // MARK: - The lock-free hand-off

    func testThePublisherHandsBackWhatWasPublished() {
        let publisher = CaptureAnchorPublisher(sampleRate: 48_000)
        XCTAssertNil(publisher.latest, "nothing has been captured yet")
        publisher.publish(frame: 4_096, hostNs: 123_456_789)
        XCTAssertEqual(publisher.latest, CaptureAnchor(frame: 4_096, hostNs: 123_456_789))
        publisher.publish(CaptureAnchor(frame: 8_192, hostNs: 987_654_321))
        XCTAssertEqual(publisher.latest?.frame, 8_192)
    }

    func testThePublisherIsSafeUnderAConcurrentWriter() {
        // A reader must never observe a frame from one block paired with a
        // host time from another. Publish hard from one thread while another
        // reads, and check every pair is internally consistent.
        let publisher = CaptureAnchorPublisher(sampleRate: 48_000)
        let writes = 200_000
        let done = expectation(description: "writer finished")
        DispatchQueue.global(qos: .userInteractive).async {
            for index in 1...writes {
                publisher.publish(frame: Int64(index), hostNs: UInt64(index) &* 1_000)
            }
            done.fulfill()
        }
        var reads = 0
        var torn = 0
        while reads < 50_000 {
            if let anchor = publisher.latest {
                reads += 1
                if anchor.hostNs != UInt64(anchor.frame) &* 1_000 { torn += 1 }
            }
        }
        wait(for: [done], timeout: 30)
        XCTAssertEqual(torn, 0, "the seqlock let a torn pair through")
    }
}
