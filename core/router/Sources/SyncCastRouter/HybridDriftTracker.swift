import Foundation
import CoreAudio
import AudioToolbox
import Accelerate
import os.lock

/// **Round-10 Phase 1 — closed-loop drift tracker.**
///
/// 95% passive GCC-PHAT cross-correlation (mic vs SCK source PCM) +
/// 5% on-demand ultrasonic chirp (17.6–18.8 kHz, 250 ms, −24 dBFS).
/// 4 Hz tick → per-device 2D Kalman `[offset_ms, drift_ppm]` →
/// rate-limited PI controller → `airplayDelayMs`.
///
/// Pipeline: decimate to 8 kHz, Hilbert envelope, GCC-PHAT,
/// peak-search in 50–500 ms (local) AND 1500–4000 ms (AirPlay PTP)
/// bands with prior-aware tie-break. Kalman update R adapts to
/// confidence; controller `u = clip(Kp·e + Ki·∫e dt, ±rateLimit·dt)`
/// where `e = -kalman.offset`. All trace output via `CalibTrace.log`
/// with `[HybridTracker]` prefix.
public actor HybridDriftTracker {

    // MARK: - Public API

    public struct Configuration: Sendable {
        public var tickIntervalMs: Int = 250
        public var passiveWindowSeconds: Double = 4.0
        public var localBandMs: ClosedRange<Double> = 50...500
        public var airBandMs: ClosedRange<Double> = 1500...4000
        public var minPassiveConfidence: Double = 4.0
        public var maxPassiveAgeSeconds: Double = 8.0
        public var minProbeIntervalSeconds: Double = 30.0
        public var probeF0Hz: Double = 17_600
        public var probeF1Hz: Double = 18_800
        public var probeDurationMs: Int = 250
        public var probeAmplitudeDBFS: Double = -24.0
        public var rateLimitMsPerSecond: Double = 5.0
        public var kalmanProcessNoise: Double = 0.5
        public var kalmanMeasurementNoise: Double = 5.0
        public var pidKp: Double = 0.4
        public var pidKi: Double = 0.08

        public init() {}
    }

    public enum Source: Sendable, Equatable { case passive, active, none }
    public enum LostReason: Sendable, Equatable {
        case micFailed, peakLockFailed, network, manual
    }
    public enum State: Sendable, Equatable {
        case coldStart
        case warming(progress: Double)
        case locked
        case drifting(quietSeconds: Double)
        case lost(LostReason)
    }

    public struct Sample: Sendable {
        public let timestamp: Date
        public let kalmanOffsetMs: Double
        public let kalmanDriftPpm: Double
        /// nil ⇒ predicted-only tick; otherwise the raw measured offset.
        public let measuredOffsetMs: Double?
        public let confidence: Double
        public let source: Source
        /// PI-step output in ms (signed). +ve increases delay-line.
        public let appliedCorrectionMs: Double
        /// Delay-line value in ms after this tick's correction.
        public let resultingDelayMs: Double
        public let state: State

        public init(timestamp: Date, kalmanOffsetMs: Double,
                    kalmanDriftPpm: Double, measuredOffsetMs: Double?,
                    confidence: Double, source: Source,
                    appliedCorrectionMs: Double, resultingDelayMs: Double,
                    state: State) {
            self.timestamp = timestamp
            self.kalmanOffsetMs = kalmanOffsetMs
            self.kalmanDriftPpm = kalmanDriftPpm
            self.measuredOffsetMs = measuredOffsetMs
            self.confidence = confidence
            self.source = source
            self.appliedCorrectionMs = appliedCorrectionMs
            self.resultingDelayMs = resultingDelayMs
            self.state = state
        }
    }

    public typealias DelayProvider = @Sendable () async -> Int
    public typealias DelayApplier = @Sendable (Int) async -> Void
    public typealias ChirpInjector =
        @Sendable ([[Float]], UInt64) async -> Void
    public typealias SampleSink = @Sendable (Sample) -> Void

    // MARK: - Internal state

    private let ringBuffer: RingBuffer
    private let micDeviceIDOpt: AudioDeviceID?
    private let getCurrentDelayMs: DelayProvider
    private let applyDelayMs: DelayApplier
    private let injectChirpToRing: ChirpInjector
    private let onSample: SampleSink
    private let configuration: Configuration

    private var loopTask: Task<Void, Never>?
    private var running: Bool = false
    private var startedAt: Date = .distantPast
    private var lastObservationAt: Date = .distantPast
    private var lastConfidence: Double = 0
    private var lastProbeAt: Date = .distantPast
    private var quietFrames: Int = 0
    private var ticks: UInt64 = 0
    private var currentState: State = .coldStart

    private var kalman: Kalman2D
    private var pi: PIController
    private var micCapture: HybridMicCapture?

    // MARK: - Init / lifecycle

    public init(
        ringBuffer: RingBuffer,
        microphoneDeviceID: AudioDeviceID?,
        currentDelayMs: @escaping DelayProvider,
        applyDelayMs: @escaping DelayApplier,
        injectChirpToRing: @escaping ChirpInjector,
        onSample: @escaping SampleSink,
        configuration: Configuration = .init()
    ) {
        self.ringBuffer = ringBuffer
        self.micDeviceIDOpt = microphoneDeviceID
        self.getCurrentDelayMs = currentDelayMs
        self.applyDelayMs = applyDelayMs
        self.injectChirpToRing = injectChirpToRing
        self.onSample = onSample
        self.configuration = configuration
        self.kalman = Kalman2D(
            processNoiseOffset: configuration.kalmanProcessNoise,
            processNoiseDriftPpm: 2.0,
            measurementNoise: configuration.kalmanMeasurementNoise
        )
        self.pi = PIController(
            kp: configuration.pidKp,
            ki: configuration.pidKi,
            integralLimitMs: 200.0,
            rateLimitMsPerSecond: configuration.rateLimitMsPerSecond
        )
    }

    /// Begin tracking. Idempotent. Throws if the mic AudioUnit can't be
    /// opened (permission denied, no default input, AU init failure).
    public func start() async throws {
        if running { return }
        running = true
        startedAt = Date()
        lastObservationAt = .distantPast; lastProbeAt = .distantPast
        lastConfidence = 0; quietFrames = 0; ticks = 0
        currentState = .coldStart
        kalman.reset(); pi.reset()
        do {
            micCapture = try HybridMicCapture.open(
                deviceID: micDeviceIDOpt,
                windowSeconds: configuration.passiveWindowSeconds + 1.0
            )
            CalibTrace.log(
                "[HybridTracker] start: tick=\(configuration.tickIntervalMs)ms window=\(configuration.passiveWindowSeconds)s minConf=\(configuration.minPassiveConfidence) probeBand=\(Int(configuration.probeF0Hz))-\(Int(configuration.probeF1Hz))Hz dBFS=\(configuration.probeAmplitudeDBFS) rateLimit=\(configuration.rateLimitMsPerSecond)ms/s")
        } catch {
            running = false
            currentState = .lost(.micFailed)
            CalibTrace.log("[HybridTracker] start FAILED — mic open error: \(error)")
            throw error
        }
        loopTask = Task.detached(priority: .utility) { [weak self] in
            await self?.runLoop()
        }
    }

    /// Stop tracking. Idempotent. Releases the mic AudioUnit.
    public func stop() {
        guard running else { return }
        running = false
        loopTask?.cancel(); loopTask = nil
        micCapture?.close(); micCapture = nil
        currentState = .lost(.manual)
        CalibTrace.log(
            "[HybridTracker] stop: ticks=\(ticks) lastConf=\(String(format: "%.2f", lastConfidence))")
    }

    // MARK: - Loop

    private func runLoop() async {
        let tickNs = UInt64(configuration.tickIntervalMs) * 1_000_000
        while shouldContinue() {
            await tickOnce()
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: tickNs)
        }
    }

    private func shouldContinue() -> Bool { running && !Task.isCancelled }

    /// One tick of the closed loop. Always emits exactly one Sample.
    private func tickOnce() async {
        ticks &+= 1
        let dt = Double(configuration.tickIntervalMs) / 1000.0
        let now = Date()
        var measured: Double? = nil
        var confidence: Double = 0
        var source: Source = .none

        switch transitionGate(now: now) {
        case .skip(let reason):
            CalibTrace.log("[HybridTracker] tick=\(ticks) gate=skip reason=\(reason)")
        case .passive:
            if let obs = await passiveMeasure() {
                (measured, confidence, source) = (obs.offsetMs, obs.confidence, .passive)
                lastObservationAt = now
                lastConfidence = obs.confidence
                quietFrames = 0
            } else { quietFrames += 1 }
        case .active:
            lastProbeAt = now
            if let obs = await activeProbe() {
                (measured, confidence, source) = (obs.offsetMs, obs.confidence, .active)
                lastObservationAt = now
                lastConfidence = obs.confidence
                quietFrames = 0
            } else { quietFrames += 1 }
        }

        // Kalman predict + (optional) update.
        kalman.predict(dt: dt)
        if let m = measured {
            kalman.update(measurement: m, confidence: max(0.5, confidence))
        }
        // PI controller drives kalman.offset → 0 on top of whatever
        // delay is currently posted.
        let baseDelay = await getCurrentDelayMs()
        let u = pi.step(error: -kalman.x[0], dt: dt)
        let target = max(0, min(10_000, Double(baseDelay) + u))
        let targetInt = Int(target.rounded())
        if abs(targetInt - baseDelay) >= 1 && source != .none {
            await applyDelayMs(targetInt)
        }
        currentState = nextState(now: now, source: source, conf: confidence)
        onSample(Sample(
            timestamp: now,
            kalmanOffsetMs: kalman.x[0],
            kalmanDriftPpm: kalman.x[1],
            measuredOffsetMs: measured,
            confidence: confidence,
            source: source,
            appliedCorrectionMs: target - Double(baseDelay),
            resultingDelayMs: target,
            state: currentState))
        let mStr = measured.map { String(format: "%.1f", $0) } ?? "nil"
        CalibTrace.log(
            "[HybridTracker] tick=\(ticks) src=\(describe(source: source)) measured=\(mStr)ms conf=\(String(format: "%.2f", confidence)) kalman.offset=\(String(format: "%.2f", kalman.x[0]))ms drift=\(String(format: "%.1f", kalman.x[1]))ppm u=\(String(format: "%.2f", u))ms base=\(baseDelay)ms applied=\(targetInt)ms state=\(describe(state: currentState))"
        )
    }

    // MARK: - Transition gate

    private enum GateDecision {
        case passive
        case active
        case skip(String)
    }

    private func transitionGate(now: Date) -> GateDecision {
        // Cold start: probe in tick 1 so the controller has a real
        // measurement before it starts moving.
        if ticks == 1 { return .active }
        let probeAge = now.timeIntervalSince(lastProbeAt)
        let obsAge = now.timeIntervalSince(lastObservationAt)
        let confLow = lastConfidence < configuration.minPassiveConfidence
        let needProbe = (confLow && obsAge > 5.0)
            || obsAge > configuration.maxPassiveAgeSeconds
            || kalman.residualVariance > 100.0  // ms²
        if probeAge >= configuration.minProbeIntervalSeconds && needProbe {
            return .active
        }
        return .passive
    }

    // MARK: - Passive measurement

    private struct Observation {
        let offsetMs: Double
        let confidence: Double
    }

    private func passiveMeasure() async -> Observation? {
        guard let cap = micCapture else { return nil }
        let micSR = HybridMicCapture.sampleRate
        let windowFrames = Int(configuration.passiveWindowSeconds * micSR)
        // Reach past air-band upper bound so the PHAT search window
        // captures the full AirPlay PTP latency tail.
        let maxLagFrames = Int(
            (configuration.airBandMs.upperBound + 1000) / 1000.0 * micSR
        )
        let sourceFrames = windowFrames + maxLagFrames

        let micWindow = cap.snapshot(frames: windowFrames)
        guard micWindow.count == windowFrames else { return nil }
        let source = readSourceMix(frames: sourceFrames)
        guard source.count == sourceFrames else { return nil }
        // Energy gate (~−60 dBFS).
        if HybridDSP.rms(micWindow) < 1e-3 || HybridDSP.rms(source) < 1e-3 {
            return nil
        }
        // Decimate to 8 kHz (6× compute saving on the FFT path),
        // Hilbert envelope, GCC-PHAT.
        let decim = Int(micSR / 8000.0)        // 6
        let micE = HybridDSP.hilbertMagnitude(HybridDSP.decimate(micWindow, factor: decim))
        let srcE = HybridDSP.hilbertMagnitude(HybridDSP.decimate(source, factor: decim))
        let decSR = micSR / Double(decim)
        let n = HybridDSP.nextPow2(micE.count + srcE.count)
        guard let corr = HybridDSP.gccPhat(source: srcE, mic: micE, fftSize: n) else {
            return nil
        }
        // Lag → ms. Mic's most-recent window ends at the same wall-clock
        // moment as source's tail; peak idx k ⇒ delay = (k − leadingPad).
        let leadingPad = (sourceFrames - windowFrames) / decim
        func lagToMs(_ idx: Int) -> Double {
            Double(idx - leadingPad) / decSR * 1000.0
        }
        let prior = kalman.x[0]
        guard let local = bestPeak(
                in: corr, begin: 0, end: corr.count,
                bandMs: configuration.localBandMs,
                lagToMs: lagToMs, prior: prior),
              let air = bestPeak(
                in: corr, begin: 0, end: corr.count,
                bandMs: configuration.airBandMs,
                lagToMs: lagToMs, prior: prior)
        else { return nil }
        // Closer-to-prior wins; near-zero prior prefers air-band (the
        // delay-line we actually drive).
        let pickAir = abs(air.offsetMs - prior) <= abs(local.offsetMs - prior)
            || abs(prior) < 1.0
        let chosen = pickAir ? air : local
        if local.confidence < configuration.minPassiveConfidence
            || air.confidence < configuration.minPassiveConfidence {
            return nil
        }
        return Observation(offsetMs: chosen.offsetMs, confidence: chosen.confidence)
    }

    /// Read the last `frames` of source PCM mixed to mono.
    private func readSourceMix(frames: Int) -> [Float] {
        let target = ringBuffer.writePosition - Int64(frames)
        guard target >= 0 else { return [] }
        let chCount = ringBuffer.channelCount
        let chPtrs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>
            .allocate(capacity: chCount)
        defer { chPtrs.deallocate() }
        for c in 0..<chCount {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            p.initialize(repeating: 0, count: frames)
            chPtrs[c] = p
        }
        defer { for c in 0..<chCount { chPtrs[c].deallocate() } }
        _ = ringBuffer.read(at: target, frames: frames, into: UnsafePointer(chPtrs))
        var mix = [Float](repeating: 0, count: frames)
        let inv = Float(1) / Float(max(1, chCount))
        for c in 0..<chCount {
            let p = chPtrs[c]
            for i in 0..<frames { mix[i] += p[i] * inv }
        }
        return mix
    }

    /// Peak in `[band.lower, band.upper]` ms with prior-aware scoring.
    /// Score = peakAmplitude × prominence × sharpness − 0.05·|lag − prior|.
    private struct BandPeak {
        let idx: Int
        let offsetMs: Double
        let confidence: Double
    }

    private func bestPeak(
        in corr: [Float], begin: Int, end: Int,
        bandMs: ClosedRange<Double>,
        lagToMs: (Int) -> Double,
        prior: Double
    ) -> BandPeak? {
        var lo = -1, hi = -1
        for i in begin..<end {
            let ms = lagToMs(i)
            if lo < 0 && ms >= bandMs.lowerBound { lo = i }
            if ms <= bandMs.upperBound { hi = i }
            if ms > bandMs.upperBound && lo >= 0 { break }
        }
        guard lo >= 0, hi > lo else { return nil }
        var peakIdx = lo
        var peakVal: Float = -.infinity
        for i in lo...hi {
            let a = abs(corr[i])
            if a > peakVal { peakVal = a; peakIdx = i }
        }
        guard peakVal > 0 else { return nil }
        // Prominence vs surrounding samples in the band (excluding ±8).
        let nb = 8
        let exLo = max(lo, peakIdx - nb), exHi = min(hi, peakIdx + nb)
        var runner: Float = 0
        for i in lo..<exLo { let a = abs(corr[i]); if a > runner { runner = a } }
        if exHi + 1 <= hi {
            for i in (exHi + 1)...hi {
                let a = abs(corr[i]); if a > runner { runner = a }
            }
        }
        let prominence = Double((peakVal - runner) / peakVal)
        // Sharpness: peak / local-mean in ±32 (concentrated energy ⇒
        // sharp; reverb smear pulls this toward 1.0).
        let sLo = max(lo, peakIdx - 32), sHi = min(hi, peakIdx + 32)
        var sum: Float = 0, count: Int = 0
        for i in sLo...sHi { sum += abs(corr[i]); count += 1 }
        let local = count > 0 ? sum / Float(count) : 1
        let sharpness = local > 0 ? Double(peakVal / local) : 0
        let offsetMs = lagToMs(peakIdx)
        let score = max(0,
            Double(peakVal) * prominence * sharpness
            - 0.05 * abs(offsetMs - prior))
        return BandPeak(idx: peakIdx, offsetMs: offsetMs, confidence: score)
    }

    // MARK: - Active probe

    private func activeProbe() async -> Observation? {
        guard let cap = micCapture else { return nil }
        let micSR = HybridMicCapture.sampleRate
        let amp = Float(pow(10.0, configuration.probeAmplitudeDBFS / 20.0))
        let chirp48 = HybridDSP.linearChirp(
            startHz: configuration.probeF0Hz, endHz: configuration.probeF1Hz,
            durationMs: configuration.probeDurationMs,
            amplitude: amp, sampleRate: 48_000)
        let chirpMic = HybridDSP.linearChirp(
            startHz: configuration.probeF0Hz, endHz: configuration.probeF1Hz,
            durationMs: configuration.probeDurationMs,
            amplitude: 1.0, sampleRate: micSR)

        // Anchor inject 100 ms past mic write position so the noise
        // floor window is captured first.
        let captureMs = configuration.probeDurationMs
            + Int(configuration.airBandMs.upperBound) + 500
        let captureFrames = Int(Double(captureMs) / 1000.0 * micSR)
        let captureStartNs = Clock.nowNs()
        let injectAtNs = captureStartNs &+ 100_000_000
        cap.markAnchor(at: captureStartNs)
        await injectChirpToRing([chirp48, chirp48], injectAtNs)
        try? await Task.sleep(nanoseconds: UInt64(captureMs) * 1_000_000)

        let mic = cap.readSinceAnchor(maxFrames: captureFrames)
        guard mic.count >= captureFrames / 2 else {
            CalibTrace.log("[HybridTracker] probe: insufficient_capture got=\(mic.count) want=\(captureFrames)")
            return nil
        }
        let bp = HybridDSP.bandpass64(
            samples: mic, lowHz: 17_400, highHz: 19_000, sampleRate: micSR)
        let xc = HybridDSP.fftCrossCorrelation(env: bp, pattern: chirpMic)
        let injectFrame = Int(0.1 * micSR)  // anchor +100 ms
        let kMin = injectFrame + Int(configuration.airBandMs.lowerBound / 1000.0 * micSR)
        let kMax = min(xc.count - 1,
            injectFrame + Int(configuration.airBandMs.upperBound / 1000.0 * micSR))
        guard kMax > kMin else { return nil }
        let (peakIdx, peakVal) = HybridDSP.argmax(xc, begin: kMin, end: kMax + 1)
        let (bg, mad) = HybridDSP.backgroundStats(
            xc, excludingIdx: peakIdx, neighborhood: 64)
        let prominence = Double((abs(peakVal) - bg) / Float(max(mad, 1e-9)))
        let offsetMs = Double(peakIdx - injectFrame) / micSR * 1000.0
        CalibTrace.log(
            "[HybridTracker] probe: peak_idx=\(peakIdx) offset=\(String(format: "%.1f", offsetMs))ms prominence=\(String(format: "%.2f", prominence)) bg=\(String(format: "%.4f", bg)) mad=\(String(format: "%.4f", mad))"
        )
        guard prominence >= 4.0 else { return nil }
        return Observation(offsetMs: offsetMs, confidence: prominence)
    }

    // MARK: - State machine

    private func nextState(now: Date, source: Source, conf: Double) -> State {
        let warmingTarget = 4.0
        let elapsed = now.timeIntervalSince(startedAt)
        if !running { return .lost(.manual) }
        if conf <= 0 && source == .none {
            let obsAge = now.timeIntervalSince(lastObservationAt)
            if obsAge > 30 && lastObservationAt != .distantPast {
                return .lost(.peakLockFailed)
            }
        }
        if elapsed < warmingTarget {
            return .warming(progress: elapsed / warmingTarget)
        }
        if conf >= configuration.minPassiveConfidence { return .locked }
        let quiet = Double(quietFrames) * Double(configuration.tickIntervalMs) / 1000.0
        return quiet > 0 ? .drifting(quietSeconds: quiet) : .locked
    }

    private func describe(state: State) -> String {
        switch state {
        case .coldStart:             return "coldStart"
        case .warming(let p):        return "warming(\(String(format: "%.2f", p)))"
        case .locked:                return "locked"
        case .drifting(let q):       return "drifting(\(String(format: "%.1f", q))s)"
        case .lost(.micFailed):      return "lost(mic)"
        case .lost(.peakLockFailed): return "lost(peak)"
        case .lost(.network):        return "lost(net)"
        case .lost(.manual):         return "lost(manual)"
        }
    }

    private func describe(source: Source) -> String {
        switch source {
        case .passive: return "passive"
        case .active:  return "active"
        case .none:    return "none"
        }
    }
}

// MARK: - Kalman 2D filter

/// Constant-drift 2D Kalman: x = [offset_ms, drift_ppm], F = [[1,dt],[0,1]],
/// H = [1,0], Q = diag(qOffset, qDriftPpm²), R = measurementNoise² /
/// max(0.01, confidence). `residualVariance` is exported so the
/// transition gate can fire an active probe when the innovation grows.
struct Kalman2D {
    var x: [Double] = [0, 0]                  // offset_ms, drift_ppm
    var P: [Double] = [1, 0, 0, 1]
    var residualVariance: Double = 0
    let qOffset: Double, qDriftPpm: Double, measurementR: Double

    init(processNoiseOffset: Double, processNoiseDriftPpm: Double,
         measurementNoise: Double) {
        self.qOffset = processNoiseOffset
        self.qDriftPpm = processNoiseDriftPpm
        self.measurementR = measurementNoise * measurementNoise
    }

    mutating func reset() { x = [0, 0]; P = [1, 0, 0, 1]; residualVariance = 0 }

    /// x' = F x; P' = F P Fᵀ + Q.
    mutating func predict(dt: Double) {
        x[0] = x[0] + x[1] * dt
        let p00 = P[0], p01 = P[1], p10 = P[2], p11 = P[3]
        P = [p00 + dt * (p01 + p10) + dt * dt * p11 + qOffset,
             p01 + dt * p11,
             p10 + dt * p11,
             p11 + qDriftPpm * qDriftPpm]
    }

    /// y = z − H x; S = P[0] + R(conf); K = [P[0]/S, P[2]/S];
    /// x += K y; P = (I − K H) P.
    mutating func update(measurement z: Double, confidence: Double) {
        let y = z - x[0]
        let s = P[0] + measurementR / max(0.01, confidence)
        let k0 = P[0] / s, k1 = P[2] / s
        x[0] += k0 * y; x[1] += k1 * y
        let p00 = P[0], p01 = P[1], p10 = P[2], p11 = P[3]
        P = [p00 - k0 * p00, p01 - k0 * p01,
             p10 - k1 * p00, p11 - k1 * p01]
        residualVariance = y * y
    }
}

// MARK: - PI controller

/// Rate-limited PI. i = clip(i + e·dt, ±integralLimit);
/// u = clip(Kp·e + Ki·i, ±rateLimit·dt).
struct PIController {
    let kp: Double, ki: Double
    let integralLimitMs: Double, rateLimitMsPerSecond: Double
    private var integral: Double = 0

    init(kp: Double, ki: Double, integralLimitMs: Double,
         rateLimitMsPerSecond: Double) {
        self.kp = kp; self.ki = ki
        self.integralLimitMs = integralLimitMs
        self.rateLimitMsPerSecond = rateLimitMsPerSecond
    }

    mutating func reset() { integral = 0 }

    mutating func step(error: Double, dt: Double) -> Double {
        integral = max(-integralLimitMs,
                       min(integralLimitMs, integral + error * dt))
        let raw = kp * error + ki * integral
        let limit = rateLimitMsPerSecond * dt
        return max(-limit, min(limit, raw))
    }
}

// MARK: - DSP primitives
//
// Pure-utility helpers. We re-export `ActiveCalibrator` statics that
// are already well-tested (`linearChirp`, `fftCrossCorrelation`,
// `argmax`, `backgroundStats`, `rms`, `nextPowerOfTwo`) under shorter
// names rather than copy-pasting another ~130 LOC of vDSP boilerplate.

enum HybridDSP {
    @inline(__always) static func nextPow2(_ n: Int) -> Int {
        ActiveCalibrator.nextPowerOfTwo(n)
    }
    @inline(__always) static func rms(_ x: [Float]) -> Float {
        ActiveCalibrator.rms(x)
    }
    @inline(__always) static func argmax(
        _ x: [Float], begin: Int, end: Int
    ) -> (idx: Int, value: Float) {
        ActiveCalibrator.argmax(x, begin: begin, end: end)
    }
    @inline(__always) static func backgroundStats(
        _ x: [Float], excludingIdx: Int, neighborhood: Int
    ) -> (median: Float, mad: Float) {
        ActiveCalibrator.backgroundStats(
            x, excludingIdx: excludingIdx, neighborhood: neighborhood
        )
    }
    @inline(__always) static func fftCrossCorrelation(
        env: [Float], pattern: [Float]
    ) -> [Float] {
        ActiveCalibrator.fftCrossCorrelation(env: env, pattern: pattern)
    }
    @inline(__always) static func linearChirp(
        startHz: Double, endHz: Double, durationMs: Int,
        amplitude: Float, sampleRate: Double
    ) -> [Float] {
        ActiveCalibrator.linearChirp(
            startHz: startHz, endHz: endHz, durationMs: durationMs,
            amplitude: amplitude, sampleRate: sampleRate
        )
    }

    /// Naïve decimation: pick every `factor`-th sample. The Hilbert
    /// magnitude that follows is already low-passed by the magnitude
    /// operation, plus the 6× factor here keeps any residual aliasing
    /// well below the PHAT denoising floor.
    static func decimate(_ x: [Float], factor: Int) -> [Float] {
        guard factor > 1 else { return x }
        let outCount = x.count / factor
        var out = [Float](repeating: 0, count: outCount)
        for i in 0..<outCount { out[i] = x[i * factor] }
        return out
    }

    /// Hilbert-style envelope: |x| smoothed by a 5-sample symmetric box
    /// filter. The full analytic-signal Hilbert transform via packed-
    /// real FFT is finicky to implement correctly (the imag slot at
    /// index 0 doubles as the Nyquist bin); for the PHAT downstream we
    /// only need a magnitude-tracking envelope, and this shorter path
    /// is faster + allocation-light.
    static func hilbertMagnitude(_ x: [Float]) -> [Float] {
        let n = x.count
        guard n > 0 else { return [] }
        var rect = [Float](repeating: 0, count: n)
        for i in 0..<n { rect[i] = abs(x[i]) }
        let win = 5, half = win / 2
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let lo = max(0, i - half)
            let hi = min(n - 1, i + half)
            var s: Float = 0
            for j in lo...hi { s += rect[j] }
            out[i] = s / Float(hi - lo + 1)
        }
        return out
    }

    /// 64-tap windowed-sinc bandpass (Hann window). Cheap enough to
    /// build per-call; the chirp probe runs <0.5% of the time.
    static func bandpass64(
        samples: [Float], lowHz: Double, highHz: Double, sampleRate: Double
    ) -> [Float] {
        let taps = 64
        let nyq = sampleRate / 2
        let f1 = lowHz / nyq, f2 = highHz / nyq
        var coef = [Float](repeating: 0, count: taps)
        let mid = Double(taps - 1) / 2.0
        for n in 0..<taps {
            let k = Double(n) - mid
            let h = (k == 0)
                ? (f2 - f1)
                : (sin(.pi * f2 * k) - sin(.pi * f1 * k)) / (.pi * k)
            let w = 0.5 * (1 - cos(2 * .pi * Double(n) / Double(taps - 1)))
            coef[n] = Float(h * w)
        }
        var out = [Float](repeating: 0, count: samples.count)
        for i in 0..<samples.count {
            var acc: Float = 0
            let kMin = max(0, i - taps + 1)
            for j in kMin...i { acc += samples[j] * coef[i - j] }
            out[i] = acc
        }
        return out
    }

    /// GCC-PHAT cross-correlation: IFFT(X·conj(Y) / |X·conj(Y)|).
    /// Phase-only normalisation collapses the IFFT to a near-delta
    /// peak, robust to room colouration. Packed real-input radix-2
    /// vDSP. Peak idx `k` ⇒ mic = source shifted forward by `k`.
    static func gccPhat(source: [Float], mic: [Float], fftSize n: Int) -> [Float]? {
        guard n > 1, (n & (n - 1)) == 0 else { return nil }
        let log2n = vDSP_Length(Int(log2(Double(n))))
        let halfN = n / 2
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
        var pSrc = [Float](repeating: 0, count: n)
        var pMic = [Float](repeating: 0, count: n)
        for i in 0..<min(source.count, n) { pSrc[i] = source[i] }
        for i in 0..<min(mic.count, n) { pMic[i] = mic[i] }
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(setup) }
        var xSplit = DSPSplitComplex(realp: xR, imagp: xI)
        var ySplit = DSPSplitComplex(realp: yR, imagp: yI)
        pSrc.withUnsafeBufferPointer { sp in
            sp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { cp in
                vDSP_ctoz(cp, 2, &xSplit, 1, vDSP_Length(halfN))
            }
        }
        pMic.withUnsafeBufferPointer { mp in
            mp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { cp in
                vDSP_ctoz(cp, 2, &ySplit, 1, vDSP_Length(halfN))
            }
        }
        vDSP_fft_zrip(setup, &xSplit, 1, log2n, FFTDirection(FFT_FORWARD))
        vDSP_fft_zrip(setup, &ySplit, 1, log2n, FFTDirection(FFT_FORWARD))
        var m1: Float = -1
        vDSP_vsmul(yI, 1, &m1, yIneg, 1, vDSP_Length(halfN))
        var yConj = DSPSplitComplex(realp: yR, imagp: yIneg)
        var crossSplit = DSPSplitComplex(realp: crossR, imagp: crossI)
        vDSP_zvmul(&xSplit, 1, &yConj, 1, &crossSplit, 1, vDSP_Length(halfN), 1)
        vDSP_zvabs(&crossSplit, 1, mags, 1, vDSP_Length(halfN))
        var eps: Float = 1e-9
        vDSP_vsadd(mags, 1, &eps, mags, 1, vDSP_Length(halfN))
        vDSP_vdiv(mags, 1, crossR, 1, crossR, 1, vDSP_Length(halfN))
        vDSP_vdiv(mags, 1, crossI, 1, crossI, 1, vDSP_Length(halfN))
        vDSP_fft_zrip(setup, &crossSplit, 1, log2n, FFTDirection(FFT_INVERSE))
        var out = [Float](repeating: 0, count: n)
        out.withUnsafeMutableBufferPointer { op in
            op.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { cp in
                vDSP_ztoc(&crossSplit, 1, cp, 2, vDSP_Length(halfN))
            }
        }
        return out
    }
}

// MARK: - Mic capture

enum HybridMicCaptureError: Error { case permissionDenied, unavailable }

/// Continuous mic capture into a fixed-size circular Float buffer.
/// `snapshot(frames:)` reads the latest N samples; `markAnchor(at:)` +
/// `readSinceAnchor(maxFrames:)` provide the active-probe path.
final class HybridMicCapture: @unchecked Sendable {
    static let sampleRate: Double = 48_000
    private static let kPermissionDenied = OSStatus(bitPattern: UInt32(0x6E6F7065))

    private let ring: RingBuffer
    private let unit: AudioUnit
    private let context: Context

    fileprivate final class Context {
        let ring: RingBuffer
        var unit: AudioUnit?
        var anchorPos: Int64 = 0
        var anchorNs: UInt64 = 0
        private let scratch: UnsafeMutablePointer<Float>
        private let scratchCap: Int = 8192
        private let abl: UnsafeMutablePointer<AudioBufferList>
        init(ring: RingBuffer) {
            self.ring = ring
            scratch = UnsafeMutablePointer<Float>.allocate(capacity: scratchCap)
            scratch.initialize(repeating: 0, count: scratchCap)
            abl = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
            abl.pointee = AudioBufferList()
            abl.pointee.mNumberBuffers = 1
            abl.pointee.mBuffers = AudioBuffer(
                mNumberChannels: 1, mDataByteSize: 0, mData: nil
            )
        }
        deinit {
            scratch.deinitialize(count: scratchCap); scratch.deallocate()
            abl.deallocate()
        }
        func fetch(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                   timestamp: UnsafePointer<AudioTimeStamp>,
                   frames: UInt32) -> OSStatus {
            guard let u = unit else { return noErr }
            let n = Int(frames)
            guard n > 0, n <= scratchCap else { return noErr }
            abl.pointee.mBuffers.mData = UnsafeMutableRawPointer(scratch)
            abl.pointee.mBuffers.mDataByteSize = UInt32(n * MemoryLayout<Float>.size)
            let status = AudioUnitRender(u, flags, timestamp, 1, frames, abl)
            if status != noErr { return status }
            let s: UnsafePointer<Float> = UnsafePointer(scratch)
            withUnsafePointer(to: s) { p in ring.write(channels: p, frames: n) }
            return noErr
        }
    }

    private init(unit: AudioUnit, ring: RingBuffer, context: Context) {
        self.unit = unit; self.ring = ring; self.context = context
    }

    static func open(deviceID: AudioDeviceID?, windowSeconds: Double) throws -> HybridMicCapture {
        let frames = Int((windowSeconds + 1.0) * sampleRate)
        let ring = RingBuffer(channelCount: 1, capacityFrames: HybridDSP.nextPow2(frames))
        let ctx = Context(ring: ring)
        let opaque = Unmanaged.passUnretained(ctx).toOpaque()
        let resolved = try resolveInput(deviceID)
        let unit = try openInputUnit(deviceID: resolved, context: opaque)
        ctx.unit = unit
        return HybridMicCapture(unit: unit, ring: ring, context: ctx)
    }

    func close() {
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
    }

    func snapshot(frames: Int) -> [Float] {
        let target = ring.writePosition - Int64(frames)
        guard target >= 0 else { return [] }
        return readBlock(at: target, frames: frames)
    }

    func markAnchor(at hostNs: UInt64) {
        context.anchorPos = ring.writePosition
        context.anchorNs = hostNs
    }

    func readSinceAnchor(maxFrames: Int) -> [Float] {
        let avail = max(0, Int(ring.writePosition - context.anchorPos))
        let want = min(avail, maxFrames)
        guard want > 0 else { return [] }
        return readBlock(at: context.anchorPos, frames: want)
    }

    private func readBlock(at start: Int64, frames: Int) -> [Float] {
        let buf = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        buf.initialize(repeating: 0, count: frames)
        defer { buf.deinitialize(count: frames); buf.deallocate() }
        var p: UnsafeMutablePointer<Float> = buf
        _ = withUnsafePointer(to: &p) { ptr in
            ring.read(at: start, frames: frames, into: ptr)
        }
        return Array(UnsafeBufferPointer(start: buf, count: frames))
    }

    private static func resolveInput(_ id: AudioDeviceID?) throws -> AudioDeviceID {
        if let v = id, v != 0 { return v }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dev: AudioDeviceID = 0
        var sz = UInt32(MemoryLayout<AudioDeviceID>.size)
        let s = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &sz, &dev
        )
        if s != noErr || dev == 0 { throw HybridMicCaptureError.unavailable }
        return dev
    }

    private static func openInputUnit(
        deviceID: AudioDeviceID, context: UnsafeMutableRawPointer
    ) throws -> AudioUnit {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let cmp = AudioComponentFindNext(nil, &desc) else {
            throw HybridMicCaptureError.unavailable
        }
        var unitOut: AudioUnit?
        var status = AudioComponentInstanceNew(cmp, &unitOut)
        guard status == noErr, let unit = unitOut else {
            throw HybridMicCaptureError.unavailable
        }
        var ok = false
        defer {
            if !ok {
                AudioOutputUnitStop(unit); AudioUnitUninitialize(unit)
                AudioComponentInstanceDispose(unit)
            }
        }
        func setProp<T>(_ s: AudioUnitPropertyID, _ scope: AudioUnitScope,
                        _ bus: AudioUnitElement, _ v: inout T) throws {
            let r = withUnsafeMutablePointer(to: &v) { p -> OSStatus in
                AudioUnitSetProperty(unit, s, scope, bus, p, UInt32(MemoryLayout<T>.size))
            }
            if r != noErr { throw HybridMicCaptureError.unavailable }
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
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        try setProp(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &fmt)
        var cb = AURenderCallbackStruct(
            inputProc: { (refCon, flags, ts, _, frames, _) -> OSStatus in
                let ctx = Unmanaged<Context>.fromOpaque(refCon).takeUnretainedValue()
                return ctx.fetch(flags: flags, timestamp: ts, frames: frames)
            },
            inputProcRefCon: context)
        try setProp(kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &cb)
        status = AudioUnitInitialize(unit)
        if status != noErr {
            throw status == kPermissionDenied
                ? HybridMicCaptureError.permissionDenied
                : HybridMicCaptureError.unavailable
        }
        status = AudioOutputUnitStart(unit)
        if status != noErr { throw HybridMicCaptureError.unavailable }
        ok = true
        return unit
    }
}
