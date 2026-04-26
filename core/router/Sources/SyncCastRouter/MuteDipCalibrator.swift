import Foundation
import CoreAudio
import AudioToolbox
import Accelerate
import os.lock
import SyncCastDiscovery

/// TDMA mute-dip per-device latency (calibration v2). See
/// `docs/calibration_v2_design.md` §3–§7 for the math.
///
/// Pipeline: TDMA volume modulation (300ms solo + 50ms guard per device)
/// → 48kHz mic capture covering preroll(λ_max)+cycle+postroll+slack →
/// 20ms/10ms sliding RMS envelope → whitening (subtract 500ms baseline,
/// divide by it) → 3-tap median filter → per-device FFT cross-correlation
/// against mean-removed expected pattern m_d → argmax in class-specific
/// window (local [0,3100]ms, AirPlay [1500,2000]ms) → τ_d. Confidence =
/// (peak − background_median) / MAD(background); design §7 threshold 4.0.
///
/// Whole-home mode caveat: in whole-home mode the broadcaster routes
/// local audio through an `airplayDelayMs` delay-line (0..3000 ms,
/// user-tunable). That delay is NOT in `Probe.commandLatencyMs`, which
/// only models intrinsic device latency (~30 ms local, ~1800 ms AirPlay).
/// So local's actual command-to-mic latency is `airplayDelayMs + ~30 ms`
/// and the local cross-correlation peak lives near τ ≈ airplayDelayMs.
/// Hence local's search window is widened to [0, 3100] ms (max possible
/// delay-line + slack) and capture is padded by `searchSlackMs` so the
/// late mute-dip is still in the recording.
///
/// Deviations: hard volume transitions (no 50ms half-cosine ramp — design
/// caveat §3.2; modulation depth is what xcorr measures, bandwidth doesn't
/// matter). vDSP_fft_zrip instead of vDSP_DFT_zrop (mathematically
/// identical, matches PassiveCalibrator's plumbing).
public final class MuteDipCalibrator: @unchecked Sendable {

    public static var verboseTracing: Bool = true
    @inline(__always)
    private static func trace(_ msg: @autoclosure () -> String) {
        guard verboseTracing else { return }
        CalibTrace.log(msg())
    }

    // MARK: - Public types

    public struct Probe: Sendable {
        public let deviceID: String
        public let transport: Transport
        /// Command-to-audible latency. ~30 ms local, ~1800 ms AirPlay.
        public let commandLatencyMs: Int
        /// Pre-calibration volume — what gets restored on cycle exit.
        public let originalVolume: Float
        public init(
            deviceID: String, transport: Transport,
            commandLatencyMs: Int, originalVolume: Float
        ) {
            self.deviceID = deviceID; self.transport = transport
            self.commandLatencyMs = commandLatencyMs
            self.originalVolume = originalVolume
        }
    }

    public struct Result: Sendable {
        public let perDeviceTauMs: [String: Int]
        public let perDeviceConfidence: [String: Double]
        public let aggregateConfidence: Double
        /// Signed delta = max(AirPlay τ) − max(local τ); ADD to airplayDelayMs.
        public let deltaMs: Int
        public init(
            perDeviceTauMs: [String: Int],
            perDeviceConfidence: [String: Double],
            aggregateConfidence: Double, deltaMs: Int
        ) {
            self.perDeviceTauMs = perDeviceTauMs
            self.perDeviceConfidence = perDeviceConfidence
            self.aggregateConfidence = aggregateConfidence
            self.deltaMs = deltaMs
        }
    }

    public enum CalibrationError: Error {
        case permissionDenied
        case noInputDevice
        case audioUnitInstantiationFailed(OSStatus)
        case audioUnitConfigurationFailed(OSStatus)
        case audioUnitStartFailed(OSStatus)
        case noProbesProvided
        case alreadyRunning
        case cancelled
        case insufficientCapture
    }

    public typealias VolumeSetter = @Sendable (
        _ deviceID: String, _ volume: Float
    ) -> Void
    public typealias AsyncVolumeSetter = @Sendable (
        _ deviceID: String, _ volume: Float
    ) async -> Void

    // MARK: - Configuration (design §3, §4.5, §7)

    /// Solo window length (ms). Bumped from 200 → 300 so AirPlay
    /// receivers' anti-click volume ramping (typically 50–200 ms) has
    /// time to actually reach `offLevel` before flipping back; this
    /// deepens the dip and improves AirPlay-side cross-correlation
    /// confidence at small cost to total calibration duration.
    public static let tSoloMs: Int = 300
    public static let tGuardMs: Int = 50
    public static let offLevel: Float = 0.3
    public static let onLevel: Float = 1.0

    public static let airplayDefaultLambdaMs: Int = 1800
    public static let localDefaultLambdaMs: Int = 30

    /// Local search window upper bound (ms). In whole-home mode local
    /// audio passes through the broadcaster's delay-line (≤ 3000 ms),
    /// so the local mute-dip arrives near τ ≈ airplayDelayMs. 3100 ms
    /// = 3000 ms hard cap + 100 ms slack. With `cycles=1` (default) the
    /// expected pattern is a single rectangular pulse whose
    /// autocorrelation has no secondary lobes within this window.
    public static let localSearchMinMs: Int = 0
    public static let localSearchMaxMs: Int = 3100
    public static let airplaySearchMinMs: Int = 1500
    public static let airplaySearchMaxMs: Int = 2000

    /// Capture-tail padding so a local mute-dip delayed by up to
    /// `localSearchMaxMs` is still inside the recording window. Without
    /// this, widening the search range alone is meaningless — the dip
    /// would arrive after capture has stopped.
    public static let searchSlackMs: Int = localSearchMaxMs

    public var cycles: Int = 1
    public var confidenceAcceptThreshold: Double = 4.0

    public let microphoneDeviceID: AudioDeviceID?

    // MARK: - State

    private let stateLock = OSAllocatedUnfairLock()
    private var _running = false
    private var _cancelled = false
    private var _liveUnit: AudioUnit?

    public init(microphoneDeviceID: AudioDeviceID? = nil) {
        self.microphoneDeviceID = microphoneDeviceID
    }

    // MARK: - Constants

    private static let sampleRate: Double = 48_000
    private static let envelopeWindowMs: Int = 20
    private static let envelopeHopMs: Int = 10
    private static let baselineWindowMs: Int = 500
    private static let medianTaps: Int = 3
    private static let postRollMs: Int = 500
    private static let captureHeadMs: Int = 200
    private static let kPermissionDenied = OSStatus(bitPattern: UInt32(0x6E6F7065))

    // MARK: - Run

    /// Drive a complete probe cycle and return per-device latencies.
    /// `setLocalVolume` and `setAirplayVolume` are invoked at slot
    /// boundaries; the runner ALWAYS issues a final restore-to-original
    /// command per device on every exit path (success/throw/cancel).
    public func run(
        probes: [Probe],
        setLocalVolume: @escaping VolumeSetter,
        setAirplayVolume: @escaping AsyncVolumeSetter
    ) async throws -> Result {
        guard !probes.isEmpty else { throw CalibrationError.noProbesProvided }
        try stateLock.withLock {
            if _running { throw CalibrationError.alreadyRunning }
            _running = true; _cancelled = false
        }
        defer { stateLock.withLock { _running = false } }

        let n = probes.count
        let slotPitchMs = Self.tSoloMs + Self.tGuardMs
        let cycleMs = n * slotPitchMs
        let lambdaMax = max(
            Self.airplayDefaultLambdaMs,
            probes.map { $0.commandLatencyMs }.max() ?? 0
        )
        let prerollMs = lambdaMax
        // `searchSlackMs` pads the tail so locals delayed by up to the
        // delay-line max (whole-home mode) are still inside the capture.
        let totalMs = prerollMs + cycleMs * max(1, cycles) + Self.postRollMs + Self.searchSlackMs

        Self.trace(
            "[MuteDip] start: deviceCount=\(n) preroll=\(prerollMs)ms cycle=\(cycleMs)ms cycles=\(cycles) postroll=\(Self.postRollMs)ms slack=\(Self.searchSlackMs)ms total=\(totalMs)ms"
        )

        let captureFrames = Int(Double(totalMs + Self.captureHeadMs) / 1000.0 * Self.sampleRate)
        let captureStartNs = Clock.nowNs()

        async let captured: [Float] = self.captureMic(
            startNs: captureStartNs, frames: captureFrames
        )
        async let sequenced: Void = self.runProbeSequencer(
            probes: probes, cycles: max(1, cycles),
            wallClockOriginNs: captureStartNs,
            slotPitchMs: slotPitchMs, cycleMs: cycleMs, prerollMs: prerollMs,
            setLocalVolume: setLocalVolume,
            setAirplayVolume: setAirplayVolume
        )

        let mic: [Float]
        do {
            try await sequenced
            mic = try await captured
            try checkCancelled()
        } catch {
            await restoreVolumes(probes: probes,
                setLocalVolume: setLocalVolume,
                setAirplayVolume: setAirplayVolume)
            throw error
        }
        await restoreVolumes(probes: probes,
            setLocalVolume: setLocalVolume,
            setAirplayVolume: setAirplayVolume)

        Self.trace(
            "[MuteDip] mic captured frames=\(mic.count) rms=\(Self.dbfs(Self.rms(mic)))dB"
        )
        guard mic.count >= captureFrames / 2 else {
            throw CalibrationError.insufficientCapture
        }

        return processCapture(
            mic: mic, probes: probes,
            prerollMs: prerollMs,
            slotPitchMs: slotPitchMs, cycleMs: cycleMs
        )
    }

    public func cancel() {
        stateLock.withLockUnchecked {
            _cancelled = true
            if let u = _liveUnit {
                AudioOutputUnitStop(u)
                AudioUnitUninitialize(u)
                AudioComponentInstanceDispose(u)
                _liveUnit = nil
            }
        }
    }

    private func checkCancelled() throws {
        if stateLock.withLock({ _cancelled }) { throw CalibrationError.cancelled }
    }

    private func setLiveUnit(_ unit: AudioUnit?) {
        stateLock.withLockUnchecked { _liveUnit = unit }
    }

    private func disposeLiveUnit() {
        stateLock.withLockUnchecked {
            if let u = _liveUnit {
                AudioOutputUnitStop(u)
                AudioUnitUninitialize(u)
                AudioComponentInstanceDispose(u)
                _liveUnit = nil
            }
        }
    }

    // MARK: - Probe sequencer

    /// For each cycle and slot k, every device d gets a volume command
    /// at t_command = t_audible − λ_d. We sleep until the next command
    /// time and fire it. Hard transitions; design caveat §3.2.
    private func runProbeSequencer(
        probes: [Probe], cycles: Int,
        wallClockOriginNs: UInt64,
        slotPitchMs: Int, cycleMs: Int, prerollMs: Int,
        setLocalVolume: @escaping VolumeSetter,
        setAirplayVolume: @escaping AsyncVolumeSetter
    ) async throws {
        struct Cmd {
            let tCommandMs: Int; let tAudibleMs: Int
            let deviceID: String; let transport: Transport; let volume: Float
        }
        var commands: [Cmd] = []
        commands.reserveCapacity(cycles * probes.count * probes.count)
        for c in 0..<cycles {
            for slot in 0..<probes.count {
                let tAudibleMs = prerollMs + c * cycleMs + slot * slotPitchMs
                for d in probes {
                    let isSolo = (d.deviceID == probes[slot].deviceID)
                    let vol = isSolo ? d.originalVolume : Self.offLevel
                    let lambda: Int
                    if d.commandLatencyMs > 0 { lambda = d.commandLatencyMs }
                    else if d.transport == .airplay2 { lambda = Self.airplayDefaultLambdaMs }
                    else { lambda = Self.localDefaultLambdaMs }
                    commands.append(Cmd(
                        tCommandMs: tAudibleMs - lambda,
                        tAudibleMs: tAudibleMs,
                        deviceID: d.deviceID, transport: d.transport, volume: vol
                    ))
                }
            }
        }
        commands.sort { $0.tCommandMs < $1.tCommandMs }

        for cmd in commands {
            try checkCancelled()
            let nowNs = Clock.nowNs()
            let targetNs = wallClockOriginNs &+ UInt64(max(0, cmd.tCommandMs)) * 1_000_000
            if targetNs > nowNs {
                try await Task.sleep(nanoseconds: targetNs - nowNs)
            }
            try checkCancelled()
            Self.trace(
                "[MuteDip] slot device=\(cmd.deviceID) t_command=\(cmd.tCommandMs)ms t_audible=\(cmd.tAudibleMs)ms volume=\(String(format: "%.2f", cmd.volume))"
            )
            switch cmd.transport {
            case .coreAudio:
                setLocalVolume(cmd.deviceID, cmd.volume)
            case .airplay2:
                await setAirplayVolume(cmd.deviceID, cmd.volume)
            }
        }
    }

    private func restoreVolumes(
        probes: [Probe],
        setLocalVolume: VolumeSetter,
        setAirplayVolume: AsyncVolumeSetter
    ) async {
        for p in probes {
            switch p.transport {
            case .coreAudio:
                setLocalVolume(p.deviceID, p.originalVolume)
            case .airplay2:
                await setAirplayVolume(p.deviceID, p.originalVolume)
            }
        }
    }

    // MARK: - Capture processing (design §4–§5)

    private func processCapture(
        mic: [Float], probes: [Probe],
        prerollMs: Int, slotPitchMs: Int, cycleMs: Int
    ) -> Result {
        let env = Self.slidingRMS(
            mic: mic, windowMs: Self.envelopeWindowMs,
            hopMs: Self.envelopeHopMs, sampleRate: Self.sampleRate
        )
        let baseline = Self.movingAverage(
            env, windowSamples: max(1, Self.baselineWindowMs / Self.envelopeHopMs)
        )
        var envMod = Self.fractionalModulation(env: env, baseline: baseline)
        envMod = Self.medianFilter(envMod, taps: Self.medianTaps)

        Self.trace(
            "[MuteDip] env_mod range=[\(String(format: "%.4f", envMod.min() ?? 0)),\(String(format: "%.4f", envMod.max() ?? 0))] std=\(String(format: "%.4f", Self.stddev(envMod))) samples=\(envMod.count)"
        )

        var perDeviceTau: [String: Int] = [:]
        var perDeviceConf: [String: Double] = [:]

        for (slotIdx, p) in probes.enumerated() {
            let m_d = Self.expectedModulationPattern(
                slotIndex: slotIdx, probesCount: probes.count,
                cycles: max(1, cycles),
                prerollMs: prerollMs, slotPitchMs: slotPitchMs, cycleMs: cycleMs,
                envelopeFrames: envMod.count
            )
            let cd = Self.fftCrossCorrelation(env: envMod, pattern: m_d)
            let (kMinMs, kMaxMs): (Int, Int) = (p.transport == .coreAudio)
                ? (Self.localSearchMinMs, Self.localSearchMaxMs)
                : (Self.airplaySearchMinMs, Self.airplaySearchMaxMs)
            let kMin = max(0, kMinMs / Self.envelopeHopMs)
            let kMax = min(cd.count - 1, kMaxMs / Self.envelopeHopMs)
            guard kMax > kMin else {
                Self.trace("[MuteDip] device=\(p.deviceID) SKIP search_window=[\(kMin),\(kMax)] empty")
                continue
            }
            // Diagnostic: full-range argmax tells us if the in-window
            // peak is the real one or an artifact of a too-narrow window.
            let (fullPeakIdx, fullPeakVal) = Self.argmax(cd, begin: 0, end: cd.count)
            let (peakIdx, peakVal) = Self.argmax(cd, begin: kMin, end: kMax + 1)
            // Outside-window max (for diagnostic — a strong peak just
            // outside the window means the window is misplaced).
            let (outsidePeakIdx, outsidePeakVal) = Self.argmaxOutside(
                cd, excludeBegin: kMin, excludeEnd: kMax + 1
            )
            let (background, mad) = Self.backgroundStats(cd, excludingIdx: peakIdx, neighborhood: 5)
            let madFloor = max(mad, 1e-9)
            let confidence = Double((abs(peakVal) - background) / Float(madFloor))
            let tauMs = peakIdx * Self.envelopeHopMs
            perDeviceTau[p.deviceID] = tauMs
            perDeviceConf[p.deviceID] = confidence
            Self.trace(
                "[MuteDip] device=\(p.deviceID) searchWindow=[\(kMinMs)ms..\(kMaxMs)ms] peak_idx_full=\(fullPeakIdx)(\(fullPeakIdx * Self.envelopeHopMs)ms,\(String(format: "%.4f", fullPeakVal))) peak_in_window=\(peakIdx)(\(tauMs)ms,\(String(format: "%.4f", peakVal))) peak_outside=\(outsidePeakIdx)(\(outsidePeakIdx * Self.envelopeHopMs)ms,\(String(format: "%.4f", outsidePeakVal)))"
            )
            Self.trace(
                "[MuteDip] device=\(p.deviceID) τ=\(tauMs)ms peak=\(String(format: "%.4f", peakVal)) background=\(String(format: "%.4f", background)) mad=\(String(format: "%.4f", mad)) confidence=\(String(format: "%.2f", confidence)) transport=\(p.transport.rawValue)"
            )
        }

        let aggregate = perDeviceConf.values.min() ?? 0.0
        var maxAir = Int.min, maxLoc = Int.min
        for p in probes {
            guard let tau = perDeviceTau[p.deviceID] else { continue }
            switch p.transport {
            case .airplay2: if tau > maxAir { maxAir = tau }
            case .coreAudio: if tau > maxLoc { maxLoc = tau }
            }
        }
        let delta: Int = (maxAir == Int.min || maxLoc == Int.min) ? 0 : maxAir - maxLoc
        Self.trace(
            "[MuteDip] DONE delta=\(delta)ms confidence=\(String(format: "%.2f", aggregate)) perDevice=\(perDeviceTau)"
        )
        return Result(
            perDeviceTauMs: perDeviceTau,
            perDeviceConfidence: perDeviceConf,
            aggregateConfidence: aggregate,
            deltaMs: delta
        )
    }

    // MARK: - Signal processing primitives

    /// `env[k] = sqrt(mean(mic[k·H..k·H+W]²))`. vDSP_rmsqv per window.
    static func slidingRMS(
        mic: [Float], windowMs: Int, hopMs: Int, sampleRate: Double
    ) -> [Float] {
        let w = Int(Double(windowMs) / 1000.0 * sampleRate)
        let h = Int(Double(hopMs) / 1000.0 * sampleRate)
        guard w > 0, h > 0, mic.count >= w else { return [] }
        let count = (mic.count - w) / h + 1
        var out = [Float](repeating: 0, count: count)
        mic.withUnsafeBufferPointer { mp in
            for k in 0..<count {
                var rms: Float = 0
                vDSP_rmsqv(mp.baseAddress!.advanced(by: k * h), 1, &rms, vDSP_Length(w))
                out[k] = rms
            }
        }
        return out
    }

    /// Centered moving average via vDSP_vswsum (sum) + vsdiv (divide by W).
    /// Edges replicate from the trailing-mean array; design doc nominally
    /// asked for vDSP_vswsmean but that symbol isn't exported.
    static func movingAverage(_ x: [Float], windowSamples w: Int) -> [Float] {
        guard !x.isEmpty else { return [] }
        let n = x.count
        let win = max(1, min(n, w))
        if win == 1 { return x }
        let trailingCount = n - win + 1
        var trailing = [Float](repeating: 0, count: trailingCount)
        x.withUnsafeBufferPointer { xp in
            trailing.withUnsafeMutableBufferPointer { tp in
                vDSP_vswsum(xp.baseAddress!, 1, tp.baseAddress!, 1,
                            vDSP_Length(trailingCount), vDSP_Length(win))
            }
        }
        var winF = Float(win)
        trailing.withUnsafeMutableBufferPointer { tp in
            vDSP_vsdiv(tp.baseAddress!, 1, &winF,
                       tp.baseAddress!, 1, vDSP_Length(trailingCount))
        }
        var out = [Float](repeating: 0, count: n)
        let halfWin = win / 2
        for i in 0..<n {
            let src = i - halfWin
            if src < 0 { out[i] = trailing.first ?? x[i] }
            else if src >= trailing.count { out[i] = trailing.last ?? x[i] }
            else { out[i] = trailing[src] }
        }
        return out
    }

    /// `(env − baseline) / (baseline + ε)`. Note vDSP semantics:
    /// vDSP_vsub(a,b,out) = b − a, so we pass baseline first.
    /// vDSP_vdiv(a,b,out) = b / a, so we pass denom first.
    static func fractionalModulation(env: [Float], baseline: [Float]) -> [Float] {
        let n = min(env.count, baseline.count)
        guard n > 0 else { return [] }
        var num = [Float](repeating: 0, count: n)
        var denom = [Float](repeating: 0, count: n)
        env.withUnsafeBufferPointer { ep in
            baseline.withUnsafeBufferPointer { bp in
                num.withUnsafeMutableBufferPointer { np in
                    vDSP_vsub(bp.baseAddress!, 1, ep.baseAddress!, 1,
                              np.baseAddress!, 1, vDSP_Length(n))
                }
            }
        }
        var eps: Float = 1e-6
        baseline.withUnsafeBufferPointer { bp in
            denom.withUnsafeMutableBufferPointer { dp in
                vDSP_vsadd(bp.baseAddress!, 1, &eps,
                           dp.baseAddress!, 1, vDSP_Length(n))
            }
        }
        var out = [Float](repeating: 0, count: n)
        denom.withUnsafeBufferPointer { dp in
            num.withUnsafeBufferPointer { np in
                out.withUnsafeMutableBufferPointer { op in
                    vDSP_vdiv(dp.baseAddress!, 1, np.baseAddress!, 1,
                              op.baseAddress!, 1, vDSP_Length(n))
                }
            }
        }
        return out
    }

    /// 3-tap median filter, edges replicate. Median of 3 = a+b+c−min−max.
    static func medianFilter(_ x: [Float], taps: Int) -> [Float] {
        guard !x.isEmpty, taps >= 3 else { return x }
        let n = x.count
        var out = [Float](repeating: 0, count: n)
        out[0] = x[0]; out[n - 1] = x[n - 1]
        for i in 1..<(n - 1) {
            let a = x[i - 1], b = x[i], c = x[i + 1]
            out[i] = a + b + c - min(a, min(b, c)) - max(a, max(b, c))
        }
        return out
    }

    /// Expected (mean-removed) modulation pattern m_d for slot `slotIndex`:
    /// onLevel during this slot's solo windows across all cycles, offLevel
    /// elsewhere. Used as the cross-correlation reference per device.
    static func expectedModulationPattern(
        slotIndex: Int, probesCount: Int, cycles: Int,
        prerollMs: Int, slotPitchMs: Int, cycleMs: Int,
        envelopeFrames: Int
    ) -> [Float] {
        var p = [Float](repeating: offLevel, count: envelopeFrames)
        for c in 0..<cycles {
            let startMs = prerollMs + c * cycleMs + slotIndex * slotPitchMs
            let endMs = startMs + tSoloMs
            let startK = startMs / envelopeHopMs
            let endK = endMs / envelopeHopMs
            for k in max(0, startK)..<min(envelopeFrames, endK) { p[k] = onLevel }
        }
        let meanVal = p.reduce(0, +) / Float(max(1, p.count))
        for i in 0..<p.count { p[i] -= meanVal }
        return p
    }

    /// FFT-based cross-correlation: IFFT(FFT(env) · conj(FFT(pattern))).
    /// Real-input radix-2 path mirrors PassiveCalibrator.gccPhat minus the
    /// PHAT magnitude-normalisation step (we want absolute peak, not phase).
    static func fftCrossCorrelation(env: [Float], pattern: [Float]) -> [Float] {
        let length = max(env.count, pattern.count)
        let n = nextPowerOfTwo(length * 2)
        guard n > 1, (n & (n - 1)) == 0 else { return [] }
        let log2n = vDSP_Length(Int(log2(Double(n))))
        let halfN = n / 2

        let xR = UnsafeMutablePointer<Float>.allocate(capacity: halfN)
        let xI = UnsafeMutablePointer<Float>.allocate(capacity: halfN)
        let yR = UnsafeMutablePointer<Float>.allocate(capacity: halfN)
        let yI = UnsafeMutablePointer<Float>.allocate(capacity: halfN)
        let yIneg = UnsafeMutablePointer<Float>.allocate(capacity: halfN)
        let crossR = UnsafeMutablePointer<Float>.allocate(capacity: halfN)
        let crossI = UnsafeMutablePointer<Float>.allocate(capacity: halfN)
        defer {
            xR.deallocate(); xI.deallocate()
            yR.deallocate(); yI.deallocate(); yIneg.deallocate()
            crossR.deallocate(); crossI.deallocate()
        }
        xR.initialize(repeating: 0, count: halfN)
        xI.initialize(repeating: 0, count: halfN)
        yR.initialize(repeating: 0, count: halfN)
        yI.initialize(repeating: 0, count: halfN)

        var paddedEnv = [Float](repeating: 0, count: n)
        var paddedPat = [Float](repeating: 0, count: n)
        for i in 0..<min(env.count, n) { paddedEnv[i] = env[i] }
        for i in 0..<min(pattern.count, n) { paddedPat[i] = pattern[i] }

        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }

        var xSplit = DSPSplitComplex(realp: xR, imagp: xI)
        var ySplit = DSPSplitComplex(realp: yR, imagp: yI)
        paddedEnv.withUnsafeBufferPointer { p in
            p.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { cp in
                vDSP_ctoz(cp, 2, &xSplit, 1, vDSP_Length(halfN))
            }
        }
        paddedPat.withUnsafeBufferPointer { p in
            p.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { cp in
                vDSP_ctoz(cp, 2, &ySplit, 1, vDSP_Length(halfN))
            }
        }
        vDSP_fft_zrip(setup, &xSplit, 1, log2n, FFTDirection(FFT_FORWARD))
        vDSP_fft_zrip(setup, &ySplit, 1, log2n, FFTDirection(FFT_FORWARD))

        var minusOne: Float = -1.0
        vDSP_vsmul(yI, 1, &minusOne, yIneg, 1, vDSP_Length(halfN))
        var yConj = DSPSplitComplex(realp: yR, imagp: yIneg)
        var crossSplit = DSPSplitComplex(realp: crossR, imagp: crossI)
        vDSP_zvmul(&xSplit, 1, &yConj, 1, &crossSplit, 1, vDSP_Length(halfN), 1)
        vDSP_fft_zrip(setup, &crossSplit, 1, log2n, FFTDirection(FFT_INVERSE))

        var output = [Float](repeating: 0, count: n)
        output.withUnsafeMutableBufferPointer { op in
            op.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { cp in
                vDSP_ztoc(&crossSplit, 1, cp, 2, vDSP_Length(halfN))
            }
        }
        return output
    }

    static func argmax(_ x: [Float], begin: Int, end: Int) -> (idx: Int, value: Float) {
        precondition(begin >= 0 && end <= x.count && begin < end)
        var idx = begin
        var val: Float = -.infinity
        for i in begin..<end {
            let a = abs(x[i])
            if a > val { val = a; idx = i }
        }
        return (idx, val)
    }

    /// argmax over `x` EXCLUDING `[excludeBegin, excludeEnd)`. Used as a
    /// diagnostic: a strong peak outside the active search window means
    /// the window is misplaced. Returns (-1, 0) if every index is excluded.
    static func argmaxOutside(
        _ x: [Float], excludeBegin: Int, excludeEnd: Int
    ) -> (idx: Int, value: Float) {
        var idx = -1
        var val: Float = 0
        for i in 0..<x.count where i < excludeBegin || i >= excludeEnd {
            let a = abs(x[i])
            if a > val { val = a; idx = i }
        }
        return (idx, val)
    }

    /// Median + MAD over correlation EXCLUDING ±neighborhood of peak.
    /// Confidence denominator (design §7).
    static func backgroundStats(
        _ x: [Float], excludingIdx: Int, neighborhood: Int
    ) -> (median: Float, mad: Float) {
        guard !x.isEmpty else { return (0, 0) }
        let lo = max(0, excludingIdx - neighborhood)
        let hi = min(x.count, excludingIdx + neighborhood + 1)
        var bg: [Float] = []
        bg.reserveCapacity(x.count)
        for i in 0..<x.count where i < lo || i >= hi { bg.append(abs(x[i])) }
        guard !bg.isEmpty else { return (0, 0) }
        bg.sort()
        let median = bg[bg.count / 2]
        var dev = bg.map { abs($0 - median) }
        dev.sort()
        let mad = dev[dev.count / 2]
        return (median, mad)
    }

    static func stddev(_ x: [Float]) -> Float {
        guard !x.isEmpty else { return 0 }
        let mean = x.reduce(0, +) / Float(x.count)
        let sq = x.reduce(Float(0)) { $0 + ($1 - mean) * ($1 - mean) }
        return sqrt(sq / Float(x.count))
    }

    static func nextPowerOfTwo(_ n: Int) -> Int {
        guard n > 1 else { return 1 }
        var p = 1; while p < n { p <<= 1 }; return p
    }

    static func rms(_ x: [Float]) -> Float {
        guard !x.isEmpty else { return 0 }
        var ms: Float = 0
        x.withUnsafeBufferPointer { ptr in
            vDSP_measqv(ptr.baseAddress!, 1, &ms, vDSP_Length(ptr.count))
        }
        return sqrt(ms)
    }

    static func dbfs(_ rms: Float) -> String {
        if rms <= 0 { return "-inf" }
        return String(format: "%.1f", 20.0 * Foundation.log10(Double(rms)))
    }

    // MARK: - Microphone capture
    //
    // Mirrors CalibrationRunner / PassiveCalibrator AUHAL plumbing. EnableIO
    // input bus 1, disable output bus 0, mono Float32 non-interleaved 48 kHz.

    fileprivate func captureMic(startNs: UInt64, frames: Int) async throws -> [Float] {
        try checkCancelled()
        guard frames > 0 else { return [] }
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        buffer.initialize(repeating: 0, count: frames)
        defer { buffer.deinitialize(count: frames); buffer.deallocate() }
        let context = MuteDipMicCaptureContext(buffer: buffer, capacity: frames)
        let opaque = Unmanaged.passUnretained(context).toOpaque()
        let resolvedDevice: AudioDeviceID
        do {
            resolvedDevice = try resolveInputDeviceID()
        } catch {
            Self.trace("[MuteDip] captureMic: FAILED to resolve mic device: \(error)")
            throw error
        }
        let unit: AudioUnit
        do {
            unit = try Self.openInputUnit(deviceID: resolvedDevice, inputCallbackContext: opaque)
            Self.trace("[MuteDip] captureMic: AU opened+started OK dev=\(resolvedDevice) target_frames=\(frames)")
        } catch {
            Self.trace("[MuteDip] captureMic: AU FAILED: \(error)")
            throw error
        }
        setLiveUnit(unit)
        let durationNs = UInt64(Double(frames) / Self.sampleRate * 1_000_000_000.0) + 100_000_000
        let endNs = startNs &+ durationNs
        do {
            while !context.isFull {
                try checkCancelled()
                if Clock.nowNs() >= endNs { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        } catch {
            disposeLiveUnit(); throw error
        }
        disposeLiveUnit()
        let written = min(frames, context.writtenFrameCount())
        Self.trace("[MuteDip] captureMic: AU torn down written=\(written)/\(frames) frames")
        return [Float](unsafeUninitializedCapacity: written) { ptr, count in
            ptr.baseAddress!.update(from: buffer, count: written)
            count = written
        }
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
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev
        )
        guard status == noErr, dev != 0 else { throw CalibrationError.noInputDevice }
        return dev
    }

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
        func setProp<T>(_ sel: AudioUnitPropertyID, _ scope: AudioUnitScope,
                        _ bus: AudioUnitElement, _ value: inout T) throws {
            let s = withUnsafeMutablePointer(to: &value) { p -> OSStatus in
                AudioUnitSetProperty(unit, sel, scope, bus, p, UInt32(MemoryLayout<T>.size))
            }
            if s != noErr { throw CalibrationError.audioUnitConfigurationFailed(s) }
        }
        var enable: UInt32 = 1, disable: UInt32 = 0, devID = deviceID
        try setProp(kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enable)
        try setProp(kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disable)
        try setProp(kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &devID)
        var fmt = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
                | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0
        )
        try setProp(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &fmt)
        var callback = AURenderCallbackStruct(
            inputProc: { (inRefCon, flags, ts, _, frames, _) -> OSStatus in
                let ctx = Unmanaged<MuteDipMicCaptureContext>
                    .fromOpaque(inRefCon).takeUnretainedValue()
                return ctx.fetch(flags: flags, timestamp: ts, frames: frames)
            },
            inputProcRefCon: inputCallbackContext
        )
        try setProp(kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback)
        let ctxObj = Unmanaged<MuteDipMicCaptureContext>
            .fromOpaque(inputCallbackContext).takeUnretainedValue()
        ctxObj.unit = unit
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
}

/// AU input-callback state. Unfair-locked memcpy from CoreAudio scratch
/// into the run-owned destination. RT-safe — no allocations after init.
private final class MuteDipMicCaptureContext {
    let buffer: UnsafeMutablePointer<Float>
    let capacity: Int
    var unit: AudioUnit?

    private let lock = OSAllocatedUnfairLock()
    private var written: Int = 0
    private let abl: UnsafeMutablePointer<AudioBufferList>
    private let scratch: UnsafeMutablePointer<Float>
    private let scratchCapacity: Int = 8192

    init(buffer: UnsafeMutablePointer<Float>, capacity: Int) {
        self.buffer = buffer; self.capacity = capacity
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

    var isFull: Bool { lock.withLock { written >= capacity } }
    func writtenFrameCount() -> Int { lock.withLock { written } }

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
        let start: Int = lock.withLock {
            let avail = capacity - written
            return avail > 0 ? written : -1
        }
        if start < 0 { return noErr }
        let take = min(n, capacity - start)
        buffer.advanced(by: start).update(from: scratch, count: take)
        lock.withLock { written = start + take }
        return noErr
    }
}
