import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation
import os.lock
import SyncCastAtomic

/// One AUHAL bound to a single CoreAudio output device. Reads from a shared
/// `RingBuffer` at a per-device frame offset (= delay compensation), applies a
/// per-device gain, and writes into the AUHAL output buffer.
///
/// Thread-safety: all property mutations from the app thread go through the
/// `OSAllocatedUnfairLock` and are read once per render callback. The render
/// callback itself runs on a real-time thread; no allocations.
public final class LocalOutput {
    public enum LocalOutputError: Error {
        case audioComponentNotFound
        case audioUnitInstantiationFailed(OSStatus)
        case configurationFailed(OSStatus)
        case startFailed(OSStatus)
    }

    public let deviceID: AudioObjectID
    public let deviceUID: String
    public let sampleRate: Double
    /// The number of source channels read from the shared ring buffer.
    /// Always 2 today (SCKCapture is stereo); kept as a generic property
    /// in case we ever capture surround.
    public let channelCount: Int
    /// The number of channels declared on AUHAL's input scope. In
    /// individual mode this equals `channelCount`. In aggregate mode
    /// this is the aggregate's actual output stream channel count,
    /// which can be `2 * subdeviceCount` when the kernel concatenates
    /// subdevice channels regardless of stacked=0.
    ///
    /// When `outputChannelCount > channelCount`, the render callback
    /// splats the source stereo into every channel pair so all
    /// subdevices play (fix for the "only one device plays" bug).
    public let outputChannelCount: Int

    private let ring: RingBuffer
    private var unit: AudioUnit?
    private let stateLock = OSAllocatedUnfairLock()
    /// The Scheduler's per-device read backoff, as pushed in by
    /// `Router.replan()`.
    ///
    /// DIAGNOSTIC ONLY — it does NOT move this AUHAL's read cursor and never
    /// has. The render target is `writePosition − ringFloorFrames −
    /// hardwareLatencyCompensation − block`, and inter-device alignment comes
    /// from `deviceLatencyFramesByDevID` (measured hardware latency), not from
    /// the Scheduler. `Scheduler.plan` is meaningful for the AirPlay/whole-home
    /// path, whose master clock is ~1.8 s away; on the local path its
    /// `safetyMarginMs` would be pure added latency on top of the ring floor.
    ///
    /// Kept (rather than deleted) because `Router.replan()` pushes it for every
    /// path and a field report wants to see what the Scheduler decided; it is
    /// surfaced through `readBackoffFramesDiagnostic`. Wiring it into the
    /// target would ADD its value to the budget — do not do that without
    /// removing the floor first.
    private var _readBackoffFrames: Int = 0
    /// Steady-state lag behind the producer, in frames. See `RingFloorPolicy`:
    /// 100 ms for the ScreenCaptureKit paths, 30 ms (env-overridable) for the
    /// Process-Tap-fed system-sink path.
    private var _ringFloorFrames: Int64
    private var _gain: Float = 1.0
    private var _muted: Bool = false
    private var _readCursor: Int64 = 0
    private var initialized = false
    /// Per-output-channel-pair software gain. Used as a fallback when
    /// hardware volume control is unavailable (e.g. DP/HDMI displays that
    /// don't expose kAudioDevicePropertyVolumeScalar). Indexed by
    /// channel-pair (0 = first pair, 1 = second pair, ...). Default
    /// 1.0 for every pair. Updated atomically via `setSoftwareGain`.
    ///
    /// Sized to `pairCount` (== outputChannelCount / channelCount). In
    /// individual mode the array has one entry and the value stays at
    /// 1.0 unless the Router applies a fallback (which it won't in
    /// individual mode — there's only one device, so the existing
    /// `_gain` field already covers it). In aggregate mode each entry
    /// targets one physical subdevice's stereo pair.
    ///
    /// Stored in a heap-allocated UnsafeMutableBufferPointer rather
    /// than a Swift Array because the render callback reads it on
    /// the RT thread; a Swift array's COW copy could heap-allocate
    /// under high contention. The pointer is allocated once at init,
    /// freed in deinit, and indexed directly under stateLock.
    ///
    /// `_softwareGainsAllOnes` is the fast-path flag the render
    /// callback uses to skip the per-pair multiplier loop entirely
    /// when no fallback is active. Maintained by setSoftwareGain.
    ///
    /// `_softwareGainsScratch` is a per-LocalOutput scratch buffer
    /// the render callback memcpy's into under lock so the per-pair
    /// multiply loop can read without holding stateLock across the
    /// whole iteration. Allocated once at init.
    private let _softwareGains: UnsafeMutablePointer<Float>
    private let _softwareGainsCount: Int
    private var _softwareGainsAllOnes: Bool = true
    private let _softwareGainsScratch: UnsafeMutablePointer<Float>
    /// Per-channel-pair tone control. Sized to the same `pairCount` as
    /// `_softwareGains`, so in aggregate mode pair `p` is physical device `p`
    /// and each speaker carries its own curve. Applied in `render()` after the
    /// splat and BEFORE the gain stage, so the user's volume slider still ends
    /// up as the last attenuator on the signal.
    ///
    /// Costs nothing while every pair is flat: `EqualizerBank.process` exits on
    /// two atomic loads and leaves the buffer byte-identical.
    private let equalizer: EqualizerBank
    /// Per-channel-pair stereo imaging (mid/side width + recursive crosstalk
    /// cancellation). Same `pairCount` and the same pair→physical-device
    /// mapping as `equalizer`, applied in `render()` immediately AFTER the
    /// equalizer and BEFORE the gain stage: the tone curve shapes what the
    /// imager then works on, and the volume slider stays the last attenuator.
    ///
    /// Costs nothing while every pair is neutral: `StereoImageProcessor.process`
    /// exits on one atomic load and leaves the buffer byte-identical.
    private let stereoImage: StereoImageProcessor
    /// Per-channel-pair channel assignment (the 2×2 "声道分配" matrix). Same
    /// `pairCount` and the same pair→physical-device mapping as `equalizer`,
    /// applied in `render()` immediately AFTER the stereo imager and BEFORE the
    /// gain stage: the tone curve and the imager shape a stereo pair, the
    /// matrix then decides which of that reaches which driver, and the volume
    /// slider stays the last attenuator.
    ///
    /// Costs nothing while every pair is at 立体声: `ChannelMatrixBank.process`
    /// exits on one atomic load plus four float compares and leaves the buffer
    /// byte-identical.
    private let channelMatrix: ChannelMatrixBank
    /// Per-channel-pair read offset — the local Stereo path's delay
    /// compensation. Sized to the same `pairCount` as `_softwareGains`, so in
    /// aggregate mode pair `p` is physical device `p` and each speaker can be
    /// held back by its own number of frames.
    ///
    /// Costs nothing while every pair is at 0: `render()` keeps its original
    /// single-read splat and the output is bit-identical to the pre-feature
    /// build. See `PairDelayBank` for the window/cursor bookkeeping.
    private let pairDelays: PairDelayBank
    /// Pre-allocated channel pointer slot for the render callback so we
    /// don't allocate a Swift Array on every render tick. Sized to
    /// `outputChannelCount`, NOT `channelCount`.
    private let outPtrs: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    private let outPtrsCount: Int
    /// Staging buffer for the source `channelCount` channels read from
    /// the ring. Lives across render calls; sized to a comfortable upper
    /// bound (4096 frames * 2 channels = 32 KB). The actual AUHAL block
    /// is typically 512–1024 frames.
    private static let stagingFrameCapacity: Int = 4096
    private let stagingChannels: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    /// Per-channel slabs for staging. We allocate one Float* per source
    /// channel and slice into them per render. Allocated once at init.
    private let stagingSlabs: [UnsafeMutablePointer<Float>]
    /// Second staging set, used ONLY while a pair's delay offset is
    /// crossfading: the pair's outgoing read position lands here and the
    /// incoming one in `stagingChannels`, and the two are mixed straight into
    /// that pair's output channels. Allocated once (32 KB) rather than on
    /// demand, because the alternative is a heap allocation on the render
    /// thread the first time the user touches the control.
    private let stagingChannelsB: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    private let stagingSlabsB: [UnsafeMutablePointer<Float>]
    /// Diagnostic — incremented on every AUHAL render callback.
    public private(set) var renderTickCount: UInt64 = 0
    /// Peak abs sample of the most recent rendered frame block.
    public private(set) var lastRenderPeak: Float = 0
    /// Phase counter for SYNCAST_TONE diagnostic mode.
    private var toneSampleIndex: UInt64 = 0
    /// Opaque pointer from `Unmanaged.passRetained(self).toOpaque()` that
    /// we hand to the AUHAL via `inputProcRefCon`. We hold a +1 retain on
    /// `self` for as long as the AUHAL is alive, then `.release()` it in
    /// `stop()` after Dispose. This closes the use-after-free window:
    /// before this fix, `passUnretained` meant the render callback could
    /// fire with `self` already deallocated (e.g. when the user toggles
    /// a device off and the dictionary releases the `LocalOutput` while
    /// AUHAL's last in-flight render is still running on the RT thread).
    private var refConOpaque: UnsafeMutableRawPointer?

    /// Per-process registry of each open LocalOutput's hardware output
    /// latency in frames (deviceLatency + safetyOffset + streamLatency).
    /// Used by every render() to determine the worst-case latency across
    /// all currently active local outputs and compensate so they all emit
    /// the same captured frame at the same wall-clock instant.
    private static let latencyLock = OSAllocatedUnfairLock()
    nonisolated(unsafe) private static var deviceLatencyFramesByDevID: [String: Int64] = [:]
    /// This output's measured hardware latency in frames.
    private var deviceLatencyFrames: Int64 = 0

    /// How far the read cursor may wander from the target before we discard it
    /// and re-anchor. 250 ms is a safety net for clock divergence, not a jitter
    /// filter: normal jitter moves the cursor by ONE producer block (10.67 ms
    /// at 512 frames / 48 kHz), so this sits ~23 blocks above the noise and
    /// still makes sense against the 30 ms sink floor — a resync there means
    /// the producer stalled for a quarter second, which is a real event.
    public static let driftResyncLimitMs: Int = 250

    // MARK: - Glitch counters (lock-free, written only by the render thread)

    /// Renders after the first that re-anchored the cursor. Non-zero means an
    /// audible discontinuity happened.
    private let resyncCounter: UnsafeMutablePointer<SCAtomicInt64>
    /// Renders after the first that asked for frames past the write cursor.
    /// `RingBuffer.read` zero-fills those, so the output is a short silence
    /// rather than stale ring content — still a dropout.
    private let underrunCounter: UnsafeMutablePointer<SCAtomicInt64>
    /// Smallest `writePosition − startFrame` seen. This is the headroom the
    /// ring floor actually bought; if it approaches 0 the floor is too low.
    private let minWaterLevelCounter: UnsafeMutablePointer<SCAtomicInt64>
    /// Renders served as silence because the producer was not writing. Not a
    /// glitch — but reported, because the counters above are only meaningful
    /// against it (and because a large idle count during playback IS a fault).
    private let idleBlockCounter: UnsafeMutablePointer<SCAtomicInt64>
    /// Sentinel for "no render has been observed yet".
    private static let waterLevelUnset: Int64 = Int64.max
    /// The bookkeeping itself. Owned by the render thread (and by `start()`
    /// before the AUHAL is running); the atomics above are its publication
    /// channel for every other thread. `GlitchTally` holds the rule so it can
    /// be tested without a CoreAudio device.
    private var tally = GlitchTally()
    /// Cross-render producer-activity state. Owned by the render thread with
    /// the tally; `RingReadSequencer` holds the rule that separates "the
    /// producer stopped" from "we got ahead of it".
    private var sequencer = RingReadSequencer()

    public init(
        deviceID: AudioObjectID,
        deviceUID: String,
        ring: RingBuffer,
        sampleRate: Double = 48_000,
        channelCount: Int = 2,
        outputChannelCount: Int? = nil,
        ringFloorFrames: Int? = nil
    ) {
        self.deviceID = deviceID
        self.deviceUID = deviceUID
        self.ring = ring
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self._ringFloorFrames = Self.clampRingFloorFrames(
            ringFloorFrames
                ?? RingFloorPolicy.frames(ms: RingFloorPolicy.legacyFloorMs, sampleRate: sampleRate),
            capacityFrames: ring.capacityFrames
        )
        let resync = UnsafeMutablePointer<SCAtomicInt64>.allocate(capacity: 1)
        sc_atomic_init(resync, 0)
        self.resyncCounter = resync
        let underrun = UnsafeMutablePointer<SCAtomicInt64>.allocate(capacity: 1)
        sc_atomic_init(underrun, 0)
        self.underrunCounter = underrun
        let water = UnsafeMutablePointer<SCAtomicInt64>.allocate(capacity: 1)
        sc_atomic_init(water, Self.waterLevelUnset)
        self.minWaterLevelCounter = water
        let idle = UnsafeMutablePointer<SCAtomicInt64>.allocate(capacity: 1)
        sc_atomic_init(idle, 0)
        self.idleBlockCounter = idle
        // outputChannelCount defaults to channelCount (individual mode);
        // aggregate mode passes a wider count. We round up to an even
        // multiple of channelCount because the splat path writes pairs
        // (or `channelCount`-tuples) into every output slot. An odd
        // surplus channel is tolerated but receives silence.
        self.outputChannelCount = max(channelCount, outputChannelCount ?? channelCount)
        // Allocate the AUHAL-side channel pointer slot, sized to the
        // AUHAL's declared channel count, not the source channel count.
        let ptrs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: self.outputChannelCount)
        // Initialize to a placeholder; will be overwritten on every render.
        let placeholder = UnsafeMutablePointer<Float>.allocate(capacity: 1)
        placeholder.initialize(to: 0)
        ptrs.initialize(repeating: placeholder, count: self.outputChannelCount)
        self.outPtrs = ptrs
        self.outPtrsCount = self.outputChannelCount
        // Staging buffer: per-channel slabs we read from the ring into,
        // then splat across output pairs in render(). Allocated once;
        // never resized. Real-time-safe.
        var slabs: [UnsafeMutablePointer<Float>] = []
        slabs.reserveCapacity(channelCount)
        for _ in 0..<channelCount {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: Self.stagingFrameCapacity)
            p.initialize(repeating: 0, count: Self.stagingFrameCapacity)
            slabs.append(p)
        }
        self.stagingSlabs = slabs
        let stagingPtrs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: channelCount)
        for i in 0..<channelCount { stagingPtrs[i] = slabs[i] }
        self.stagingChannels = stagingPtrs
        var slabsB: [UnsafeMutablePointer<Float>] = []
        slabsB.reserveCapacity(channelCount)
        for _ in 0..<channelCount {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: Self.stagingFrameCapacity)
            p.initialize(repeating: 0, count: Self.stagingFrameCapacity)
            slabsB.append(p)
        }
        self.stagingSlabsB = slabsB
        let stagingPtrsB = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: channelCount)
        for i in 0..<channelCount { stagingPtrsB[i] = slabsB[i] }
        self.stagingChannelsB = stagingPtrsB
        // Per-pair software gain — one entry per output channel pair.
        // Default 1.0 (no attenuation). Heap-allocated so the render
        // callback can index it without going through a Swift Array
        // (which would COW under contention).
        let pairCount = max(1, self.outputChannelCount / channelCount)
        let gainsBuf = UnsafeMutablePointer<Float>.allocate(capacity: pairCount)
        gainsBuf.initialize(repeating: 1.0, count: pairCount)
        self._softwareGains = gainsBuf
        self._softwareGainsCount = pairCount
        // Scratch buffer the render callback memcpy's into under
        // stateLock so the per-pair multiply doesn't hold the lock.
        let scratchBuf = UnsafeMutablePointer<Float>.allocate(capacity: pairCount)
        scratchBuf.initialize(repeating: 1.0, count: pairCount)
        self._softwareGainsScratch = scratchBuf
        self.equalizer = EqualizerBank(
            pairCount: pairCount,
            channelsPerPair: channelCount,
            sampleRate: sampleRate
        )
        self.stereoImage = StereoImageProcessor(
            pairCount: pairCount,
            channelsPerPair: channelCount,
            sampleRate: sampleRate
        )
        self.channelMatrix = ChannelMatrixBank(
            pairCount: pairCount,
            channelsPerPair: channelCount,
            sampleRate: sampleRate
        )
        self.pairDelays = PairDelayBank(pairCount: pairCount, sampleRate: sampleRate)
        // We deliberately leak the placeholder; deinit deallocates outPtrs
        // and the staging slabs. The actual outPtrs used per-render are
        // owned by CoreAudio.
    }

    deinit {
        stop()
        outPtrs.deallocate()
        stagingChannels.deallocate()
        stagingChannelsB.deallocate()
        for slab in stagingSlabs + stagingSlabsB {
            slab.deinitialize(count: Self.stagingFrameCapacity)
            slab.deallocate()
        }
        _softwareGains.deinitialize(count: _softwareGainsCount)
        _softwareGains.deallocate()
        _softwareGainsScratch.deinitialize(count: _softwareGainsCount)
        _softwareGainsScratch.deallocate()
        resyncCounter.deallocate()
        underrunCounter.deallocate()
        minWaterLevelCounter.deallocate()
        idleBlockCounter.deallocate()
    }

    // MARK: - Ring floor

    /// Keep the floor inside something the ring can actually serve. A floor
    /// larger than half the ring leaves no room for the block itself plus
    /// producer overrun, and a negative one is meaningless.
    static func clampRingFloorFrames(_ frames: Int, capacityFrames: Int) -> Int64 {
        Int64(max(0, min(frames, capacityFrames / 2)))
    }

    /// Current steady-state lag behind the producer, in frames.
    public var ringFloorFrames: Int {
        Int(stateLock.withLock { _ringFloorFrames })
    }

    /// Change the floor on a live output. Guarded by the same lock the render
    /// callback snapshots under, so a render either sees the old value or the
    /// new one — never a torn read.
    public func setRingFloorFrames(_ frames: Int) {
        let clamped = Self.clampRingFloorFrames(frames, capacityFrames: ring.capacityFrames)
        stateLock.withLock { _ringFloorFrames = clamped }
    }

    /// The Scheduler backoff the Router last pushed in. Reported in
    /// diagnostics; NOT used by the render target — see `_readBackoffFrames`.
    public var readBackoffFramesDiagnostic: Int {
        stateLock.withLock { _readBackoffFrames }
    }

    // MARK: - Glitch counters

    /// Cursor re-anchors after the first render.
    public var resyncCount: Int64 { sc_atomic_load_acquire(resyncCounter) }
    /// Renders after the first that read past the producer's write cursor.
    public var underrunCount: Int64 { sc_atomic_load_acquire(underrunCounter) }
    /// Smallest observed water level (written frames ahead of the read point),
    /// or nil when nothing has rendered yet.
    public var minWaterLevelFrames: Int64? {
        let value = sc_atomic_load_acquire(minWaterLevelCounter)
        return value == Self.waterLevelUnset ? nil : value
    }
    /// Renders served as silence because nothing was rendering into the
    /// captured device.
    public var idleBlockCount: Int64 { sc_atomic_load_acquire(idleBlockCounter) }

    /// Zero the glitch counters. Called from `start()` so each session's
    /// numbers stand on their own. Also zeroes `renderTickCount`, which is
    /// what "first render" is keyed on — otherwise a restarted output would
    /// book its warm-up resync as a glitch.
    public func resetGlitchCounters() {
        tally.reset()
        sequencer.reset()
        // The render-thread half of the delay bank belongs to this session
        // too: a half-finished crossfade or a stale window carried into a
        // restarted AUHAL would shift the cursor for a change nobody made.
        // The published offsets survive — they are the user's setting.
        pairDelays.resetRenderState()
        sc_atomic_store_release(resyncCounter, 0)
        sc_atomic_store_release(underrunCounter, 0)
        sc_atomic_store_release(minWaterLevelCounter, Self.waterLevelUnset)
        sc_atomic_store_release(idleBlockCounter, 0)
        equalizer.resetClipCount()
        stereoImage.resetClipCount()
        channelMatrix.resetClipCount()
        renderTickCount = 0
    }

    /// One-line counter summary for diagnostics/health logs.
    public func glitchSummary() -> String {
        let water = minWaterLevelFrames.map {
            String(format: "%.1fms", RingFloorPolicy.milliseconds(frames: Int($0), sampleRate: sampleRate))
        } ?? "-"
        // `eqClip` is reported only once it is non-zero: it is a fault signal
        // ("your boost is driving the output past full scale"), and a
        // permanent `eqClip:0` in every line would train the reader to skip
        // the column it is supposed to notice.
        let clips = equalizerClipCount
        let clipInfo = clips > 0 ? " eqClip:\(clips)" : ""
        // Same rule for the imager's limiter: reported only once it fires.
        let imageClips = stereoImageClipCount
        let imageClipInfo = imageClips > 0 ? " imgClip:\(imageClips)" : ""
        // Same rule again for the channel matrix's limiter.
        let matrixClips = channelMatrixClipCount
        let matrixClipInfo = matrixClips > 0 ? " matClip:\(matrixClips)" : ""
        return "resync:\(resyncCount) underrun:\(underrunCount) minWater:\(water)"
            + " idle:\(idleBlockCount)\(clipInfo)\(imageClipInfo)\(matrixClipInfo)"
    }

    // MARK: - Hardware latency probing

    /// Total output latency in frames for a CoreAudio device:
    ///   device-level latency + safety offset + max stream latency.
    /// Called once per LocalOutput at start time; values are stable for
    /// the lifetime of an AUHAL binding.
    ///
    /// Also the measured hardware term of the whole-home `L_local` budget —
    /// `LocalAirPlayBridge` reads it through `outputLatencyFrames(deviceID:)`
    /// so both playback paths agree on what a device's presentation latency
    /// is, rather than each carrying its own probe.
    private static func queryOutputLatencyFrames(deviceID: AudioObjectID) -> Int64 {
        let dev = readUInt32Property(deviceID, kAudioDevicePropertyLatency, kAudioDevicePropertyScopeOutput)
        let safety = readUInt32Property(deviceID, kAudioDevicePropertySafetyOffset, kAudioDevicePropertyScopeOutput)
        // Per-stream latency (output-stream side). We sum the largest one.
        var streamAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &streamAddr, 0, nil, &size) == noErr else {
            return Int64(dev + safety)
        }
        let count = Int(size) / MemoryLayout<AudioStreamID>.size
        var streams = Array(repeating: AudioStreamID(0), count: count)
        if AudioObjectGetPropertyData(deviceID, &streamAddr, 0, nil, &size, &streams) != noErr {
            return Int64(dev + safety)
        }
        var maxStreamLat: UInt32 = 0
        for s in streams {
            let l = readUInt32Property(s, kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal)
            if l > maxStreamLat { maxStreamLat = l }
        }
        return Int64(dev + safety + maxStreamLat)
    }

    /// Public reader for the same probe, so callers outside `LocalOutput`
    /// (notably `LocalAirPlayBridge`, which needs the hardware term of
    /// `L_local`) do not reimplement the property walk. Pure query — it
    /// opens nothing and mutates nothing.
    public static func outputLatencyFrames(deviceID: AudioObjectID) -> Int64 {
        queryOutputLatencyFrames(deviceID: deviceID)
    }

    private static func readUInt32Property(
        _ id: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope
    ) -> UInt32 {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) != noErr {
            return 0
        }
        return value
    }

    public func setRouting(readBackoffFrames: Int, gain: Float, muted: Bool) {
        stateLock.withLock {
            _readBackoffFrames = max(0, readBackoffFrames)
            _gain = max(0, min(1, gain))
            _muted = muted
        }
    }

    /// Apply a per-channel-pair software gain. Used as a fallback when a
    /// physical subdevice (typically a DP/HDMI display speaker) has no
    /// writable kAudioDevicePropertyVolumeScalar — the Router computes
    /// the channel-pair offset via `AggregateDevice.subdeviceChannelOffset`
    /// and routes the user's slider value here instead.
    ///
    /// `pair` is the channel-pair index (0 = first pair = channels 0..1,
    /// 1 = second pair = channels 2..3, ...). Out-of-range pair indices
    /// are silently ignored — keeps the call site simple when the
    /// aggregate's subdevice ordering doesn't line up with what we
    /// expected (we'd rather NOT apply gain than crash). Gain is
    /// clamped to [0, 1].
    ///
    /// Real-time safety: writes through `stateLock`, which the render
    /// callback only takes briefly with `withLock`. The lock is
    /// non-reentrant and never held across a CoreAudio call, so the
    /// render callback can't observe a partial update.
    public func setSoftwareGain(pair: Int, gain: Float) {
        let clamped = max(0, min(1, gain))
        stateLock.withLock {
            guard pair >= 0, pair < _softwareGainsCount else { return }
            _softwareGains[pair] = clamped
            // Recompute the all-ones flag so the render callback can
            // skip the per-pair loop on the common (no-fallback) path.
            var allOnes = true
            for i in 0..<_softwareGainsCount where _softwareGains[i] != 1.0 {
                allOnes = false
                break
            }
            _softwareGainsAllOnes = allOnes
        }
    }

    // MARK: - Equalizer

    /// Install one channel pair's tone curve.
    ///
    /// `pair` follows the same convention as `setSoftwareGain`: 0 is the first
    /// output pair, which in aggregate mode is the first physical subdevice.
    /// Out-of-range indices are ignored rather than fatal, for the same reason
    /// they are there — a subdevice-ordering disagreement mid-rebuild must not
    /// take the render thread down with it.
    ///
    /// Idempotent: re-installing an unchanged curve returns false without
    /// touching the render thread, which is what lets the Router re-apply its
    /// whole UID→curve map on every replan.
    @discardableResult
    public func setEqualizer(pair: Int, settings: EqualizerSettings) -> Bool {
        equalizer.setSettings(settings, pair: pair)
    }

    /// Drop every pair back to flat. Used when an output is being repurposed
    /// so a rebuilt aggregate never inherits the previous device's curve.
    public func resetEqualizers() {
        equalizer.resetAll()
    }

    /// Samples the equalizer's output limiter had to clamp this session.
    /// Non-zero means a boosted band is driving the output past full scale and
    /// the user wants negative trim.
    public var equalizerClipCount: Int64 { equalizer.clipCount }

    /// True when at least one pair has a curve that changes the signal.
    public var equalizerIsEngaged: Bool { equalizer.isEngaged }

    // MARK: - Stereo image

    /// Install one channel pair's stereo-image setting.
    ///
    /// `pair` follows the same convention as `setEqualizer`. Idempotent:
    /// re-installing an unchanged setting returns false without touching the
    /// render thread, which is what lets the Router re-apply its whole
    /// UID → setting map on every replan.
    @discardableResult
    public func setStereoImage(pair: Int, settings: StereoImageSettings) -> Bool {
        stereoImage.setSettings(settings, pair: pair)
    }

    /// Drop every pair back to neutral. Used when an output is being
    /// repurposed so a rebuilt aggregate never inherits the previous device's
    /// imaging.
    public func resetStereoImages() {
        stereoImage.resetAll()
    }

    /// Samples the stereo imager's output limiter had to clamp this session.
    /// Non-zero means the width or the crosstalk recursion is driving the
    /// output past full scale.
    public var stereoImageClipCount: Int64 { stereoImage.clipCount }

    /// True when at least one pair has imaging that changes the signal.
    public var stereoImageIsEngaged: Bool { stereoImage.isEngaged }

    // MARK: - Channel matrix

    /// Install one channel pair's channel assignment.
    ///
    /// `pair` follows the same convention as `setEqualizer`. Idempotent:
    /// re-installing an unchanged matrix returns false without touching the
    /// render thread, which is what lets the Router re-apply its whole
    /// UID → setting map on every replan.
    @discardableResult
    public func setChannelMatrix(pair: Int, settings: ChannelMatrixSettings) -> Bool {
        channelMatrix.setSettings(settings, pair: pair)
    }

    /// Drop every pair back to 立体声. Used when an output is being repurposed
    /// so a rebuilt aggregate never inherits the previous device's assignment.
    public func resetChannelMatrices() {
        channelMatrix.resetAll()
    }

    /// Samples the channel matrix's output limiter had to clamp this session.
    /// Non-zero means a boosted coefficient — or a sum of two loud channels —
    /// is driving the output past full scale.
    public var channelMatrixClipCount: Int64 { channelMatrix.clipCount }

    /// True when at least one pair has an assignment that changes the signal.
    public var channelMatrixIsEngaged: Bool { channelMatrix.isEngaged }

    // MARK: - Per-device delay compensation

    /// Install the whole pair → read-offset map, in frames.
    ///
    /// Offsets are non-negative holds: a pair with a larger offset reads older
    /// audio and therefore sounds later. Pairs absent from the map are 0, so
    /// "the user cleared this device" and "the user never touched it" are the
    /// same call — which is what lets the Router re-push its full map on every
    /// reconcile without special-casing removals.
    ///
    /// Idempotent: an unchanged map returns false and never reaches the render
    /// thread, so no crossfade is spent.
    ///
    /// The values come from `LocalDelayTrimPlanner.offsetFrames`, which does
    /// the normalisation and the clamping; this call clamps negatives away as
    /// a backstop but does not re-derive anything.
    @discardableResult
    public func setPairDelays(_ framesByPair: [Int: Int]) -> Bool {
        pairDelays.setOffsets(framesByPair)
    }

    /// Drop every pair's delay back to 0. Used when an output is repurposed so
    /// a rebuilt aggregate never inherits the previous device set's offsets.
    public func resetPairDelays() {
        pairDelays.resetOffsets()
    }

    /// The offsets last accepted, indexed by pair. For diagnostics and tests.
    public func pairDelayFrames() -> [Int] { pairDelays.requestedOffsets() }

    /// Reset every pair's software gain back to 1.0. Called by the
    /// Router when a device's hardware-volume probe succeeds (we no
    /// longer need the fallback) or when the aggregate is torn down.
    /// Safe to call when no fallback is active — it's a no-op.
    public func resetSoftwareGains() {
        stateLock.withLock {
            for i in 0..<_softwareGainsCount { _softwareGains[i] = 1.0 }
            _softwareGainsAllOnes = true
        }
    }

    public func start() throws {
        guard !initialized else { return }
        // Zero the glitch counters BEFORE the AUHAL can call render(), so the
        // reset never races a live render thread and the session's numbers
        // start at zero.
        resetGlitchCounters()
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw LocalOutputError.audioComponentNotFound
        }
        var unitOut: AudioUnit?
        var status = AudioComponentInstanceNew(component, &unitOut)
        guard status == noErr, let unit = unitOut else {
            throw LocalOutputError.audioUnitInstantiationFailed(status)
        }

        // Bind to specific output device.
        var devID = deviceID
        status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &devID,
            UInt32(MemoryLayout<AudioObjectID>.size)
        )
        guard status == noErr else { throw LocalOutputError.configurationFailed(status) }

        // Set output stream format (Float32 non-interleaved). Channel
        // count is `outputChannelCount` — equals `channelCount` (=2) in
        // individual mode, but in aggregate mode can be wider when the
        // kernel exposes one stream concatenating subdevice channels.
        // The render callback splats source stereo across all pairs so
        // every subdevice plays.
        var format = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat
                | kAudioFormatFlagIsPacked
                | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: UInt32(outputChannelCount),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        status = AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            0,
            &format,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        guard status == noErr else { throw LocalOutputError.configurationFailed(status) }

        // Render callback. We `passRetained(self)` so the AUHAL holds a
        // strong reference for its entire lifetime. The matching
        // `.release()` lives in `stop()` after the unit is disposed.
        //
        // CRITICAL leak window: if start() succeeds at passRetained but
        // throws before reaching `self.unit = unit` below (e.g. a later
        // `AudioUnitInitialize` failure), `refConOpaque` is set but
        // `self.unit` is not — meaning stop()'s `guard let unit = unit
        // else { return }` exits early and never invokes `.release()`,
        // leaking a permanent +1 retain. To close that window, every
        // error path between `passRetained` and `self.unit = unit` MUST
        // release the opaque before throwing. We use a defer that fires
        // only if `self.unit` is still nil at function exit (i.e. we
        // didn't reach the success path), driven by a local `installed`
        // sentinel.
        let opaque = Unmanaged.passRetained(self).toOpaque()
        self.refConOpaque = opaque
        var installed = false
        defer {
            if !installed {
                // start() is exiting via an error path. Roll back the
                // retain we placed on `self`, otherwise stop() — which
                // gates on `self.unit != nil` — will skip the release
                // and leak a permanent retain.
                self.refConOpaque = nil
                Unmanaged<LocalOutput>.fromOpaque(opaque).release()
            }
        }
        var callback = AURenderCallbackStruct(
            inputProc: { (inRefCon, _, _, _, inNumberFrames, ioData) -> OSStatus in
                let owner = Unmanaged<LocalOutput>.fromOpaque(inRefCon).takeUnretainedValue()
                return owner.render(frames: Int(inNumberFrames), ioData: ioData)
            },
            inputProcRefCon: opaque
        )
        status = AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input,
            0,
            &callback,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        guard status == noErr else { throw LocalOutputError.configurationFailed(status) }

        status = AudioUnitInitialize(unit)
        guard status == noErr else { throw LocalOutputError.configurationFailed(status) }
        status = AudioOutputUnitStart(unit)
        guard status == noErr else { throw LocalOutputError.startFailed(status) }

        self.unit = unit
        self.initialized = true
        installed = true   // Tells the rollback `defer` above NOT to release.
        // Measure this device's hardware output latency NOW that it's
        // initialized — kAudioDevicePropertyLatency is only stable after
        // the AUHAL has bound. Store globally so peer LocalOutputs can
        // compensate against the worst-case latency in the group.
        let latencyFrames = Self.queryOutputLatencyFrames(deviceID: deviceID)
        deviceLatencyFrames = latencyFrames
        Self.latencyLock.withLock {
            Self.deviceLatencyFramesByDevID[deviceUID] = latencyFrames
        }
        // Initialize read cursor to lag the writer by this output's own floor.
        // The first render resyncs anyway (cursor == 0 is the trigger); this
        // only matters for anyone inspecting the cursor before then.
        stateLock.withLock {
            self._readCursor = max(0, ring.writePosition - self._ringFloorFrames)
        }
    }

    public func stop() {
        guard let unit = unit else { return }
        // Order matters. Stop first (blocks until the current render
        // callback has returned), then uninitialize, then dispose. After
        // Dispose, the AUHAL no longer holds our refCon, so it's safe to
        // release the +1 retain we put on `self` in start().
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        self.unit = nil
        initialized = false
        if let opaque = refConOpaque {
            // Mark consumed BEFORE releasing so any (impossible but
            // defensive) re-entry sees a nil opaque and skips the release.
            refConOpaque = nil
            Unmanaged<LocalOutput>.fromOpaque(opaque).release()
        }
        _ = Self.latencyLock.withLock {
            Self.deviceLatencyFramesByDevID.removeValue(forKey: deviceUID)
        }
    }

    /// Internal rather than private so `LocalOutputDelayRenderTests` can push
    /// blocks through the SHIPPING render path with a hand-built
    /// `AudioBufferList` and no CoreAudio device. Nothing else calls it; the
    /// AUHAL reaches it through the C callback.
    func render(frames: Int, ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        guard let ioData = ioData else { return noErr }
        let bufList = UnsafeMutableAudioBufferListPointer(ioData)
        // AUHAL gives us `outputChannelCount` non-interleaved buffers.
        // (In individual mode, outputChannelCount == channelCount == 2.
        // In aggregate mode it can be wider.)
        guard bufList.count >= outputChannelCount else { return noErr }
        guard frames > 0, frames <= Self.stagingFrameCapacity else { return noErr }

        // Read state once. softwareGainsAllOnes lets the render path
        // skip the per-pair multiply loop on the common case where
        // no fallback is in use; if false, we re-acquire the lock
        // below to copy the per-pair values into a small stack
        // scratch (avoids holding the lock across the whole loop).
        let snapshot = stateLock.withLock {
            (gain: _gain,
             muted: _muted,
             floor: _ringFloorFrames,
             cursor: _readCursor,
             swGainsAllOnes: _softwareGainsAllOnes)
        }

        let writePos = ring.writePosition
        // Compensation target — the position the next read SHOULD land at
        // for inter-device sync. compensation = (peerMaxLat − myLat) makes
        // a fast device wait long enough to play the same captured frame
        // at the same wall-clock instant as the slowest peer. On top of that
        // sits the ring floor, sized to the PRODUCER's jitter: 100 ms for
        // ScreenCaptureKit, 30 ms for the system sink's Process Tap.
        let maxLatencyFrames: Int64 = Self.latencyLock.withLock {
            Self.deviceLatencyFramesByDevID.values.max() ?? deviceLatencyFrames
        }
        let compensation = max(0, maxLatencyFrames - deviceLatencyFrames)

        // Per-device delay compensation. Adopt whatever the app thread
        // published, then slide the cursor by the change in the read window so
        // that pairs the user did NOT touch keep reading exactly the samples
        // they would have read anyway — see `PairDelayBank`. A cursor of 0 is
        // the "never rendered" sentinel and must stay 0; the floor of 1 keeps
        // a large negative shift during warm-up from landing back on it.
        let delay = pairDelays.adoptPublishedChanges()
        let cursor: Int64 = snapshot.cursor == 0
            ? 0
            : max(1, snapshot.cursor &+ delay.cursorShift)

        // CRITICAL: anchor reads on the previous render's end position.
        // Recomputing startFrame from `writePos` every render meant
        // adjacent render blocks could overlap or leave gaps in the
        // captured stream — `writePos` advances by SCK's 1024-frame
        // chunks while AUHAL pulls 512/1024 frames at its own clock.
        // Even a 16-sample overlap repeats audio (audible doubling /
        // "granularity"); a 16-sample gap drops audio (click). This
        // was the primary source of user-reported 毛刺感 + 啸叫.
        //
        // `RingReadSequencer` owns the resync/underrun arithmetic (through
        // `RingReadPlanner`) plus the one thing a single render cannot see:
        // whether the producer is producing at all. Pure integer math, no
        // allocation, unit-tested in RingReadPolicyTests.
        let plan = sequencer.plan(
            writePosition: writePos,
            cursor: cursor,
            frames: frames,
            floorFrames: snapshot.floor,
            compensationFrames: compensation,
            capacityFrames: ring.capacityFrames,
            driftLimitFrames: Int64(Self.driftResyncLimitMs) * Int64(sampleRate) / 1000,
            readWindowFrames: delay.window
        )
        let startFrame: Int64 = plan.startFrame

        // Capture the AUHAL output pointers (non-interleaved, one per
        // output channel). Used for the splat write below.
        var allOk = true
        for ch in 0..<outputChannelCount {
            if let raw = bufList[ch].mData {
                outPtrs[ch] = raw.assumingMemoryBound(to: Float.self)
            } else {
                allOk = false
                break
            }
        }
        if !allOk { return noErr }

        // Counters. Recorded only past the bail-out above, so a render that
        // produced no audio is not booked as one that did.
        //
        // Skipped on the very first render: the cursor is 0 by construction
        // there, so it always resyncs, and counting it would put a permanent 1
        // in every session's glitch column. A few counts in the first hundreds
        // of ms are warm-up (the producer has not written `floor` frames yet);
        // the steady-state claim is "these numbers stopped moving", not "these
        // numbers are zero".
        if renderTickCount > 0 {
            tally.record(plan)
            // Publish. Single writer (this render thread), many readers, so
            // plain release stores are enough — no CAS, no lock, no allocation.
            sc_atomic_store_release(resyncCounter, tally.resyncCount)
            sc_atomic_store_release(underrunCounter, tally.underrunCount)
            sc_atomic_store_release(
                minWaterLevelCounter, tally.minWaterLevelFrames ?? Self.waterLevelUnset
            )
            sc_atomic_store_release(idleBlockCounter, tally.idleBlocks)
        }

        // Producer idle: nothing is rendering into the captured device, so
        // there is no audio to serve and no cursor movement to make. Emit
        // silence and leave the cursor exactly where it is — advancing it
        // through a long silence would push it thousands of blocks past the
        // write head, and the recovery from THAT would be a real resync.
        //
        // `ring.read` would also produce silence here (it zero-fills anything
        // past the write cursor), but it would do so at the cost of a full
        // staging read plus the splat; writing the output buffers directly is
        // both cheaper and impossible to misread as "we played something".
        if plan.producerIdle {
            for ch in 0..<outputChannelCount {
                let dst = outPtrs[ch]
                var i = 0
                while i < frames { dst[i] = 0; i += 1 }
            }
            renderTickCount &+= 1
            lastRenderPeak = 0
            // Write the (possibly window-shifted) cursor back even though it
            // did not advance: dropping the shift here would leave the cursor
            // describing the previous window. The resume-from-idle re-anchor
            // would paper over it, but only by accident.
            if cursor != snapshot.cursor {
                stateLock.withLock { _readCursor = cursor }
            }
            return noErr
        }

        // Read source channels (always `channelCount`, typically 2)
        // into the pre-allocated staging slabs.
        //
        // On an underrun (`plan.underrunFrames > 0`) we deliberately do NOT
        // substitute anything: `RingBuffer.read` already zero-fills every
        // frame outside [writePos − capacity, writePos), so the tail of the
        // block is silence, not stale ring content from a lap ago. A short
        // silence is the least-bad dropout and it is counted above.
        //
        // Splat: write the source stereo into every output channel
        // pair. For (sourceCh=2, outputCh=2): writes one pair (no-op
        // in individual mode beyond a copy). For (sourceCh=2,
        // outputCh=4): writes pairs (0,1) and (2,3) — covers two
        // physical speakers stacked in the aggregate stream.
        //
        // pairCount = outputChannelCount / channelCount. Surplus
        // output channels (when outputChannelCount isn't a clean
        // multiple of channelCount) are filled with zeros so we
        // don't emit garbage from uninitialized memory.
        let pairCount = outputChannelCount / channelCount
        let surplusStart = pairCount * channelCount
        // Snapshot for the splat path so we don't iterate stagingSlabs
        // (which is a Swift Array — boxed).
        let stage = stagingChannels
        if pairDelays.isSettledAtZero {
            // FAST PATH — nothing dialled in, no fade running. One ring read
            // for the whole AUHAL, splatted. Byte-for-byte what this callback
            // did before per-device delay existed.
            ring.read(at: startFrame, frames: frames, into: stage)
            for p in 0..<pairCount {
                for ch in 0..<channelCount {
                    let dst = outPtrs[p * channelCount + ch]
                    let src = stage[ch]
                    // memcpy-style copy — RT-safe.
                    dst.update(from: src, count: frames)
                }
            }
        } else {
            // SLOW PATH — at least one pair is held back. Each pair gets its
            // own read at `startFrame + lead`, where a larger delay means a
            // smaller lead and therefore older audio. `startFrame` is anchored
            // to the MOST delayed pair, so every lead is ≥ 0 and the block the
            // planner reserved (`readWindowFrames`) covers all of them.
            //
            // One extra `RingBuffer.read` per pair. That is a bounded memcpy
            // of `frames * channelCount` floats with no allocation and no
            // lock, and it only happens once the user has asked for it.
            let stageB = stagingChannelsB
            for p in 0..<pairCount {
                let lead = pairDelays.readLeadFrames(pair: p)
                ring.read(at: startFrame &+ lead, frames: frames, into: stage)
                let remaining = pairDelays.fadeRemainingFrames(pair: p)
                let base = p * channelCount
                if remaining <= 0 {
                    for ch in 0..<channelCount {
                        outPtrs[base + ch].update(from: stage[ch], count: frames)
                    }
                    continue
                }
                // Crossfading to a new offset: read the outgoing position too
                // and mix, so a moved slider is a 20 ms blend rather than a
                // step discontinuity in the read position (an audible click).
                let previousLead = pairDelays.previousReadLeadFrames(pair: p)
                ring.read(at: startFrame &+ previousLead, frames: frames, into: stageB)
                let fadeFrames = pairDelays.fadeFrames
                for ch in 0..<channelCount {
                    let dst = outPtrs[base + ch]
                    let incoming = stage[ch]
                    let outgoing = stageB[ch]
                    var i = 0
                    while i < frames {
                        let w = PairDelayBank.fadeWeight(
                            remaining: remaining, index: i, fadeFrames: fadeFrames
                        )
                        dst[i] = outgoing[i] * (1 - w) + incoming[i] * w
                        i += 1
                    }
                }
            }
            pairDelays.advance(frames: frames)
        }
        // Zero any odd surplus output channels (e.g. 5-ch aggregate
        // with 2-ch source: channels 0..3 written from pairs, channel
        // 4 zeroed).
        if surplusStart < outputChannelCount {
            for ch in surplusStart..<outputChannelCount {
                let dst = outPtrs[ch]
                var i = 0
                while i < frames { dst[i] = 0; i += 1 }
            }
        }

        // Per-render diagnostics: bump tick count + sample peak so the
        // engine can tell whether AUHAL is firing AND emitting non-zero
        // audio. Done before gain is applied (so we measure actual
        // captured audio, not gain-attenuated). Sampled from output channel 0
        // — the first pair's left channel, which on the fast path is the same
        // buffer the staging read produced and on the delayed path is the one
        // that pair actually plays.
        renderTickCount &+= 1
        var pk: Float = 0
        let n = min(frames, 128)
        let p0 = outPtrs[0]
        for i in 0..<n { pk = max(pk, abs(p0[i])) }
        lastRenderPeak = pk

        // Per-device tone control, applied to each pair's own channels.
        //
        // Placed HERE deliberately: after the splat (so each physical device
        // has its own copy of the source to shape) and before the gain stage
        // (so the volume slider stays the last attenuator, and a boosted curve
        // that would clip at unity does not clip once the user turns down).
        // The bank's own limiter still catches full-scale material plus a
        // boost, and counts it.
        //
        // Flat outputs take the bank's fast exit and leave the buffers exactly
        // as the splat wrote them — the pre-equalizer render path is bit-for-
        // bit unchanged when nobody has dialled anything in.
        for p in 0..<pairCount {
            equalizer.process(
                pair: p,
                channels: outPtrs,
                channelOffset: p * channelCount,
                channelCount: channelCount,
                frames: frames
            )
        }

        // Per-device stereo imaging, immediately after the tone curve and
        // still before the gain stage. Order matters both ways round: the
        // imager's mid/side split works on the equalised signal (so a bass cut
        // is not re-widened into the side channel), and the volume slider
        // remains the last thing on the signal.
        //
        // A neutral pair takes the processor's fast exit and leaves the
        // buffers exactly as the equalizer left them, so a user who never
        // opens the panel gets the pre-feature render path bit for bit.
        for p in 0..<pairCount {
            stereoImage.process(
                pair: p,
                channels: outPtrs,
                channelOffset: p * channelCount,
                channelCount: channelCount,
                frames: frames
            )
        }

        // Per-device channel assignment, immediately after the imager and
        // still before the gain stage. Order matters both ways round: the
        // matrix routes what the tone curve and the imager produced (so "this
        // speaker plays the left channel" means the *processed* left channel),
        // and the volume slider remains the last thing on the signal.
        //
        // A pair at 立体声 takes the bank's fast exit and leaves the buffers
        // exactly as the imager left them, so a user who never opens the panel
        // gets the pre-feature render path bit for bit.
        for p in 0..<pairCount {
            channelMatrix.process(
                pair: p,
                channels: outPtrs,
                channelOffset: p * channelCount,
                channelCount: channelCount,
                frames: frames
            )
        }

        // Apply gain / mute. Two paths:
        //
        //   FAST PATH — when softwareGainsAllOnes is true (no per-
        //   subdevice fallback active), apply a single global multiplier
        //   across every channel, just like the original code.
        //
        //   SLOW PATH — when at least one pair has a software-gain
        //   fallback (DP / HDMI display whose hardware volume was
        //   rejected), multiply each pair's two channels by
        //   `globalGain * softwareGains[p]`. This lets the user's
        //   per-device slider attenuate one physical speaker without
        //   touching its peer.
        //
        // Surplus channels were zeroed above; iterating to surplusStart
        // skips them.
        let effectiveGain = snapshot.muted ? Float(0) : snapshot.gain
        if snapshot.swGainsAllOnes {
            if effectiveGain != 1.0 {
                for ch in 0..<surplusStart {
                    let p = outPtrs[ch]
                    var i = 0
                    while i < frames {
                        p[i] *= effectiveGain
                        i += 1
                    }
                }
            }
        } else {
            // Copy the per-pair gains into our pre-allocated scratch
            // under a brief lock acquisition. No heap allocation —
            // the scratch buffer is owned for the lifetime of this
            // LocalOutput. We use self._softwareGains{,Scratch}
            // directly inside the lock closure rather than capturing
            // a let-binding to keep Swift 6 Sendable analysis happy
            // (raw pointers are non-Sendable).
            let n = min(pairCount, _softwareGainsCount)
            stateLock.withLock {
                for i in 0..<n {
                    self._softwareGainsScratch[i] = self._softwareGains[i]
                }
            }
            for p in 0..<pairCount {
                let g: Float = (p < n) ? _softwareGainsScratch[p] : 1.0
                let pairGain = effectiveGain * g
                if pairGain == 1.0 { continue }
                let base = p * channelCount
                for ch in 0..<channelCount {
                    let dst = outPtrs[base + ch]
                    var i = 0
                    while i < frames {
                        dst[i] *= pairGain
                        i += 1
                    }
                }
            }
        }

        // Advance the cursor so the next render reads contiguously,
        // never recomputing from `writePos` and never overlapping the
        // previous block.
        stateLock.withLock { _readCursor = startFrame &+ Int64(frames) }
        return noErr
    }
}
