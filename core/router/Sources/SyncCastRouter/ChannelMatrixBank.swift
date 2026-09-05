import Foundation
import os.lock
import SyncCastAtomic

/// Real-time channel assignment for one output: a 2×2 gain matrix per output
/// channel pair (= per physical speaker in aggregate mode).
///
/// # Real-time contract
///
/// `process()` runs on the render thread (or, for `LanReceiverOutput`, on its
/// producer timer). It never allocates, never calls into CoreAudio, and takes
/// `paramLock` only on the block where the app thread has published new
/// coefficients — steady state is one atomic load per pair per block. All the
/// `pow`/`log10` work happens on the app thread in `setSettings()`.
///
/// # Why a coefficient ramp rather than two parallel chains
///
/// `EqualizerBank` and `StereoImageProcessor` both run TWO banks in parallel
/// during a change and crossfade their outputs, because a biquad and a
/// recursive delay line carry state: you cannot interpolate their parameters
/// without interpolating a filter into something that is not the filter you
/// wanted.
///
/// A channel matrix is memoryless and linear, so the two are identical here:
/// crossfading `A·x` with `B·x` by weight `w` gives `((1−w)A + wB)·x`, which is
/// exactly the interpolated matrix applied once. One multiply-add chain, no
/// second bank, no state to seed — and the same 20 ms feel as the other two
/// panels, which is what the user actually perceives.
public final class ChannelMatrixBank {

    /// Ramp length for a parameter change. Matches `EqualizerBank` and
    /// `StereoImageProcessor`, so dragging any of the three panels feels the
    /// same.
    public static let fadeMilliseconds: Double = 20

    /// Largest block the caller may hand us. Matches
    /// `LocalOutput.stagingFrameCapacity`.
    public static let maxFramesPerBlock: Int = 4096

    /// Channels the module is defined on. A 2×2 matrix is a statement about a
    /// left/right pair; a pair that is not stereo is left alone.
    public static let requiredChannelsPerPair: Int = 2

    public let pairCount: Int
    public let channelsPerPair: Int
    public let sampleRate: Double

    private let fadeFrames: Int

    /// Coefficient layout inside one pair's slot.
    private enum Coefficient {
        static let leftToLeft = 0
        static let rightToLeft = 1
        static let leftToRight = 2
        static let rightToRight = 3
        static let count = 4
    }

    // MARK: Storage
    //
    // Heap-allocated once at init and indexed directly: a Swift Array would be
    // copy-on-write, and a COW copy on the render thread is a heap allocation
    // in an audio callback.

    /// The coefficients in force at the start of a ramp, per pair.
    private let fromCoefficients: UnsafeMutablePointer<Float>
    /// The coefficients being ramped towards, per pair. Equal to `from` when no
    /// ramp is running.
    private let toCoefficients: UnsafeMutablePointer<Float>
    /// App-thread staging, read by the render thread under `paramLock` on the
    /// block it adopts the publish.
    private let pendingCoefficients: UnsafeMutablePointer<Float>
    /// Bumped by the app thread after the staging slot is filled; compared by
    /// the render thread against `appliedGeneration`.
    private let pendingGeneration: UnsafeMutablePointer<SCAtomicInt64>

    // Render-thread-owned bookkeeping. Written only by `process()`.
    private let appliedGeneration: UnsafeMutablePointer<Int64>
    private let fadeRemaining: UnsafeMutablePointer<Int32>

    /// Samples the output clamp had to limit. Published lock-free for the
    /// diagnostics line; non-zero means a boosted coefficient is driving the
    /// output past full scale.
    private let clipCounter: UnsafeMutablePointer<SCAtomicInt64>

    private let paramLock = OSAllocatedUnfairLock()
    /// Last settings accepted per pair, so a reconcile that re-pushes the same
    /// values does not spend a ramp. App-thread state, guarded by `paramLock`
    /// because the Router actor may hop threads between calls.
    private var lastRequested: [ChannelMatrixSettings?]

    public init(pairCount: Int, channelsPerPair: Int, sampleRate: Double) {
        let pairs = max(1, pairCount)
        let channels = max(1, channelsPerPair)
        self.pairCount = pairs
        self.channelsPerPair = channels
        self.sampleRate = sampleRate > 0 ? sampleRate : 48_000
        self.fadeFrames = max(
            1, Int((self.sampleRate * Self.fadeMilliseconds / 1000).rounded())
        )
        self.lastRequested = Array(repeating: nil, count: pairs)

        let words = pairs * Coefficient.count
        fromCoefficients = .allocate(capacity: words)
        toCoefficients = .allocate(capacity: words)
        pendingCoefficients = .allocate(capacity: words)
        fromCoefficients.initialize(repeating: 0, count: words)
        toCoefficients.initialize(repeating: 0, count: words)
        pendingCoefficients.initialize(repeating: 0, count: words)
        for pair in 0..<pairs {
            Self.write(.identity, to: fromCoefficients, pair: pair)
            Self.write(.identity, to: toCoefficients, pair: pair)
            Self.write(.identity, to: pendingCoefficients, pair: pair)
        }

        pendingGeneration = .allocate(capacity: pairs)
        for index in 0..<pairs { sc_atomic_init(pendingGeneration.advanced(by: index), 0) }
        appliedGeneration = .allocate(capacity: pairs)
        appliedGeneration.initialize(repeating: 0, count: pairs)
        fadeRemaining = .allocate(capacity: pairs)
        fadeRemaining.initialize(repeating: 0, count: pairs)

        clipCounter = .allocate(capacity: 1)
        sc_atomic_init(clipCounter, 0)
    }

    deinit {
        let words = pairCount * Coefficient.count
        fromCoefficients.deinitialize(count: words)
        fromCoefficients.deallocate()
        toCoefficients.deinitialize(count: words)
        toCoefficients.deallocate()
        pendingCoefficients.deinitialize(count: words)
        pendingCoefficients.deallocate()
        pendingGeneration.deallocate()
        appliedGeneration.deinitialize(count: pairCount)
        appliedGeneration.deallocate()
        fadeRemaining.deinitialize(count: pairCount)
        fadeRemaining.deallocate()
        clipCounter.deallocate()
    }

    private static func write(
        _ matrix: ChannelMatrix,
        to buffer: UnsafeMutablePointer<Float>,
        pair: Int
    ) {
        let base = pair * Coefficient.count
        buffer[base + Coefficient.leftToLeft] = Float(matrix.leftToLeft)
        buffer[base + Coefficient.rightToLeft] = Float(matrix.rightToLeft)
        buffer[base + Coefficient.leftToRight] = Float(matrix.leftToRight)
        buffer[base + Coefficient.rightToRight] = Float(matrix.rightToRight)
    }

    // MARK: - Diagnostics

    /// Samples clamped by the output limiter since the counter was last reset.
    public var clipCount: Int64 { sc_atomic_load_acquire(clipCounter) }

    public func resetClipCount() {
        sc_atomic_store_release(clipCounter, 0)
    }

    /// True when at least one pair has a matrix that changes the signal.
    public var isEngaged: Bool {
        paramLock.withLock {
            lastRequested.contains { ($0?.isNeutral ?? true) == false }
        }
    }

    // MARK: - App thread

    /// Publish a matrix for one channel pair.
    ///
    /// Idempotent: re-publishing what a pair already has returns immediately,
    /// so the Router can re-apply the whole map on every replan without
    /// spending a ramp per reconcile.
    ///
    /// - Returns: whether anything was actually published.
    @discardableResult
    public func setSettings(_ settings: ChannelMatrixSettings, pair: Int) -> Bool {
        guard pair >= 0, pair < pairCount else { return false }
        let clean = settings.sanitized()
        // The transcendental work (`pow` per coefficient) happens here, before
        // the lock: the render thread may be waiting on it for a fixed-size
        // copy of four floats.
        let matrix = clean.matrix
        return paramLock.withLock {
            if lastRequested[pair] == clean { return false }
            lastRequested[pair] = clean
            Self.write(matrix, to: pendingCoefficients, pair: pair)
            // Release store: the coefficients above must be visible to the
            // render thread before it can observe the new generation.
            let next = sc_atomic_load_acquire(pendingGeneration.advanced(by: pair)) &+ 1
            sc_atomic_store_release(pendingGeneration.advanced(by: pair), next)
            return true
        }
    }

    /// Publish `.stereo` to every pair. Used when an output is torn down so a
    /// rebuilt one never inherits the previous device's assignment.
    public func resetAll() {
        for pair in 0..<pairCount {
            setSettings(.stereo, pair: pair)
        }
    }

    /// The settings last accepted, indexed by pair. For diagnostics and tests.
    public func requestedSettings() -> [ChannelMatrixSettings] {
        paramLock.withLock {
            lastRequested.map { $0 ?? .stereo }
        }
    }

    // MARK: - Render thread

    /// Apply one channel pair's matrix in place.
    ///
    /// - Parameters:
    ///   - pair: channel-pair index (0 = first physical device in aggregate
    ///     mode).
    ///   - channels: the caller's per-channel pointer table.
    ///   - channelOffset: index of this pair's first channel in that table.
    ///   - channelCount: channels in this pair.
    ///   - frames: frames in the block.
    public func process(
        pair: Int,
        channels: UnsafeMutablePointer<UnsafeMutablePointer<Float>>,
        channelOffset: Int,
        channelCount: Int,
        frames: Int
    ) {
        guard pair >= 0, pair < pairCount else { return }
        guard frames > 0, frames <= Self.maxFramesPerBlock else { return }
        guard channelCount >= Self.requiredChannelsPerPair,
              channelsPerPair >= Self.requiredChannelsPerPair
        else { return }

        adoptPending(pair: pair)

        let base = pair * Coefficient.count
        let remaining = Int(fadeRemaining[pair])
        if remaining <= 0 {
            let a = fromCoefficients[base + Coefficient.leftToLeft]
            let b = fromCoefficients[base + Coefficient.rightToLeft]
            let c = fromCoefficients[base + Coefficient.leftToRight]
            let d = fromCoefficients[base + Coefficient.rightToRight]
            if a == 1, b == 0, c == 0, d == 1 {
                // Fast path: plain stereo. The buffer is left byte-identical to
                // what the caller handed us.
                return
            }
            apply(
                left: channels[channelOffset],
                right: channels[channelOffset + 1],
                frames: frames,
                a: a, b: b, c: c, d: d
            )
            return
        }
        rampAndApply(pair: pair, base: base, remaining: remaining,
                     left: channels[channelOffset],
                     right: channels[channelOffset + 1],
                     frames: frames)
    }

    // MARK: - Render-thread internals

    /// Take the app thread's staged coefficients, if there are newer ones.
    ///
    /// A publish that lands mid-ramp starts a NEW ramp from wherever the
    /// interpolation currently sits (`fromCoefficients` is rewritten to the
    /// live value by `rampAndApply` as the ramp advances), so a user dragging a
    /// slider gets one continuous glide rather than a step back to the
    /// previous matrix.
    private func adoptPending(pair: Int) {
        let generation = sc_atomic_load_acquire(pendingGeneration.advanced(by: pair))
        guard generation != appliedGeneration[pair] else { return }
        let base = pair * Coefficient.count
        paramLock.withLock {
            for index in 0..<Coefficient.count {
                toCoefficients[base + index] = pendingCoefficients[base + index]
            }
        }
        appliedGeneration[pair] = generation
        fadeRemaining[pair] = Int32(fadeFrames)
    }

    /// Interpolate the four coefficients across the block and apply them.
    ///
    /// The interpolation runs to `min(frames, remaining)` and then holds the
    /// target, so a block longer than the rest of the ramp finishes it rather
    /// than overshooting.
    private func rampAndApply(
        pair: Int,
        base: Int,
        remaining: Int,
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        frames: Int
    ) {
        let a0 = fromCoefficients[base + Coefficient.leftToLeft]
        let b0 = fromCoefficients[base + Coefficient.rightToLeft]
        let c0 = fromCoefficients[base + Coefficient.leftToRight]
        let d0 = fromCoefficients[base + Coefficient.rightToRight]
        let a1 = toCoefficients[base + Coefficient.leftToLeft]
        let b1 = toCoefficients[base + Coefficient.rightToLeft]
        let c1 = toCoefficients[base + Coefficient.leftToRight]
        let d1 = toCoefficients[base + Coefficient.rightToRight]

        let start = Float(fadeFrames - remaining) / Float(fadeFrames)
        let step = 1 / Float(fadeFrames)
        var position = start
        var clipped: Int64 = 0
        for index in 0..<frames {
            let weight = position < 1 ? position : 1
            let inverse = 1 - weight
            let a = a0 * inverse + a1 * weight
            let b = b0 * inverse + b1 * weight
            let c = c0 * inverse + c1 * weight
            let d = d0 * inverse + d1 * weight
            let inLeft = left[index]
            let inRight = right[index]
            let (outLeft, leftClips) = Self.limit(a * inLeft + b * inRight)
            let (outRight, rightClips) = Self.limit(c * inLeft + d * inRight)
            left[index] = outLeft
            right[index] = outRight
            clipped &+= leftClips + rightClips
            position += step
        }
        if clipped > 0 { _ = sc_atomic_fetch_add(clipCounter, clipped) }

        let consumed = min(remaining, frames)
        let newRemaining = remaining - consumed
        fadeRemaining[pair] = Int32(newRemaining)
        // Park the ramp's origin at where it actually got to, so a publish
        // arriving mid-ramp glides on from here.
        let reached = Float(fadeFrames - newRemaining) / Float(fadeFrames)
        let inverse = 1 - reached
        fromCoefficients[base + Coefficient.leftToLeft] = a0 * inverse + a1 * reached
        fromCoefficients[base + Coefficient.rightToLeft] = b0 * inverse + b1 * reached
        fromCoefficients[base + Coefficient.leftToRight] = c0 * inverse + c1 * reached
        fromCoefficients[base + Coefficient.rightToRight] = d0 * inverse + d1 * reached
    }

    /// The steady-state multiply-add, with no per-sample interpolation.
    private func apply(
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        frames: Int,
        a: Float, b: Float, c: Float, d: Float
    ) {
        var clipped: Int64 = 0
        for index in 0..<frames {
            let inLeft = left[index]
            let inRight = right[index]
            let (outLeft, leftClips) = Self.limit(a * inLeft + b * inRight)
            let (outRight, rightClips) = Self.limit(c * inLeft + d * inRight)
            left[index] = outLeft
            right[index] = outRight
            clipped &+= leftClips + rightClips
        }
        if clipped > 0 { _ = sc_atomic_fetch_add(clipCounter, clipped) }
    }

    /// Hard limiter plus NaN backstop. A matrix can sum two full-scale channels
    /// or boost by up to +6 dB, and handing CoreAudio a value outside ±1 is far
    /// worse than clamping; the count is what tells the user to back it off.
    @inline(__always)
    private static func limit(_ value: Float) -> (Float, Int64) {
        if !value.isFinite { return (0, 1) }
        if value > 1 { return (1, 1) }
        if value < -1 { return (-1, 1) }
        return (value, 0)
    }
}
