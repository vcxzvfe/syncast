import Foundation

/// "Has the capture producer stopped writing?", answered from the ring alone.
///
/// # Why this exists
///
/// The LAN producer wakes every 5 ms; the capture backend writes a block
/// every ~10.7 ms (512 frames at 48 kHz), and neither is aligned to the
/// other. So roughly every second tick legitimately finds the ring's write
/// cursor exactly where it left it. That is NOT idleness — the audio for
/// that slot is a millisecond away — and an earlier version of this link
/// treated it as such: it synthesised a silence packet stamped from wall
/// clock whenever a tick found no new frames.
///
/// A two-machine run showed what that costs. 35 % of everything the sender
/// put on the wire was such a packet, each one carrying a timestamp from a
/// DIFFERENT timeline than the real audio around it (wall clock plus 5 ms,
/// versus the capture hardware's clock). The receiver dutifully scheduled
/// both, its jitter buffer grew by about 8 % per second, its trim pinned at
/// −200 ppm, it re-anchored every second, and the two interleaved streams
/// played on top of each other. The music was garbled at every latency
/// target, which is the signature of a timeline fault rather than a tuning
/// one.
///
/// # The rule
///
/// Idleness is a property of the RING, not of a tick. The producer is idle
/// when the write cursor has not moved for `thresholdMs` — an order of
/// magnitude longer than the block period, so no amount of beating between
/// the two rates can trip it, and short enough that the resume path runs
/// before the receiver's buffer has drained far.
///
/// And the response to idleness is to send NOTHING. The receiver zero-fills
/// what it does not have and counts it; that is the correct rendering of
/// silence, and it needs no packet to say so.
public struct ProducerIdleDetector: Equatable, Sendable {

    /// How long the ring's write cursor must sit still before the producer
    /// is judged idle.
    ///
    /// A capture block is ~10.7 ms, and a backend under load can be a couple
    /// of blocks late without having stopped. 100 ms is roughly ten blocks:
    /// far above that noise, and far below the point at which the receiver's
    /// buffer (90 ms of audio at the default target) has finished draining.
    public static let defaultIdleThresholdMs: Int = 100

    /// What this tick's observation says about the producer.
    public enum State: Equatable, Sendable {
        /// New frames landed, or the ring has been still for less than the
        /// threshold. Nothing special to do.
        case running
        /// The write cursor has not moved for at least the threshold.
        case idle
        /// New frames landed after an idle stretch. The caller re-anchors
        /// its cursor on this edge rather than replaying the gap.
        case resumed
    }

    public let thresholdNs: UInt64

    private var lastWritePosition: Int64 = -1
    private var lastAdvanceNs: UInt64 = 0
    private var idle: Bool = false

    public init(thresholdMs: Int = defaultIdleThresholdMs) {
        self.thresholdNs = UInt64(max(1, thresholdMs)) * 1_000_000
    }

    /// Whether the producer was idle as of the last observation.
    public var isIdle: Bool { idle }

    /// Forget everything. Used when the link goes down and the cursor is
    /// dropped: the next observation starts a fresh stretch rather than
    /// reporting a resume that nothing was waiting for.
    public mutating func reset() {
        lastWritePosition = -1
        lastAdvanceNs = 0
        idle = false
    }

    /// Fold one tick's view of the ring into the detector.
    @discardableResult
    public mutating func observe(writePosition: Int64, nowNs: UInt64) -> State {
        guard lastWritePosition >= 0 else {
            // First observation of this stretch: there is no previous cursor
            // to compare against, so start the clock and say nothing.
            lastWritePosition = writePosition
            lastAdvanceNs = nowNs
            idle = false
            return .running
        }
        if writePosition > lastWritePosition {
            let wasIdle = idle
            lastWritePosition = writePosition
            lastAdvanceNs = nowNs
            idle = false
            return wasIdle ? .resumed : .running
        }
        // The cursor stood still. Only time decides whether that matters.
        let stalledNs = nowNs >= lastAdvanceNs ? nowNs - lastAdvanceNs : 0
        if stalledNs >= thresholdNs { idle = true }
        return idle ? .idle : .running
    }
}
