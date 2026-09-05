import Foundation
import os.lock
import SyncCastAtomic

/// Real-time stereo imaging for one output: mid/side width plus recursive
/// crosstalk cancellation, per output channel pair (= per physical speaker in
/// aggregate mode).
///
/// # Real-time contract
///
/// `process()` runs on the CoreAudio render thread. It never allocates, never
/// calls into CoreAudio, and takes `paramLock` only on the block where the app
/// thread has published new parameters — steady state is one atomic load per
/// pair per block. Filter coefficients and the derived delay are computed on
/// the app thread in `setSettings()` (`pow`/`sin`/`cos` have no place on a
/// render thread) and handed over through a staging buffer.
///
/// # Signal flow, per pair
///
/// ```
/// L,R ─┬─ mid/side width ─┬─ band split ─┬─ RACE recursion ─┬─ + ─ clamp ─→ L',R'
///      │                  │              └─ out-of-band ────┘
///      └─ (stage off: untouched)
/// ```
///
/// 1. **Width.** `M=(L+R)/2`, `S=(L−R)/2`, `S' = S + (width−1)·HP(S)`,
///    `L' = midGain·M + S'`, `R' = midGain·M − S'`. Mono-compatible by
///    construction: `L'+R' = 2·midGain·M` for any width.
/// 2. **Crosstalk.** The band between `lowHz` and `highHz` is split off with
///    matched second-order Butterworth sections, the remainder is carried
///    around the stage unprocessed (`rest = x − band`, so the two sum back to
///    the input *exactly* when the recursion is a no-op), and the band runs
///    through `L' = L − a·z^(−τ)·R'`, `R' = R − a·z^(−τ)·L'`.
///
/// # Why two parameter banks and a crossfade
///
/// The same reason `EqualizerBank` has them: swapping coefficients — or, here,
/// a delay length — under a running filter puts a step in the output. Each
/// pair owns TWO parameter banks with their own filter state and delay lines.
/// On a publish the new parameters land in the idle bank, its state is seeded
/// from the audible bank's (so a small slider move is continuous rather than a
/// restart), and both are run in parallel for `fadeMilliseconds` while their
/// outputs are linearly crossfaded.
///
/// # Fractional delay
///
/// τ is derived from geometry and is not a whole number of samples (≈5.5 at
/// 48 kHz for the default cabinet), so the recursion reads its own past output
/// through a **linear (first-order Lagrange) interpolator**. That choice over
/// a Thiran allpass is deliberate: linear interpolation has magnitude ≤ 1 at
/// every frequency, so the loop gain is bounded by `a²` and stability needs no
/// argument beyond `|a| < 1`. The price is a first-order lowpass on the
/// crosstalk path — worst case (fractional part 0.5) about −0.95 dB at 7 kHz
/// and −0.25 dB at 3.5 kHz — which *under*-cancels slightly at the top of the
/// band rather than overshooting, the conservative direction for an effect
/// whose failure mode is an unstable, phasey image.
public final class StereoImageProcessor {

    /// Crossfade length for a parameter change. Matches `EqualizerBank`'s, so
    /// a user dragging either panel's sliders gets the same feel.
    public static let fadeMilliseconds: Double = 20

    /// Largest block the render thread may hand us. Matches
    /// `LocalOutput.stagingFrameCapacity`; a longer block is refused rather
    /// than served from a short scratch buffer.
    public static let maxFramesPerBlock: Int = 4096

    /// Channels the module is defined on. Width and crosstalk are both
    /// statements about a left/right pair; there is no meaningful mono or
    /// 5.1 reading of either.
    public static let requiredChannelsPerPair: Int = 2

    /// Backstop on the value stored in the delay line. The recursion is
    /// provably stable for `|a| < 1` and its worst-case gain on correlated
    /// content is `1/(1−a)` ≤ 20, so nothing legitimate comes near this; it
    /// exists so that a single corrupt sample cannot be recirculated forever.
    private static let feedbackCeiling: Double = 32

    public let pairCount: Int
    public let channelsPerPair: Int
    public let sampleRate: Double

    private let fadeFrames: Int

    // MARK: Parameter block layout
    //
    // One flat `Double` block per (pair, bank). Indices are constants rather
    // than a struct so the render thread reads them by offset with no
    // pointer-to-struct rebinding.

    private enum Parameter {
        static let widthMinusOne = 0
        static let midGain = 1
        static let sideHighpass = 2         // 5 coefficients
        static let feedback = 7
        static let delaySamples = 8
        static let bandHighpass = 9         // 5 coefficients
        static let bandLowpass = 14         // 5 coefficients
        static let count = 19
    }

    private enum Flag {
        static let widthActive = 0
        static let crosstalkActive = 1
        static let lowSplitActive = 2
        static let highSplitActive = 3
        static let identity = 4
        static let count = 5
    }

    // MARK: Storage
    //
    // All heap-allocated once at init and indexed directly: a Swift Array
    // would be copy-on-write, and a COW copy on the render thread is a heap
    // allocation in an audio callback.

    /// `pairCount * 2` banks of `Parameter.count` doubles.
    private let bankParameters: UnsafeMutablePointer<Double>
    /// `pairCount * 2` banks of `Flag.count` bytes.
    private let bankFlags: UnsafeMutablePointer<UInt8>
    /// Filter state, `stateWordsPerBank` per bank: side high-pass (2), band
    /// high-pass (2 per channel), band low-pass (2 per channel).
    private let bankFilterState: UnsafeMutablePointer<Double>
    /// Recursion output history, `delayLineLength` per channel per bank.
    private let bankDelayLine: UnsafeMutablePointer<Double>
    /// Where the next output sample goes in each bank's delay lines.
    private let bankDelayWrite: UnsafeMutablePointer<Int32>

    /// App-thread staging, read by the render thread under `paramLock` on the
    /// block it adopts the publish.
    private let pendingParameters: UnsafeMutablePointer<Double>
    private let pendingFlags: UnsafeMutablePointer<UInt8>
    /// Bumped by the app thread after the staging slot is filled; compared by
    /// the render thread against `appliedGeneration`.
    private let pendingGeneration: UnsafeMutablePointer<SCAtomicInt64>

    // Render-thread-owned bookkeeping. Written only by `process()`.
    private let appliedGeneration: UnsafeMutablePointer<Int64>
    private let activeBank: UnsafeMutablePointer<Int32>
    private let fadeRemaining: UnsafeMutablePointer<Int32>

    /// Double-precision working buffers, one block wide per channel.
    /// `scratchA` carries the audible chain, `scratchB` the incoming one
    /// during a crossfade. Shared across pairs because `process()` is called
    /// for one pair at a time on one thread.
    private let scratchA: UnsafeMutablePointer<Double>
    private let scratchB: UnsafeMutablePointer<Double>

    /// Samples the output clamp had to limit. Published lock-free for the
    /// diagnostics line; non-zero means the crosstalk recursion's own
    /// colouration peak is driving the output past full scale.
    private let clipCounter: UnsafeMutablePointer<SCAtomicInt64>

    private let paramLock = OSAllocatedUnfairLock()
    /// Last settings accepted per pair, so a reconcile that re-pushes the same
    /// values does not spend a crossfade. App-thread state, guarded by
    /// `paramLock` because the Router actor may hop threads between calls.
    private var lastRequested: [StereoImageSettings?]

    private var filterWordsPerBank: Int { 2 + channelsPerPair * 4 }
    private var delayWordsPerBank: Int { channelsPerPair * StereoImageLimits.delayLineLength }

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

        let bankSlots = pairs * 2
        let filterWords = 2 + channels * 4
        let delayWords = channels * StereoImageLimits.delayLineLength

        bankParameters = .allocate(capacity: bankSlots * Parameter.count)
        bankParameters.initialize(repeating: 0, count: bankSlots * Parameter.count)
        bankFlags = .allocate(capacity: bankSlots * Flag.count)
        bankFlags.initialize(repeating: 0, count: bankSlots * Flag.count)
        for slot in 0..<bankSlots {
            bankFlags[slot * Flag.count + Flag.identity] = 1
            bankParameters[slot * Parameter.count + Parameter.midGain] = 1
            bankParameters[slot * Parameter.count + Parameter.delaySamples] = 1
        }
        bankFilterState = .allocate(capacity: bankSlots * filterWords)
        bankFilterState.initialize(repeating: 0, count: bankSlots * filterWords)
        bankDelayLine = .allocate(capacity: bankSlots * delayWords)
        bankDelayLine.initialize(repeating: 0, count: bankSlots * delayWords)
        bankDelayWrite = .allocate(capacity: bankSlots)
        bankDelayWrite.initialize(repeating: 0, count: bankSlots)

        pendingParameters = .allocate(capacity: pairs * Parameter.count)
        pendingParameters.initialize(repeating: 0, count: pairs * Parameter.count)
        pendingFlags = .allocate(capacity: pairs * Flag.count)
        pendingFlags.initialize(repeating: 0, count: pairs * Flag.count)
        for pair in 0..<pairs {
            pendingFlags[pair * Flag.count + Flag.identity] = 1
            pendingParameters[pair * Parameter.count + Parameter.midGain] = 1
            pendingParameters[pair * Parameter.count + Parameter.delaySamples] = 1
        }
        pendingGeneration = .allocate(capacity: pairs)
        for index in 0..<pairs { sc_atomic_init(pendingGeneration.advanced(by: index), 0) }

        appliedGeneration = .allocate(capacity: pairs)
        appliedGeneration.initialize(repeating: 0, count: pairs)
        activeBank = .allocate(capacity: pairs)
        activeBank.initialize(repeating: 0, count: pairs)
        fadeRemaining = .allocate(capacity: pairs)
        fadeRemaining.initialize(repeating: 0, count: pairs)

        scratchA = .allocate(capacity: Self.maxFramesPerBlock * channels)
        scratchA.initialize(repeating: 0, count: Self.maxFramesPerBlock * channels)
        scratchB = .allocate(capacity: Self.maxFramesPerBlock * channels)
        scratchB.initialize(repeating: 0, count: Self.maxFramesPerBlock * channels)

        clipCounter = .allocate(capacity: 1)
        sc_atomic_init(clipCounter, 0)
    }

    deinit {
        let bankSlots = pairCount * 2
        bankParameters.deinitialize(count: bankSlots * Parameter.count)
        bankParameters.deallocate()
        bankFlags.deinitialize(count: bankSlots * Flag.count)
        bankFlags.deallocate()
        bankFilterState.deinitialize(count: bankSlots * filterWordsPerBank)
        bankFilterState.deallocate()
        bankDelayLine.deinitialize(count: bankSlots * delayWordsPerBank)
        bankDelayLine.deallocate()
        bankDelayWrite.deinitialize(count: bankSlots)
        bankDelayWrite.deallocate()
        pendingParameters.deinitialize(count: pairCount * Parameter.count)
        pendingParameters.deallocate()
        pendingFlags.deinitialize(count: pairCount * Flag.count)
        pendingFlags.deallocate()
        pendingGeneration.deallocate()
        appliedGeneration.deinitialize(count: pairCount)
        appliedGeneration.deallocate()
        activeBank.deinitialize(count: pairCount)
        activeBank.deallocate()
        fadeRemaining.deinitialize(count: pairCount)
        fadeRemaining.deallocate()
        scratchA.deinitialize(count: Self.maxFramesPerBlock * channelsPerPair)
        scratchA.deallocate()
        scratchB.deinitialize(count: Self.maxFramesPerBlock * channelsPerPair)
        scratchB.deallocate()
        clipCounter.deallocate()
    }

    // MARK: - Diagnostics

    /// Samples clamped by the output limiter since the counter was last reset.
    public var clipCount: Int64 { sc_atomic_load_acquire(clipCounter) }

    public func resetClipCount() {
        sc_atomic_store_release(clipCounter, 0)
    }

    /// True when at least one pair has a setting that changes the signal.
    public var isEngaged: Bool {
        paramLock.withLock {
            lastRequested.contains { ($0?.isNeutral ?? true) == false }
        }
    }

    // MARK: - App thread

    /// Publish a setting for one channel pair.
    ///
    /// Idempotent: re-publishing what a pair already has returns immediately,
    /// so the Router can re-apply the whole map on every replan without
    /// spending a crossfade per reconcile.
    ///
    /// - Returns: whether anything was actually published.
    @discardableResult
    public func setSettings(_ settings: StereoImageSettings, pair: Int) -> Bool {
        guard pair >= 0, pair < pairCount else { return false }
        let clean = settings.sanitized()
        let engaged = !clean.isNeutral

        // All the transcendental work happens here, OUTSIDE the lock: the
        // render thread may be waiting on the same lock for a fixed-size copy.
        let widthActive = engaged && !clean.width.isNeutral
        let sideHighpass = widthActive
            ? StereoImageFilter.highpass(
                cornerHz: clean.width.cornerHz, sampleRate: sampleRate
            )
            : .identity
        // A corner the section could not be built for (only reachable at an
        // absurd sample rate) degrades to "no width", never to an unfiltered
        // full-band side boost — that would be a loud surprise, not a subtle
        // one.
        let widthUsable = widthActive && sideHighpass != .identity
        let widthMinusOne = widthUsable ? clean.width.width - 1 : 0
        let midGain = widthUsable ? clean.width.midAmplitude : 1

        let crosstalkActive = engaged && !clean.crosstalk.isNeutral
        let feedback = crosstalkActive ? clean.crosstalk.feedbackAmplitude : 0
        let delaySamples = clean.crosstalk.delaySamples(sampleRate: sampleRate)
        let lowSplit = crosstalkActive
            && StereoImageLimits.lowSplitIsEngaged(clean.crosstalk.lowHz)
        let highSplit = crosstalkActive
            && StereoImageLimits.highSplitIsEngaged(
                clean.crosstalk.highHz, sampleRate: sampleRate
            )
        let bandHighpass = lowSplit
            ? StereoImageFilter.highpass(
                cornerHz: clean.crosstalk.lowHz, sampleRate: sampleRate
            )
            : .identity
        let bandLowpass = highSplit
            ? StereoImageFilter.lowpass(
                cornerHz: clean.crosstalk.highHz, sampleRate: sampleRate
            )
            : .identity
        let lowSplitUsable = lowSplit && bandHighpass != .identity
        let highSplitUsable = highSplit && bandLowpass != .identity
        let crosstalkUsable = crosstalkActive && feedback > 0
        let identity = !widthUsable && !crosstalkUsable

        return paramLock.withLock {
            if lastRequested[pair] == clean { return false }
            lastRequested[pair] = clean
            let base = pair * Parameter.count
            pendingParameters[base + Parameter.widthMinusOne] = widthMinusOne
            pendingParameters[base + Parameter.midGain] = midGain
            write(sideHighpass, to: pendingParameters, at: base + Parameter.sideHighpass)
            pendingParameters[base + Parameter.feedback] = feedback
            pendingParameters[base + Parameter.delaySamples] = delaySamples
            write(bandHighpass, to: pendingParameters, at: base + Parameter.bandHighpass)
            write(bandLowpass, to: pendingParameters, at: base + Parameter.bandLowpass)

            let flags = pair * Flag.count
            pendingFlags[flags + Flag.widthActive] = widthUsable ? 1 : 0
            pendingFlags[flags + Flag.crosstalkActive] = crosstalkUsable ? 1 : 0
            pendingFlags[flags + Flag.lowSplitActive] = lowSplitUsable ? 1 : 0
            pendingFlags[flags + Flag.highSplitActive] = highSplitUsable ? 1 : 0
            pendingFlags[flags + Flag.identity] = identity ? 1 : 0

            // Release store: everything above must be visible to the render
            // thread before it can observe the new generation.
            let next = sc_atomic_load_acquire(pendingGeneration.advanced(by: pair)) &+ 1
            sc_atomic_store_release(pendingGeneration.advanced(by: pair), next)
            return true
        }
    }

    /// Publish `.neutral` to every pair. Used when an output is torn down so a
    /// rebuilt one never inherits the previous device's setting.
    public func resetAll() {
        for pair in 0..<pairCount {
            setSettings(.neutral, pair: pair)
        }
    }

    private func write(
        _ coefficients: BiquadCoefficients,
        to buffer: UnsafeMutablePointer<Double>,
        at index: Int
    ) {
        buffer[index] = coefficients.b0
        buffer[index + 1] = coefficients.b1
        buffer[index + 2] = coefficients.b2
        buffer[index + 3] = coefficients.a1
        buffer[index + 4] = coefficients.a2
    }

    // MARK: - Render thread

    /// Process one channel pair in place.
    ///
    /// - Parameters:
    ///   - pair: channel-pair index (0 = first physical device in aggregate
    ///     mode).
    ///   - channels: the render callback's per-channel pointer table.
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
        // Both stages are statements about a left/right pair. A pair that is
        // not stereo is left alone rather than half-processed.
        guard channelCount >= Self.requiredChannelsPerPair,
              channelsPerPair >= Self.requiredChannelsPerPair
        else { return }

        adoptPending(pair: pair)

        let fading = fadeRemaining[pair] > 0
        let current = Int(activeBank[pair])
        if !fading, bankFlags[slot(pair: pair, bank: current) * Flag.count + Flag.identity] == 1 {
            // Fast path: nothing engaged, no fade. The buffer is left
            // byte-identical to what the caller handed us.
            return
        }

        let left = channels[channelOffset]
        let right = channels[channelOffset + 1]
        let workLeftA = scratchA
        let workRightA = scratchA.advanced(by: Self.maxFramesPerBlock)
        for index in 0..<frames {
            workLeftA[index] = Double(left[index])
            workRightA[index] = Double(right[index])
        }

        var clipped: Int64 = 0
        if fading {
            let workLeftB = scratchB
            let workRightB = scratchB.advanced(by: Self.maxFramesPerBlock)
            for index in 0..<frames {
                workLeftB[index] = workLeftA[index]
                workRightB[index] = workRightA[index]
            }
            let outgoing = current
            let incoming = 1 - current
            // BOTH banks run over the whole block even once the mix reaches 1:
            // the outgoing bank's state (and delay line) has to stay current
            // until the fade is retired, or a second edit arriving mid-fade
            // would carry stale history into its own crossfade.
            run(pair: pair, bank: outgoing, left: workLeftA, right: workRightA, frames: frames)
            run(pair: pair, bank: incoming, left: workLeftB, right: workRightB, frames: frames)

            let remaining = Int(fadeRemaining[pair])
            let start = Double(fadeFrames - remaining) / Double(fadeFrames)
            let step = 1.0 / Double(fadeFrames)
            var position = start
            for index in 0..<frames {
                let mix = position < 1 ? position : 1
                workLeftA[index] = workLeftA[index] * (1 - mix) + workLeftB[index] * mix
                workRightA[index] = workRightA[index] * (1 - mix) + workRightB[index] * mix
                position += step
            }
            let consumed = min(remaining, frames)
            fadeRemaining[pair] = Int32(remaining - consumed)
            if fadeRemaining[pair] == 0 { activeBank[pair] = Int32(incoming) }
        } else {
            run(pair: pair, bank: current, left: workLeftA, right: workRightA, frames: frames)
        }

        clipped &+= writeBack(from: workLeftA, to: left, frames: frames)
        clipped &+= writeBack(from: workRightA, to: right, frames: frames)
        if clipped > 0 {
            _ = sc_atomic_fetch_add(clipCounter, clipped)
        }
    }

    // MARK: - Render-thread internals

    private func slot(pair: Int, bank: Int) -> Int { pair * 2 + bank }

    /// Take the app thread's staged parameters, if there are newer ones, seed
    /// the incoming bank from the audible one, and start a crossfade.
    ///
    /// The state carry-over is what makes a slider drag continuous: the
    /// incoming bank inherits the filter memories and the whole recursion
    /// history, so the only thing the crossfade has to cover is the difference
    /// the new parameters make — not a filter and a delay line starting from
    /// rest.
    private func adoptPending(pair: Int) {
        let generation = sc_atomic_load_acquire(pendingGeneration.advanced(by: pair))
        guard generation != appliedGeneration[pair] else { return }
        let current = Int(activeBank[pair])
        let target = 1 - current
        let targetSlot = slot(pair: pair, bank: target)
        let currentSlot = slot(pair: pair, bank: current)

        paramLock.withLock {
            let source = pair * Parameter.count
            let destination = targetSlot * Parameter.count
            for index in 0..<Parameter.count {
                bankParameters[destination + index] = pendingParameters[source + index]
            }
            let sourceFlags = pair * Flag.count
            let destinationFlags = targetSlot * Flag.count
            for index in 0..<Flag.count {
                bankFlags[destinationFlags + index] = pendingFlags[sourceFlags + index]
            }
        }

        let filterWords = filterWordsPerBank
        let targetFilter = targetSlot * filterWords
        let currentFilter = currentSlot * filterWords
        for index in 0..<filterWords {
            bankFilterState[targetFilter + index] = bankFilterState[currentFilter + index]
        }
        let delayWords = delayWordsPerBank
        let targetDelay = targetSlot * delayWords
        let currentDelay = currentSlot * delayWords
        for index in 0..<delayWords {
            bankDelayLine[targetDelay + index] = bankDelayLine[currentDelay + index]
        }
        bankDelayWrite[targetSlot] = bankDelayWrite[currentSlot]

        appliedGeneration[pair] = generation
        fadeRemaining[pair] = Int32(fadeFrames)
    }

    /// Run one bank's two stages over the block, in place.
    private func run(
        pair: Int,
        bank: Int,
        left: UnsafeMutablePointer<Double>,
        right: UnsafeMutablePointer<Double>,
        frames: Int
    ) {
        let bankSlot = slot(pair: pair, bank: bank)
        let flags = bankSlot * Flag.count
        let parameters = bankSlot * Parameter.count
        let filterBase = bankSlot * filterWordsPerBank

        if bankFlags[flags + Flag.widthActive] == 1 {
            runWidth(
                parameters: parameters,
                stateBase: filterBase,
                left: left, right: right, frames: frames
            )
        }
        if bankFlags[flags + Flag.crosstalkActive] == 1 {
            runCrosstalk(
                bankSlot: bankSlot,
                parameters: parameters,
                stateBase: filterBase + 2,
                lowSplit: bankFlags[flags + Flag.lowSplitActive] == 1,
                highSplit: bankFlags[flags + Flag.highSplitActive] == 1,
                left: left, right: right, frames: frames
            )
        }
    }

    /// `S' = S + (width−1)·HP(S)`, `M` scaled by the mid trim.
    ///
    /// The high-pass is run on the side signal only, so the mid path stays
    /// bit-exact apart from a single multiply — which is what keeps the mono
    /// sum untouched.
    private func runWidth(
        parameters: Int,
        stateBase: Int,
        left: UnsafeMutablePointer<Double>,
        right: UnsafeMutablePointer<Double>,
        frames: Int
    ) {
        let widthMinusOne = bankParameters[parameters + Parameter.widthMinusOne]
        let midGain = bankParameters[parameters + Parameter.midGain]
        let coefficients = parameters + Parameter.sideHighpass
        let b0 = bankParameters[coefficients]
        let b1 = bankParameters[coefficients + 1]
        let b2 = bankParameters[coefficients + 2]
        let a1 = bankParameters[coefficients + 3]
        let a2 = bankParameters[coefficients + 4]
        var s1 = bankFilterState[stateBase]
        var s2 = bankFilterState[stateBase + 1]

        for index in 0..<frames {
            let mid = (left[index] + right[index]) * 0.5
            let side = (left[index] - right[index]) * 0.5
            let highpassed = b0 * side + s1
            s1 = b1 * side - a1 * highpassed + s2
            s2 = b2 * side - a2 * highpassed
            let widened = side + widthMinusOne * highpassed
            let scaledMid = mid * midGain
            left[index] = scaledMid + widened
            right[index] = scaledMid - widened
        }
        bankFilterState[stateBase] = Self.flushDenormal(s1)
        bankFilterState[stateBase + 1] = Self.flushDenormal(s2)
    }

    /// Band-split + the recursive crosstalk canceller.
    ///
    /// `rest = x − band` rather than a second (low-pass) filter chain, so the
    /// split sums back to the input *exactly* when the recursion is a no-op —
    /// no crossover phase error, no summing dip at the band edges. What the
    /// out-of-band signal does see is the recursion's effect leaking through
    /// the filters' skirts, which falls at 12 dB/octave away from each edge.
    private func runCrosstalk(
        bankSlot: Int,
        parameters: Int,
        stateBase: Int,
        lowSplit: Bool,
        highSplit: Bool,
        left: UnsafeMutablePointer<Double>,
        right: UnsafeMutablePointer<Double>,
        frames: Int
    ) {
        let feedback = bankParameters[parameters + Parameter.feedback]
        let delay = bankParameters[parameters + Parameter.delaySamples]
        let wholeDelay = max(1, Int(delay))
        let fraction = delay - Double(wholeDelay)

        let highpass = parameters + Parameter.bandHighpass
        let hpB0 = bankParameters[highpass]
        let hpB1 = bankParameters[highpass + 1]
        let hpB2 = bankParameters[highpass + 2]
        let hpA1 = bankParameters[highpass + 3]
        let hpA2 = bankParameters[highpass + 4]
        let lowpass = parameters + Parameter.bandLowpass
        let lpB0 = bankParameters[lowpass]
        let lpB1 = bankParameters[lowpass + 1]
        let lpB2 = bankParameters[lowpass + 2]
        let lpA1 = bankParameters[lowpass + 3]
        let lpA2 = bankParameters[lowpass + 4]

        // Filter memories: [hpL1, hpL2, hpR1, hpR2, lpL1, lpL2, lpR1, lpR2].
        var hpLeft1 = bankFilterState[stateBase]
        var hpLeft2 = bankFilterState[stateBase + 1]
        var hpRight1 = bankFilterState[stateBase + 2]
        var hpRight2 = bankFilterState[stateBase + 3]
        var lpLeft1 = bankFilterState[stateBase + 4]
        var lpLeft2 = bankFilterState[stateBase + 5]
        var lpRight1 = bankFilterState[stateBase + 6]
        var lpRight2 = bankFilterState[stateBase + 7]

        let mask = StereoImageLimits.delayLineLength - 1
        let lineLeft = bankSlot * delayWordsPerBank
        let lineRight = lineLeft + StereoImageLimits.delayLineLength
        var writeIndex = Int(bankDelayWrite[bankSlot])

        for index in 0..<frames {
            let inputLeft = left[index]
            let inputRight = right[index]

            var bandLeft = inputLeft
            var bandRight = inputRight
            if lowSplit {
                let yl = hpB0 * bandLeft + hpLeft1
                hpLeft1 = hpB1 * bandLeft - hpA1 * yl + hpLeft2
                hpLeft2 = hpB2 * bandLeft - hpA2 * yl
                let yr = hpB0 * bandRight + hpRight1
                hpRight1 = hpB1 * bandRight - hpA1 * yr + hpRight2
                hpRight2 = hpB2 * bandRight - hpA2 * yr
                bandLeft = yl
                bandRight = yr
            }
            if highSplit {
                let yl = lpB0 * bandLeft + lpLeft1
                lpLeft1 = lpB1 * bandLeft - lpA1 * yl + lpLeft2
                lpLeft2 = lpB2 * bandLeft - lpA2 * yl
                let yr = lpB0 * bandRight + lpRight1
                lpRight1 = lpB1 * bandRight - lpA1 * yr + lpRight2
                lpRight2 = lpB2 * bandRight - lpA2 * yr
                bandLeft = yl
                bandRight = yr
            }

            // Read the opposite channel's own past OUTPUT — the recursion.
            // `wholeDelay >= 1` guarantees both taps are already written.
            let near = (writeIndex - wholeDelay) & mask
            let far = (writeIndex - wholeDelay - 1) & mask
            let delayedLeft = bankDelayLine[lineLeft + near] * (1 - fraction)
                + bankDelayLine[lineLeft + far] * fraction
            let delayedRight = bankDelayLine[lineRight + near] * (1 - fraction)
                + bankDelayLine[lineRight + far] * fraction

            let outLeft = Self.guardFeedback(bandLeft - feedback * delayedRight)
            let outRight = Self.guardFeedback(bandRight - feedback * delayedLeft)
            bankDelayLine[lineLeft + writeIndex] = outLeft
            bankDelayLine[lineRight + writeIndex] = outRight
            writeIndex = (writeIndex + 1) & mask

            left[index] = (inputLeft - bandLeft) + outLeft
            right[index] = (inputRight - bandRight) + outRight
        }

        bankFilterState[stateBase] = Self.flushDenormal(hpLeft1)
        bankFilterState[stateBase + 1] = Self.flushDenormal(hpLeft2)
        bankFilterState[stateBase + 2] = Self.flushDenormal(hpRight1)
        bankFilterState[stateBase + 3] = Self.flushDenormal(hpRight2)
        bankFilterState[stateBase + 4] = Self.flushDenormal(lpLeft1)
        bankFilterState[stateBase + 5] = Self.flushDenormal(lpLeft2)
        bankFilterState[stateBase + 6] = Self.flushDenormal(lpRight1)
        bankFilterState[stateBase + 7] = Self.flushDenormal(lpRight2)
        bankDelayWrite[bankSlot] = Int32(writeIndex)
    }

    /// NaN backstop, denormal flush and runaway ceiling for the one value that
    /// is fed back into itself. A per-sample check is worth it here in a way
    /// it is not in a feed-forward chain: anything that gets into this delay
    /// line stays in it.
    @inline(__always)
    private static func guardFeedback(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        if abs(value) < 1e-15 { return 0 }
        if value > feedbackCeiling { return feedbackCeiling }
        if value < -feedbackCeiling { return -feedbackCeiling }
        return value
    }

    @inline(__always)
    private static func flushDenormal(_ value: Double) -> Double {
        value.isFinite ? (abs(value) < 1e-15 ? 0 : value) : 0
    }

    /// Convert the working buffer back to Float32, hard-limiting on the way.
    ///
    /// Widening the side signal, and the crosstalk recursion's own peak on
    /// correlated content, both push loud material past full scale; handing
    /// CoreAudio a value outside ±1 is far worse than clamping, and the count
    /// is what tells the user to back the strength off. Also the NaN backstop.
    ///
    /// - Returns: how many samples were clamped or zeroed.
    private func writeBack(
        from source: UnsafeMutablePointer<Double>,
        to destination: UnsafeMutablePointer<Float>,
        frames: Int
    ) -> Int64 {
        var clipped: Int64 = 0
        for index in 0..<frames {
            let value = source[index]
            if !value.isFinite {
                destination[index] = 0
                clipped &+= 1
            } else if value > 1 {
                destination[index] = 1
                clipped &+= 1
            } else if value < -1 {
                destination[index] = -1
                clipped &+= 1
            } else {
                destination[index] = Float(value)
            }
        }
        return clipped
    }
}
