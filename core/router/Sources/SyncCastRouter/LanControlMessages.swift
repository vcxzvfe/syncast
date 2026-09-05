import Foundation

/// The LAN link's control channel: newline-delimited JSON over TCP.
///
/// Pure encode/decode with no socket in sight, so both directions can be
/// pinned by tests against literal JSON. Every inbound field is validated
/// here — this is the boundary where a peer's bytes become our numbers, and a
/// receiver on the far side of a LAN is external data no matter how friendly
/// it looks.

// MARK: - Sender → receiver

public enum LanOutboundMessage: Equatable, Sendable {
    /// Opens the session. The token is the shared secret; a receiver that does
    /// not recognise it answers `error` and closes.
    case hello(token: String, senderName: String, streamID: UInt32)
    /// Master level for this leg, as linear amplitude plus the mute flag.
    case gain(linear: Double, muted: Bool)
    /// The playout target the receiver must honour.
    case latency(targetMs: Int)
    /// Round-trip probe and keep-alive. `t1` is sender monotonic ns.
    /// `prevT4`: when the previous pong arrived (sender clock), so the receiver
    /// can close the NTP loop with all four timestamps (receiver-side extension).
    case ping(t1: UInt64, prevT4: UInt64? = nil)
    /// Orderly shutdown.
    case bye

    /// The `type` string this message carries on the wire.
    public var typeName: String {
        switch self {
        case .hello: return "hello"
        case .gain: return "gain"
        case .latency: return "latency"
        case .ping: return "ping"
        case .bye: return "bye"
        }
    }
}

// MARK: - Receiver → sender

/// The receiver's answer to `hello`.
public struct LanHelloAck: Equatable, Sendable {
    public let version: Int
    /// UDP port the audio packets must go to.
    public let udpPort: Int
    /// Human-readable name of the output device the receiver is playing on.
    public let deviceName: String
    public let deviceUID: String
    /// Whether the receiver can carry the master level in hardware. Reported
    /// so the UI can say "this receiver's own volume knob is being driven"
    /// rather than leaving the user guessing.
    public let hasHardwareVolume: Bool
    /// The receiver's own jitter-buffer depth, in milliseconds.
    public let bufferMs: Int

    public init(
        version: Int,
        udpPort: Int,
        deviceName: String,
        deviceUID: String,
        hasHardwareVolume: Bool,
        bufferMs: Int
    ) {
        self.version = version
        self.udpPort = udpPort
        self.deviceName = deviceName
        self.deviceUID = deviceUID
        self.hasHardwareVolume = hasHardwareVolume
        self.bufferMs = bufferMs
    }
}

/// The receiver's periodic health report.
public struct LanReceiverStats: Equatable, Sendable {
    /// Packets whose play time had already passed when they arrived.
    public let late: Int
    /// Sequence numbers that never arrived.
    public let lost: Int
    /// Render callbacks served as silence because the jitter buffer was empty.
    public let underrun: Int
    /// Current jitter-buffer fill, in milliseconds.
    public let bufferMs: Double
    /// The resampler ratio the receiver's PI loop has settled on. 1.0 means the
    /// two clocks agree.
    public let ratio: Double
    /// Samples the receiver's own output limiter had to clamp.
    public let clip: Int

    public init(
        late: Int, lost: Int, underrun: Int,
        bufferMs: Double, ratio: Double, clip: Int
    ) {
        self.late = late
        self.lost = lost
        self.underrun = underrun
        self.bufferMs = bufferMs
        self.ratio = ratio
        self.clip = clip
    }

    public static let zero = LanReceiverStats(
        late: 0, lost: 0, underrun: 0, bufferMs: 0, ratio: 1, clip: 0
    )
}

public enum LanInboundMessage: Equatable, Sendable {
    case helloAck(LanHelloAck)
    /// NTP-style timestamps: `t1` is our echoed send time, `t2` the receiver's
    /// arrival time, `t3` its send time. `t4` is stamped locally on receipt.
    case pong(t1: UInt64, t2: UInt64, t3: UInt64)
    case stats(LanReceiverStats)
    case error(message: String)
}

// MARK: - Codec

public enum LanControlCodec {

    /// Largest control line we will buffer before giving up on the peer.
    ///
    /// Every legal message is well under 512 bytes. A peer that sends
    /// megabytes without a newline is either broken or hostile, and the only
    /// safe answer is to stop reading rather than grow a buffer for it.
    public static let maximumLineBytes: Int = 64 * 1024

    public enum CodecError: Error, Equatable, CustomStringConvertible {
        case notJSON
        case missingType
        case unknownType(String)
        case missingField(String)
        case lineTooLong(Int)

        public var description: String {
            switch self {
            case .notJSON: return "control line was not a JSON object"
            case .missingType: return "control line had no \"type\""
            case .unknownType(let type): return "unknown control message \"\(type)\""
            case .missingField(let field): return "control line was missing \"\(field)\""
            case .lineTooLong(let count): return "control line of \(count) bytes exceeds the cap"
            }
        }
    }

    /// Serialise one outbound message as a single UTF-8 line, newline
    /// included.
    ///
    /// `JSONSerialization` with `.sortedKeys` rather than a `Codable`
    /// conformance per case: the wire shape is defined by the protocol
    /// document, not by Swift's synthesised keys, and sorted output makes the
    /// bytes reproducible so a test can compare them literally.
    public static func encode(_ message: LanOutboundMessage) throws -> Data {
        var object: [String: Any] = ["type": message.typeName]
        switch message {
        case .hello(let token, let senderName, let streamID):
            object["v"] = LanPcmWire.version
            object["token"] = token
            object["name"] = senderName
            object["rate"] = Int(LanPcmWire.sampleRate)
            object["channels"] = LanPcmWire.channelCount
            object["frames_per_packet"] = LanPcmWire.framesPerPacket
            object["stream_id"] = streamID
        case .gain(let linear, let muted):
            object["linear"] = linear
            object["muted"] = muted
        case .latency(let targetMs):
            object["target_ms"] = targetMs
        case .ping(let t1, let prevT4):
            object["t1"] = t1
            if let prevT4 { object["prev_t4"] = prevT4 }
        case .bye:
            break
        }
        var data = try JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]
        )
        data.append(0x0A)
        return data
    }

    /// Parse one inbound line (with or without its trailing newline).
    public static func decode(line: Data) throws -> LanInboundMessage {
        guard line.count <= maximumLineBytes else {
            throw CodecError.lineTooLong(line.count)
        }
        let trimmed = line.last == 0x0A ? line.dropLast() : line[...]
        guard let object = try? JSONSerialization.jsonObject(with: Data(trimmed)),
              let dictionary = object as? [String: Any]
        else {
            throw CodecError.notJSON
        }
        guard let type = dictionary["type"] as? String else {
            throw CodecError.missingType
        }
        switch type {
        case "hello_ack":
            guard let port = intValue(dictionary["udp_port"]) else {
                throw CodecError.missingField("udp_port")
            }
            return .helloAck(
                LanHelloAck(
                    version: intValue(dictionary["v"]) ?? LanPcmWire.version,
                    udpPort: port,
                    deviceName: (dictionary["device"] as? String) ?? "",
                    deviceUID: (dictionary["device_uid"] as? String) ?? "",
                    hasHardwareVolume: (dictionary["hw_volume"] as? Bool) ?? false,
                    bufferMs: intValue(dictionary["buffer_ms"]) ?? 0
                )
            )
        case "pong":
            guard let t1 = unsignedValue(dictionary["t1"]) else {
                throw CodecError.missingField("t1")
            }
            guard let t2 = unsignedValue(dictionary["t2"]) else {
                throw CodecError.missingField("t2")
            }
            guard let t3 = unsignedValue(dictionary["t3"]) else {
                throw CodecError.missingField("t3")
            }
            return .pong(t1: t1, t2: t2, t3: t3)
        case "stats":
            return .stats(
                LanReceiverStats(
                    late: intValue(dictionary["late"]) ?? 0,
                    lost: intValue(dictionary["lost"]) ?? 0,
                    underrun: intValue(dictionary["underrun"]) ?? 0,
                    bufferMs: doubleValue(dictionary["buffer_ms"]) ?? 0,
                    ratio: doubleValue(dictionary["ratio"]) ?? 1,
                    clip: intValue(dictionary["clip"]) ?? 0
                )
            )
        case "error":
            return .error(message: (dictionary["message"] as? String) ?? "unspecified")
        default:
            throw CodecError.unknownType(type)
        }
    }

    /// Split a byte stream into complete lines, returning the remainder.
    ///
    /// TCP gives no message boundaries, so a `read` can land mid-line or carry
    /// three of them; this is the only place that knows it.
    public static func split(buffer: Data) -> (lines: [Data], remainder: Data) {
        var lines: [Data] = []
        var start = buffer.startIndex
        while let newline = buffer[start...].firstIndex(of: 0x0A) {
            lines.append(Data(buffer[start..<newline]))
            start = buffer.index(after: newline)
        }
        return (lines, Data(buffer[start...]))
    }

    // Numeric coercion. JSONSerialization hands back `NSNumber`, whose Swift
    // bridging depends on how the literal was written, so every reader goes
    // through these rather than a single conditional cast that works in the
    // test and fails on a receiver that wrote `90.0`.

    static func intValue(_ any: Any?) -> Int? {
        if let value = any as? Int { return value }
        if let value = any as? NSNumber { return value.intValue }
        if let value = any as? String { return Int(value) }
        return nil
    }

    static func unsignedValue(_ any: Any?) -> UInt64? {
        if let value = any as? UInt64 { return value }
        if let value = any as? NSNumber {
            let double = value.doubleValue
            guard double >= 0, double.isFinite else { return nil }
            return value.uint64Value
        }
        if let value = any as? String { return UInt64(value) }
        return nil
    }

    static func doubleValue(_ any: Any?) -> Double? {
        if let value = any as? Double { return value }
        if let value = any as? NSNumber { return value.doubleValue }
        if let value = any as? String { return Double(value) }
        return nil
    }
}
