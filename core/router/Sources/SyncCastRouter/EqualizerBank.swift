import Foundation
import os.lock
import SyncCastAtomic

/// Real-time equalisation for one `LocalOutput`: an independent chain of RBJ
/// biquads plus a pre-gain per output channel pair (= per physical speaker in
/// aggregate mode).
///
/// # Real-time contract
///
/// `process()` runs on the CoreAudio render thread. It never allocates, never
/// calls into CoreAudio, and takes `paramLock` only on the block where the app
/// thread has published a new curve — steady state is two atomic loads per
/// pair per block. Coefficients are computed on the app thread in
/// `setSettings()` (`BiquadCoefficients.make` uses `pow`/`sin`/`cos`, which
/// have no place on a render thread) and handed over through a staging buffer.
///
/// # Why two banks and a crossfade
///
/// Swapping biquad coefficients under a running filter puts a step
/// discontinuity in the output — the classic zipper/tick when a slider is
/// dragged. Each pair therefore owns TWO coefficient banks: the one being
/// heard and the one being faded in. On a publish the new curve lands in the
/// idle bank, its state is seeded from the audible bank's state where the
/// chain shape is unchanged, and the two are run in parallel for
/// `fadeMilliseconds` while their outputs are linearly crossfaded. Both chains
/// are guaranteed stable on their own (`BiquadCoefficients.isUsable` runs the
/// Jury test at construction), which is exactly the property that interpolating
/// coefficients directly would NOT give us.
///
/// # Section indexing
///
/// Sections are stored at the index the band has in `EqualizerSettings.bands`,
/// with an identity section for a band sitting at 0 dB. A neutral RBJ section
/// is `y = x` with permanently zero state, so identity sections are skipped in
/// the inner loop and cost nothing — while the stable indexing means dragging
/// one slider of a ten-band graphic curve keeps every other section's filter
/// state, and the crossfade only has to cover the band that moved.
public final class EqualizerBank {

    /// Crossfade length for a curve change. Long enough to make a full-scale
    /// coefficient swap inaudible, short enough that a slider drag still feels
    /// immediate (a drag emits one publish per debounce window, ~50 ms).
    public static let fadeMilliseconds: Double = 20

    /// Largest block the render thread may hand us. Matches
    /// `LocalOutput.stagingFrameCapacity`; a longer block is refused rather
    /// than served from a short scratch buffer.
    public static let maxFramesPerBlock: Int = 4096

    public let pairCount: Int
    public let channelsPerPair: Int
    public let sampleRate: Double
    public let maxBands: Int

    private let fadeFrames: Int

    // MARK: Storage
    //
    // All of it heap-allocated once at init and indexed directly: a Swift
    // Array would be copy-on-write, and a COW copy on the render thread is a
    // heap allocation in an audio callback.

    /// `pairCount * 2` banks of `maxBands` sections of 5 coefficients.
    private let bankCoefficients: UnsafeMutablePointer<Double>
    /// Per section, 1 when it is not an identity section.
    private let bankSectionActive: UnsafeMutablePointer<UInt8>
    /// Sections stored in this bank (identity ones included), so a publish can
    /// tell whether the chain shape changed and state may be carried over.
    private let bankSectionCount: UnsafeMutablePointer<Int32>
    /// Linear pre-gain of this bank.
    private let bankTrim: UnsafeMutablePointer<Double>
    /// 1 when the bank cannot change the signal at all.
    private let bankIsIdentity: UnsafeMutablePointer<UInt8>
    /// TDF-II state: `pairCount * 2` banks × `maxBands` sections ×
    /// `channelsPerPair` channels × 2 words.
    private let bankState: UnsafeMutablePointer<Double>

    /// App-thread staging for the next curve, read by the render thread under
    /// `paramLock` on the block it adopts the publish.
    private let pendingCoefficients: UnsafeMutablePointer<Double>
    private let pendingSectionActive: UnsafeMutablePointer<UInt8>
    private let pendingSectionCount: UnsafeMutablePointer<Int32>
    private let pendingTrim: UnsafeMutablePointer<Double>
    private let pendingIsIdentity: UnsafeMutablePointer<UInt8>
    /// Bumped by the app thread after the staging slot is filled; compared by
    /// the render thread against `appliedGeneration`.
    private let pendingGeneration: UnsafeMutablePointer<SCAtomicInt64>

    // Render-thread-owned bookkeeping. Written only by `process()`.
    private let appliedGeneration: UnsafeMutablePointer<Int64>
    private let activeBank: UnsafeMutablePointer<Int32>
    private let fadeRemaining: UnsafeMutablePointer<Int32>

    /// Double-precision working buffers, one block wide per channel. `scratchA`
    /// carries the audible chain, `scratchB` the incoming one during a
    /// crossfade. Shared across pairs because `process()` is called for one
    /// pair at a time on one thread. Running the whole chain in double and
    /// converting once at the end keeps ten cascaded sections from
    /// accumulating Float32 quantisation between stages.
    private let scratchA: UnsafeMutablePointer<Double>
    private let scratchB: UnsafeMutablePointer<Double>

    /// Samples the hard limiter had to clamp. Published lock-free for the
    /// diagnostics line — a non-zero and climbing count is the signal that the
    /// user's boost needs negative trim.
    private let clipCounter: UnsafeMutablePointer<SCAtomicInt64>

    private let paramLock = OSAllocatedUnfairLock()
    /// Last curve accepted per pair, so a reconcile that re-pushes the same
    /// settings does not spend a crossfade. App-thread state, guarded by
    /// `paramLock` because the Router actor may hop threads between calls.
    private var lastRequested: [EqualizerSettings?]

    public init(
        pairCount: Int,
        channelsPerPair: Int,
        sampleRate: Double,
        maxBands: Int = EqualizerLimits.maxBands
    ) {
        let pairs = max(1, pairCount)
        let channels = max(1, channelsPerPair)
        let bands = max(1, maxBands)
        self.pairCount = pairs
        self.channelsPerPair = channels
        self.sampleRate = sampleRate > 0 ? sampleRate : 48_000
        self.maxBands = bands
        self.fadeFrames = max(
            1, Int((self.sampleRate * Self.fadeMilliseconds / 1000).rounded())
        )
        self.lastRequested = Array(repeating: nil, count: pairs)

        let bankSlots = pairs * 2
        bankCoefficients = .allocate(capacity: bankSlots * bands * 5)
        bankCoefficients.initialize(repeating: 0, count: bankSlots * bands * 5)
        bankSectionActive = .allocate(capacity: bankSlots * bands)
        bankSectionActive.initialize(repeating: 0, count: bankSlots * bands)
        bankSectionCount = .allocate(capacity: bankSlots)
        bankSectionCount.initialize(repeating: 0, count: bankSlots)
        bankTrim = .allocate(capacity: bankSlots)
        bankTrim.initialize(repeating: 1, count: bankSlots)
        bankIsIdentity = .allocate(capacity: bankSlots)
        bankIsIdentity.initialize(repeating: 1, count: bankSlots)
        let stateWords = bankSlots * bands * channels * 2
        bankState = .allocate(capacity: stateWords)
        bankState.initialize(repeating: 0, count: stateWords)

        pendingCoefficients = .allocate(capacity: pairs * bands * 5)
        pendingCoefficients.initialize(repeating: 0, count: pairs * bands * 5)
        pendingSectionActive = .allocate(capacity: pairs * bands)
        pendingSectionActive.initialize(repeating: 0, count: pairs * bands)
        pendingSectionCount = .allocate(capacity: pairs)
        pendingSectionCount.initialize(repeating: 0, count: pairs)
        pendingTrim = .allocate(capacity: pairs)
        pendingTrim.initialize(repeating: 1, count: pairs)
        pendingIsIdentity = .allocate(capacity: pairs)
        pendingIsIdentity.initialize(repeating: 1, count: pairs)
        pendingGeneration = .allocate(capacity: pairs)
        for i in 0..<pairs { sc_atomic_init(pendingGeneration.advanced(by: i), 0) }

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
        bankCoefficients.deinitialize(count: bankSlots * maxBands * 5)
        bankCoefficients.deallocate()
        bankSectionActive.deinitialize(count: bankSlots * maxBands)
        bankSectionActive.deallocate()
        bankSectionCount.deinitialize(count: bankSlots)
        bankSectionCount.deallocate()
        bankTrim.deinitialize(count: bankSlots)
        bankTrim.deallocate()
        bankIsIdentity.deinitialize(count: bankSlots)
        bankIsIdentity.deallocate()
        bankState.deinitialize(count: bankSlots * maxBands * channelsPerPair * 2)
        bankState.deallocate()
        pendingCoefficients.deinitialize(count: pairCount * maxBands * 5)
        pendingCoefficients.deallocate()
        pendingSectionActive.deinitialize(count: pairCount * maxBands)
        pendingSectionActive.deallocate()
        pendingSectionCount.deinitialize(count: pairCount)
        pendingSectionCount.deallocate()
        pendingTrim.deinitialize(count: pairCount)
        pendingTrim.deallocate()
        pendingIsIdentity.deinitialize(count: pairCount)
        pendingIsIdentity.deallocate()
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

    /// True when at least one pair has a curve that changes the signal. Purely
    /// informational (`process()` short-circuits per pair on its own).
    public var isEngaged: Bool {
        paramLock.withLock {
            lastRequested.contains { ($0?.isNeutral ?? true) == false }
        }
    }

    // MARK: - App thread

    /// Publish a curve for one channel pair.
    ///
    /// Idempotent: re-publishing the settings a pair already has returns
    /// immediately, so the Router can re-apply the whole map on every replan
    /// without spending a crossfade per reconcile.
    ///
    /// - Returns: whether anything was actually published.
    @discardableResult
    public func setSettings(_ settings: EqualizerSettings, pair: Int) -> Bool {
        guard pair >= 0, pair < pairCount else { return false }
        let clean = settings.sanitized()
        // Coefficients first, OUTSIDE the lock: this is the `pow`/`sin`/`cos`
        // work, and the render thread may be holding nothing but waiting on
        // the same lock for a memcpy.
        var coefficients = [BiquadCoefficients](repeating: .identity, count: maxBands)
        var active = [UInt8](repeating: 0, count: maxBands)
        let bands = Array(clean.bands.prefix(maxBands))
        var anyActive = false
        for (index, band) in bands.enumerated() {
            let coefficient = clean.bypassed
                ? BiquadCoefficients.identity
                : BiquadCoefficients.make(band: band, sampleRate: sampleRate)
            coefficients[index] = coefficient
            let isActive = coefficient != .identity
            active[index] = isActive ? 1 : 0
            anyActive = anyActive || isActive
        }
        let trim = clean.trimAmplitude
        let identity = !anyActive && trim == 1

        return paramLock.withLock {
            if lastRequested[pair] == clean { return false }
            lastRequested[pair] = clean
            let base = pair * maxBands * 5
            for index in 0..<maxBands {
                let coefficient = coefficients[index]
                let slot = base + index * 5
                pendingCoefficients[slot] = coefficient.b0
                pendingCoefficients[slot + 1] = coefficient.b1
                pendingCoefficients[slot + 2] = coefficient.b2
                pendingCoefficients[slot + 3] = coefficient.a1
                pendingCoefficients[slot + 4] = coefficient.a2
                pendingSectionActive[pair * maxBands + index] = active[index]
            }
            pendingSectionCount[pair] = Int32(bands.count)
            pendingTrim[pair] = trim
            pendingIsIdentity[pair] = identity ? 1 : 0
            // Release store: everything above must be visible to the render
            // thread before it can observe the new generation.
            let next = sc_atomic_load_acquire(pendingGeneration.advanced(by: pair)) &+ 1
            sc_atomic_store_release(pendingGeneration.advanced(by: pair), next)
            return true
        }
    }

    /// Publish `.flat` to every pair. Used when an output is torn down so a
    /// rebuilt one never inherits the previous device's curve.
    public func resetAll() {
        for pair in 0..<pairCount {
            setSettings(.flat, pair: pair)
        }
    }

    // MARK: - Render thread

    /// Equalise one channel pair in place.
    ///
    /// - Parameters:
    ///   - pair: channel-pair index (0 = first physical device in aggregate
    ///     mode).
    ///   - channels: the render callback's per-channel pointer table.
    ///   - channelOffset: index of this pair's first channel in that table.
    ///   - channelCount: channels in this pair (2 for stereo).
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
        let channelsToRun = min(channelCount, channelsPerPair)
        guard channelsToRun > 0 else { return }

        adoptPendingCurve(pair: pair)

        let fading = fadeRemaining[pair] > 0
        let current = Int(activeBank[pair])
        if !fading, bankIsIdentity[bankSlot(pair: pair, bank: current)] == 1 {
            // Fast path: no curve, no fade. The buffer is left byte-identical
            // to what the splat wrote, so an untouched device pays nothing.
            return
        }

        var clipped: Int64 = 0
        if fading {
            clipped = processCrossfade(
                pair: pair,
                channels: channels,
                channelOffset: channelOffset,
                channelsToRun: channelsToRun,
                frames: frames
            )
        } else {
            for channel in 0..<channelsToRun {
                let buffer = channels[channelOffset + channel]
                let work = scratchA.advanced(by: channel * Self.maxFramesPerBlock)
                for index in 0..<frames { work[index] = Double(buffer[index]) }
                runChain(
                    pair: pair, bank: current, channel: channel,
                    buffer: work, frames: frames
                )
                clipped &+= writeBack(from: work, to: buffer, frames: frames)
            }
        }
        if clipped > 0 {
            _ = sc_atomic_fetch_add(clipCounter, clipped)
        }
    }

    // MARK: - Render-thread internals

    private func bankSlot(pair: Int, bank: Int) -> Int { pair * 2 + bank }

    private func coefficientBase(pair: Int, bank: Int) -> Int {
        bankSlot(pair: pair, bank: bank) * maxBands * 5
    }

    private func sectionBase(pair: Int, bank: Int) -> Int {
        bankSlot(pair: pair, bank: bank) * maxBands
    }

    private func stateBase(pair: Int, bank: Int) -> Int {
        bankSlot(pair: pair, bank: bank) * maxBands * channelsPerPair * 2
    }

    /// Take the app thread's staged curve, if there is a newer one, and start
    /// a crossfade into it. Takes `paramLock` for a fixed-size copy and
    /// nothing else — never on a block where no publish happened.
    private func adoptPendingCurve(pair: Int) {
        let generation = sc_atomic_load_acquire(pendingGeneration.advanced(by: pair))
        guard generation != appliedGeneration[pair] else { return }
        let current = Int(activeBank[pair])
        let target = 1 - current
        let targetCoefficients = coefficientBase(pair: pair, bank: target)
        let targetSections = sectionBase(pair: pair, bank: target)
        let targetSlot = bankSlot(pair: pair, bank: target)
        let currentSlot = bankSlot(pair: pair, bank: current)
        let sourceCoefficients = pair * maxBands * 5
        let sourceSections = pair * maxBands

        paramLock.withLock {
            for index in 0..<(maxBands * 5) {
                bankCoefficients[targetCoefficients + index] =
                    pendingCoefficients[sourceCoefficients + index]
            }
            for index in 0..<maxBands {
                bankSectionActive[targetSections + index] =
                    pendingSectionActive[sourceSections + index]
            }
            bankSectionCount[targetSlot] = pendingSectionCount[pair]
            bankTrim[targetSlot] = pendingTrim[pair]
            bankIsIdentity[targetSlot] = pendingIsIdentity[pair]
        }

        // Carry the audible chain's filter state into the incoming one when
        // the chain shape is unchanged — the normal case, since the graphic
        // layout keeps a fixed band list and only a gain moved. Carrying state
        // is what makes a one-slider edit continuous rather than a re-start of
        // ten filters. When the shape DID change the mapping is meaningless,
        // so the incoming chain starts from rest and the crossfade covers its
        // start-up transient.
        let stateWords = maxBands * channelsPerPair * 2
        let targetState = stateBase(pair: pair, bank: target)
        if bankSectionCount[targetSlot] == bankSectionCount[currentSlot] {
            let currentState = stateBase(pair: pair, bank: current)
            for index in 0..<stateWords {
                bankState[targetState + index] = bankState[currentState + index]
            }
        } else {
            for index in 0..<stateWords {
                bankState[targetState + index] = 0
            }
        }

        appliedGeneration[pair] = generation
        fadeRemaining[pair] = Int32(fadeFrames)
    }

    /// Run both banks over the block and linearly crossfade their outputs.
    ///
    /// - Returns: how many output samples the limiter had to clamp.
    private func processCrossfade(
        pair: Int,
        channels: UnsafeMutablePointer<UnsafeMutablePointer<Float>>,
        channelOffset: Int,
        channelsToRun: Int,
        frames: Int
    ) -> Int64 {
        let outgoing = Int(activeBank[pair])
        let incoming = 1 - outgoing
        let remaining = Int(fadeRemaining[pair])
        let startPosition = Double(fadeFrames - remaining) / Double(fadeFrames)
        let step = 1.0 / Double(fadeFrames)
        var clipped: Int64 = 0

        for channel in 0..<channelsToRun {
            let buffer = channels[channelOffset + channel]
            let old = scratchA.advanced(by: channel * Self.maxFramesPerBlock)
            let new = scratchB.advanced(by: channel * Self.maxFramesPerBlock)
            for index in 0..<frames {
                let sample = Double(buffer[index])
                old[index] = sample
                new[index] = sample
            }
            // BOTH chains are run over the whole block even once the mix has
            // reached 1: the outgoing chain's state has to stay current until
            // the fade is retired, or a second edit arriving mid-fade would
            // carry stale state into its own crossfade.
            runChain(pair: pair, bank: outgoing, channel: channel, buffer: old, frames: frames)
            runChain(pair: pair, bank: incoming, channel: channel, buffer: new, frames: frames)
            var position = startPosition
            for index in 0..<frames {
                let mix = position < 1 ? position : 1
                old[index] = old[index] * (1 - mix) + new[index] * mix
                position += step
            }
            clipped &+= writeBack(from: old, to: buffer, frames: frames)
        }

        let consumed = min(remaining, frames)
        fadeRemaining[pair] = Int32(remaining - consumed)
        if fadeRemaining[pair] == 0 {
            activeBank[pair] = Int32(incoming)
        }
        return clipped
    }

    /// Trim + cascaded transposed-direct-form-II sections, in place over the
    /// double-precision working buffer.
    private func runChain(
        pair: Int,
        bank: Int,
        channel: Int,
        buffer: UnsafeMutablePointer<Double>,
        frames: Int
    ) {
        let slot = bankSlot(pair: pair, bank: bank)
        let trim = bankTrim[slot]
        if trim != 1 {
            for index in 0..<frames { buffer[index] *= trim }
        }
        let sections = Int(bankSectionCount[slot])
        guard sections > 0 else { return }
        let coefficients = coefficientBase(pair: pair, bank: bank)
        let sectionFlags = sectionBase(pair: pair, bank: bank)
        let states = stateBase(pair: pair, bank: bank) + channel * maxBands * 2
        for section in 0..<sections {
            guard bankSectionActive[sectionFlags + section] == 1 else { continue }
            let coefficient = coefficients + section * 5
            let b0 = bankCoefficients[coefficient]
            let b1 = bankCoefficients[coefficient + 1]
            let b2 = bankCoefficients[coefficient + 2]
            let a1 = bankCoefficients[coefficient + 3]
            let a2 = bankCoefficients[coefficient + 4]
            var s1 = bankState[states + section * 2]
            var s2 = bankState[states + section * 2 + 1]
            for index in 0..<frames {
                let x = buffer[index]
                let y = b0 * x + s1
                s1 = b1 * x - a1 * y + s2
                s2 = b2 * x - a2 * y
                buffer[index] = y
            }
            bankState[states + section * 2] = Self.flushDenormal(s1)
            bankState[states + section * 2 + 1] = Self.flushDenormal(s2)
        }
    }

    /// Denormals in a resonant low-frequency section cost hundreds of cycles
    /// per sample on some cores once a track goes silent. Flushing the stored
    /// state is cheaper than a per-sample guard and cannot change anything
    /// audible — the threshold is 300 dB below full scale.
    private static func flushDenormal(_ value: Double) -> Double {
        value.isFinite ? (abs(value) < 1e-15 ? 0 : value) : 0
    }

    /// Convert the working buffer back to Float32, hard-limiting on the way.
    ///
    /// A boosted band on already-loud material will exceed full scale; handing
    /// CoreAudio a value outside ±1 is far worse than clamping, and the count
    /// is what tells the user to pull the trim down. Also the NaN backstop: a
    /// non-finite sample becomes silence, so one bad block cannot turn into
    /// permanent noise.
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
