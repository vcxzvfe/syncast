import Foundation

/// How many packets the LAN producer sends on one timer tick, and from which
/// ring frame.
///
/// Extracted from `LanReceiverOutput` so the cursor arithmetic — which is the
/// whole reason the receiver stays rate-locked to the ring rather than to our
/// timer — is unit-testable without a socket.
///
/// # The rule
///
/// The cursor is held a constant `lagFrames` behind the producer's write
/// cursor, exactly like `LocalOutput`'s ring floor, and the tick sends however
/// many whole packets have become available since the last one. At 48 kHz with
/// a 5 ms timer that is one packet per tick on average, occasionally zero or
/// two as the timer and the producer beat against each other — and because
/// `play_at_ns` is derived from the FRAME number (see `RingWriteClock`), a tick
/// that sends zero or two packets still produces a timestamp sequence that
/// advances at exactly the producer's rate.
///
/// The cursor never moves backwards, which is what makes `play_at_ns`
/// monotonic by construction: it either advances by whole packets or waits.
public struct LanSendPlan: Equatable, Sendable {
    /// How many packets to send this tick. Zero is normal and not a fault.
    public let packets: Int
    /// Ring frame the first packet reads from. Only meaningful when
    /// `packets > 0`.
    public let startFrame: Int64
    /// The cursor after this tick's packets have been sent.
    public let nextCursor: Int64
    /// The cursor was discarded and re-anchored. Audible as a skip on the
    /// receiver, so it is counted.
    public let didReanchor: Bool

    public init(packets: Int, startFrame: Int64, nextCursor: Int64, didReanchor: Bool) {
        self.packets = packets
        self.startFrame = startFrame
        self.nextCursor = nextCursor
        self.didReanchor = didReanchor
    }
}

public enum LanSendPlanner {

    /// Ceiling on packets per tick.
    ///
    /// A tick that finds a large backlog — the app was suspended, the timer
    /// coalesced — must not empty it in one burst: 200 packets back to back is
    /// a 200 kB blast at line rate that the receiver's socket buffer will
    /// simply drop. Four packets is 20 ms of catch-up per 5 ms tick, which
    /// recovers a one-second stall in about 300 ms without ever bursting.
    public static let maximumPacketsPerTick: Int = 4

    /// How far the cursor may fall behind its target before it is discarded
    /// rather than caught up packet by packet. 250 ms matches
    /// `LocalOutput.driftResyncLimitMs`, for the same reason: normal jitter
    /// moves the cursor by one packet, so this sits far above the noise and a
    /// trip past it is a real event.
    public static let driftResyncLimitMs: Int = 250

    /// - Parameters:
    ///   - writePosition: the capture ring's published write cursor.
    ///   - cursor: where we read up to last tick; nil before the first packet.
    ///   - lagFrames: steady-state distance to hold behind the producer.
    ///   - capacityFrames: ring size; a cursor older than this is gone.
    ///   - framesPerPacket: 240, by protocol.
    ///   - driftLimitFrames: see `driftResyncLimitMs`.
    ///   - maximumPackets: burst ceiling.
    public static func plan(
        writePosition: Int64,
        cursor: Int64?,
        lagFrames: Int64,
        capacityFrames: Int,
        framesPerPacket: Int = LanPcmWire.framesPerPacket,
        driftLimitFrames: Int64,
        maximumPackets: Int = maximumPacketsPerTick
    ) -> LanSendPlan {
        let packetFrames = Int64(max(1, framesPerPacket))
        // Highest frame the producer has written that we are willing to read.
        let ceiling = writePosition - max(0, lagFrames)
        // Nothing to send until the producer is at least one packet past the
        // lag we insist on holding.
        guard ceiling >= packetFrames else {
            return LanSendPlan(
                packets: 0, startFrame: cursor ?? 0,
                nextCursor: cursor ?? 0, didReanchor: false
            )
        }
        // Oldest frame still backed by the ring for a whole packet.
        let lowerValid = max(0, writePosition - Int64(capacityFrames) + packetFrames)
        let anchor = max(0, ceiling - packetFrames)

        var reanchored = false
        var position: Int64
        if let cursor {
            if cursor < lowerValid || ceiling - cursor > driftLimitFrames {
                // Either the producer lapped us or the timer stalled long
                // enough that catching up would mean playing stale audio.
                position = anchor
                reanchored = true
            } else {
                position = cursor
            }
        } else {
            position = anchor
            reanchored = true
        }

        let available = ceiling - position
        guard available >= packetFrames else {
            return LanSendPlan(
                packets: 0, startFrame: position,
                nextCursor: position, didReanchor: reanchored
            )
        }
        let count = min(Int(available / packetFrames), max(1, maximumPackets))
        return LanSendPlan(
            packets: count,
            startFrame: position,
            nextCursor: position + Int64(count) * packetFrames,
            didReanchor: reanchored
        )
    }
}

/// The alignment arithmetic that keeps the local CoreAudio legs playing the
/// same ring frame as the LAN receiver.
///
/// # The two budgets
///
/// A local AUHAL presents ring frame `F` at roughly
/// `ringTime(F) + ringFloor + renderBlock + hardwareLatency`: the render
/// callback deliberately trails the producer by the floor plus a block, and
/// the samples then take the device's own latency to reach the driver.
/// `LocalOutput.render()` already equalises the hardware term across the
/// enabled set (`compensation = maxLatency − myLatency`), so the whole local
/// set shares ONE budget, built from the worst device.
///
/// The LAN leg presents `F` at `ringTime(F) + target_ms`, by construction —
/// that is what `play_at_ns` says and what the receiver's jitter buffer is
/// sized for.
///
/// So when the target exceeds the local budget, every local leg has to be held
/// back by the difference. Nothing can be played early, so the other direction
/// (a target below the local budget) is not correctable from here; the UI says
/// so rather than pretending, and the fix is a larger target.
public enum LanAlignmentPlanner {

    /// The render quantum assumed for the local budget, in frames.
    ///
    /// The Router does not learn the AUHAL's real block size until it renders,
    /// and it is not worth plumbing back for this: 512 frames is 10.7 ms at
    /// 48 kHz and is what both the sink tap and a default output device use.
    /// An error of one block here is an error of ~10 ms in the alignment,
    /// which is at the edge of audibility for two speakers in one room and far
    /// below the target's own tuning range.
    public static let assumedRenderBlockFrames: Int = 512

    /// Frames the local legs already lag the ring by.
    public static func localPresentationLagFrames(
        ringFloorFrames: Int,
        maximumDeviceLatencyFrames: Int
    ) -> Int {
        max(0, ringFloorFrames) + assumedRenderBlockFrames + max(0, maximumDeviceLatencyFrames)
    }

    /// Extra hold every local leg needs so it lands with the LAN receiver.
    ///
    /// Non-negative: a target smaller than the local budget cannot be fixed by
    /// delaying the local legs, and returning a negative number here would
    /// silently reverse the sign of the whole trim stack.
    public static func localHoldFrames(
        targetMs: Int,
        ringFloorFrames: Int,
        maximumDeviceLatencyFrames: Int,
        sampleRate: Double
    ) -> Int {
        let targetFrames = LocalDelayTrim.frames(
            ms: LanPcmWire.clampTargetMs(targetMs), sampleRate: sampleRate
        )
        let localLag = localPresentationLagFrames(
            ringFloorFrames: ringFloorFrames,
            maximumDeviceLatencyFrames: maximumDeviceLatencyFrames
        )
        return max(0, targetFrames - localLag)
    }

    /// The end-to-end lag the user will actually hear, in milliseconds:
    /// whichever leg is slowest, since they are all aligned to it.
    ///
    /// Honest about what it does NOT include: the capture stage's own latency
    /// (the tap or ScreenCaptureKit delivering the application's audio into
    /// the ring), which adds a handful of milliseconds this layer never sees.
    public static func totalLagMs(
        targetMs: Int,
        ringFloorFrames: Int,
        maximumDeviceLatencyFrames: Int,
        sampleRate: Double
    ) -> Double {
        let localLagMs = LocalDelayTrim.milliseconds(
            frames: localPresentationLagFrames(
                ringFloorFrames: ringFloorFrames,
                maximumDeviceLatencyFrames: maximumDeviceLatencyFrames
            ),
            sampleRate: sampleRate
        )
        return max(Double(LanPcmWire.clampTargetMs(targetMs)), localLagMs)
    }
}
