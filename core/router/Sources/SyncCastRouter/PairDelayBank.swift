import Foundation
import os.lock
import SyncCastAtomic

/// Per-channel-pair read offsets for one `LocalOutput`, plus the crossfade
/// that makes a change to one inaudible.
///
/// In aggregate mode a channel pair is one physical device, so an offset here
/// is "hold this speaker back by N frames": pair `p` reads the shared ring at
/// `startFrame + readOffsetFrames(pair: p)`, and a pair with a LARGER offset
/// reads OLDER audio and therefore sounds later. Offsets are non-negative by
/// construction — nothing can be played early — and are produced by
/// `LocalDelayTrimPlanner`.
///
/// # The window, and why the cursor moves with it
///
/// The render cursor is a single number shared by every pair, so the bank
/// publishes a `window` = the largest offset in play, and pair `p` reads at
/// `cursor + window − offset(p)`. The most-delayed pair therefore reads at the
/// cursor itself and the least-delayed one reads `window` frames ahead of it,
/// which is why `RingReadPlanner` has to know the window: the block it plans
/// must have `window` frames of written audio ABOVE the cursor, not just one
/// block's worth.
///
/// When the window itself changes (a device's trim moved, or a fade ended and
/// the window shrank), every pair's absolute read position would jump by the
/// same amount — including pairs the user did not touch. `adoptPublishedChanges`
/// therefore reports a `cursorShift` of `oldWindow − newWindow`, which the
/// caller adds to the cursor before planning. Untouched pairs then land on
/// exactly the sample they would have read anyway, and only the pair whose own
/// offset moved sees a discontinuity — which is the one the crossfade covers.
///
/// # Real-time contract
///
/// Everything the render thread calls is integer arithmetic over
/// heap-allocated storage owned for the lifetime of the bank: no allocation,
/// no CoreAudio, and `paramLock` is taken only on the block that adopts a
/// publish. Steady state is one atomic load per block.
public final class PairDelayBank {
    /// Crossfade length for an offset change. Matches `EqualizerBank`'s: long
    /// enough that a full-scale jump in read position is not a click, short
    /// enough that a slider still feels live against the menubar's ~50 ms
    /// commit debounce.
    public static let fadeMilliseconds: Double = 20

    public let pairCount: Int
    public let sampleRate: Double
    /// Crossfade length in frames. Never 0 — a zero-length fade would divide
    /// by zero in the weight calculation.
    public let fadeFrames: Int

    // MARK: App-thread staging → render thread

    /// Offsets the app thread wants, in frames. Written under `paramLock`,
    /// read by the render thread on the block it adopts them.
    private let pendingOffsets: UnsafeMutablePointer<Int32>
    /// Bumped after `pendingOffsets` is filled; compared by the render thread
    /// against `appliedGeneration`. This is the whole publish protocol.
    private let pendingGeneration: UnsafeMutablePointer<SCAtomicInt64>
    private let paramLock = OSAllocatedUnfairLock()
    /// Last offsets accepted, so a Router that re-pushes an unchanged map on
    /// every reconcile does not spend a crossfade per reconcile.
    private var lastRequested: [Int32]

    // MARK: Render-thread-owned state

    /// The offset each pair is being read at right now.
    private let activeOffsets: UnsafeMutablePointer<Int32>
    /// The offset each pair is fading OUT of. Equal to `activeOffsets` when no
    /// fade is running.
    private let previousOffsets: UnsafeMutablePointer<Int32>
    /// Frames of crossfade left per pair; 0 means "settled".
    private let fadeRemaining: UnsafeMutablePointer<Int32>
    private var appliedGeneration: Int64 = 0
    private var currentWindow: Int64 = 0
    /// True while every pair is at 0 with no fade running — the flag that lets
    /// `LocalOutput.render()` take its original single-read splat path and
    /// stay bit-identical to the pre-feature build.
    private var settledAtZero: Bool = true

    public init(pairCount: Int, sampleRate: Double) {
        let pairs = max(1, pairCount)
        self.pairCount = pairs
        self.sampleRate = sampleRate > 0 ? sampleRate : 48_000
        self.fadeFrames = max(
            1, Int((self.sampleRate * Self.fadeMilliseconds / 1000).rounded())
        )
        self.lastRequested = Array(repeating: 0, count: pairs)
        pendingOffsets = .allocate(capacity: pairs)
        pendingOffsets.initialize(repeating: 0, count: pairs)
        activeOffsets = .allocate(capacity: pairs)
        activeOffsets.initialize(repeating: 0, count: pairs)
        previousOffsets = .allocate(capacity: pairs)
        previousOffsets.initialize(repeating: 0, count: pairs)
        fadeRemaining = .allocate(capacity: pairs)
        fadeRemaining.initialize(repeating: 0, count: pairs)
        let generation = UnsafeMutablePointer<SCAtomicInt64>.allocate(capacity: 1)
        sc_atomic_init(generation, 0)
        pendingGeneration = generation
    }

    deinit {
        pendingOffsets.deinitialize(count: pairCount)
        pendingOffsets.deallocate()
        activeOffsets.deinitialize(count: pairCount)
        activeOffsets.deallocate()
        previousOffsets.deinitialize(count: pairCount)
        previousOffsets.deallocate()
        fadeRemaining.deinitialize(count: pairCount)
        fadeRemaining.deallocate()
        pendingGeneration.deallocate()
    }

    // MARK: - App thread

    /// Publish the whole pair → offset map. Absent pairs are 0, which is what
    /// makes "the user cleared this device's trim" and "the user never set
    /// one" the same input.
    ///
    /// Idempotent: re-publishing the same map returns false without touching
    /// the render thread, so the Router can re-apply on every reconcile.
    @discardableResult
    public func setOffsets(_ framesByPair: [Int: Int]) -> Bool {
        // Built through an immediately-applied closure so the array the lock
        // closure captures is a `let`: capturing a `var` across a
        // non-escaping-but-Sendable closure is an error under Swift 6.
        let requested: [Int32] = {
            var out = Array(repeating: Int32(0), count: pairCount)
            for (pair, frames) in framesByPair {
                guard pair >= 0, pair < pairCount else { continue }
                // Negative offsets are meaningless (nothing plays early) and
                // would make the render read past the write head. Clamp rather
                // than reject: the planner already guarantees non-negative
                // values, and a caller that gets it wrong should lose the
                // trim, not the audio.
                out[pair] = Int32(max(0, frames))
            }
            return out
        }()
        return paramLock.withLock {
            guard requested != lastRequested else { return false }
            lastRequested = requested
            for pair in 0..<pairCount { pendingOffsets[pair] = requested[pair] }
            sc_atomic_store_release(
                pendingGeneration, sc_atomic_load_acquire(pendingGeneration) &+ 1
            )
            return true
        }
    }

    /// Drop every pair back to 0. Used when an output is repurposed so a
    /// rebuilt aggregate never inherits the previous device set's offsets.
    public func resetOffsets() {
        setOffsets([:])
    }

    /// The offsets last accepted from the app thread, for tests and reports.
    public func requestedOffsets() -> [Int] {
        paramLock.withLock { lastRequested.map(Int.init) }
    }

    // MARK: - Render thread

    /// Adopt anything the app thread published and report how far the read
    /// cursor must move so untouched pairs stay continuous.
    ///
    /// Call once per render block, BEFORE planning the read.
    ///
    /// - Returns: the read window (largest offset in play, fades included) and
    ///   the signed shift to add to the read cursor.
    public func adoptPublishedChanges() -> (window: Int64, cursorShift: Int64) {
        let published = sc_atomic_load_acquire(pendingGeneration)
        if published != appliedGeneration {
            paramLock.withLock {
                for pair in 0..<pairCount {
                    let next = pendingOffsets[pair]
                    guard next != activeOffsets[pair] else { continue }
                    // A change arriving mid-fade restarts the fade from
                    // wherever the pair is nominally reading now. The dropped
                    // tail of the old fade is a partial-amplitude step, far
                    // smaller than the position jump it is replacing, and it
                    // takes a second change inside 20 ms to happen at all.
                    previousOffsets[pair] = activeOffsets[pair]
                    activeOffsets[pair] = next
                    fadeRemaining[pair] = Int32(fadeFrames)
                }
            }
            appliedGeneration = published
        }
        var window: Int64 = 0
        var allZero = true
        for pair in 0..<pairCount {
            let active = Int64(activeOffsets[pair])
            if active != 0 { allZero = false }
            window = max(window, active)
            if fadeRemaining[pair] > 0 {
                allZero = false
                window = max(window, Int64(previousOffsets[pair]))
            }
        }
        settledAtZero = allZero
        let shift = currentWindow - window
        currentWindow = window
        return (window: window, cursorShift: shift)
    }

    /// True while nothing is dialled in and no fade is running. The caller's
    /// fast path.
    public var isSettledAtZero: Bool { settledAtZero }

    /// The read window last computed by `adoptPublishedChanges`.
    public var window: Int64 { currentWindow }

    /// Frames to add to the planned start frame for this pair's read. Larger
    /// offset ⇒ smaller lead ⇒ older audio ⇒ this speaker sounds later.
    public func readLeadFrames(pair: Int) -> Int64 {
        guard pair >= 0, pair < pairCount else { return currentWindow }
        return currentWindow - Int64(activeOffsets[pair])
    }

    /// Same, for the offset this pair is fading out of. Meaningless unless
    /// `fadeRemainingFrames(pair:) > 0`.
    public func previousReadLeadFrames(pair: Int) -> Int64 {
        guard pair >= 0, pair < pairCount else { return currentWindow }
        return currentWindow - Int64(previousOffsets[pair])
    }

    public func fadeRemainingFrames(pair: Int) -> Int {
        guard pair >= 0, pair < pairCount else { return 0 }
        return Int(fadeRemaining[pair])
    }

    /// Weight of the NEW read position for sample `index` of a block that
    /// started with `remaining` frames of fade left.
    ///
    /// Linear, matching `EqualizerBank`'s crossfade. For a small offset change
    /// the two windows are strongly correlated and linear is exactly right;
    /// for a large one they are not, and the midpoint dips ~3 dB for 10 ms.
    /// An equal-power law would fix the large case and put a matching +3 dB
    /// bump on the small one, which is the more common edit — so linear is the
    /// deliberate choice, not an oversight.
    public static func fadeWeight(remaining: Int, index: Int, fadeFrames: Int) -> Float {
        guard fadeFrames > 0 else { return 1 }
        let elapsed = fadeFrames - remaining + index
        if elapsed <= 0 { return 0 }
        if elapsed >= fadeFrames { return 1 }
        return Float(elapsed) / Float(fadeFrames)
    }

    /// Advance every running fade by a rendered block. A fade that completes
    /// collapses `previousOffsets` onto `activeOffsets`, which is what lets
    /// the window shrink again.
    public func advance(frames: Int) {
        guard frames > 0 else { return }
        for pair in 0..<pairCount where fadeRemaining[pair] > 0 {
            let left = fadeRemaining[pair] - Int32(min(frames, Int(Int32.max)))
            if left <= 0 {
                fadeRemaining[pair] = 0
                previousOffsets[pair] = activeOffsets[pair]
            } else {
                fadeRemaining[pair] = left
            }
        }
    }

    /// Discard render-thread state. Called wherever the output's glitch
    /// counters are zeroed, so a restarted AUHAL does not inherit a
    /// half-finished crossfade or a stale window.
    public func resetRenderState() {
        for pair in 0..<pairCount {
            previousOffsets[pair] = activeOffsets[pair]
            fadeRemaining[pair] = 0
        }
        currentWindow = 0
        for pair in 0..<pairCount {
            currentWindow = max(currentWindow, Int64(activeOffsets[pair]))
        }
        settledAtZero = currentWindow == 0
    }
}
