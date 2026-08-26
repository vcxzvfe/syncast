import Foundation
import Accelerate
import CoreAudio
import AudioToolbox
import AVFoundation
import Darwin
import os.lock

/// Single-slot holder handed to `AVAudioConverter`'s input block so the
/// block reads/clears a reference property instead of mutating a captured
/// `var` (which trips Swift 6's `@Sendable`-closure capture check). Access
/// is confined to the reader task, hence `@unchecked Sendable`.
private final class ConverterInputFeed: @unchecked Sendable {
    var buffer: AVAudioPCMBuffer?
}

/// Bridges OwnTone's player-clock-driven PCM output to a single local
/// CoreAudio device, so the device stays in lockstep with AirPlay 2
/// receivers in *whole-home AirPlay mode* (Strategy 1).
///
/// Data flow:
///
///   ```
///   OwnTone player thread
///       │
///       ▼  (44.1 kHz s16le 2ch, 1408-byte packets)
///   output.fifo  (named pipe)
///       │
///       ▼  (read by LocalFifoBroadcaster in the Python sidecar)
///   /tmp/syncast-$UID.localfifo.sock  (SOCK_STREAM, multi-listen)
///       │
///       ▼  (THIS class — one TCP-shaped read per bridge instance)
///   internal Float32 non-interleaved ring buffer (~200 ms)
///       │
///       ▼  (AUHAL render callback, real-time CoreAudio thread)
///   physical CoreAudio device (built-in speakers, USB DAC, HDMI/DP, ...)
///   ```
///
/// Why a *separate* ring buffer (independent from SCKCapture's):
/// SCKCapture's ring is fed by the system audio capture — which we do
/// NOT want to play back when whole-home AirPlay mode is active. In
/// whole-home mode, every output (local CoreAudio + AirPlay receivers)
/// is driven by OwnTone's player. Reusing SCKCapture's ring would mix
/// the two clocks and re-introduce drift.
///
/// Threading model:
///  * `start()` / `stop()` are called from `Router` (an `actor`); they
///    are NOT real-time.
///  * The reader runs in a detached `Task` and does blocking `read(2)`
///    on the Unix socket. It's a non-RT thread; it allocates a small
///    interleaved-Int16 staging buffer once and reuses it.
///  * The render callback runs on a CoreAudio real-time thread; it does
///    NO allocations and only takes the unfair lock to read state once.
///
/// Latency budget: the internal ring is sized for ~200 ms (8192 frames at
/// 44.1 kHz, rounded up to a power of two for cheap modulo). The
/// broadcaster's per-client SO_SNDBUF is ~50 ms, so the end-to-end
/// queue depth for an idle, well-paced bridge sits well under 100 ms —
/// matched against AirPlay's ~1.8 s buffer by OwnTone's per-output
/// `delay_ms`. Drift correction is OwnTone's job (it owns the player
/// clock); we just consume.
public final class LocalAirPlayBridge: @unchecked Sendable {
    public enum BridgeError: Error {
        case audioComponentNotFound
        case audioUnitInstantiationFailed(OSStatus)
        case configurationFailed(OSStatus)
        case startFailed(OSStatus)
        case socketCreationFailed(Int32)
        case socketConnectFailed(Int32)
    }

    public let deviceID: AudioObjectID
    public let deviceUID: String
    public let socketPath: URL
    /// Bridge feed format (direction B). The local leg is fed from
    /// OwnTone's OUTPUT fifo (`fifo {}` module), which
    /// `LocalFifoBroadcaster._run_broadcaster` reads and fans out to the
    /// bridge clients. OwnTone's fifo output is hardcoded to 44.1 kHz
    /// s16le 2ch — see `build/owntone-server/src/outputs/fifo.c`
    /// (`fifo_quality = { 44100, 16, 2, 0 }`, `FIFO_PACKET_SIZE = 1408`).
    ///
    /// We do NOT rely on the AUHAL to resample this 44.1 kHz feed to the
    /// device's nominal rate. Setting the AUHAL input-scope format to
    /// 44.1 kHz while the device runs at 48 kHz was observed NOT to engage
    /// implicit conversion on Tahoe: the render callback was pulled at the
    /// device rate (~48 kHz) while the ring was filled at 44.1 kHz, so the
    /// read cursor outran the writer ~8.8 % and triggered a continuous
    /// overrun-resync storm (audible stutter + noise). Instead we query the
    /// device's real nominal rate, open the AUHAL input scope at THAT rate,
    /// and resample 44.1 kHz → device rate explicitly on the non-RT reader
    /// thread with an `AVAudioConverter` (see `resampleConverter`). This is
    /// device-rate-agnostic (48 kHz, 96 kHz, or native 44.1 kHz all work).
    public let inboundSampleRate: Double = 44_100
    public let channelCount: Int = 2
    /// The target device's nominal sample rate, discovered in
    /// `openAudioUnit`. The ring, the AUHAL input format, and every
    /// rate-derived constant (backoff, drift limit, tone phase) are
    /// expressed in THIS rate. Defaults to the feed rate so any code
    /// running before `openAudioUnit` (e.g. an early caller)
    /// stays self-consistent.
    private var deviceSampleRate: Double = 44_100
    /// One OwnTone fifo output packet: 352 frames * 2 channels * 2 bytes
    /// = 1408 bytes s16le. Matches `FIFO_PACKET_SIZE` in fifo.c and
    /// `LOCAL_FIFO_CHUNK_BYTES` in the sidecar broadcaster, so each read
    /// lands on exactly one OwnTone packet boundary.
    public let packetBytes: Int = 1408

    /// Internal ring buffer capacity, in DEVICE-rate frames. Must be a power
    /// of two — `RingBuffer.init` preconditions it for cheap modulo. We
    /// deliberately use the same `RingBuffer` type as the capture path so the
    /// producer/consumer atomic-ordering audit is shared.
    ///
    /// Sized 262_144 (≈5.5 s at 48 kHz, ≈1.4 s at 192 kHz) rather than the
    /// original 16_384 for two reasons, in order of importance:
    ///
    ///  1. The 16_384 ring could not hold `backoffFrames` at high device
    ///     rates. At 192 kHz `baselineBackoffMs` alone is 20_928 frames —
    ///     already larger than the whole ring — so the read tap sat
    ///     permanently outside the valid window and `RingBuffer.read`
    ///     zero-filled every block. That is a pre-existing bug, independent
    ///     of per-device trim.
    ///  2. The per-device delay trim moves the read tap FURTHER back
    ///     (`startFrame - trimFrames`). The usable trim headroom is
    ///     `capacity - backoffFrames - 2·framesPerRender`, which at 16_384
    ///     was only ~51 ms at 96 kHz and ~147 ms at 48 kHz with 2048-frame
    ///     quanta. Normalising the widest legal pair of user values (−200 on
    ///     one speaker, +200 on another) asks a single output for the full
    ///     400 ms span, and the clamp must stay UNREACHABLE: clamping would
    ///     silently break the relative alignment that is the entire point of
    ///     the feature. The budget is `backoffFrames + 2·framesPerRender +
    ///     resyncDriftMs + trim`: the drift term belongs there because
    ///     render() tolerates the cursor lagging `target` by up to
    ///     `resyncDriftMs` before it snaps, and during that window the
    ///     trimmed tap sits that much further back again. 65_536 and 131_072
    ///     both fell short at 176.4/192 kHz — see
    ///     `LocalBridgeTrimHeadroomTests`, which is what caught it.
    ///
    /// Cost is 2 ch × 4 B × 262_144 = 2 MB per bridge. The steady-state
    /// operating point is unchanged: the Layer-2 PLL still holds the fill at
    /// `backoffFrames + framesPerRender`. The only behavioural difference is
    /// that render()'s `underrun` backstop now fires later than its `drift`
    /// backstop at every rate, i.e. strictly more forgiving.
    public static let defaultRingCapacityFrames: Int = 262_144
    public let ringCapacityFrames: Int = LocalAirPlayBridge.defaultRingCapacityFrames
    private let ring: RingBuffer

    // AUHAL state
    private var unit: AudioUnit?
    private let stateLock = OSAllocatedUnfairLock()
    private var initialized = false
    private var refConOpaque: UnsafeMutableRawPointer?
    /// Pre-allocated channel pointer slot for the render callback.
    private let outPtrs: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    private let outPtrPlaceholder: UnsafeMutablePointer<Float>
    /// Pre-allocated planar Float32 staging buffer used by the SOCKET
    /// reader to convert s16le interleaved → Float32 non-interleaved
    /// once per packet, then `RingBuffer.write` straight into the ring.
    /// Sized to one packet's worth of frames (352).
    private let scratchFloat: [UnsafeMutablePointer<Float>]
    private let scratchFramesPerPacket: Int
    /// Pre-allocated 2-slot channel-pointer buffer for the ring-write
    /// call. RingBuffer.write expects a `UnsafePointer<UnsafePointer<Float>>`
    /// pointing at exactly `channelCount` channel pointers. Allocating
    /// it per-iteration was burning ~31 alloc/dealloc cycles per second
    /// per bridge — not real-time-thread, but still wasteful and the
    /// header above the call site claimed "no heap allocation". Now that
    /// claim is correct.
    private let chansPtr: UnsafeMutablePointer<UnsafePointer<Float>>

    // MARK: - Sample-rate conversion (reader thread, non-RT)
    /// Resamples the 44.1 kHz feed to `deviceSampleRate`. Nil when the
    /// device already runs at 44.1 kHz (passthrough — no conversion). Set
    /// up once in `openAudioUnit`, used only on the reader task, released
    /// in `stop()`. `AVAudioConverter` keeps polyphase filter state across
    /// calls, so feeding it one packet at a time yields glitch-free
    /// continuous conversion.
    private var resampleConverter: AVAudioConverter?
    /// Reused converter input buffer (one packet, 44.1 kHz). The reader
    /// copies the de-interleaved Float32 packet in, then hands it to the
    /// converter.
    private var resampleInBuffer: AVAudioPCMBuffer?
    /// Reused converter output buffer (device rate). Capacity is sized for
    /// the worst-case upsample ratio so one input packet always fits.
    private var resampleOutBuffer: AVAudioPCMBuffer?
    /// Reused single-slot input holder for the converter (reader thread).
    private let resampleFeed = ConverterInputFeed()

    // MARK: - Layer 2: closed-loop clock following (reader thread, non-RT)
    /// Second-stage near-unity resampler that applies the PI controller's
    /// trim ratio so the local device clock stays slaved to OwnTone's fifo
    /// WRITE rate. Runs on the reader thread AFTER `resampleConverter`
    /// (or as the sole resampler in the 44.1 kHz passthrough path). See
    /// `FractionalTrimResampler` and `updateClockControl`.
    private let trimResampler: FractionalTrimResampler
    /// Trim-stage output channels (device rate), fixed worst-case capacity
    /// so no allocation happens per packet. Fed straight into the ring.
    private let trimOut: [UnsafeMutablePointer<Float>]
    /// `outputs` argument for `trimResampler.process` — points at `trimOut`.
    private let trimOutPtrs: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    /// `inputs` argument for `trimResampler.process` — re-pointed each
    /// packet at either the converter output or the passthrough scratch.
    private let trimInChansPtr: UnsafeMutablePointer<UnsafePointer<Float>>
    /// Ring-write channel pointers wired to `trimOut`.
    private let trimRingChansPtr: UnsafeMutablePointer<UnsafePointer<Float>>
    /// Current trim ratio (outFrames/inFrames), 1.0 ± a few hundred ppm.
    /// Reader-thread-owned: written by `updateClockControl`, read where the
    /// trim resampler runs. Never crosses to the RT render thread.
    private var controlRatio: Double = 1.0
    /// PI integrator term (a fractional-ratio offset), clamped to
    /// ±`maxRatioPpm`. Cancels the constant local-vs-OwnTone clock offset.
    private var controlIntegrator: Double = 0.0
    /// Last `_resyncSeqWritten` value the controller observed. A change
    /// means render() fired a jump-resync since the last control tick, so
    /// the integrator is zeroed (anti-windup) — the cursor was snapped and
    /// the fill is back near target.
    private var controlLastResyncSeq: UInt64 = 0

    /// AUHAL render block size (frames), stamped by `render()` under
    /// `stateLock`. The controller needs it to compute the steady-state
    /// target fill (`backoffFrames + framesPerRender`) — the exact
    /// operating point render() settles at when no resync fires, so the
    /// loop trims residual drift without shifting the equilibrium. 0 until
    /// the first render.
    private var _lastRenderFrames: Int = 0

    /// Diagnostic — every successful socket read of one full packet
    /// bumps this. Should advance at ~31 Hz (44.1 kHz / 1408 B per
    /// packet ÷ 4 B per frame ÷ 352 frames). Zero after a few seconds
    /// of "running" → broadcaster is starved or not connected.
    public private(set) var packetsReceived: UInt64 = 0
    /// Diagnostic — render callback ticks. Same role as
    /// `LocalOutput.renderTickCount`.
    public private(set) var renderTickCount: UInt64 = 0
    /// Diagnostic — peak abs sample of the most recent rendered block,
    /// measured BEFORE the volume gain is applied.
    ///
    /// Pre-gain deliberately. `peak: 0.0000` is this project's long-standing
    /// "no audio is reaching this bridge" signal, and once the user can
    /// actually attenuate a speaker, a post-gain peak would shrink whenever
    /// they turned it down — making a working bridge look like a starved one.
    /// The gain in force is published separately as `lastRenderGain`, so the
    /// audible level is still recoverable as `lastRenderPeak * lastRenderGain`.
    public private(set) var lastRenderPeak: Float = 0
    /// Diagnostic — volume gain in force at the end of the most recent
    /// rendered block (the ramp's landing value, not its target).
    public private(set) var lastRenderGain: Float = 1
    /// Diagnostic — most recent error string (empty if everything's OK).
    public private(set) var lastError: String = ""

    // Reader-task state
    private var fd: Int32 = -1
    private var readerTask: Task<Void, Never>?
    /// Monotonic counter the render callback reads from. Producer is
    /// the reader Task; consumer is the AUHAL render callback. Updated
    /// via `RingBuffer.write` (which has its own atomic publish) so
    /// nothing else needs to be atomic here.
    private var readCursor: Int64 = 0

    /// Per-bridge software-gain multiplier applied in the render
    /// callback. Mirrors the per-channel-pair fallback in
    /// `LocalOutput` for the stereo-mode aggregate path: many DP/HDMI
    /// display speakers (e.g. ExternalDisplay) expose no writable
    /// `kAudioDevicePropertyVolumeScalar`, so the user's slider would
    /// otherwise have no audible effect on those devices in whole-
    /// home mode. Lock-protected because the slider runs on
    /// MainActor while render() runs on a CoreAudio RT thread; the
    /// unfair lock has to be brief and uncontended on the RT side
    /// (single Float read).
    ///
    /// Default 1.0 means "no attenuation"; setting to 0 mutes the
    /// device. Clamped to [0, 1] in `setVolume`. `setVolume` updates
    /// `_volumeGainTarget`; the render callback ramps `_current`
    /// toward target across `volumeRampMs` (~10 ms) so volume changes
    /// don't click on non-zero signal (FIX 2a).
    private var _volumeGainCurrent: Float = 1.0
    private var _volumeGainTarget: Float = 1.0
    private static let volumeRampMs: Double = 10.0

    /// How many leading samples of a block the peak diagnostic inspects. A
    /// bounded prefix rather than the whole block so the cost per render is
    /// constant regardless of the device's render quantum.
    private static let peakMeasurementSamples: Int = 128

    // MARK: - Per-device delay trim (user listening-position compensation)
    //
    // The trim is a pure READ-TAP OFFSET: render() reads the ring at
    // `startFrame - trimFrames` while `readCursor` keeps advancing from the
    // UNTRIMMED `startFrame`. That distinction is the whole design.
    //
    // `updateClockControl()` measures `fill = writePosition - readCursor`
    // against `backoffFrames + framesPerRender`. Because readCursor never
    // sees the trim, `fill`, `error`, `controlIntegrator` and `controlRatio`
    // are bit-identical to a zero-trim run for the same write history — the
    // PLL is structurally blind to the trim, so a steady-state bias can never
    // be mistaken for clock drift and slewed away.
    //
    // The rejected alternative was folding the trim into `backoffFrames` /
    // the controller target. That makes it an INPUT to the loop: with
    // `maxRatioPpm = 300` (1 ms per 3.3 s) a 3 ms trim would take ~10 s to
    // walk in and a 100 ms trim ~5.5 minutes, with the integrator pinned at
    // its clamp throughout.
    //
    // Only non-negative values are representable: the pipe cannot surrender a
    // byte before OwnTone releases it, so nothing can play EARLY. The signed
    // user intent is turned into non-negative per-leg values upstream by
    // `DelayTrimNormalizer`.
    private var _trimFramesCurrent: Int = 0
    private var _trimFramesTarget: Int = 0
    /// Half-length of the equal-power cross-fade that bridges a tap move.
    /// ~5 ms each side of the splice; deliberately shorter than
    /// `volumeRampMs` because this masks a waveform discontinuity rather
    /// than tracking a level the user is listening for.
    private static let trimRampMs: Double = 5.0
    /// `trimRampMs` in device-rate frames, computed once in `openAudioUnit`
    /// alongside `backoffFrames` (both are read unlocked by render(), which
    /// is safe only because both are written before `AudioOutputUnitStart`).
    private var trimRampFrames: Int = 0
    /// Render quantum assumed by `maxTrimFrames` before the first AUHAL
    /// callback has reported a real one. Deliberately pessimistic (large
    /// quanta shrink the headroom) so a trim set during startup can never be
    /// admitted above what the ring will actually hold.
    private static let assumedRenderQuantumFrames: Int = 2_048
    /// Scratch channels for the cross-fade's second ring read. Pre-allocated
    /// at the worst-case render quantum so the RT path never touches the
    /// heap; a block larger than this falls back to a hard tap switch, which
    /// only ever happens on hardware with an unusually huge buffer.
    private static let crossfadeCapacityFrames: Int = 4_096
    private let crossfadeBuffers: [UnsafeMutablePointer<Float>]
    private let crossfadePtrs: UnsafeMutablePointer<UnsafeMutablePointer<Float>>

    // MARK: - Drift-resync diagnostics (FIX 2d)
    // render() stamps event metadata under the lock; the non-RT
    // reader task drains via `drainDriftResyncLog` → `DiagnosticLog`.
    private var _resyncSeqWritten: UInt64 = 0
    private var _resyncSeqLogged: UInt64 = 0
    private var _resyncFromCursor: Int64 = 0
    private var _resyncToTarget: Int64 = 0
    private var _resyncWritePos: Int64 = 0
    /// Stored as `StaticString` so the render-thread store does NOT
    /// allocate (Swift `String(describing:)` would heap-allocate).
    /// Stringification happens in the non-RT drain function.
    private var _resyncReason: StaticString = ""
    public private(set) var driftResyncCount: UInt64 = 0
    public var lastDriftResyncReason: String {
        stateLock.withLock { String(describing: _resyncReason) }
    }
    public var lastDriftResyncFrameDelta: Int64 {
        stateLock.withLock { abs(_resyncFromCursor - _resyncToTarget) }
    }

    // MARK: - L_local measurement (Layer 3 input)
    //
    // How long a byte takes to get from OwnTone's output fifo to the air, on
    // THIS device. The AirPlay leg is delayed by this much (via OwnTone's
    // per-output `offset_ms`) so the two legs land together; the local leg
    // itself cannot be advanced, because the pipe cannot surrender a byte
    // before OwnTone releases it. Everything below is read from the running
    // pipeline rather than assumed — see `localPipelineLatencyMs`.

    /// `kAudioDevicePropertyLatency` + safety offset + max stream latency for
    /// the bound device, in DEVICE-rate frames. Probed once in
    /// `openAudioUnit` (the values are fixed for the life of an AUHAL
    /// binding); 0 before the unit opens.
    private var hardwareLatencyFrames: Int64 = 0

    /// Mean latency contributed by the broadcaster's packet quantisation.
    /// The fan-out is one whole OwnTone fifo packet at a time — 352 frames at
    /// 44.1 kHz ≈ 8 ms — so a byte waits on average half a packet before it
    /// ships.
    private static let packetQuantizationMs: Double =
        (352.0 / 44_100.0) * 1000.0 / 2.0

    /// Measured `L_local` in milliseconds, or nil before the AUHAL has opened
    /// and rendered at least once (until then the render quantum is unknown
    /// and any answer would be a guess dressed as a measurement).
    ///
    ///     L_local = ring fill the PLL holds (`backoffFrames` + render quantum)
    ///             + broadcaster packet quantisation
    ///             + the device's own presentation latency
    ///
    /// The first term is the Layer-2 controller's steady-state operating
    /// point — the same `backoffFrames + framesPerRender` target
    /// `updateClockControl` servos to — so this tracks whatever the loop is
    /// actually holding rather than a nominal figure. Read-only: computing it
    /// touches no controller state.
    public var localPipelineLatencyMs: Double? {
        let (renderFrames, hardware) = stateLock.withLock {
            (self._lastRenderFrames, self.hardwareLatencyFrames)
        }
        guard renderFrames > 0, deviceSampleRate > 0 else { return nil }
        let frames = Double(backoffFrames + Int64(renderFrames) + hardware)
        return frames / deviceSampleRate * 1000.0 + Self.packetQuantizationMs
    }

    public init(
        deviceID: AudioObjectID,
        deviceUID: String,
        socketPath: URL
    ) {
        self.deviceID = deviceID
        self.deviceUID = deviceUID
        self.socketPath = socketPath
        self.ring = RingBuffer(
            channelCount: 2,
            capacityFrames: Self.defaultRingCapacityFrames
        )
        let ptrs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 2)
        let placeholder = UnsafeMutablePointer<Float>.allocate(capacity: 1)
        placeholder.initialize(to: 0)
        ptrs.initialize(repeating: placeholder, count: 2)
        self.outPtrs = ptrs
        self.outPtrPlaceholder = placeholder
        // 352 frames per OwnTone fifo packet (1408 B / 4 B-per-frame for
        // s16 stereo). Matches fifo.c's FIFO_PACKET_SIZE and the sidecar
        // broadcaster's LOCAL_FIFO_CHUNK_BYTES.
        let framesPerPacket = packetBytes / (2 * MemoryLayout<Int16>.size)
        self.scratchFramesPerPacket = framesPerPacket
        let scratch: [UnsafeMutablePointer<Float>] = (0..<2).map { _ in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: framesPerPacket)
            p.initialize(repeating: 0, count: framesPerPacket)
            return p
        }
        self.scratchFloat = scratch
        // chansPtr holds two `UnsafePointer<Float>` slots that the reader
        // populates with addresses of `scratchFloat[0]` / `scratchFloat[1]`
        // each iteration. The pointed-to pointers don't change since
        // `scratchFloat` is `let` — we could in principle initialize once
        // here, but populating each iteration keeps the read loop's
        // intent obvious and the cost is two stores per packet.
        let chans = UnsafeMutablePointer<UnsafePointer<Float>>.allocate(capacity: 2)
        chans[0] = UnsafePointer(scratch[0])
        chans[1] = UnsafePointer(scratch[1])
        self.chansPtr = chans

        // Layer-2 trim stage. Fixed worst-case output buffers so the
        // per-packet path stays allocation-free (same discipline as
        // `scratchFloat`). Two channel-pointer slots each for the
        // resampler's `outputs`/`inputs` args and the ring write.
        self.trimResampler = FractionalTrimResampler(channelCount: 2)
        let trimCap = Self.trimOutputCapacityFrames
        let trimBufs: [UnsafeMutablePointer<Float>] = (0..<2).map { _ in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: trimCap)
            p.initialize(repeating: 0, count: trimCap)
            return p
        }
        self.trimOut = trimBufs
        let trimOutP = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 2)
        trimOutP[0] = trimBufs[0]
        trimOutP[1] = trimBufs[1]
        self.trimOutPtrs = trimOutP
        let trimIn = UnsafeMutablePointer<UnsafePointer<Float>>.allocate(capacity: 2)
        trimIn[0] = UnsafePointer(placeholder)
        trimIn[1] = UnsafePointer(placeholder)
        self.trimInChansPtr = trimIn
        let trimRing = UnsafeMutablePointer<UnsafePointer<Float>>.allocate(capacity: 2)
        trimRing[0] = UnsafePointer(trimBufs[0])
        trimRing[1] = UnsafePointer(trimBufs[1])
        self.trimRingChansPtr = trimRing

        // Delay-trim cross-fade scratch (RT path, see `_trimFramesCurrent`).
        let xfadeCap = Self.crossfadeCapacityFrames
        let xfadeBufs: [UnsafeMutablePointer<Float>] = (0..<2).map { _ in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: xfadeCap)
            p.initialize(repeating: 0, count: xfadeCap)
            return p
        }
        self.crossfadeBuffers = xfadeBufs
        let xfadePtrs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 2)
        xfadePtrs[0] = xfadeBufs[0]
        xfadePtrs[1] = xfadeBufs[1]
        self.crossfadePtrs = xfadePtrs
    }

    deinit {
        stop()
        outPtrs.deallocate()
        outPtrPlaceholder.deinitialize(count: 1)
        outPtrPlaceholder.deallocate()
        chansPtr.deallocate()
        for p in scratchFloat {
            p.deinitialize(count: scratchFramesPerPacket)
            p.deallocate()
        }
        trimOutPtrs.deallocate()
        trimInChansPtr.deallocate()
        trimRingChansPtr.deallocate()
        for p in trimOut {
            p.deinitialize(count: Self.trimOutputCapacityFrames)
            p.deallocate()
        }
        crossfadePtrs.deallocate()
        for p in crossfadeBuffers {
            p.deinitialize(count: Self.crossfadeCapacityFrames)
            p.deallocate()
        }
    }

    // MARK: - Volume

    /// Apply the user's slider value to this bridge. Clamped to [0, 1].
    /// The render callback applies the multiplier to every Float32
    /// sample it writes to AUHAL; takes effect on the next render
    /// block (≤ 10 ms in practice).
    ///
    /// This is the whole-home-mode counterpart to
    /// `LocalOutput.setSoftwareGain(pair:gain:)` — same rationale
    /// (DP/HDMI displays expose no writable hardware volume), same
    /// digital-attenuation trade-off (very low values lose effective
    /// bit depth).
    public func setVolume(_ v: Float) {
        let clamped = max(0, min(1, v))
        stateLock.withLock { _volumeGainTarget = clamped }
    }

    /// Read the current software-gain TARGET (last value passed to
    /// `setVolume`), not the in-flight ramp value — set/get symmetry
    /// matters for Phase-2 snapshot/restore.
    public var currentVolume: Float {
        stateLock.withLock { _volumeGainTarget }
    }

    // MARK: - Delay trim

    /// Largest read-tap offset (device-rate frames) the ring can serve
    /// without falling outside its valid window.
    ///
    /// `render()` reads `frames` frames starting at
    /// `cursor - trim`, and `RingBuffer.read` only guarantees data at or
    /// above `writePos - capacity`. Three terms are reserved:
    ///
    ///  * `backoffFrames` — where the PLL holds the cursor.
    ///  * `2 · framesPerRender` — one block for the read itself, one so a
    ///    block arriving slightly early cannot graze the boundary. A graze
    ///    does not crash; it zero-fills, which is a silent dropout and
    ///    therefore the worst failure mode available.
    ///  * `resyncDriftMs` — render() tolerates the cursor lagging `target`
    ///    by up to this much before the backstop snaps it, and the trimmed
    ///    tap sits that far back again on top of the trim itself. Omitting
    ///    this term made the bound merely usually-true.
    ///
    /// Derived from the LIVE device rate and the LIVE render quantum, never
    /// from a static table: a 96 kHz DAC has less than half the headroom of
    /// a 44.1 kHz one.
    public var maxTrimFrames: Int {
        let renderFrames = stateLock.withLock { self._lastRenderFrames }
        let quantum = renderFrames > 0 ? renderFrames : Self.assumedRenderQuantumFrames
        return Self.maxTrimFrames(
            capacityFrames: ringCapacityFrames,
            backoffFrames: Int(backoffFrames),
            framesPerRender: quantum,
            driftAllowanceFrames: Self.driftAllowanceFrames(
                forSampleRate: deviceSampleRate
            )
        )
    }

    /// Pure form of `maxTrimFrames`, so the ring-headroom arithmetic can be
    /// checked across every plausible device rate / quantum combination
    /// without a live AUHAL.
    static func maxTrimFrames(
        capacityFrames: Int,
        backoffFrames: Int,
        framesPerRender: Int,
        driftAllowanceFrames: Int
    ) -> Int {
        max(
            0,
            capacityFrames - backoffFrames - 2 * framesPerRender
                - driftAllowanceFrames
        )
    }

    /// `resyncDriftMs` in frames at an arbitrary rate — the worst-case extra
    /// lag render() will tolerate before snapping the cursor.
    static func driftAllowanceFrames(forSampleRate rate: Double) -> Int {
        Int((rate * Self.resyncDriftMs / 1000.0).rounded())
    }

    /// `baselineBackoffMs` expressed in frames at an arbitrary rate. Same
    /// expression `openAudioUnit` uses, factored out so a test cannot drift
    /// from the real thing by re-deriving it.
    static func backoffFrames(forSampleRate rate: Double) -> Int {
        Int((rate * Self.baselineBackoffMs / 1000.0).rounded())
    }

    /// `maxTrimFrames` expressed in whole milliseconds (rounded down, so the
    /// reported ceiling is always actually servable).
    public var maxTrimMs: Int {
        guard deviceSampleRate > 0 else { return 0 }
        return Int((Double(maxTrimFrames) / deviceSampleRate * 1000.0).rounded(.down))
    }

    /// Hold this device back by `ms` milliseconds relative to the fifo
    /// release instant. Only non-negative delays exist (see
    /// `_trimFramesCurrent`); negative input is treated as 0 rather than
    /// silently wrapping.
    ///
    /// Clamped to `maxTrimFrames` — the caller's range is an ergonomic
    /// bound, this is the safety bound. Takes effect on the next render
    /// block, cross-faded over ~`trimRampMs` so the tap move does not click.
    /// Setting the value already in force is a no-op all the way down: the
    /// render callback compares target to current and takes the cheap path.
    public func setTrimMs(_ ms: Int) {
        let requested = max(0, ms)
        let frames = Int((Double(requested) / 1000.0 * deviceSampleRate).rounded())
        let clamped = min(frames, maxTrimFrames)
        stateLock.withLock { _trimFramesTarget = clamped }
    }

    /// The trim TARGET currently in force, in device-rate frames (the value
    /// render() is converging on, not the in-flight cross-fade state).
    public var currentTrimFrames: Int {
        stateLock.withLock { _trimFramesTarget }
    }

    // MARK: - Lifecycle

    /// Open AUHAL on the target device, connect to the broadcast socket,
    /// and start the reader task. Idempotent — calling start() on an
    /// already-running bridge is a no-op.
    public func start() throws {
        if initialized { return }
        try openSocket()
        do {
            try openAudioUnit()
        } catch {
            // AUHAL setup failed — close the socket we just opened so
            // we don't leak the fd.
            closeSocket()
            throw error
        }
        // Reader runs at userInitiated priority. It does blocking
        // syscalls (read on the Unix socket); a Task.detached gives it
        // its own thread without contending on the cooperative pool.
        readerTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.runReader()
        }
        initialized = true
    }

    /// Cancel the reader, close the socket, stop and dispose the AUHAL.
    /// Safe to call multiple times. Same retain-rollback pattern as
    /// LocalOutput.stop() — we only release the +1 retain on `self`
    /// (handed to the AUHAL via inputProcRefCon) AFTER Dispose so the
    /// last in-flight render callback can't fire on a freed object.
    ///
    /// Ordering rationale (mirrors LocalOutput.stop):
    ///   1. Cancel the reader task FIRST so it stops writing into the
    ///      ring while we're tearing the AUHAL down.
    ///   2. Close the socket — this unblocks the reader's `recv` if it
    ///      was sleeping inside the kernel; recv returns -1 / EBADF and
    ///      the loop exits via the cancellation check.
    ///   3. AudioOutputUnitStop drains the in-flight render block
    ///      synchronously. Apple's docs guarantee this; on Tahoe it's
    ///      observably weaker, which is why the +1 retain on self
    ///      handed to the render callback's refCon must outlive the
    ///      Stop call. We release it AFTER Dispose, below.
    ///   4. Uninitialize → Dispose. Reversing has been observed to
    ///      deadlock coreaudiod (see BlackHole issue tracker).
    ///   5. ONLY AFTER Dispose, release the refCon retain so a final
    ///      stragler render callback can still safely call
    ///      `takeUnretainedValue` against a live LocalAirPlayBridge.
    public func stop() {
        // 1. Cancel reader. It may still be blocked in recv until we
        //    close the socket below, but observing this flag once recv
        //    returns is the fast-exit signal.
        readerTask?.cancel()
        readerTask = nil
        // 2. Close the socket. This unblocks any in-flight recv() with
        //    EBADF, letting the reader loop exit.
        closeSocket()
        // 3-4. AUHAL teardown. Skip cleanly if start() failed before
        //      assigning self.unit.
        if let unit = unit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            self.unit = nil
        }
        // 5. Release the +1 retain we placed on self when handing the
        //    opaque pointer to the AUHAL. Done AFTER Dispose so any
        //    in-flight render callback can complete safely. Mark
        //    consumed BEFORE releasing so a defensive re-entry sees
        //    nil and skips the release (impossible in practice, but
        //    cheap insurance against future refactors).
        if let opaque = refConOpaque {
            refConOpaque = nil
            Unmanaged<LocalAirPlayBridge>.fromOpaque(opaque).release()
        }
        // Release the resampler (ARC). The reader task is already
        // cancelled (step 1) so nothing else touches these.
        resampleConverter = nil
        resampleInBuffer = nil
        resampleOutBuffer = nil
        initialized = false
    }

    // MARK: - Socket

    private func openSocket() throws {
        let s = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        if s < 0 { throw BridgeError.socketCreationFailed(errno) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        socketPath.path.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                let dstPtr = UnsafeMutableRawPointer(dst).assumingMemoryBound(to: CChar.self)
                let n = min(strlen(src), cap - 1)
                memcpy(dstPtr, src, n)
                dstPtr[n] = 0
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(s, $0, len)
            }
        }
        if rc != 0 {
            let e = errno
            Darwin.close(s)
            throw BridgeError.socketConnectFailed(e)
        }
        // Enlarge the receive buffer so a brief reader hiccup queues in the
        // kernel instead of back-pressuring the broadcaster's send buffer
        // into EAGAIN drops. Matches the broadcaster's per-client SO_SNDBUF.
        var rcvbuf: Int32 = Int32(Self.socketBufferBytes)
        _ = setsockopt(
            s, SOL_SOCKET, SO_RCVBUF, &rcvbuf,
            socklen_t(MemoryLayout<Int32>.size)
        )
        fd = s
    }

    /// Receive-buffer target for the broadcast socket, matched to the
    /// sidecar broadcaster's `LOCAL_FIFO_CLIENT_SNDBUF`. Large enough to
    /// ride out a startup catch-up burst without dropping, small enough not
    /// to hide a chronically slow reader behind a multi-second backlog.
    private static let socketBufferBytes: Int = 64 * 1024

    private func closeSocket() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    // MARK: - Reader task

    /// Pulls 1408-byte packets off the broadcast socket, converts s16le
    /// interleaved → Float32 non-interleaved, writes into the ring.
    /// Runs forever until cancelled. Sidecar mode changes and broadcaster
    /// resets can briefly close the accepted client socket; whole-home
    /// should reconnect instead of rendering permanent silence.
    private func runReader() async {
        // One-time scaling constant for s16 → float.
        let invInt16Max: Float = 1.0 / 32_767.0
        var buffer = [UInt8](repeating: 0, count: packetBytes)
        while !Task.isCancelled {
            if fd < 0 {
                do {
                    try openSocket()
                } catch BridgeError.socketConnectFailed(let err) {
                    lastError = "socket reconnect errno=\(err)"
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    continue
                } catch {
                    lastError = "socket reconnect failed"
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    continue
                }
                // A reconnect is a genuine stream break: the fifo backlog
                // was lost. Reset the Layer-2 loop so stale integrator
                // wind-up and resampler phase don't corrupt the fresh
                // stream. render()'s startup resync re-seats the cursor.
                trimResampler.reset()
                controlIntegrator = 0
                controlRatio = 1.0
            }
            // Read EXACTLY one OwnTone packet per iteration. The
            // sidecar's broadcaster sends one full packet per send(),
            // but TCP-shaped Unix sockets coalesce, so we MUST loop on
            // recv until we have packetBytes bytes — otherwise we'd
            // mis-frame the s16le stream and play noise.
            let ok = await readExactly(into: &buffer, count: packetBytes)
            if !ok {
                closeSocket()
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: 250_000_000)
                continue
            }
            // De-interleave + convert in-place. The packet contains
            // `framesPerPacket` frames of stereo s16le — read from
            // buffer in 2-byte LE pairs, write into scratchFloat[ch].
            // Avoid Swift Array-of-Int16 allocation by reading directly
            // through the UInt8 array.
            let n = scratchFramesPerPacket
            buffer.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let s16 = raw.bindMemory(to: Int16.self)
                let l = scratchFloat[0]
                let r = scratchFloat[1]
                var src = 0
                for i in 0..<n {
                    // Int16 is host-endian on Apple Silicon (LE) so we
                    // can read directly. If we ever ship to BE we'd
                    // need an explicit byteswap.
                    let lv = s16[src]; src += 1
                    let rv = s16[src]; src += 1
                    l[i] = Float(lv) * invInt16Max
                    r[i] = Float(rv) * invInt16Max
                }
            }
            // Resample 44.1 kHz → device rate on this (non-RT) reader
            // thread, then publish to the ring. RingBuffer.write does its
            // own release-store on the cursor so the render callback sees
            // both the new cursor and the new audio data.
            if let converter = resampleConverter,
               let inBuf = resampleInBuffer,
               let outBuf = resampleOutBuffer,
               let inCh = inBuf.floatChannelData,
               let outCh = outBuf.floatChannelData {
                // Copy the de-interleaved packet into the converter's input
                // buffer, then hand it over exactly once. AVAudioConverter
                // keeps its polyphase filter state across calls, so this
                // yields glitch-free continuous conversion.
                inBuf.frameLength = AVAudioFrameCount(n)
                inCh[0].update(from: scratchFloat[0], count: n)
                inCh[1].update(from: scratchFloat[1], count: n)
                // Hand this one packet to the converter exactly once. The
                // reusable feed holder avoids mutating a captured var.
                let feed = resampleFeed
                feed.buffer = inBuf
                let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                    if let pending = feed.buffer {
                        feed.buffer = nil
                        outStatus.pointee = .haveData
                        return pending
                    }
                    outStatus.pointee = .noDataNow
                    return nil
                }
                outBuf.frameLength = outBuf.frameCapacity
                var convErr: NSError?
                let convStatus = converter.convert(
                    to: outBuf, error: &convErr, withInputFrom: inputBlock
                )
                let produced = Int(outBuf.frameLength)
                if convStatus == .error {
                    lastError = "resample failed code=\(convErr?.code ?? -1)"
                } else if produced > 0 {
                    // Layer 2: apply the PI trim ratio to the device-rate
                    // stream, then publish. Locks the device clock to
                    // OwnTone's fifo write rate via the ring fill level.
                    trimInChansPtr[0] = UnsafePointer(outCh[0])
                    trimInChansPtr[1] = UnsafePointer(outCh[1])
                    writeTrimmed(inFrames: produced)
                }
            } else {
                // Passthrough: the device already runs at the 44.1 kHz feed
                // rate, so the converter is bypassed — but the Layer-2 trim
                // stage still runs (the device's real clock still has to be
                // locked to OwnTone's write rate). scratchFloat / trim
                // buffers are pre-allocated, so zero heap traffic here.
                trimInChansPtr[0] = UnsafePointer(scratchFloat[0])
                trimInChansPtr[1] = UnsafePointer(scratchFloat[1])
                writeTrimmed(inFrames: n)
            }
            packetsReceived &+= 1
            // Layer-2 control tick, decimated off the per-packet path.
            if packetsReceived % Self.controlUpdateIntervalPackets == 0 {
                updateClockControl()
            }
            if !lastError.isEmpty { lastError = "" }
            // Drain drift-resync events (FIX 2d, non-RT side). DiagnosticLog.log
            // opens+seeks+writes launch.log synchronously, so calling it every
            // packet turned a resync burst into a reader-thread stall: the
            // reader fell behind, the broadcaster's small per-client SO_SNDBUF
            // filled, packets were EAGAIN-dropped, the ring starved, and the
            // starvation produced MORE resyncs — a self-sustaining spiral that
            // choked the whole local leg. Drain at most ~once/sec (the drain
            // is already batched: it logs one line with events=count) so the
            // file I/O leaves the per-packet hot path.
            if packetsReceived % Self.driftLogDrainIntervalPackets == 0 {
                drainDriftResyncLog()
            }
        }
    }

    /// Run the Layer-2 trim resampler over `inFrames` frames pointed at by
    /// `trimInChansPtr` and publish the result to the ring. Reader thread
    /// only. `controlRatio` is the live PI trim; near 1.0 so the output
    /// length ≈ `inFrames`.
    private func writeTrimmed(inFrames: Int) {
        let produced = trimResampler.process(
            inputs: trimInChansPtr,
            inFrames: inFrames,
            ratio: controlRatio,
            outputs: trimOutPtrs,
            outCapacity: Self.trimOutputCapacityFrames
        )
        if produced > 0 {
            ring.write(channels: trimRingChansPtr, frames: produced)
        }
    }

    /// Layer-2 PI update: measure the ring fill error against the
    /// steady-state target and nudge `controlRatio`. Runs on the non-RT
    /// reader thread every `controlUpdateIntervalPackets`.
    ///
    /// Error detector: `fill = writePosition - readCursor`. The target is
    /// `backoffFrames + framesPerRender`, exactly where render() settles
    /// the cursor with no resync (so u = 0 at today's equilibrium — the
    /// loop is non-regressing, it only trims residual drift).
    ///
    /// Sign: `fill` too high ⇒ OwnTone outran the device ⇒ emit fewer
    /// output frames per input ⇒ ratio down ⇒ `u < 0`. Hence
    /// `u = -(Kp·e + integrator)`.
    private func updateClockControl() {
        let writePos = ring.writePosition
        let snap: (cursor: Int64, frames: Int, seq: UInt64) = stateLock.withLock {
            (self.readCursor, self._lastRenderFrames, self._resyncSeqWritten)
        }
        // Anti-windup: a jump-resync since the last tick snapped the cursor
        // back to target, so discard the integrator wind-up that preceded
        // it. (controlRatio itself is slewed, not snapped, so no click.)
        if snap.seq != controlLastResyncSeq {
            controlLastResyncSeq = snap.seq
            controlIntegrator = 0
        }
        // No render has happened yet → no meaningful target. Hold neutral.
        guard snap.frames > 0 else { return }
        let target = backoffFrames + Int64(snap.frames)
        let fill = writePos - snap.cursor
        let error = Double(fill - target)
        let deadbandFrames = Self.controlDeadbandMs / 1000.0 * deviceSampleRate
        // Inside the deadband: freeze the integrator and hold the ratio so
        // the loop doesn't limit-cycle around the target.
        if abs(error) < deadbandFrames { return }
        let maxRatio = Self.maxRatioPpm * 1.0e-6
        controlIntegrator += Self.controlKi * error
        controlIntegrator = min(max(controlIntegrator, -maxRatio), maxRatio)
        var u = -(Self.controlKp * error + controlIntegrator)
        u = min(max(u, -maxRatio), maxRatio)
        // Slew-limit |Δu| per update so a step in error can't jerk the
        // pitch audibly.
        let slew = Self.slewPpmPerUpdate * 1.0e-6
        let prevU = controlRatio - 1.0
        let du = min(max(u - prevU, -slew), slew)
        controlRatio = 1.0 + (prevU + du)
    }

    /// ~1 second at the 44.1 kHz feed's ~125 packets/sec. Keeps drift-resync
    /// logging off the per-packet path (see the call site).
    private static let driftLogDrainIntervalPackets: UInt64 = 128

    /// Blocking ``recv`` loop until exactly `count` bytes are read.
    /// Returns false on EOF / error / cancellation; the caller should
    /// then drop out of the read loop.
    private func readExactly(into buffer: inout [UInt8], count: Int) async -> Bool {
        var got = 0
        while got < count {
            if Task.isCancelled { return false }
            let s = fd
            if s < 0 { return false }
            let n: Int = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.recv(
                    s,
                    base.advanced(by: got),
                    count - got,
                    0
                )
            }
            if n > 0 {
                got += n
                continue
            }
            if n == 0 {
                // EOF — sidecar closed our socket (mode switch back to
                // stereo / shutdown).
                lastError = "socket EOF"
                return false
            }
            // n < 0
            let e = errno
            if e == EINTR { continue }
            // Yield once on EAGAIN to avoid busy-loop. SOCK_STREAM
            // shouldn't normally hit EAGAIN since fd is blocking, but
            // be defensive.
            if e == EAGAIN || e == EWOULDBLOCK {
                try? await Task.sleep(nanoseconds: 1_000_000)  // 1 ms
                continue
            }
            lastError = "recv errno=\(e)"
            return false
        }
        return true
    }

    // MARK: - AUHAL

    /// Read a CoreAudio output device's nominal sample rate. Returns nil
    /// on any CoreAudio error or a non-positive rate, so the caller can
    /// fall back to the feed rate.
    private static func nominalSampleRate(of device: AudioObjectID) -> Double? {
        // NominalSampleRate is a GLOBAL-scope device property (matches
        // AggregateDevice.swift and CoreAudioDiscovery.swift). Querying it
        // with the output scope fails, which would silently fall back to
        // the feed rate and disable resampling.
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &rate)
        guard status == noErr, rate > 0 else { return nil }
        return Double(rate)
    }

    /// Build the 44.1 kHz → `deviceRate` resampler and its reusable
    /// buffers. When the device already runs at 44.1 kHz this leaves
    /// `resampleConverter` nil and the reader writes the de-interleaved
    /// feed straight to the ring (passthrough). Runs on the (non-RT)
    /// `start()` path.
    private func setUpResampler(deviceRate: Double) throws {
        guard deviceRate != inboundSampleRate else {
            resampleConverter = nil
            resampleInBuffer = nil
            resampleOutBuffer = nil
            return
        }
        guard
            let inFmt = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: inboundSampleRate,
                channels: AVAudioChannelCount(channelCount),
                interleaved: false
            ),
            let outFmt = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: deviceRate,
                channels: AVAudioChannelCount(channelCount),
                interleaved: false
            ),
            let converter = AVAudioConverter(from: inFmt, to: outFmt),
            let inBuf = AVAudioPCMBuffer(
                pcmFormat: inFmt,
                frameCapacity: AVAudioFrameCount(scratchFramesPerPacket)
            )
        else {
            throw BridgeError.configurationFailed(kAudioUnitErr_FormatNotSupported)
        }
        // Output capacity: worst-case upsample of one input packet plus a
        // generous slop for converter priming latency. 352 frames * (rate
        // / 44100), rounded up, + 512.
        let outCapacity = Int(
            (Double(scratchFramesPerPacket) * deviceRate / inboundSampleRate).rounded(.up)
        ) + 512
        guard
            let outBuf = AVAudioPCMBuffer(
                pcmFormat: outFmt,
                frameCapacity: AVAudioFrameCount(outCapacity)
            )
        else {
            throw BridgeError.configurationFailed(kAudioUnitErr_FormatNotSupported)
        }
        resampleConverter = converter
        resampleInBuffer = inBuf
        resampleOutBuffer = outBuf
    }

    /// Set up an AUHAL on `deviceID` and wire its render callback to
    /// our ring buffer. Mirrors LocalOutput.start(). The AUHAL input
    /// scope is opened at the DEVICE's nominal sample rate; the reader
    /// thread resamples OwnTone's 44.1 kHz feed up to that rate before it
    /// reaches the ring, so the AUHAL performs no implicit conversion.
    private func openAudioUnit() throws {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw BridgeError.audioComponentNotFound
        }
        var unitOut: AudioUnit?
        var status = AudioComponentInstanceNew(component, &unitOut)
        guard status == noErr, let unit = unitOut else {
            throw BridgeError.audioUnitInstantiationFailed(status)
        }
        // From here on, EVERY error path must dispose `unit` —
        // AudioComponentInstanceNew has already allocated kernel state.
        // We track success with a sentinel; defer disposes the local
        // unit when the function exits via an error path.
        var unitInitialized = false
        var unitStarted = false
        var unitInstalled = false
        defer {
            if !unitInstalled {
                if unitStarted { AudioOutputUnitStop(unit) }
                if unitInitialized { AudioUnitUninitialize(unit) }
                AudioComponentInstanceDispose(unit)
            }
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
        guard status == noErr else { throw BridgeError.configurationFailed(status) }

        // Discover the device's real nominal sample rate and set up the
        // resampler (44.1 kHz feed → device rate). See `inboundSampleRate`
        // doc comment for why we resample explicitly instead of trusting
        // the AUHAL's implicit conversion.
        deviceSampleRate = Self.nominalSampleRate(of: deviceID) ?? inboundSampleRate
        backoffFrames = Int64((deviceSampleRate * Self.baselineBackoffMs / 1000.0).rounded())
        // Same write-once-before-Start discipline as `backoffFrames`, which is
        // what makes both safe to read unlocked from the render callback.
        trimRampFrames = max(
            1, Int((deviceSampleRate * Self.trimRampMs / 1000.0).rounded())
        )
        // Hardware term of `L_local` (see `localPipelineLatencyMs`). Probed
        // here because the properties are fixed for the life of an AUHAL
        // binding, and because this is the one place that already knows the
        // device rate the frame count is expressed in. Pure query — it does
        // not touch the AudioUnit or any Layer-2 state.
        let latencyFrames = LocalOutput.outputLatencyFrames(deviceID: deviceID)
        stateLock.withLock { self.hardwareLatencyFrames = latencyFrames }
        try setUpResampler(deviceRate: deviceSampleRate)
        DiagnosticLog.log(
            "[Bridge \(deviceUID)] device nominal rate=\(Int(deviceSampleRate)) Hz; "
            + (resampleConverter != nil
                ? "resampling 44100→\(Int(deviceSampleRate))"
                : "passthrough (native 44100)")
        )

        // Stream format: Float32 non-interleaved at the DEVICE's nominal
        // rate. The reader thread has already resampled to this rate, so
        // the AUHAL performs no implicit conversion and the render callback
        // consumes at exactly the rate the ring is filled.
        var format = AudioStreamBasicDescription(
            mSampleRate: deviceSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat
                | kAudioFormatFlagIsPacked
                | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: UInt32(channelCount),
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
        guard status == noErr else { throw BridgeError.configurationFailed(status) }

        // Render callback. Same retain-with-rollback pattern as
        // LocalOutput.start — see that file for the rationale.
        let opaque = Unmanaged.passRetained(self).toOpaque()
        self.refConOpaque = opaque
        var refConInstalled = false
        defer {
            if !refConInstalled {
                self.refConOpaque = nil
                Unmanaged<LocalAirPlayBridge>.fromOpaque(opaque).release()
            }
        }
        var callback = AURenderCallbackStruct(
            inputProc: { (inRefCon, _, _, _, inNumberFrames, ioData) -> OSStatus in
                let owner = Unmanaged<LocalAirPlayBridge>.fromOpaque(inRefCon).takeUnretainedValue()
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
        guard status == noErr else { throw BridgeError.configurationFailed(status) }

        status = AudioUnitInitialize(unit)
        guard status == noErr else { throw BridgeError.configurationFailed(status) }
        unitInitialized = true
        status = AudioOutputUnitStart(unit)
        guard status == noErr else { throw BridgeError.startFailed(status) }
        unitStarted = true

        self.unit = unit
        unitInstalled = true   // Suppresses the AudioUnit-rollback defer.
        refConInstalled = true // Suppresses the refCon-rollback defer.
        // Read cursor lags the writer by ~100 ms so the very first
        // renders see real data even before the broadcaster's first
        // packet has arrived over the socket. 4800 frames ≈ 109 ms at
        // 44.1 kHz, on par with LocalOutput.openAudioUnit's safety margin.
        stateLock.withLock {
            self.readCursor = max(0, ring.writePosition - backoffFrames)
        }
    }

    /// ~109 ms safety margin between the writer's `writePosition` and the
    /// render callback's `readCursor`, expressed in `deviceSampleRate`
    /// frames (set in `openAudioUnit`). Without this, the bridge ran with
    /// only `frames` (≈ 10 ms) of slack — but OwnTone's player-clock write
    /// rate and the local device's AUHAL clock drift independently, so with
    /// a near-zero margin the cursor periodically lands at exactly
    /// `writePos` and `RingBuffer.read` returns 0 valid frames (zero-fills
    /// the whole AUHAL buffer) — observable as `peak: 0.0000` while pkts
    /// and ticks both advance. ~109 ms; the ring is sized 16384 frames
    /// (≈ 341 ms at 48 kHz) so this still leaves headroom against drift.
    static let baselineBackoffMs: Double = 109.0
    private var backoffFrames: Int64 = 4_800

    // MARK: - Layer 2 control-loop tuning
    //
    // All order-of-magnitude starting points, to be refined on real
    // hardware against `(writePosition - readCursor)` fill logs (see the
    // FinalGate verification checklist). The plant is a pure integrator of
    // gain `deviceSampleRate`: d(fill)/dt = u · deviceSampleRate, so with
    // Ts ≈ 0.255 s per control tick the P-only crossover is
    // ωc = Kp · deviceSampleRate ≈ 0.048 rad/s (τ ≈ 21 s) — a gentle loop
    // whose corrections stay in the low-ppm range and never modulate pitch
    // audibly.
    /// Worst-case trim-stage output capacity per channel (frames). Covers
    /// one 44.1 kHz packet upsampled to ≤192 kHz at the clamped ratio with
    /// generous slop; the resampler stops at capacity so this is a hard
    /// ceiling, never exceeded in practice.
    private static let trimOutputCapacityFrames: Int = 4_096
    /// Control update cadence in packets. ~32 packets ≈ 255 ms ≈ 3.9 Hz at
    /// the feed's ~125 packets/s — a few-Hz loop with a multi-second time
    /// constant is ample for sub-Hz clock drift and keeps each correction a
    /// few ppm. Mirrors the `driftLogDrainIntervalPackets` decimation idea.
    private static let controlUpdateIntervalPackets: UInt64 = 32
    /// Deadband half-width (ms of fill) around the target. Inside it the
    /// integrator freezes and the ratio holds, killing limit-cycle dither.
    private static let controlDeadbandMs: Double = 2.0
    /// Absolute clamp on |trim| (parts per million). 300 ppm ≈ 0.5 cent —
    /// inaudible in absolute pitch — while giving capture headroom over
    /// consumer-grade clock error (~±100 ppm).
    private static let maxRatioPpm: Double = 300.0
    /// Per-update slew clamp on |Δtrim| (ppm). ~8 ppm/update ≈ 31 ppm/s so
    /// pitch modulation during a correction stays sub-audible.
    private static let slewPpmPerUpdate: Double = 8.0
    /// Proportional gain (per frame of fill error). ωc = Kp·deviceRate.
    private static let controlKp: Double = 1.0e-6
    /// Integral gain (per frame of fill error, per update). A decade below
    /// Kp for phase margin; cancels the constant clock offset so fill → 0
    /// error while the trim settles at the device's true clock error.
    private static let controlKi: Double = 1.2e-7
    /// Backstop jump-resync drift ceiling (ms). Widened from the old
    /// deviceSampleRate/4 (250 ms) because the PLL now holds the fill — the
    /// jump should essentially never fire in steady state and exists only
    /// for genuine faults (startup, underrun/overrun, data loss).
    static let resyncDriftMs: Double = 400.0

    /// AUHAL render callback. Real-time thread: NO allocations, NO
    /// async, NO Swift runtime calls beyond the unfair-lock acquire.
    /// Pipeline: ring read at the Layer-2 cursor → software-gain ramp.
    /// The gain ramp is what suppresses clicks on sudden volume changes.
    private func render(frames: Int, ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        guard let ioData = ioData else { return noErr }
        let bufList = UnsafeMutableAudioBufferListPointer(ioData)
        if bufList.count < channelCount { return noErr }
        if frames <= 0 { return noErr }

        // Snapshot the cursor + gain under the lock. One lock
        // acquisition per render block.
        struct RenderSnapshot {
            var cursor: Int64
            var gainCurrent: Float
            var gainTarget: Float
            var trimCurrent: Int
            var trimTarget: Int
        }
        let snapshot: RenderSnapshot = stateLock.withLock {
            RenderSnapshot(
                cursor: self.readCursor,
                gainCurrent: self._volumeGainCurrent,
                gainTarget: self._volumeGainTarget,
                trimCurrent: self._trimFramesCurrent,
                trimTarget: self._trimFramesTarget
            )
        }

        // Channel-pointer wiring with the pre-allocated outPtrs slot.
        for ch in 0..<channelCount {
            if let raw = bufList[ch].mData {
                outPtrs[ch] = raw.assumingMemoryBound(to: Float.self)
            } else {
                return noErr
            }
        }

        let cursor = snapshot.cursor
        let writePos = ring.writePosition
        // Default target: trail the writer by `baselineBackoffFrames`
        // (~100 ms) PLUS one render block. That gives every read full
        // coverage even when the device clock and the writer's wall-
        // clock pacer drift; without the baseline margin, cursor would
        // tend to settle exactly at `writePos` and every read would
        // return 0 valid frames (silent peak).
        let target: Int64 = max(
            0, writePos - backoffFrames - Int64(frames)
        )
        // Resync conditions:
        //   * first call (cursor=0)
        //   * cursor fell so far behind the writer that it's outside
        //     the ring (lost data — sustained stall)
        //   * cursor leapt ahead of the writer (shouldn't happen, but
        //     defend against it)
        //   * cursor drifted more than `resyncDriftMs` from `target` in
        //     either direction — an extreme backstop only. The Layer-2 PLL
        //     holds the fill near target, so in steady state this branch
        //     must essentially never fire; a widened ceiling keeps a rare
        //     transient from snapping (which would click) instead of
        //     letting the PLL slew it back.
        let lowerValid = max(0, writePos - Int64(ring.capacityFrames) + Int64(frames))
        let driftLimitFrames = Int64((Self.resyncDriftMs / 1000.0 * deviceSampleRate).rounded())
        let needsResync =
            cursor == 0 ||
            cursor < lowerValid ||
            cursor > writePos ||
            abs(cursor - target) > driftLimitFrames
        // Capture which branch fired (FIX 2d diagnostic, no allocs).
        var resyncReasonLocal: StaticString = ""
        if needsResync {
            if cursor == 0 { resyncReasonLocal = "first" }
            else if cursor < lowerValid { resyncReasonLocal = "underrun" }
            else if cursor > writePos { resyncReasonLocal = "overrun" }
            else { resyncReasonLocal = "drift" }
        }
        let startFrame: Int64 = needsResync ? target : cursor

        // Per-device delay trim: read the ring at a tap that lags
        // `startFrame` by `trimFrames`. `startFrame` — and therefore
        // `readCursor`, published below — is UNTRIMMED, which is what keeps
        // `updateClockControl()`'s error signal identical to a zero-trim run.
        //
        // Moving the tap splices two unrelated points of the waveform
        // together, so a change is cross-faded (equal-power, ~`trimRampMs`)
        // inside this one block. `sqrtf` is a hardware instruction on arm64:
        // no allocation, no lock, no libm call-out that could block.
        //
        // The tap is deliberately NOT clamped at 0. At cold start `startFrame`
        // pins at 0 while the trim is already at its full value, so the tap
        // goes negative — and that is correct: the frames it asks for predate
        // the stream, so silence is the honest output. Clamping to 0 would
        // instead play the head of the stream now AND again once the cursor
        // passes the trim. `RingBuffer.read` bounds its own zero-fill to
        // `frames` (see the INVARIANT on it), which is what makes a negative
        // tap safe on this thread.
        var newTrimCurrent = snapshot.trimCurrent
        if snapshot.trimTarget == snapshot.trimCurrent {
            ring.read(
                at: startFrame &- Int64(snapshot.trimCurrent),
                frames: frames, into: outPtrs
            )
        } else if needsResync || frames > Self.crossfadeCapacityFrames {
            // A resync has already broken waveform continuity (or the block
            // is bigger than the pre-allocated scratch, so a cross-fade would
            // need the heap). Adopt the new tap outright.
            ring.read(
                at: startFrame &- Int64(snapshot.trimTarget),
                frames: frames, into: outPtrs
            )
            newTrimCurrent = snapshot.trimTarget
        } else {
            ring.read(
                at: startFrame &- Int64(snapshot.trimCurrent),
                frames: frames, into: outPtrs
            )
            ring.read(
                at: startFrame &- Int64(snapshot.trimTarget),
                frames: frames, into: crossfadePtrs
            )
            let fadeFrames = min(frames, max(1, trimRampFrames))
            let inv = 1.0 / Float(fadeFrames)
            for ch in 0..<channelCount {
                let old = outPtrs[ch]
                let new = crossfadePtrs[ch]
                for i in 0..<fadeFrames {
                    let w = Float(i) * inv
                    old[i] = old[i] * sqrtf(1 - w) + new[i] * sqrtf(w)
                }
                if frames > fadeFrames {
                    old.advanced(by: fadeFrames)
                        .update(
                            from: new.advanced(by: fadeFrames),
                            count: frames - fadeFrames
                        )
                }
            }
            newTrimCurrent = snapshot.trimTarget
        }

        // Peak measurement, taken here — after the ring read and any trim
        // cross-fade, but BEFORE the volume gain — so the "is audio arriving
        // at all?" diagnostic stays independent of how loud the user set this
        // speaker. See `lastRenderPeak`. Plain reads and a max, no allocation.
        var pk: Float = 0
        let peakSamples = min(frames, Self.peakMeasurementSamples)
        let peakChannel = outPtrs[0]
        for i in 0..<peakSamples { pk = max(pk, abs(peakChannel[i])) }
        lastRenderPeak = pk

        // Software gain: ramp per-sample if current != target, vDSP
        // fast path otherwise. Ramped to suppress click on sudden
        // 1.0 → 0 transitions (pop-suppressing).
        var newGainCurrent = snapshot.gainCurrent
        if snapshot.gainCurrent != snapshot.gainTarget {
            let rampTotalSamples = Int(Self.volumeRampMs / 1000.0 * deviceSampleRate)
            let stepSamples = min(frames, max(1, rampTotalSamples))
            let stepDelta = (snapshot.gainTarget - snapshot.gainCurrent) / Float(stepSamples)
            var g = snapshot.gainCurrent
            for i in 0..<frames {
                if i < stepSamples { g += stepDelta } else { g = snapshot.gainTarget }
                for ch in 0..<channelCount { outPtrs[ch][i] *= g }
            }
            newGainCurrent = (frames >= stepSamples) ? snapshot.gainTarget : g
        } else if snapshot.gainCurrent != 1.0 {
            var g = snapshot.gainCurrent
            let frameCount = vDSP_Length(frames)
            for ch in 0..<channelCount {
                let p = outPtrs[ch]
                vDSP_vsmul(p, 1, &g, p, 1, frameCount)
            }
        }

        // Persist back under the lock. Locals → immutable lets so
        // the withLock closure satisfies Sendable-capture rules.
        let endFrame = startFrame &+ Int64(frames)
        let gainCurrentSnapshot = newGainCurrent
        let trimCurrentSnapshot = newTrimCurrent
        let resyncFiredSnapshot = needsResync
        let resyncFromSnapshot = cursor
        let resyncToSnapshot = startFrame
        let resyncWriteSnapshot = writePos
        let resyncReasonSnapshot = resyncReasonLocal
        stateLock.withLock {
            self.readCursor = endFrame
            // Publish the block size for the Layer-2 controller's target
            // (backoffFrames + framesPerRender). Plain store under the lock
            // the reader already snapshots — no new RT work.
            self._lastRenderFrames = frames
            self._volumeGainCurrent = gainCurrentSnapshot
            // The tap position actually in force after this block. Written
            // here (not in `setTrimMs`) so the cross-fade owns the
            // transition and a target that arrives mid-block is picked up on
            // the next one rather than tearing this one.
            self._trimFramesCurrent = trimCurrentSnapshot
            if resyncFiredSnapshot {
                self._resyncSeqWritten &+= 1
                self.driftResyncCount = self._resyncSeqWritten
                self._resyncFromCursor = resyncFromSnapshot
                self._resyncToTarget = resyncToSnapshot
                self._resyncWritePos = resyncWriteSnapshot
                self._resyncReason = resyncReasonSnapshot
            }
        }

        // Diagnostics + tail accounting. Done on the RT thread but
        // they're just simple writes, no allocation.
        renderTickCount &+= 1
        lastRenderGain = gainCurrentSnapshot
        return noErr
    }

    // MARK: - Drift-resync log drain (non-RT)

    /// Drain drift-resync events stamped by render() and emit one
    /// `DiagnosticLog.log` per batch. Called from the reader task — safe
    /// to allocate / do file I/O here.
    private func drainDriftResyncLog() {
        let pending: (count: UInt64, from: Int64, to: Int64, write: Int64, reason: StaticString)? = stateLock.withLock {
            if self._resyncSeqWritten == self._resyncSeqLogged {
                return nil
            }
            let count = self._resyncSeqWritten &- self._resyncSeqLogged
            let from = self._resyncFromCursor
            let to = self._resyncToTarget
            let write = self._resyncWritePos
            let reason = self._resyncReason
            self._resyncSeqLogged = self._resyncSeqWritten
            return (count, from, to, write, reason)
        }
        if let p = pending {
            // String conversion happens here, off the RT thread.
            DiagnosticLog.log(
                "[Bridge \(deviceUID)] drift resync (\(String(describing: p.reason)))"
                + ": cursor jumped from \(p.from) to \(p.to)"
                + " at writePos=\(p.write)"
                + " (events=\(p.count))"
            )
        }
    }
}
