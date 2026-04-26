import Foundation
import CoreAudio
import AudioToolbox
import Accelerate
import os.lock

/// **DEPRECATED** — replaced by `ContinuousActiveCalibrator` (driven
/// by `ActiveCalibrator` instead of GCC-PHAT). The passive engine
/// cannot distinguish per-device latencies on a single mic capture
/// (single-peak detection on shared music produces ±100 ms run-to-run
/// variance plus bad absolute values), which made continuous
/// correction worse than no correction. Kept around as a legacy
/// fallback for the router-side methods that still reference the
/// type; new continuous-calibration entry points use
/// `Router.startContinuousActiveCalibration`.
///
/// Original docstring follows.
///
/// Passive continuous-calibration engine. Cross-correlates the source
/// PCM (mono mix from the SCK ring) against a live mic capture; the
/// GCC-PHAT peak gives the wall-clock playback delay (room re-radiation
/// included). Fires every `measurementIntervalSeconds` (default 30 s)
/// and emits a `Sample` whenever confidence ≥ `minConfidenceForUpdate`.
/// Output-device-agnostic — measures source-to-mic round-trip only.
///
/// GCC-PHAT (Knapp & Carter 1976): phase-normalising X·conj(Y) before
/// the IFFT leaves a near-delta peak dominated by phase delay rather
/// than speaker EQ — robust to room colouration where plain xcorr
/// smears. 1.5 s @ 48 kHz ≈ 72 000 evidence samples (~150× a click)
/// and injects nothing audible.
///
/// Threads: AUHAL render callback writes mic into a lock-free ring; a
/// background `Task` runs the periodic correlation off the audio
/// thread. `start()` / `stop()` are idempotent.
@available(*, deprecated, message: "Use ContinuousActiveCalibrator (Router.startContinuousActiveCalibration). Passive GCC-PHAT cannot distinguish per-device latencies and produces unreliable measurements.")
public final class PassiveCalibrator: @unchecked Sendable {

    /// Per-class trace gate. `false` ⇒ skip string construction entirely.
    public static var verboseTracing: Bool = true
    /// `iter=…` counter on every cycle log. Reset to 0 on `start()`.
    private var iterationCount: UInt64 = 0
    /// Last-seen mic write position. Delta = frames pushed by the AU
    /// render callback since the previous cycle — zero ⇒ AU dead
    /// (hypothesis #3) even though `AudioOutputUnitStart` returned ok.
    private var lastMicWritePos: Int64 = 0
    @inline(__always)
    private static func trace(_ msg: @autoclosure () -> String) {
        guard verboseTracing else { return }
        CalibTrace.log(msg())
    }

    public struct Sample: Sendable {
        public let measuredDelayMs: Int
        /// 0..1, peak prominence: (peak − runner-up) / peak.
        public let confidence: Double
        /// `measuredDelayMs` clamped to ≥ 0 — broadcaster delay-line value.
        public let suggestedDelayMs: Int
        public let timestamp: Date
        public init(
            measuredDelayMs: Int, confidence: Double,
            suggestedDelayMs: Int, timestamp: Date
        ) {
            self.measuredDelayMs = measuredDelayMs
            self.confidence = confidence
            self.suggestedDelayMs = suggestedDelayMs
            self.timestamp = timestamp
        }
    }

    public enum CalibrationError: Error {
        case permissionDenied
        case noInputDevice
        case audioUnitInstantiationFailed(OSStatus)
        case audioUnitConfigurationFailed(OSStatus)
        case audioUnitStartFailed(OSStatus)
    }

    /// 1.5 s @ 48 kHz → 72 k samples, FFT size 1<<17.
    public var correlationWindowSeconds: Double = 1.5
    public var measurementIntervalSeconds: Double = 30.0
    public var minConfidenceForUpdate: Double = 0.5
    /// Bounds the searched lag window. AirPlay 2 PTP ~1.8 s; slack for
    /// crowded Wi-Fi.
    public var maxExpectedDelaySeconds: Double = 2.5

    public let microphoneDeviceID: AudioDeviceID?

    private let sourceRing: RingBuffer
    private let onSampleAvailable: @Sendable (Sample) -> Void

    private let stateLock = OSAllocatedUnfairLock()
    private var _running = false
    private var _liveUnit: AudioUnit?
    private var _captureContext: PassiveMicCaptureContext?
    private var _measurementTask: Task<Void, Never>?

    private static let sampleRate: Double = 48_000
    /// Four-CC 'nope' = `kAudio_NoPermissionError`.
    private static let kPermissionDenied = OSStatus(bitPattern: UInt32(0x6E6F7065))

    public init(
        ringBuffer: RingBuffer,
        microphoneDeviceID: AudioDeviceID? = nil,
        onSampleAvailable: @escaping @Sendable (Sample) -> Void
    ) {
        self.sourceRing = ringBuffer
        self.microphoneDeviceID = microphoneDeviceID
        self.onSampleAvailable = onSampleAvailable
    }

    deinit { stopInternal() }

    /// Begin continuous capture + correlation. Idempotent.
    public func start() async throws {
        let alreadyRunning: Bool = stateLock.withLock {
            if _running { return true }
            _running = true
            return false
        }
        if alreadyRunning { return }
        do {
            try startInternal()
        } catch {
            stateLock.withLock { _running = false }
            throw error
        }
    }

    /// Stop and release the AudioUnit. Idempotent.
    public func stop() { stopInternal() }

    private func startInternal() throws {
        // Mic ring: 1 window + 0.5 s slack, padded to a power of two
        // (RingBuffer requires it). 48 kHz / 1.5 s → 1<<17.
        let neededFrames = Int((correlationWindowSeconds + 0.5) * Self.sampleRate)
        let micRing = RingBuffer(
            channelCount: 1, capacityFrames: Self.nextPowerOfTwo(neededFrames)
        )
        let context = PassiveMicCaptureContext(ring: micRing)
        let opaque = Unmanaged.passUnretained(context).toOpaque()
        let resolvedDevice: AudioDeviceID
        do {
            resolvedDevice = try resolveInputDeviceID()
            Self.trace("[PassiveCalibrator] start: mic device id=\(resolvedDevice) caller_provided=\(microphoneDeviceID.map(String.init) ?? "nil") interval=\(measurementIntervalSeconds)s window=\(correlationWindowSeconds)s minConf=\(minConfidenceForUpdate) maxLag=\(maxExpectedDelaySeconds)s")
        } catch {
            Self.trace("[PassiveCalibrator] start: FAILED to resolve input device: \(error) — hypothesis #6 (TCC) or no default mic")
            throw error
        }
        let unit: AudioUnit
        do {
            unit = try Self.openInputUnit(
                deviceID: resolvedDevice,
                inputCallbackContext: opaque
            )
            Self.trace("[PassiveCalibrator] start: AudioUnit opened+started OK on dev=\(resolvedDevice)")
        } catch {
            // Permission-denied / start-failed surfaces here. Logging the
            // exact error shape disambiguates hypothesis #6 (TCC) from
            // hypothesis #3 (AU started but render callback never fires).
            Self.trace("[PassiveCalibrator] start: AudioUnit FAILED: \(error)")
            throw error
        }
        context.unit = unit
        iterationCount = 0
        lastMicWritePos = 0
        stateLock.withLockUnchecked {
            _liveUnit = unit
            _captureContext = context
        }
        let task: Task<Void, Never> = Task.detached(priority: .utility) {
            [weak self] in
            guard let self else { return }
            await self.runMeasurementLoop()
        }
        stateLock.withLockUnchecked { _measurementTask = task }
    }

    private func stopInternal() {
        // Snapshot, then release outside the lock — CoreAudio teardown
        // must not run with the unfair lock held.
        let (unit, task) = stateLock.withLockUnchecked {
            () -> (AudioUnit?, Task<Void, Never>?) in
            let u = _liveUnit; let t = _measurementTask
            _liveUnit = nil; _captureContext = nil
            _measurementTask = nil; _running = false
            return (u, t)
        }
        task?.cancel()
        if let unit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            Self.trace("[PassiveCalibrator] stop: AudioUnit torn down (last iter=\(iterationCount))")
        }
    }

    private func runMeasurementLoop() async {
        // Wait one interval — gives the mic ring time to fill and
        // OwnTone time to settle after a mode switch.
        let firstWaitNs = UInt64(measurementIntervalSeconds * 1_000_000_000)
        Self.trace("[PassiveCalibrator] loop: armed; first sleep=\(measurementIntervalSeconds)s before first cycle")
        do { try await Task.sleep(nanoseconds: firstWaitNs) } catch { return }

        while !Task.isCancelled {
            // Snapshot tunables so the cycle is coherent if the caller
            // mutates them concurrently.
            let window = correlationWindowSeconds
            let interval = measurementIntervalSeconds
            let minConf = minConfidenceForUpdate
            let maxLag = maxExpectedDelaySeconds
            let context: PassiveMicCaptureContext? =
                stateLock.withLockUnchecked { _captureContext }
            guard let context else { return }
            iterationCount &+= 1
            let outcome = computeOnce(
                micContext: context, windowSeconds: window,
                maxLagSeconds: maxLag
            )
            if let sample = outcome.sample, sample.confidence >= minConf {
                Self.trace("[PassiveCalibrator] iter=\(iterationCount) \(outcome.summary) -> SAMPLE_EMITTED measuredDelay=\(sample.measuredDelayMs)ms suggested=\(sample.suggestedDelayMs)ms")
                onSampleAvailable(sample)
            } else if let sample = outcome.sample {
                Self.trace("[PassiveCalibrator] iter=\(iterationCount) \(outcome.summary) -> SKIP (confidence \(String(format: "%.2f", sample.confidence)) < min \(String(format: "%.2f", minConf)))")
            } else {
                // Skipped before producing a Sample: gate / not-enough-frames
                // / FFT failure. `outcome.summary` carries the reason.
                Self.trace("[PassiveCalibrator] iter=\(iterationCount) \(outcome.summary) -> SKIP")
            }
            // Sleep in 500 ms chunks so cancellation lands quickly.
            var remaining = UInt64(interval * 1_000_000_000)
            while remaining > 0 {
                if Task.isCancelled { return }
                let slice = min(remaining, UInt64(500_000_000))
                do { try await Task.sleep(nanoseconds: slice) } catch { return }
                remaining &-= slice
            }
        }
    }

    /// Wrapper for `computeOnce` that pairs the (optional) Sample with a
    /// human-readable trace string. `sample == nil` ⇒ early-skip path
    /// (gates / not-enough-frames / FFT failure); the loop logger pulls
    /// `summary` out either way.
    private struct CycleOutcome {
        let sample: Sample?
        let summary: String
    }

    /// One correlation cycle. Returns nil on insufficient signal or
    /// not-yet-filled rings. Lag-window bookkeeping: mic = last
    /// `windowFrames` of mic ring; source = last `windowFrames + 2 ×
    /// maxLagFrames` of SCK ring (extended `maxLagFrames` earlier on
    /// the start side). After GCC-PHAT, peak index `k` in
    /// `[0, sourceFrames − windowFrames]` means the mic matches the
    /// source shifted forward by `k` samples; actual delay = `k − maxLagFrames`.
    private func computeOnce(
        micContext: PassiveMicCaptureContext,
        windowSeconds: Double,
        maxLagSeconds: Double
    ) -> CycleOutcome {
        let sr = Self.sampleRate
        let windowFrames = Int(windowSeconds * sr)
        let maxLagFrames = Int(maxLagSeconds * sr)
        let sourceFrames = windowFrames + 2 * maxLagFrames

        let micRing = micContext.ring
        let micWritePos = micRing.writePosition
        // Frames pushed by the AU render callback since the last cycle.
        // Zero across multiple consecutive iterations ⇒ AU render dead
        // (hypothesis #3) even though `AudioOutputUnitStart` returned ok.
        let framesSinceLast = micWritePos - lastMicWritePos
        lastMicWritePos = micWritePos
        guard micWritePos >= Int64(windowFrames) else {
            return CycleOutcome(sample: nil,
                summary: "mic_writepos=\(micWritePos) need=\(windowFrames) mic_frames=\(framesSinceLast) gate=NO_MIC_FRAMES")
        }
        let micBuf = UnsafeMutablePointer<Float>.allocate(capacity: windowFrames)
        defer { micBuf.deallocate() }
        micBuf.initialize(repeating: 0, count: windowFrames)
        var micChanPtr: UnsafeMutablePointer<Float> = micBuf
        let micFilled: Int = withUnsafePointer(to: &micChanPtr) { p in
            micRing.read(
                at: micWritePos - Int64(windowFrames),
                frames: windowFrames, into: p
            )
        }
        guard micFilled == windowFrames else {
            return CycleOutcome(sample: nil,
                summary: "mic_filled=\(micFilled)/\(windowFrames) gate=MIC_RING_UNDERREAD")
        }
        let mic = Array(UnsafeBufferPointer(start: micBuf, count: windowFrames))

        let sourceTargetStart = sourceRing.writePosition - Int64(sourceFrames)
        guard sourceTargetStart >= 0 else {
            return CycleOutcome(sample: nil,
                summary: "source_writepos=\(sourceRing.writePosition) need=\(sourceFrames) gate=SOURCE_RING_NOT_READY")
        }
        let chCount = sourceRing.channelCount
        let chPtrs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>
            .allocate(capacity: chCount)
        defer { chPtrs.deallocate() }
        for c in 0..<chCount {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: sourceFrames)
            p.initialize(repeating: 0, count: sourceFrames)
            chPtrs[c] = p
        }
        defer { for c in 0..<chCount { chPtrs[c].deallocate() } }
        _ = sourceRing.read(
            at: sourceTargetStart, frames: sourceFrames,
            into: UnsafePointer(chPtrs)
        )
        var source = [Float](repeating: 0, count: sourceFrames)
        let inv = Float(1) / Float(max(1, chCount))
        for c in 0..<chCount {
            let p = chPtrs[c]
            for i in 0..<sourceFrames { source[i] += p[i] * inv }
        }

        // Energy gate at ~−60 dBFS RMS — below this, correlation
        // produces meaningless peaks (silence or noise on either side).
        let silenceThreshold: Float = 0.001
        let micRms = Self.rms(mic)
        let sourceRms = Self.rms(source)
        let micDb = Self.dbfs(micRms)
        let srcDb = Self.dbfs(sourceRms)
        if micRms < silenceThreshold {
            return CycleOutcome(sample: nil,
                summary: "mic_rms=\(micDb)dB source_rms=\(srcDb)dB mic_frames=\(framesSinceLast) gate=FAIL_MIC_BELOW_-60dBFS")
        }
        if sourceRms < silenceThreshold {
            return CycleOutcome(sample: nil,
                summary: "mic_rms=\(micDb)dB source_rms=\(srcDb)dB mic_frames=\(framesSinceLast) gate=FAIL_SOURCE_BELOW_-60dBFS")
        }

        let n = Self.nextPowerOfTwo(sourceFrames + windowFrames)
        guard let corr = Self.gccPhat(
            source: source, sourceLength: sourceFrames,
            mic: mic, micLength: windowFrames, fftSize: n
        ) else {
            return CycleOutcome(sample: nil,
                summary: "mic_rms=\(micDb)dB source_rms=\(srcDb)dB gate=PASS fft_size=\(n) gate=FAIL_GCCPHAT")
        }

        let validEnd = sourceFrames - windowFrames + 1
        guard validEnd > 1 else {
            return CycleOutcome(sample: nil,
                summary: "mic_rms=\(micDb)dB source_rms=\(srcDb)dB gate=PASS validEnd=\(validEnd) gate=FAIL_NO_VALID_LAG_RANGE")
        }
        let (peakIndex, peakValue, runnerUp) = Self.peakAndRunnerUp(
            in: corr, begin: 0, end: validEnd
        )
        guard peakValue > 0 else {
            return CycleOutcome(sample: nil,
                summary: "mic_rms=\(micDb)dB source_rms=\(srcDb)dB gate=PASS peak_idx=\(peakIndex) peak_mag=0 gate=FAIL_ZERO_PEAK")
        }

        let lagSamples = peakIndex - maxLagFrames
        let measuredDelayMs = Int((Double(lagSamples) / sr) * 1000.0)
        let confidence = max(0.0, min(1.0,
            Double((peakValue - runnerUp) / peakValue)
        ))
        let summary = "mic_rms=\(micDb)dB source_rms=\(srcDb)dB mic_frames=\(framesSinceLast) gate=PASS peak_idx=\(peakIndex) peak_mag=\(String(format: "%.4f", peakValue)) runnerUp=\(String(format: "%.4f", runnerUp)) confidence=\(String(format: "%.2f", confidence))"
        return CycleOutcome(
            sample: Sample(
                measuredDelayMs: measuredDelayMs,
                confidence: confidence,
                suggestedDelayMs: max(0, measuredDelayMs),
                timestamp: Date()
            ),
            summary: summary
        )
    }

    private func resolveInputDeviceID() throws -> AudioDeviceID {
        if let id = microphoneDeviceID, id != 0 { return id }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dev: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr, 0, nil, &size, &dev
        )
        guard status == noErr, dev != 0 else {
            throw CalibrationError.noInputDevice
        }
        return dev
    }

    /// Mirrors `CalibrationRunner.openInputUnit` — kept parallel; the
    /// continuous-vs-one-shot lifetime models differ enough that a
    /// shared helper would only save ~30 LOC at a wider blast radius.
    private static func openInputUnit(
        deviceID: AudioDeviceID,
        inputCallbackContext: UnsafeMutableRawPointer
    ) throws -> AudioUnit {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw CalibrationError.audioUnitInstantiationFailed(-1)
        }
        var unitOut: AudioUnit?
        var status = AudioComponentInstanceNew(component, &unitOut)
        guard status == noErr, let unit = unitOut else {
            throw CalibrationError.audioUnitInstantiationFailed(status)
        }
        var ok = false
        defer {
            if !ok {
                AudioOutputUnitStop(unit)
                AudioUnitUninitialize(unit)
                AudioComponentInstanceDispose(unit)
            }
        }
        func setProp<T>(
            _ sel: AudioUnitPropertyID, _ scope: AudioUnitScope,
            _ bus: AudioUnitElement, _ value: inout T
        ) throws {
            let s = withUnsafeMutablePointer(to: &value) { p -> OSStatus in
                AudioUnitSetProperty(unit, sel, scope, bus, p,
                                     UInt32(MemoryLayout<T>.size))
            }
            if s != noErr { throw CalibrationError.audioUnitConfigurationFailed(s) }
        }
        var enable: UInt32 = 1, disable: UInt32 = 0, devID = deviceID
        try setProp(kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enable)
        try setProp(kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disable)
        try setProp(kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &devID)
        var fmt = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat
                | kAudioFormatFlagIsPacked
                | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0
        )
        try setProp(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &fmt)
        var callback = AURenderCallbackStruct(
            inputProc: { (inRefCon, flags, ts, _, frames, _) -> OSStatus in
                let ctx = Unmanaged<PassiveMicCaptureContext>
                    .fromOpaque(inRefCon).takeUnretainedValue()
                return ctx.fetch(flags: flags, timestamp: ts, frames: frames)
            },
            inputProcRefCon: inputCallbackContext
        )
        try setProp(kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback)

        status = AudioUnitInitialize(unit)
        if status != noErr {
            if status == kPermissionDenied { throw CalibrationError.permissionDenied }
            throw CalibrationError.audioUnitConfigurationFailed(status)
        }
        status = AudioOutputUnitStart(unit)
        if status != noErr {
            if status == kPermissionDenied { throw CalibrationError.permissionDenied }
            throw CalibrationError.audioUnitStartFailed(status)
        }
        ok = true
        return unit
    }

    private static func nextPowerOfTwo(_ n: Int) -> Int {
        guard n > 1 else { return 1 }
        var p = 1
        while p < n { p <<= 1 }
        return p
    }

    private static func rms(_ x: [Float]) -> Float {
        guard !x.isEmpty else { return 0 }
        var ms: Float = 0
        x.withUnsafeBufferPointer { ptr in
            vDSP_measqv(ptr.baseAddress!, 1, &ms, vDSP_Length(ptr.count))
        }
        return sqrt(ms)
    }

    /// Convert a linear-amplitude RMS to a 1-decimal dBFS string. Returns
    /// `-inf` for zero. Used only for log formatting.
    private static func dbfs(_ rms: Float) -> String {
        if rms <= 0 { return "-inf" }
        return String(format: "%.1f", 20.0 * Foundation.log10(Double(rms)))
    }

    /// Locate the global maximum and the next-highest peak from outside
    /// ±neighbourhood of the main peak (so a wide sidelobe doesn't
    /// depress the prominence number). |abs| because some speakers
    /// invert polarity.
    private static func peakAndRunnerUp(
        in corr: [Float], begin: Int, end: Int
    ) -> (peakIndex: Int, peakValue: Float, runnerUp: Float) {
        precondition(begin >= 0 && end <= corr.count && begin < end)
        var peak: Float = -.infinity
        var peakIdx: Int = begin
        for i in begin..<end {
            let a = abs(corr[i])
            if a > peak { peak = a; peakIdx = i }
        }
        let nb = max(8, (end - begin) / 200)
        let lo = max(begin, peakIdx - nb)
        let hi = min(end, peakIdx + nb + 1)
        var runnerUp: Float = 0
        for i in begin..<lo { let a = abs(corr[i]); if a > runnerUp { runnerUp = a } }
        for i in hi..<end   { let a = abs(corr[i]); if a > runnerUp { runnerUp = a } }
        return (peakIdx, peak, runnerUp)
    }

    /// Generalised cross-correlation with phase transform.
    ///   1. zero-pad source/mic to `fftSize`
    ///   2. X = FFT(source); Y = FFT(mic)
    ///   3. G = X · conj(Y); G_norm = G / (|G| + ε)
    ///   4. r = IFFT(G_norm)
    /// Peak position k in [0, sourceLength − micLength] = source-vs-mic
    /// shift in samples. vDSP packs N-pt real FFTs into N/2 complex
    /// pairs (real[0]=DC, imag[0]=Nyquist); IFFT is unscaled but the
    /// peak finder is scale-invariant.
    private static func gccPhat(
        source: [Float], sourceLength: Int,
        mic: [Float], micLength: Int,
        fftSize n: Int
    ) -> [Float]? {
        guard n > 1, (n & (n - 1)) == 0 else { return nil }
        let log2n = vDSP_Length(Int(log2(Double(n))))
        let halfN = n / 2

        // Manual allocation keeps every split-complex pointer alive
        // through the whole FFT pipeline without nested withUnsafe…
        let xR = UnsafeMutablePointer<Float>.allocate(capacity: halfN)
        let xI = UnsafeMutablePointer<Float>.allocate(capacity: halfN)
        let yR = UnsafeMutablePointer<Float>.allocate(capacity: halfN)
        let yI = UnsafeMutablePointer<Float>.allocate(capacity: halfN)
        let yIneg = UnsafeMutablePointer<Float>.allocate(capacity: halfN)
        let crossR = UnsafeMutablePointer<Float>.allocate(capacity: halfN)
        let crossI = UnsafeMutablePointer<Float>.allocate(capacity: halfN)
        let mags = UnsafeMutablePointer<Float>.allocate(capacity: halfN)
        defer {
            xR.deallocate(); xI.deallocate()
            yR.deallocate(); yI.deallocate(); yIneg.deallocate()
            crossR.deallocate(); crossI.deallocate(); mags.deallocate()
        }
        xR.initialize(repeating: 0, count: halfN)
        xI.initialize(repeating: 0, count: halfN)
        yR.initialize(repeating: 0, count: halfN)
        yI.initialize(repeating: 0, count: halfN)

        var paddedSource = [Float](repeating: 0, count: n)
        var paddedMic = [Float](repeating: 0, count: n)
        for i in 0..<min(sourceLength, n) { paddedSource[i] = source[i] }
        for i in 0..<min(micLength, n) { paddedMic[i] = mic[i] }

        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return nil
        }
        defer { vDSP_destroy_fftsetup(setup) }

        var xSplit = DSPSplitComplex(realp: xR, imagp: xI)
        var ySplit = DSPSplitComplex(realp: yR, imagp: yI)

        paddedSource.withUnsafeBufferPointer { sp in
            sp.baseAddress!.withMemoryRebound(
                to: DSPComplex.self, capacity: halfN
            ) { cp in vDSP_ctoz(cp, 2, &xSplit, 1, vDSP_Length(halfN)) }
        }
        paddedMic.withUnsafeBufferPointer { mp in
            mp.baseAddress!.withMemoryRebound(
                to: DSPComplex.self, capacity: halfN
            ) { cp in vDSP_ctoz(cp, 2, &ySplit, 1, vDSP_Length(halfN)) }
        }
        vDSP_fft_zrip(setup, &xSplit, 1, log2n, FFTDirection(FFT_FORWARD))
        vDSP_fft_zrip(setup, &ySplit, 1, log2n, FFTDirection(FFT_FORWARD))

        // Conjugate Y by negating its imaginary part.
        var minusOne: Float = -1.0
        vDSP_vsmul(yI, 1, &minusOne, yIneg, 1, vDSP_Length(halfN))
        var yConj = DSPSplitComplex(realp: yR, imagp: yIneg)

        var crossSplit = DSPSplitComplex(realp: crossR, imagp: crossI)
        vDSP_zvmul(&xSplit, 1, &yConj, 1, &crossSplit, 1,
                   vDSP_Length(halfN), 1)

        // PHAT: divide each bin by its magnitude (+ ε floor).
        vDSP_zvabs(&crossSplit, 1, mags, 1, vDSP_Length(halfN))
        var eps: Float = 1e-9
        vDSP_vsadd(mags, 1, &eps, mags, 1, vDSP_Length(halfN))
        vDSP_vdiv(mags, 1, crossR, 1, crossR, 1, vDSP_Length(halfN))
        vDSP_vdiv(mags, 1, crossI, 1, crossI, 1, vDSP_Length(halfN))

        vDSP_fft_zrip(setup, &crossSplit, 1, log2n, FFTDirection(FFT_INVERSE))

        var output = [Float](repeating: 0, count: n)
        output.withUnsafeMutableBufferPointer { op in
            op.baseAddress!.withMemoryRebound(
                to: DSPComplex.self, capacity: halfN
            ) { cp in vDSP_ztoc(&crossSplit, 1, cp, 2, vDSP_Length(halfN)) }
        }
        return output
    }
}

/// AU render-callback state. RT-safe: no allocations after init, no
/// Darwin locks across the AU render call.
private final class PassiveMicCaptureContext {
    let ring: RingBuffer
    var unit: AudioUnit?

    private let scratch: UnsafeMutablePointer<Float>
    private let scratchCapacity: Int = 8192
    private let abl: UnsafeMutablePointer<AudioBufferList>

    init(ring: RingBuffer) {
        self.ring = ring
        let p = UnsafeMutablePointer<Float>.allocate(capacity: scratchCapacity)
        p.initialize(repeating: 0, count: scratchCapacity)
        self.scratch = p
        self.abl = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
        self.abl.pointee = AudioBufferList()
        self.abl.pointee.mNumberBuffers = 1
        self.abl.pointee.mBuffers = AudioBuffer(
            mNumberChannels: 1, mDataByteSize: 0, mData: nil
        )
    }

    deinit {
        scratch.deinitialize(count: scratchCapacity)
        scratch.deallocate()
        abl.deallocate()
    }

    func fetch(
        flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timestamp: UnsafePointer<AudioTimeStamp>,
        frames: UInt32
    ) -> OSStatus {
        guard let unit = unit else { return noErr }
        let n = Int(frames)
        guard n > 0, n <= scratchCapacity else { return noErr }
        abl.pointee.mBuffers.mData = UnsafeMutableRawPointer(scratch)
        abl.pointee.mBuffers.mDataByteSize = UInt32(n * MemoryLayout<Float>.size)
        let status = AudioUnitRender(unit, flags, timestamp, 1, frames, abl)
        if status != noErr { return status }
        let sptr: UnsafePointer<Float> = UnsafePointer(scratch)
        withUnsafePointer(to: sptr) { ptr in
            ring.write(channels: ptr, frames: n)
        }
        return noErr
    }
}


