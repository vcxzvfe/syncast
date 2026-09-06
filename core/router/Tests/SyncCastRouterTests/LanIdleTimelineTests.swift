import XCTest
@testable import SyncCastRouter

/// The regression tests for the fault a two-machine run exposed: the sender
/// putting packets on the wire that came from a second timeline.
///
/// The old producer synthesised a silence packet whenever a tick found no new
/// ring frames, stamping it from wall clock. Because the capture backend
/// writes a 512-frame block every 10.67 ms while the producer wakes every
/// 5 ms, that happened on roughly every second tick: 35 % of everything sent
/// in the field run was such a packet, overlapping in time with the real
/// audio around it. The receiver scheduled both, its buffer grew about 8 %
/// per second, and the music garbled at every latency setting.
///
/// So these tests drive the sender with a producer shaped like a real one —
/// whole blocks, released with jitter — and assert on the SHAPE of the
/// timeline rather than on any tuning number.
final class LanIdleTimelineTests: XCTestCase {

    private var receiver: FakeLanReceiver!
    private var producer: SyntheticRingProducer!
    private var output: LanReceiverOutput!

    /// Ring floor the sender is built with here, matching the other LAN
    /// tests. With `LanReceiverOutput.extraLagFrames` on top it is the
    /// distance the cursor holds behind the write head.
    private static let ringFloorFrames = 1_440
    private static var lagFrames: Int {
        ringFloorFrames + LanReceiverOutput.extraLagFrames
    }
    /// The lead a correctly behaving sender puts on the wire, in
    /// milliseconds: `play_at_ns` minus the moment the packet was sent.
    ///
    /// Derived rather than tuned. The sender cannot send ring frame `F` until
    /// the ring holds `F + lag + one packet`, and the ring only moves in whole
    /// capture blocks, so the packet leaves about one lag, one packet and one
    /// block after `F` was captured — and it is stamped for one target after
    /// that same moment.
    private static var expectedLeadMs: Double {
        // `play_at_ns` now carries the producer's read lag on top of the
        // target, so the lag no longer eats into the lead; what remains is
        // the packet the tick has not yet sent and the block the ring has
        // not yet written.
        Double(LanPcmWire.defaultTargetMs)
            - Double(LanPcmWire.framesPerPacket + SyntheticRingProducer.blockFrames)
            / 48.0
    }

    override func tearDown() {
        output?.stop()
        producer?.stop()
        receiver?.stop()
        output = nil
        producer = nil
        receiver = nil
        super.tearDown()
    }

    private func makeBurstyLink(targetMs: Int = LanPcmWire.defaultTargetMs) throws {
        receiver = FakeLanReceiver()
        try receiver.start()
        producer = SyntheticRingProducer(mode: .bursty)
        producer.start()
        let link = LanReceiverLink(
            receiverUID: "lan:test-receiver",
            endpoint: .hostPort(host: "127.0.0.1", port: receiver.controlPort),
            token: "cafef00d",
            senderName: "SyncCast",
            streamID: 0x0BAD_F00D,
            targetMs: targetMs
        )
        output = LanReceiverOutput(
            receiverUID: "lan:test-receiver",
            displayName: "Test receiver",
            ring: producer.ring,
            sampleRate: 48_000,
            channelCount: 2,
            ringFloorFrames: Self.ringFloorFrames,
            link: link,
            captureAnchors: producer.anchors
        )
        output.start()
        XCTAssertTrue(
            receiver.wait(upTo: 5) { $0.packets.count > 20 },
            "audio never started: \(link.snapshot)"
        )
    }

    /// `play_at_ns` minus arrival, in milliseconds — the sender-side proxy for
    /// the receiver's buffer level.
    private func leadMs(
        _ packet: (header: LanAudioPacketHeader, payload: Data, arrivalNs: UInt64)
    ) -> Double {
        (Double(packet.header.playAtNs) - Double(packet.arrivalNs)) / 1_000_000
    }

    // MARK: - Continuous playback

    /// Ten seconds of block-shaped capture must produce exactly the packets
    /// the ring's frames account for, and not one more.
    func testContinuousPlaybackSendsOnePacketPerRingPacketAndNoSilence() throws {
        try makeBurstyLink()
        // Let the link settle before measuring: the cold-start cursor anchor
        // and the first clock fit are not what this test is about.
        Thread.sleep(forTimeInterval: 1.0)

        // Take both ends of the window as close together as the sampling
        // allows; the packet count is read first so it can only ever LAG the
        // write position, never lead it.
        let startPackets = receiver.snapshot.packets.count
        let startFrame = producer.ring.writePosition
        Thread.sleep(forTimeInterval: 10.0)
        let endPackets = receiver.snapshot.packets.count
        let endFrame = producer.ring.writePosition

        let counters = output.counters
        let framesInWindow = endFrame - startFrame
        let expectedPackets = Int(framesInWindow / Int64(LanPcmWire.framesPerPacket))
        let sentInWindow = endPackets - startPackets

        // The cursor advances by whole packets and holds a constant lag, so
        // the only slack is the partial packet left over at each end of the
        // window plus the sampling race above.
        XCTAssertLessThanOrEqual(
            abs(sentInWindow - expectedPackets), 3,
            "sent \(sentInWindow) packets for \(framesInWindow) ring frames "
            + "(\(expectedPackets) expected); the sender is inventing or "
            + "dropping audio"
        )
        XCTAssertEqual(
            counters.silencePackets, 0,
            "the link sent \(counters.silencePackets) digitally silent packets "
            + "while the ring was carrying a tone"
        )
        XCTAssertEqual(
            counters.gapSkips, 0,
            "nothing stalled, so nothing should have been skipped"
        )

        // The timeline: strictly monotonic, exactly one packet apart.
        let window = Array(receiver.snapshot.packets[startPackets..<endPackets])
        var strayed = 0
        for index in 1..<window.count {
            XCTAssertGreaterThan(
                window[index].header.playAtNs, window[index - 1].header.playAtNs,
                "play_at_ns went backwards at packet \(index)"
            )
            let spacing = Int64(window[index].header.playAtNs)
                - Int64(window[index - 1].header.playAtNs)
            if abs(spacing - Int64(LanPcmWire.packetDurationNs)) > 1_000 { strayed += 1 }
        }
        XCTAssertLessThanOrEqual(
            strayed, counters.reanchorCount + counters.gapSkips,
            "\(strayed) packets were not 5 ms after their predecessor, with only "
            + "\(counters.reanchorCount + counters.gapSkips) re-anchors to explain it"
        )
        // Sequence numbers stay contiguous: nothing was emitted outside the
        // ring-driven path.
        for index in 1..<window.count {
            XCTAssertEqual(
                window[index].header.sequence,
                window[index - 1].header.sequence &+ 1,
                "sequence jumped at packet \(index)"
            )
        }

        // The lead — how far ahead of arrival each packet is scheduled — is
        // the sender-side view of the receiver's buffer level. It sits at the
        // target minus the ring lag the producer deliberately holds, and the
        // thing that matters is that it does not GROW: the old fault put 8 %
        // more audio on the wire than the ring produced, which showed up here
        // as a lead climbing by tens of milliseconds a second.
        let leads = window.map(leadMs)
        let expectedLead = Self.expectedLeadMs
        let mean = leads.reduce(0, +) / Double(leads.count)
        XCTAssertLessThan(
            abs(mean - expectedLead), 10,
            String(format: "mean lead %.1f ms, expected %.1f ms", mean, expectedLead)
        )
        let head = leads.prefix(200)
        let tail = leads.suffix(200)
        let headMean = head.reduce(0, +) / Double(head.count)
        let tailMean = tail.reduce(0, +) / Double(tail.count)
        XCTAssertLessThan(
            abs(tailMean - headMean), 5,
            String(format: "the buffer level drifted %.1f ms over ten seconds "
                   + "(%.1f → %.1f)", tailMean - headMean, headMean, tailMean)
        )
    }

    // MARK: - Idle and resume

    /// Two seconds with nothing written must put nothing on the wire, and the
    /// stream must pick up cleanly afterwards.
    func testAProducerStallSendsNothingAndResumesWithoutOverlap() throws {
        try makeBurstyLink()
        Thread.sleep(forTimeInterval: 1.5)

        let beforeStall = receiver.snapshot.packets.count
        producer.pause()
        Thread.sleep(forTimeInterval: 2.0)
        let afterStall = receiver.snapshot.packets.count
        // Whatever whole packets were already in the ring at the moment of
        // the pause may still go out; nothing may be invented after that.
        XCTAssertLessThanOrEqual(
            afterStall - beforeStall, 2,
            "\(afterStall - beforeStall) packets were sent during a two-second "
            + "stall; the sender is synthesising audio again"
        )
        XCTAssertGreaterThan(
            output.counters.idleTicks, 100,
            "the producer stalled for two seconds and the sender never noticed"
        )

        producer.resume()
        Thread.sleep(forTimeInterval: 1.5)
        let counters = output.counters
        let packets = receiver.snapshot.packets

        XCTAssertGreaterThan(
            packets.count - afterStall, 200,
            "the stream did not resume"
        )
        XCTAssertEqual(counters.silencePackets, 0)

        // Nothing overlaps: the whole capture, across the gap, is strictly
        // increasing in play time.
        var gaps: [Double] = []
        for index in 1..<packets.count {
            XCTAssertGreaterThan(
                packets[index].header.playAtNs, packets[index - 1].header.playAtNs,
                "play_at_ns went backwards at packet \(index) — the gap and the "
                + "resumed stream overlap"
            )
            let spacing = Double(packets[index].header.playAtNs)
                - Double(packets[index - 1].header.playAtNs)
            if spacing > 100_000_000 { gaps.append(spacing / 1_000_000) }
        }
        XCTAssertEqual(gaps.count, 1, "expected exactly one hole, saw \(gaps) ms")
        if let gap = gaps.first {
            XCTAssertGreaterThan(gap, 1_500, "the hole is shorter than the stall")
            XCTAssertLessThan(gap, 2_600, "the hole is longer than the stall")
        }

        // A ring that simply freezes leaves no stale frames behind, so the
        // correct number of cursor jumps is at most one — the clock model
        // re-anchoring on the discontinuity, not a burst of skipped audio.
        XCTAssertLessThanOrEqual(
            counters.gapSkips + counters.reanchorCount, 1,
            "the resume cost \(counters.gapSkips) gap skips and "
            + "\(counters.reanchorCount) cursor re-anchors"
        )

        // And the level is back where it belongs within a second of resuming.
        let recovered = packets.suffix(100).map(leadMs)
        let mean = recovered.reduce(0, +) / Double(recovered.count)
        let expectedLead = Self.expectedLeadMs
        XCTAssertLessThan(
            abs(mean - expectedLead), 10,
            String(format: "lead settled at %.1f ms, expected %.1f ms", mean, expectedLead)
        )
    }

    // MARK: - The pure pieces

    func testTheIdleDetectorIgnoresTheGapBetweenCaptureBlocks() {
        var detector = ProducerIdleDetector(thresholdMs: 100)
        var now: UInt64 = 1_000_000_000
        var written: Int64 = 0
        // 5 ms ticks against 10.67 ms blocks: every second tick finds nothing
        // new, and none of them is idleness.
        var nextBlockNs: UInt64 = now
        for _ in 0..<400 {
            if now >= nextBlockNs {
                written += 512
                nextBlockNs = now + 10_667_000
            }
            XCTAssertEqual(
                detector.observe(writePosition: written, nowNs: now), .running
            )
            now += 5_000_000
        }
        XCTAssertFalse(detector.isIdle)
    }

    func testTheIdleDetectorFiresOnlyAfterTheThreshold() {
        var detector = ProducerIdleDetector(thresholdMs: 100)
        var now: UInt64 = 5_000_000_000
        XCTAssertEqual(detector.observe(writePosition: 1_000, nowNs: now), .running)
        // 99 ms of stillness is not idleness.
        now += 99_000_000
        XCTAssertEqual(detector.observe(writePosition: 1_000, nowNs: now), .running)
        now += 2_000_000
        XCTAssertEqual(detector.observe(writePosition: 1_000, nowNs: now), .idle)
        XCTAssertTrue(detector.isIdle)
        // It stays idle until frames actually land, and then reports the edge
        // exactly once.
        now += 500_000_000
        XCTAssertEqual(detector.observe(writePosition: 1_000, nowNs: now), .idle)
        now += 5_000_000
        XCTAssertEqual(detector.observe(writePosition: 1_512, nowNs: now), .resumed)
        now += 5_000_000
        XCTAssertEqual(detector.observe(writePosition: 2_024, nowNs: now), .running)
        XCTAssertFalse(detector.isIdle)
    }

    func testResumeSkipsOnlyABacklogWorthSkipping() {
        let lag: Int64 = 1_680
        // A ring that simply froze: the cursor is already at the write head,
        // so there is nothing to skip and the stream carries straight on.
        XCTAssertNil(
            LanSendPlanner.resumeCursor(
                writePosition: 100_000, cursor: 100_000 - lag - 100, lagFrames: lag
            )
        )
        // One block plus change is still within the slack a tick landing
        // between blocks opens.
        XCTAssertNil(
            LanSendPlanner.resumeCursor(
                writePosition: 100_000, cursor: 100_000 - lag - 512, lagFrames: lag
            )
        )
        // A backend that flushes a backlog on resume moves the write head by
        // far more than that; replaying it would be a burst of stale
        // timestamps, so the cursor jumps to the ceiling instead.
        let cursor: Int64 = 100_000 - lag - 48_000
        let skipped = LanSendPlanner.resumeCursor(
            writePosition: 100_000, cursor: cursor, lagFrames: lag
        )
        XCTAssertEqual(skipped, 100_000 - lag)
        // Nothing to resume from before the first packet.
        XCTAssertNil(
            LanSendPlanner.resumeCursor(writePosition: 100_000, cursor: nil, lagFrames: lag)
        )
    }
}
