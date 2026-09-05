import XCTest
@testable import SyncCastRouter

/// The wire format's specification: hand-assembled bytes on one side, the
/// encoder on the other. If these two ever disagree, the receiver daemon in
/// the other repository is the thing that breaks, so the expected bytes are
/// written out longhand rather than derived from the code under test.
final class LanPcmProtocolTests: XCTestCase {

    // MARK: - Packet header

    func testHeaderMatchesHandAssembledBytes() {
        let header = LanAudioPacketHeader(
            streamID: 0x1122_3344,
            sequence: 0x0000_0007,
            playAtNs: 0x0102_0304_0506_0708,
            frames: 240
        )
        var buffer = [UInt8](repeating: 0xAA, count: LanPcmWire.headerBytes)
        buffer.withUnsafeMutableBytes { XCTAssertTrue(header.encode(into: $0)) }

        // magic 0x53435043 little-endian, then stream_id, seq, play_at_ns,
        // frames — every field little-endian, per proto/lan-pcm-link.md.
        let expected: [UInt8] = [
            0x43, 0x50, 0x43, 0x53,
            0x44, 0x33, 0x22, 0x11,
            0x07, 0x00, 0x00, 0x00,
            0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01,
            0xF0, 0x00, 0x00, 0x00,
        ]
        XCTAssertEqual(buffer, expected)
    }

    func testTheFirstFourBytesSpellSCPC() {
        // The magic is written little-endian, so the ASCII reads backwards on
        // the wire. Pinned because it is the first thing anyone will check
        // with a packet capture.
        var buffer = [UInt8](repeating: 0, count: LanPcmWire.headerBytes)
        let header = LanAudioPacketHeader(
            streamID: 1, sequence: 0, playAtNs: 0, frames: 240
        )
        buffer.withUnsafeMutableBytes { _ = header.encode(into: $0) }
        XCTAssertEqual(String(decoding: buffer[0..<4].reversed(), as: UTF8.self), "SCPC")
    }

    func testHeaderRoundTrips() {
        let header = LanAudioPacketHeader(
            streamID: .max, sequence: 4_294_967_295, playAtNs: .max / 3, frames: 240
        )
        var buffer = [UInt8](repeating: 0, count: LanPcmWire.headerBytes)
        buffer.withUnsafeMutableBytes { _ = header.encode(into: $0) }
        let decoded = buffer.withUnsafeBytes { LanAudioPacketHeader.decode($0) }
        XCTAssertEqual(decoded, header)
    }

    func testHeaderRejectsBadMagicAndFrameCount() {
        var buffer = [UInt8](repeating: 0, count: LanPcmWire.headerBytes)
        let header = LanAudioPacketHeader(
            streamID: 1, sequence: 1, playAtNs: 1, frames: 240
        )
        buffer.withUnsafeMutableBytes { _ = header.encode(into: $0) }

        var wrongMagic = buffer
        wrongMagic[0] ^= 0xFF
        XCTAssertNil(wrongMagic.withUnsafeBytes { LanAudioPacketHeader.decode($0) })

        var wrongFrames = buffer
        wrongFrames[20] = 0x80
        XCTAssertNil(wrongFrames.withUnsafeBytes { LanAudioPacketHeader.decode($0) })

        let short = Array(buffer.dropLast())
        XCTAssertNil(short.withUnsafeBytes { LanAudioPacketHeader.decode($0) })
    }

    func testEncodeRefusesAShortBuffer() {
        let header = LanAudioPacketHeader(
            streamID: 1, sequence: 1, playAtNs: 1, frames: 240
        )
        var buffer = [UInt8](repeating: 0x5A, count: LanPcmWire.headerBytes - 1)
        let written = buffer.withUnsafeMutableBytes { header.encode(into: $0) }
        XCTAssertFalse(written)
        XCTAssertTrue(buffer.allSatisfy { $0 == 0x5A })
    }

    func testPacketGeometryMatchesTheSpec() {
        XCTAssertEqual(LanPcmWire.headerBytes, 24)
        XCTAssertEqual(LanPcmWire.payloadBytes, 960)
        XCTAssertEqual(LanPcmWire.packetBytes, 984)
        XCTAssertEqual(LanPcmWire.framesPerPacket, 240)
        // 240 frames at 48 kHz is exactly 5 ms — the whole timing model rests
        // on that being exact rather than approximate.
        XCTAssertEqual(
            Double(LanPcmWire.framesPerPacket) / LanPcmWire.sampleRate * 1_000_000_000,
            Double(LanPcmWire.packetDurationNs)
        )
    }

    // MARK: - PCM payload

    func testPcmEncodeInterleavesAndRoundTrips() {
        let frames = 4
        var left: [Float] = [0, 0.5, -0.5, 1]
        var right: [Float] = [1, -1, 0.25, 0]
        var buffer = [UInt8](repeating: 0, count: frames * 2 * 2)
        var clipped = 0
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                let table = UnsafeMutablePointer<UnsafeMutablePointer<Float>>
                    .allocate(capacity: 2)
                defer { table.deallocate() }
                table[0] = l.baseAddress!
                table[1] = r.baseAddress!
                buffer.withUnsafeMutableBytes { raw in
                    clipped = LanPcmEncoder.encode(
                        channels: table, channelCount: 2, frames: frames,
                        into: raw, offset: 0
                    )
                }
            }
        }
        XCTAssertEqual(clipped, 0)
        let decoded = LanPcmEncoder.decode(payload: Data(buffer), channelCount: 2)
        XCTAssertEqual(decoded.count, frames * 2)
        // Interleaved: L0 R0 L1 R1 …
        XCTAssertEqual(decoded[0], 0, accuracy: 1e-4)
        XCTAssertEqual(decoded[1], 1, accuracy: 1e-4)
        XCTAssertEqual(decoded[2], 0.5, accuracy: 1e-4)
        XCTAssertEqual(decoded[3], -1, accuracy: 1e-4)
        XCTAssertEqual(decoded[4], -0.5, accuracy: 1e-4)
        XCTAssertEqual(decoded[6], 1, accuracy: 1e-4)
    }

    func testPcmEncodeClampsRatherThanWrapping() {
        var left: [Float] = [2, -2, .nan]
        var right: [Float] = [-3, 3, .infinity]
        var buffer = [UInt8](repeating: 0, count: 3 * 2 * 2)
        var clipped = 0
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                let table = UnsafeMutablePointer<UnsafeMutablePointer<Float>>
                    .allocate(capacity: 2)
                defer { table.deallocate() }
                table[0] = l.baseAddress!
                table[1] = r.baseAddress!
                buffer.withUnsafeMutableBytes { raw in
                    clipped = LanPcmEncoder.encode(
                        channels: table, channelCount: 2, frames: 3,
                        into: raw, offset: 0
                    )
                }
            }
        }
        XCTAssertEqual(clipped, 6)
        let decoded = LanPcmEncoder.decode(payload: Data(buffer), channelCount: 2)
        XCTAssertEqual(decoded[0], 1, accuracy: 1e-4)
        XCTAssertEqual(decoded[1], -1, accuracy: 1e-4)
        XCTAssertEqual(decoded[4], 0)   // NaN → silence, counted
    }

    // MARK: - Control messages

    func testHelloEncodesTheAgreedShape() throws {
        let data = try LanControlCodec.encode(
            .hello(token: "cafef00d", senderName: "SyncCast", streamID: 42)
        )
        XCTAssertEqual(data.last, 0x0A, "control lines are newline-delimited")
        let object = try JSONSerialization.jsonObject(with: data.dropLast()) as? [String: Any]
        let json = try XCTUnwrap(object)
        XCTAssertEqual(json["type"] as? String, "hello")
        XCTAssertEqual(json["v"] as? Int, 1)
        XCTAssertEqual(json["token"] as? String, "cafef00d")
        XCTAssertEqual(json["name"] as? String, "SyncCast")
        XCTAssertEqual(json["rate"] as? Int, 48_000)
        XCTAssertEqual(json["channels"] as? Int, 2)
        XCTAssertEqual(json["frames_per_packet"] as? Int, 240)
        XCTAssertEqual(json["stream_id"] as? Int, 42)
    }

    func testGainLatencyPingAndByeEncode() throws {
        let gain = try JSONSerialization.jsonObject(
            with: LanControlCodec.encode(.gain(linear: 0.5, muted: true))
        ) as? [String: Any]
        XCTAssertEqual(gain?["type"] as? String, "gain")
        XCTAssertEqual(gain?["linear"] as? Double, 0.5)
        XCTAssertEqual(gain?["muted"] as? Bool, true)

        let latency = try JSONSerialization.jsonObject(
            with: LanControlCodec.encode(.latency(targetMs: 120))
        ) as? [String: Any]
        XCTAssertEqual(latency?["type"] as? String, "latency")
        XCTAssertEqual(latency?["target_ms"] as? Int, 120)

        let ping = try JSONSerialization.jsonObject(
            with: LanControlCodec.encode(.ping(t1: 1_234_567_890_123))
        ) as? [String: Any]
        XCTAssertEqual(ping?["type"] as? String, "ping")
        XCTAssertEqual(ping?["t1"] as? UInt64, 1_234_567_890_123)

        let bye = try JSONSerialization.jsonObject(
            with: LanControlCodec.encode(.bye)
        ) as? [String: Any]
        XCTAssertEqual(bye?["type"] as? String, "bye")
        XCTAssertEqual(bye?.count, 1)
    }

    func testHelloAckDecodes() throws {
        let line = Data(#"""
        {"type":"hello_ack","v":1,"udp_port":45678,"device":"Built-in Output","device_uid":"BuiltInSpeakerDevice","hw_volume":true,"buffer_ms":90}
        """#.utf8)
        guard case .helloAck(let ack) = try LanControlCodec.decode(line: line) else {
            return XCTFail("expected hello_ack")
        }
        XCTAssertEqual(ack.version, 1)
        XCTAssertEqual(ack.udpPort, 45_678)
        XCTAssertEqual(ack.deviceName, "Built-in Output")
        XCTAssertEqual(ack.deviceUID, "BuiltInSpeakerDevice")
        XCTAssertTrue(ack.hasHardwareVolume)
        XCTAssertEqual(ack.bufferMs, 90)
    }

    func testStatsAndErrorDecode() throws {
        let stats = try LanControlCodec.decode(
            line: Data(#"{"type":"stats","late":2,"lost":1,"underrun":0,"buffer_ms":88.5,"ratio":1.000012,"clip":7}"#.utf8)
        )
        guard case .stats(let value) = stats else { return XCTFail("expected stats") }
        XCTAssertEqual(value.late, 2)
        XCTAssertEqual(value.lost, 1)
        XCTAssertEqual(value.underrun, 0)
        XCTAssertEqual(value.bufferMs, 88.5, accuracy: 1e-9)
        XCTAssertEqual(value.ratio, 1.000012, accuracy: 1e-9)
        XCTAssertEqual(value.clip, 7)

        let error = try LanControlCodec.decode(
            line: Data(#"{"type":"error","message":"bad token"}"#.utf8)
        )
        XCTAssertEqual(error, .error(message: "bad token"))
    }

    func testMalformedControlLinesAreRejectedNotGuessedAt() {
        XCTAssertThrowsError(try LanControlCodec.decode(line: Data("not json".utf8)))
        XCTAssertThrowsError(try LanControlCodec.decode(line: Data("{}".utf8)))
        XCTAssertThrowsError(
            try LanControlCodec.decode(line: Data(#"{"type":"launch_missiles"}"#.utf8))
        )
        // hello_ack without a port has nowhere to send audio.
        XCTAssertThrowsError(
            try LanControlCodec.decode(line: Data(#"{"type":"hello_ack","v":1}"#.utf8))
        )
    }

    func testStatsToleratesMissingFields() throws {
        let stats = try LanControlCodec.decode(line: Data(#"{"type":"stats"}"#.utf8))
        XCTAssertEqual(stats, .stats(.zero))
    }

    func testLineSplittingHandlesPartialAndMultipleMessages() {
        let buffer = Data("alpha\nbeta\npar".utf8)
        let split = LanControlCodec.split(buffer: buffer)
        XCTAssertEqual(split.lines.map { String(decoding: $0, as: UTF8.self) }, ["alpha", "beta"])
        XCTAssertEqual(String(decoding: split.remainder, as: UTF8.self), "par")

        let none = LanControlCodec.split(buffer: Data("nothing yet".utf8))
        XCTAssertTrue(none.lines.isEmpty)
        XCTAssertEqual(none.remainder.count, 11)
    }

    func testAnOverlongLineIsRefused() {
        let huge = Data(repeating: 0x20, count: LanControlCodec.maximumLineBytes + 1)
        XCTAssertThrowsError(try LanControlCodec.decode(line: huge)) { error in
            XCTAssertEqual(
                error as? LanControlCodec.CodecError,
                .lineTooLong(LanControlCodec.maximumLineBytes + 1)
            )
        }
    }

    // MARK: - Target clamp

    func testTargetIsClampedToTheOfferedRange() {
        XCTAssertEqual(LanPcmWire.clampTargetMs(0), 30)
        XCTAssertEqual(LanPcmWire.clampTargetMs(90), 90)
        XCTAssertEqual(LanPcmWire.clampTargetMs(5_000), 300)
    }
}
