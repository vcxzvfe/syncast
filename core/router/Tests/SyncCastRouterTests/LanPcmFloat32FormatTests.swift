import Foundation
import XCTest
@testable import SyncCastRouter

/// The `f32le` payload and how it is negotiated: asked for in `hello`,
/// granted only by a `hello_ack` that echoes it, encoded without clipping.
final class LanPcmFloat32FormatTests: XCTestCase {

    func testHelloAsksForFloat32() throws {
        let data = try LanControlCodec.encode(
            .hello(token: "cafef00d", senderName: "SyncCast", streamID: 42)
        )
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data.dropLast()) as? [String: Any]
        )
        XCTAssertEqual(json["format"] as? String, "f32le")
        XCTAssertEqual(LanPcmWire.preferredFormat, .float32)
    }

    func testHelloAckWithoutFormatMeansInt16() throws {
        let line = Data(#"{"type":"hello_ack","v":1,"udp_port":1,"device":"d","device_uid":"u","hw_volume":true,"buffer_ms":90}"#.utf8)
        guard case .helloAck(let ack) = try LanControlCodec.decode(line: line) else {
            return XCTFail("expected hello_ack")
        }
        XCTAssertEqual(ack.format, .int16, "a v1 receiver says nothing and gets s16le")
    }

    func testHelloAckEchoingFloat32IsHonoured() throws {
        let line = Data(#"{"type":"hello_ack","v":1,"udp_port":1,"device":"d","device_uid":"u","hw_volume":true,"buffer_ms":90,"format":"f32le"}"#.utf8)
        guard case .helloAck(let ack) = try LanControlCodec.decode(line: line) else {
            return XCTFail("expected hello_ack")
        }
        XCTAssertEqual(ack.format, .float32)
        let unknown = Data(#"{"type":"hello_ack","v":1,"udp_port":1,"device":"d","device_uid":"u","hw_volume":true,"buffer_ms":90,"format":"opus"}"#.utf8)
        guard case .helloAck(let odd) = try LanControlCodec.decode(line: unknown) else {
            return XCTFail("expected hello_ack")
        }
        XCTAssertEqual(odd.format, .int16, "an unknown format is not trusted")
    }

    func testFloat32EncodeKeepsHotSamplesAndCountsThem() {
        let frames = 4
        var left: [Float] = [0, 0.5, -1.55, 1]
        var right: [Float] = [1.25, -1, 0.25, 0]
        var buffer = [UInt8](repeating: 0, count: frames * 2 * 4)
        var hot = 0
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                let table = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 2)
                defer { table.deallocate() }
                table[0] = l.baseAddress!
                table[1] = r.baseAddress!
                buffer.withUnsafeMutableBytes { raw in
                    hot = LanPcmEncoder.encodeFloat32(
                        channels: table, channelCount: 2, frames: frames, into: raw, offset: 0
                    )
                }
            }
        }
        XCTAssertEqual(hot, 2, "two samples lie past full scale")
        let decoded = LanPcmEncoder.decode(payload: Data(buffer), channelCount: 2, format: .float32)
        XCTAssertEqual(decoded, [0, 1.25, 0.5, -1, -1.55, 0.25, 1, 0])
    }

    func testPacketSizesPerFormat() {
        XCTAssertEqual(LanPcmWire.payloadBytes(for: .int16), 960)
        XCTAssertEqual(LanPcmWire.payloadBytes(for: .float32), 1_920)
        XCTAssertEqual(LanPcmWire.packetBytes(for: .float32), 1_944)
        XCTAssertEqual(LanPcmWire.maximumPacketBytes, 1_944)
    }
}
