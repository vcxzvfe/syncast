import XCTest
@testable import SyncCastRouter

/// End-to-end sender tests against an in-process fake receiver on loopback.
///
/// These are the only tests here that use wall-clock time and real sockets, so
/// they are deliberately few and each one runs a couple of seconds. What they
/// pin is the part no pure test can: that the timer, the planner, the ring
/// clock and the socket together produce a packet stream a receiver can
/// actually play — continuous sequence numbers, monotonic playout times one
/// packet apart at the ring's own rate, and control messages that follow the
/// settings.
final class LanReceiverOutputTests: XCTestCase {

    private var receiver: FakeLanReceiver!
    private var producer: SyntheticRingProducer!
    private var output: LanReceiverOutput!

    override func tearDown() {
        output?.stop()
        producer?.stop()
        receiver?.stop()
        output = nil
        producer = nil
        receiver = nil
        super.tearDown()
    }

    /// Build the whole sender chain against the fake, and wait until audio is
    /// flowing. Returns once the link is up.
    private func makeLink(
        token: String = "cafef00d",
        targetMs: Int = LanPcmWire.defaultTargetMs
    ) throws -> LanReceiverLink {
        receiver = FakeLanReceiver()
        try receiver.start()
        producer = SyntheticRingProducer()
        producer.start()
        let link = LanReceiverLink(
            receiverUID: "lan:test-receiver",
            endpoint: .hostPort(host: "127.0.0.1", port: receiver.controlPort),
            token: token,
            senderName: "SyncCast",
            streamID: 0xABCD_1234,
            targetMs: targetMs
        )
        output = LanReceiverOutput(
            receiverUID: "lan:test-receiver",
            displayName: "Test receiver",
            ring: producer.ring,
            sampleRate: 48_000,
            channelCount: 2,
            ringFloorFrames: 1_440,
            link: link
        )
        output.start()
        return link
    }

    // MARK: - Handshake

    func testTheHandshakeCarriesTheTokenAndStreamID() throws {
        _ = try makeLink()
        XCTAssertTrue(
            receiver.wait(upTo: 5) { $0.helloToken != nil },
            "the sender never sent hello"
        )
        XCTAssertEqual(receiver.snapshot.helloToken, "cafef00d")
        XCTAssertEqual(receiver.snapshot.helloStreamID, 0xABCD_1234)
    }

    func testAWrongTokenIsReportedRatherThanRetriedSilently() throws {
        let link = try makeLink(token: "deadbeef")
        XCTAssertTrue(
            receiver.wait(upTo: 5) { $0.helloToken != nil },
            "the sender never sent hello"
        )
        // The receiver answers `error` and closes; the link must surface that
        // and must never claim the audio path is up.
        let deadline = Date().addingTimeInterval(5)
        var sawError = false
        while Date() < deadline {
            if let message = link.snapshot.lastError, message.contains("refused") {
                sawError = true
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertTrue(sawError, "a rejected token must reach the UI: \(link.snapshot)")
        XCTAssertFalse(link.isAudioReady)
    }

    // MARK: - The packet stream

    func testTwoSecondsOfAudioArrivesAsAContinuousStream() throws {
        let link = try makeLink()
        XCTAssertTrue(
            receiver.wait(upTo: 5) { $0.packets.count > 20 },
            "audio never started: \(link.snapshot)"
        )
        // Two seconds at 5 ms per packet is ~400 packets. The window is
        // generous because a loaded test machine can stretch the producer
        // timer; what is being asserted is the SHAPE of the stream, not the
        // wall-clock rate of the runner.
        let collected = receiver.wait(upTo: 10) { $0.packets.count >= 400 }
        let packets = receiver.snapshot.packets
        // Stamped here, next to the snapshot: the assertion loops below take
        // real time on a loaded machine, and a `now` read after them would be
        // measuring the test runner rather than the link.
        let observedAtNs = Clock.nowNs()
        XCTAssertTrue(collected, "only \(packets.count) packets in 4 s")
        XCTAssertEqual(receiver.snapshot.rejectedPackets, 0, "a packet failed to parse")

        // Every packet is a whole, well-formed one.
        for packet in packets {
            XCTAssertEqual(packet.header.frames, UInt32(LanPcmWire.framesPerPacket))
            XCTAssertEqual(packet.header.streamID, 0xABCD_1234)
            XCTAssertEqual(packet.payload.count, LanPcmWire.payloadBytes)
        }

        // Sequence numbers are contiguous. UDP on loopback does not reorder or
        // drop, so any gap here is the sender's fault, not the network's.
        let sequences = packets.map(\.header.sequence)
        for index in 1..<sequences.count {
            XCTAssertEqual(
                sequences[index], sequences[index - 1] &+ 1,
                "sequence jumped at packet \(index)"
            )
        }

        // Playout times advance monotonically, one packet at a time.
        //
        // The spacing is one packet at the RING's measured rate, not at the
        // nominal one — that is the entire point of `RingWriteClock`, and a
        // test that demanded exactly 5,000,000 ns here would be demanding that
        // the sender ignore the producer's real clock. (The exact-5 ms
        // property IS pinned, on the model itself, in
        // `LanClockAndPlannerTests.testTimeAdvancesByExactlyOnePacketPerPacketAtNominalRate`.)
        //
        // So two claims are made instead, and together they are stronger than
        // the literal one: no gap may exceed one packet by more than the
        // model's own bounded phase step, and the MEDIAN spacing has to sit
        // within 500 ppm of 5 ms — i.e. the timeline really is running at the
        // ring's rate, not drifting away from it.
        //
        // The one thing asserted unconditionally is monotonicity, because a
        // receiver that saw time run backwards would drop everything until it
        // caught up. Corrections are COUNTED rather than forbidden: the model
        // is allowed one bounded phase step per window (one second), and a
        // loaded machine can additionally stall the producer hard enough to
        // make it re-anchor. More than a couple of those in two seconds means
        // the loop is not settling, which is the real fault.
        let times = packets.map(\.header.playAtNs)
        var spacings: [UInt64] = []
        var corrections = 0
        // One bounded phase step, plus room for the rate term and for integer
        // rounding. 75 µs is 1.5 % of a packet.
        let slack = UInt64(RingWriteClock.maximumPhaseStepNs) + 25_000
        for index in 1..<times.count {
            XCTAssertGreaterThan(
                times[index], times[index - 1],
                "play_at_ns went backwards at packet \(index)"
            )
            let spacing = times[index] - times[index - 1]
            spacings.append(spacing)
            if spacing > LanPcmWire.packetDurationNs + slack
                || spacing + slack < LanPcmWire.packetDurationNs {
                corrections += 1
            }
        }
        XCTAssertLessThanOrEqual(
            corrections, packets.count / 200 + 2,
            "the clock model is correcting on nearly every packet, not settling"
        )
        let median = spacings.sorted()[spacings.count / 2]
        let drift = abs(Double(median) - Double(LanPcmWire.packetDurationNs))
            / Double(LanPcmWire.packetDurationNs)
        XCTAssertLessThan(
            drift, 500e-6,
            "median packet spacing is \(median) ns, \(drift * 1e6) ppm off the ring's rate"
        )

        // And they are in the future by roughly the target when they are sent.
        // A generous window: the assertion is "the receiver is given time to
        // schedule this", not a measurement of the loopback stack.
        let targetNs = UInt64(LanPcmWire.defaultTargetMs) * 1_000_000
        let lastPlayAt = times[times.count - 1]
        XCTAssertGreaterThan(
            lastPlayAt, observedAtNs,
            "the newest packet's play time had already passed when it was sent"
        )
        XCTAssertLessThan(lastPlayAt - observedAtNs, targetNs * 3)
    }

    func testTheAudioIsTheRingsAudioAndNotSilence() throws {
        _ = try makeLink()
        XCTAssertTrue(receiver.wait(upTo: 5) { $0.packets.count > 50 })
        // Skip the first few packets: the producer's ring starts empty, so the
        // very first reads can legitimately be zero-filled.
        let packet = receiver.snapshot.packets[40]
        let samples = LanPcmEncoder.decode(payload: packet.payload, channelCount: 2)
        XCTAssertEqual(samples.count, LanPcmWire.framesPerPacket * 2)
        let peak = samples.map(abs).max() ?? 0
        XCTAssertGreaterThan(peak, 0.05, "the packet carried silence")
        XCTAssertLessThanOrEqual(peak, 1.0)
    }

    // MARK: - Control traffic

    func testAMasterChangeSendsAGainMessage() throws {
        let link = try makeLink()
        XCTAssertTrue(receiver.wait(upTo: 5) { $0.packets.count > 5 })
        // The link sends one gain on connect; the change under test is the
        // second one.
        let before = receiver.snapshot.gains.count
        link.setGain(linear: 0.25, muted: false)
        XCTAssertTrue(
            receiver.wait(upTo: 3) { $0.gains.count > before },
            "a master change did not reach the receiver"
        )
        let latest = receiver.snapshot.gains[receiver.snapshot.gains.count - 1]
        XCTAssertEqual(latest.linear, 0.25, accuracy: 1e-9)
        XCTAssertFalse(latest.muted)

        // Re-sending the same value must NOT put another message on the wire:
        // the Router re-pushes settings on every replan, and a per-replan
        // message would be a message per second forever.
        let settled = receiver.snapshot.gains.count
        link.setGain(linear: 0.25, muted: false)
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(receiver.snapshot.gains.count, settled)

        link.setGain(linear: 0.25, muted: true)
        XCTAssertTrue(receiver.wait(upTo: 3) { $0.gains.count > settled })
        XCTAssertTrue(receiver.snapshot.gains[receiver.snapshot.gains.count - 1].muted)
    }

    func testTheTargetIsSentOnConnectAndOnChange() throws {
        let link = try makeLink(targetMs: 120)
        XCTAssertTrue(receiver.wait(upTo: 5) { !$0.targets.isEmpty })
        XCTAssertEqual(receiver.snapshot.targets.first, 120)
        let before = receiver.snapshot.targets.count
        link.setTargetMs(200)
        XCTAssertTrue(receiver.wait(upTo: 3) { $0.targets.count > before })
        XCTAssertEqual(receiver.snapshot.targets.last, 200)
    }

    func testPingsArriveAndPongsProduceAnRTT() throws {
        let link = try makeLink()
        XCTAssertTrue(
            receiver.wait(upTo: 6) { $0.pings >= 2 },
            "the keep-alive never fired"
        )
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, link.snapshot.roundTripMs == nil {
            Thread.sleep(forTimeInterval: 0.02)
        }
        let snapshot = link.snapshot
        let rtt = try XCTUnwrap(snapshot.roundTripMs, "no round trip was measured")
        XCTAssertGreaterThanOrEqual(rtt, 0)
        // Loopback: single-digit milliseconds at worst.
        XCTAssertLessThan(rtt, 100)
        XCTAssertNotNil(snapshot.offsetMs)
    }

    func testTheHelloAckIsReflectedInTheSnapshot() throws {
        let link = try makeLink()
        XCTAssertTrue(receiver.wait(upTo: 5) { $0.packets.count > 5 })
        let snapshot = link.snapshot
        XCTAssertTrue(snapshot.isConnected)
        XCTAssertTrue(snapshot.isAudioReady)
        XCTAssertEqual(snapshot.deviceName, "Test Output")
        XCTAssertEqual(snapshot.hasHardwareVolume, true)
        XCTAssertEqual(snapshot.receiverBufferMs, 90)
        XCTAssertNil(snapshot.lastError)
    }

    // MARK: - The per-device chain

    func testTheChannelMatrixIsAppliedBeforePacketising() throws {
        _ = try makeLink()
        XCTAssertTrue(receiver.wait(upTo: 5) { $0.packets.count > 30 })
        // The synthetic ring's two channels are exact negatives of each other,
        // so 单声道 must sum them to silence. That is a property no amount of
        // gain or filtering elsewhere in the chain could fake.
        output.setChannelMatrix(ChannelMatrixSettings(preset: .mono))
        let before = receiver.snapshot.packets.count
        // Wait past the 20 ms ramp plus a margin.
        XCTAssertTrue(receiver.wait(upTo: 3) { $0.packets.count > before + 40 })
        let packet = receiver.snapshot.packets[before + 30]
        let samples = LanPcmEncoder.decode(payload: packet.payload, channelCount: 2)
        let peak = samples.map(abs).max() ?? 1
        XCTAssertLessThan(peak, 0.01, "mono did not cancel an anti-correlated pair")
    }

    func testTheBalanceAttenuatesTheSentAudio() throws {
        _ = try makeLink()
        XCTAssertTrue(receiver.wait(upTo: 5) { $0.packets.count > 30 })
        let loudPeak = LanPcmEncoder
            .decode(payload: receiver.snapshot.packets[25].payload, channelCount: 2)
            .map(abs).max() ?? 0
        output.setBalance(amplitude: 0.1)
        let before = receiver.snapshot.packets.count
        XCTAssertTrue(receiver.wait(upTo: 3) { $0.packets.count > before + 40 })
        let quietPeak = LanPcmEncoder
            .decode(payload: receiver.snapshot.packets[before + 30].payload, channelCount: 2)
            .map(abs).max() ?? 0
        XCTAssertLessThan(quietPeak, loudPeak * 0.3)
        XCTAssertGreaterThan(quietPeak, 0)
    }

    // MARK: - Shutdown

    func testStoppingSaysGoodbye() throws {
        _ = try makeLink()
        XCTAssertTrue(receiver.wait(upTo: 5) { $0.packets.count > 5 })
        output.stop()
        XCTAssertTrue(
            receiver.wait(upTo: 3) { $0.sawBye },
            "the receiver was left waiting for a keep-alive that never came"
        )
        let settled = receiver.snapshot.packets.count
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(
            receiver.snapshot.packets.count, settled,
            "packets kept arriving after stop()"
        )
    }
}
