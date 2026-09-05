import Foundation
import SyncCastAtomic

/// "Ring frame N was captured at host time T", straight from the hardware.
///
/// The LAN link is the only consumer that has to state a capture time out
/// loud — the local AUHALs share the capture device's clock domain and stay
/// locked by construction — and it is much better off being TOLD the time
/// than inferring it. A CoreAudio IOProc is handed an `AudioTimeStamp` for
/// every block it receives; that stamp comes from the same hardware clock
/// that produced the samples, so a timeline built from it has the device's
/// own rate in it and none of the scheduler's noise.
public struct CaptureAnchor: Equatable, Sendable {
    /// Ring write position of this block's FIRST frame.
    public let frame: Int64
    /// Monotonic nanoseconds at which that frame was captured.
    public let hostNs: UInt64

    public init(frame: Int64, hostNs: UInt64) {
        self.frame = frame
        self.hostNs = hostNs
    }
}

/// Publishes the newest `CaptureAnchor` from a real-time capture callback to
/// whoever asks for it.
///
/// Only the LATEST anchor is kept. A consumer that misses one has lost
/// nothing that matters: anchors arrive every few milliseconds, each one
/// carries its own host time, and the rate estimate is fitted over ten
/// seconds of them.
///
/// The publish side is wait-free (a seqlock write, see `SCAtomicAnchor`) so
/// it is safe to call from the IOProc; the read side retries a bounded number
/// of times and reports "nothing yet" rather than spinning.
public final class CaptureAnchorPublisher: @unchecked Sendable {

    /// Nominal frames per second of the capture device, as configured. The
    /// consumer uses it as the starting rate until enough anchors have
    /// arrived to fit a real one.
    public let sampleRate: Double

    private let slot: UnsafeMutablePointer<SCAtomicAnchor>

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate > 0 ? sampleRate : LanPcmWire.sampleRate
        let pointer = UnsafeMutablePointer<SCAtomicAnchor>.allocate(capacity: 1)
        sc_anchor_init(pointer)
        self.slot = pointer
    }

    deinit { slot.deallocate() }

    /// Real-time safe: no allocation, no locks, no Swift runtime calls.
    public func publish(frame: Int64, hostNs: UInt64) {
        sc_anchor_publish(slot, frame, hostNs)
    }

    public func publish(_ anchor: CaptureAnchor) {
        publish(frame: anchor.frame, hostNs: anchor.hostNs)
    }

    /// The newest anchor, or nil before the capture backend has delivered its
    /// first block.
    public var latest: CaptureAnchor? {
        var frame: Int64 = 0
        var hostNs: UInt64 = 0
        guard sc_anchor_load(slot, &frame, &hostNs) == 1 else { return nil }
        return CaptureAnchor(frame: frame, hostNs: hostNs)
    }
}
