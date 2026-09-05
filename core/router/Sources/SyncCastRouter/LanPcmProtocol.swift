import Foundation

/// The SyncCast LAN PCM link's wire format: the UDP audio packet and the
/// newline-delimited JSON control messages.
///
/// Everything in this file is pure — no sockets, no clock, no allocation
/// beyond the buffers the caller hands in — so the encoder and the decoder can
/// be pinned by tests against hand-assembled bytes. The socket half lives in
/// `LanReceiverLink`, the audio producer in `LanReceiverOutput`.
///
/// The canonical description of the protocol is `proto/lan-pcm-link.md` in
/// this repository; the receiver daemon implements the other side of it.
public enum LanPcmWire {

    // MARK: - Constants

    /// `"SCPC"` read as a big-endian ASCII quad. Written to the wire as a
    /// little-endian `u32` like every other header field, so the first four
    /// bytes of a packet are `43 50 43 53`.
    public static let magic: UInt32 = 0x5343_5043

    /// Protocol version carried in `hello` / `hello_ack`.
    public static let version: Int = 1

    /// The only sample rate the link is defined on.
    public static let sampleRate: Double = 48_000
    /// Interleaved stereo, Int16 LE.
    public static let channelCount: Int = 2
    public static let bytesPerSample: Int = 2
    /// 240 frames = exactly 5 ms at 48 kHz.
    public static let framesPerPacket: Int = 240
    /// 24 bytes: magic + stream_id + seq + play_at_ns + frames.
    public static let headerBytes: Int = 24
    /// 240 frames × 2 channels × 2 bytes.
    public static let payloadBytes: Int =
        framesPerPacket * channelCount * bytesPerSample
    public static let packetBytes: Int = headerBytes + payloadBytes

    /// Nanoseconds one packet covers, by definition of `framesPerPacket`.
    public static let packetDurationNs: UInt64 = 5_000_000

    /// Bonjour service the receiver advertises.
    public static let bonjourServiceType = "_synccast-pcm._udp"

    // MARK: - Latency target

    /// Playout target the sender asks the receiver to honour, in
    /// milliseconds. 90 ms is the default because it is the smallest value
    /// that survived a Wi-Fi hop in the design budget; the range is offered
    /// because the only instrument that can judge it is the listener's own
    /// network.
    public static let defaultTargetMs: Int = 90
    public static let targetRangeMs: ClosedRange<Int> = 30...300
    public static let targetStepMs: Int = 5

    public static func clampTargetMs(_ ms: Int) -> Int {
        min(targetRangeMs.upperBound, max(targetRangeMs.lowerBound, ms))
    }
}

// MARK: - Audio packet

/// The 24-byte UDP audio header.
public struct LanAudioPacketHeader: Equatable, Sendable {
    public var streamID: UInt32
    public var sequence: UInt32
    /// SENDER monotonic nanoseconds at which the first frame of this packet
    /// must leave the receiver's DAC.
    public var playAtNs: UInt64
    public var frames: UInt32

    public init(streamID: UInt32, sequence: UInt32, playAtNs: UInt64, frames: UInt32) {
        self.streamID = streamID
        self.sequence = sequence
        self.playAtNs = playAtNs
        self.frames = frames
    }

    /// Serialise into the first `LanPcmWire.headerBytes` of `buffer`.
    ///
    /// - Returns: false when the buffer is too short; the buffer is then
    ///   untouched. Refusing is the only safe failure — a short write here
    ///   would put a truncated header on the wire.
    @discardableResult
    public func encode(into buffer: UnsafeMutableRawBufferPointer) -> Bool {
        guard buffer.count >= LanPcmWire.headerBytes else { return false }
        Self.writeLE(UInt32(LanPcmWire.magic), to: buffer, at: 0)
        Self.writeLE(streamID, to: buffer, at: 4)
        Self.writeLE(sequence, to: buffer, at: 8)
        Self.writeLE(playAtNs, to: buffer, at: 12)
        Self.writeLE(frames, to: buffer, at: 20)
        return true
    }

    /// Parse a header, rejecting anything whose magic, frame count or overall
    /// length does not match the contract. External data: every field is
    /// checked before it can reach the audio path.
    public static func decode(_ bytes: UnsafeRawBufferPointer) -> LanAudioPacketHeader? {
        guard bytes.count >= LanPcmWire.headerBytes else { return nil }
        guard readLE32(bytes, at: 0) == LanPcmWire.magic else { return nil }
        let frames = readLE32(bytes, at: 20)
        guard frames == UInt32(LanPcmWire.framesPerPacket) else { return nil }
        return LanAudioPacketHeader(
            streamID: readLE32(bytes, at: 4),
            sequence: readLE32(bytes, at: 8),
            playAtNs: readLE64(bytes, at: 12),
            frames: frames
        )
    }

    /// Parse a whole packet: header plus the exact PCM payload length.
    public static func decodePacket(
        _ data: Data
    ) -> (header: LanAudioPacketHeader, payload: Data)? {
        guard data.count == LanPcmWire.packetBytes else { return nil }
        let header: LanAudioPacketHeader? = data.withUnsafeBytes { LanAudioPacketHeader.decode($0) }
        guard let header else { return nil }
        return (header, data.subdata(in: LanPcmWire.headerBytes..<data.count))
    }

    // Little-endian primitives, written byte by byte rather than through
    // `withUnsafeBytes(of:)` so the layout does not depend on the host's
    // endianness or on struct padding.

    static func writeLE(_ value: UInt32, to buffer: UnsafeMutableRawBufferPointer, at offset: Int) {
        buffer[offset] = UInt8(truncatingIfNeeded: value)
        buffer[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        buffer[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        buffer[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }

    static func writeLE(_ value: UInt64, to buffer: UnsafeMutableRawBufferPointer, at offset: Int) {
        for byte in 0..<8 {
            buffer[offset + byte] = UInt8(truncatingIfNeeded: value >> (8 * UInt64(byte)))
        }
    }

    static func readLE32(_ bytes: UnsafeRawBufferPointer, at offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }

    static func readLE64(_ bytes: UnsafeRawBufferPointer, at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for byte in 0..<8 {
            value |= UInt64(bytes[offset + byte]) << (8 * UInt64(byte))
        }
        return value
    }
}

/// Float32 planar → Int16 LE interleaved, straight into a packet's payload.
public enum LanPcmEncoder {
    /// Full-scale Int16. `Int16.min` is one step further from zero than
    /// `Int16.max`, so the positive rail is what a symmetric conversion has to
    /// respect; using 32767 for both keeps the two rails equal and avoids a
    /// wrap at exactly −1.0.
    public static let fullScale: Float = 32_767

    /// Write `frames` frames of planar Float32 as interleaved Int16 LE.
    ///
    /// - Parameters:
    ///   - channels: `channelCount` pointers to `frames` floats each.
    ///   - buffer: destination, at least `frames * channelCount * 2` bytes.
    ///   - offset: byte offset into `buffer` to start writing at.
    /// - Returns: how many samples were clamped. Non-zero means the signal
    ///   reaching the link is over full scale, which is a fault worth
    ///   reporting rather than silently wrapping.
    @discardableResult
    public static func encode(
        channels: UnsafeMutablePointer<UnsafeMutablePointer<Float>>,
        channelCount: Int,
        frames: Int,
        into buffer: UnsafeMutableRawBufferPointer,
        offset: Int
    ) -> Int {
        let needed = frames * channelCount * LanPcmWire.bytesPerSample
        guard frames > 0, channelCount > 0, buffer.count >= offset + needed else { return 0 }
        var clipped = 0
        var byteIndex = offset
        for frame in 0..<frames {
            for channel in 0..<channelCount {
                let sample = channels[channel][frame]
                var scaled: Float
                if !sample.isFinite {
                    scaled = 0
                    clipped += 1
                } else if sample > 1 {
                    scaled = fullScale
                    clipped += 1
                } else if sample < -1 {
                    scaled = -fullScale
                    clipped += 1
                } else {
                    scaled = sample * fullScale
                }
                let value = Int16(scaled.rounded())
                let bits = UInt16(bitPattern: value)
                buffer[byteIndex] = UInt8(truncatingIfNeeded: bits)
                buffer[byteIndex + 1] = UInt8(truncatingIfNeeded: bits >> 8)
                byteIndex += 2
            }
        }
        return clipped
    }

    /// The inverse, for tests and for anything that wants to look at what was
    /// sent. Returns interleaved Float32 in −1…1.
    public static func decode(payload: Data, channelCount: Int) -> [Float] {
        let sampleCount = payload.count / LanPcmWire.bytesPerSample
        guard sampleCount > 0, channelCount > 0 else { return [] }
        var out: [Float] = []
        out.reserveCapacity(sampleCount)
        payload.withUnsafeBytes { raw in
            for index in 0..<sampleCount {
                let low = UInt16(raw[index * 2])
                let high = UInt16(raw[index * 2 + 1]) << 8
                let value = Int16(bitPattern: low | high)
                out.append(Float(value) / fullScale)
            }
        }
        return out
    }
}
