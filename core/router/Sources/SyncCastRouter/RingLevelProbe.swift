import Foundation

/// "How loud was what the producer wrote since I last looked?", answered by
/// reading the ring a capture backend already fills.
///
/// # Why read the ring instead of metering in the IOProc
///
/// Every capture backend (the sink path's Process Tap, ScreenCaptureKit, the
/// meter-only tap the menu bar starts when nothing else is capturing) ends in
/// the same `RingBuffer.write`. Reading that ring from a slow, ordinary
/// thread meters all of them with one piece of code and adds nothing to a
/// real-time callback. The ring is built for exactly this: one writer, any
/// number of readers, each with its own cursor (the AUHALs already read it
/// this way).
///
/// # Semantics
///
/// `measure` returns the peak absolute sample, over every channel, of the
/// frames written since the previous call, or nil when nothing new was
/// written. Nil is information too: a Process Tap only delivers blocks while
/// some process is rendering, so a still write cursor means "nobody is
/// playing".
///
/// The first call on a ring (and the first call after the caller switches to
/// a different ring, e.g. the router moved to another path) only places the
/// cursor and returns nil. Metering the backlog would report audio from
/// before the caller started looking.
///
/// When the caller falls further behind than `maxFrames`, only the newest
/// `maxFrames` are read. The caller asks once a second; a late tick must not
/// turn into a multi-second read, and frames that old say nothing about now.
///
/// Not thread-safe: one probe belongs to one polling loop.
public final class RingLevelProbe {
    /// Frames read per `RingBuffer.read` call. Small enough that the scratch
    /// buffers stay a few tens of kilobytes whatever window the caller asks
    /// for.
    public static let chunkFrames = 4096

    private var ringIdentity: ObjectIdentifier?
    private var cursor: Int64 = 0
    private var scratch: [UnsafeMutablePointer<Float>] = []
    private var scratchChannels: UnsafeMutablePointer<UnsafeMutablePointer<Float>>?
    private var scratchChannelCount = 0

    public init() {}

    deinit {
        releaseScratch()
    }

    /// Forget the current ring. The next `measure` re-anchors without
    /// metering, wherever it is pointed.
    public func reset() {
        ringIdentity = nil
        cursor = 0
    }

    /// Peak |sample| across all channels of the frames written since the
    /// previous call, or nil when there are none (or this call only
    /// anchored the cursor).
    public func measure(ring: RingBuffer, maxFrames: Int) -> Float? {
        let identity = ObjectIdentifier(ring)
        let writePos = ring.writePosition
        guard ringIdentity == identity else {
            ringIdentity = identity
            cursor = writePos
            return nil
        }
        guard writePos > cursor else {
            // A ring never runs backwards; a smaller cursor can only mean a
            // replaced ring that happens to reuse an address. Re-anchor.
            if writePos < cursor { cursor = writePos }
            return nil
        }
        let window = Int64(max(1, min(maxFrames, ring.capacityFrames)))
        var position = max(cursor, writePos - window)
        cursor = writePos
        ensureScratch(channelCount: ring.channelCount)
        guard let channels = scratchChannels else { return nil }

        var peak: Float = 0
        while position < writePos {
            let frames = Int(min(Int64(Self.chunkFrames), writePos - position))
            let filled = ring.read(at: position, frames: frames, into: UnsafePointer(channels))
            if filled > 0 {
                for ch in 0..<scratchChannelCount {
                    peak = max(peak, Self.peak(scratch[ch], frames: frames))
                }
            }
            position += Int64(frames)
        }
        return peak
    }

    /// Full-scale-relative level of a linear peak. Zero (digital silence)
    /// maps to -infinity rather than to a made-up floor, so a threshold
    /// comparison stays honest.
    public static func dbfs(_ peak: Float) -> Double {
        guard peak > 0, peak.isFinite else { return -.infinity }
        return 20 * log10(Double(peak))
    }

    private static func peak(_ pointer: UnsafeMutablePointer<Float>, frames: Int) -> Float {
        var result: Float = 0
        for i in 0..<frames {
            let value = abs(pointer[i])
            // NaN fails every comparison, so it can never become the peak.
            if value > result { result = value }
        }
        return result
    }

    private func ensureScratch(channelCount: Int) {
        guard channelCount != scratchChannelCount || scratchChannels == nil else { return }
        releaseScratch()
        let count = max(1, channelCount)
        var slabs: [UnsafeMutablePointer<Float>] = []
        slabs.reserveCapacity(count)
        for _ in 0..<count {
            let slab = UnsafeMutablePointer<Float>.allocate(capacity: Self.chunkFrames)
            slab.initialize(repeating: 0, count: Self.chunkFrames)
            slabs.append(slab)
        }
        let table = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: count)
        for i in 0..<count { table[i] = slabs[i] }
        scratch = slabs
        scratchChannels = table
        scratchChannelCount = count
    }

    private func releaseScratch() {
        for slab in scratch {
            slab.deinitialize(count: Self.chunkFrames)
            slab.deallocate()
        }
        scratch = []
        scratchChannels?.deallocate()
        scratchChannels = nil
        scratchChannelCount = 0
    }
}

/// Whether one output's routing row lets audio through. Pure, so the rule
/// the meter relies on is pinned by a test rather than by reading `Router`.
public enum PlaybackRouteAudibility {
    /// Below this the row's level is treated as off. The sliders' floor is
    /// 0; any position above it is audible.
    public static let silentVolumeCeiling: Float = 0.0001

    /// - Parameter wholeHome: the whole-home local legs run the row through
    ///   `VolumeCurve` (as `Router.localBridgeGain` does), whose 0 % is
    ///   −30 dB and still audible. Every Stereo path treats the row as a
    ///   linear level or a dB-composed balance, where 0 is silence.
    public static func audible(_ route: DeviceRouting, wholeHome: Bool = false) -> Bool {
        guard route.enabled, !route.muted else { return false }
        guard wholeHome else { return route.volume > silentVolumeCeiling }
        let amplitude = VolumeCurve.deviceAmplitude(
            forPercent: VolumeCurve.percent(forFraction: Double(route.volume)),
            muted: false
        )
        return amplitude > silentVolumeCeiling
    }
}
