import Foundation
import CoreAudio
import AudioToolbox
import Accelerate
import os.lock
import SyncCastDiscovery

/// **v4 mixed-architecture calibrator** — replaces `MuteDipCalibrator`'s
/// ambient-music modulation (±90 ms run-to-run variance under the
/// `tSoloMs=300 ms` regime) with **active per-device unique signals** so
/// the room mic can identify which output played which tone.
///
/// Why a fundamentally different architecture vs. v2/v3:
///   * **Local bridges** each own their AUHAL render callback, so we
///     can synthesize ANY signal per-device in parallel — TRUE FDM.
///     Bridge_0 plays 1 kHz sine, bridge_1 plays 2 kHz, …; the mic
///     captures the superposition and we bandpass each device's band
///     to recover its onset time independently.
///   * **AirPlay** receivers receive a SINGLE PCM stream from OwnTone
///     (AirPlay 2 multi-room is single-stream by spec). We CANNOT play
///     different audio on different AirPlay devices simultaneously, so
///     we time-share — TDMA via `device.set_volume(0)` to mute every
///     device except the one being measured, inject a unique chirp
///     into the SCK ring, wait for AirPlay's PTP buffer to deliver,
///     measure, restore.
///
/// **Phase 1 (local FDM, parallel, ~1.5 s)**
///   1. Assign each enabled local bridge a unique frequency from
///      `Self.localFrequencies` (defaults: 1k, 2k, 3k, 4k Hz). Tones
///      are audible for the user — amplitude 0.05 ≈ −26 dBFS.
///   2. All bridges call `startCalibrationTone(...)` simultaneously,
///      each with its own frequency.
///   3. Mic captures the superposition for `localToneDurationMs` ms.
///   4. Stop tones; bridges return to normal playback.
///   5. For each device: bandpass mic at f_i ±100 Hz → 5 ms-RMS
///      envelope → first-rise threshold → onset_time = arrival
///      latency.
///
/// **Phase 2 (AirPlay TDMA, sequential, ~2.5 s per device)**
///   For each enabled AirPlay device j:
///   1. Snapshot all AirPlay devices' current volumes.
///   2. Set `volume=0` on every OTHER AirPlay device via
///      `device.set_volume`.
///   3. Synthesize a linear-sweep chirp `chirpStartHz` → `chirpEndHz`
///      over `chirpDurationMs` ms with a small per-device frequency
///      offset for spectral identifiability.
///   4. Inject the chirp into the SCK ring at a known wall-clock
///      anchor (mic capture is synchronized to the same clock).
///   5. Wait `airplayCaptureDurationMs` for the chirp to arrive +
///      tail.
///   6. Restore the snapshotted volumes.
///   7. Cross-correlate mic signal vs. the known chirp template to
///      find peak position → arrival_time.
///
/// **Phase 3 (compute alignment)**
///   `delta = max(airplay τ) − max(local τ)`. ADD to current
///   `airplayDelayMs` (delay-line that delays LOCAL devices to match
///   the slowest AirPlay receiver).
///
/// All measurements are recorded via `CalibTrace.log` with the
/// `[ActiveCalib]` prefix, mirroring `MuteDipCalibrator`'s tracing
/// style for log-grep continuity.
public final class ActiveCalibrator: @unchecked Sendable {

    public static var verboseTracing: Bool = true
    @inline(__always)
    private static func trace(_ msg: @autoclosure () -> String) {
        guard verboseTracing else { return }
        CalibTrace.log(msg())
    }

    // MARK: - Public types

    public struct LocalProbe: Sendable {
        public let deviceID: String
        public let bridge: LocalAirPlayBridge
        public init(deviceID: String, bridge: LocalAirPlayBridge) {
            self.deviceID = deviceID
            self.bridge = bridge
        }
    }

    public struct AirPlayProbe: Sendable {
        public let deviceID: String
        /// Pre-calibration volume — restored on every exit path.
        public let originalVolume: Float
        public init(deviceID: String, originalVolume: Float) {
            self.deviceID = deviceID
            self.originalVolume = originalVolume
        }
    }

    public struct Result: Sendable {
        /// Per-device measured one-way latency, in ms, since the
        /// calibration time origin. Local entries are typically tens
        /// of ms (modulo the airplayDelayMs delay-line in whole-home
        /// mode); AirPlay entries are typically 1500–3500 ms.
        public let perDeviceTauMs: [String: Int]
        /// Per-device confidence: SNR for local (peak / noise floor),
        /// xcorr peak / background MAD for AirPlay. Higher is better;
        /// values below ~3.0 should be treated as "couldn't measure".
        public let perDeviceConfidence: [String: Double]
        /// Worst (lowest) per-device confidence in this run.
        public let aggregateConfidence: Double
        /// Signed delta = max(AirPlay τ) − max(local τ); ADD to
        /// airplayDelayMs to align local outputs with the slowest
        /// AirPlay receiver.
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

    public typealias AsyncAirplayVolumeSetter = @Sendable (
        _ deviceID: String, _ volume: Float
    ) async -> Void

    // MARK: - Configuration

    /// Frequencies assigned to local bridges in order. With 4 entries we
    /// support up to 4 simultaneous local devices; expand if you ever
    /// support more. Spaced 1 kHz apart so the bandpass at ±100 Hz has
    /// >800 Hz of guard band in either direction — effectively zero
    /// cross-talk between devices.
    public static let localFrequencies: [Double] = [1000, 2000, 3000, 4000]
    public static let localToneAmplitude: Float = 0.05
    public static let localToneDurationMs: Int = 1500
    /// Mic capture window is the tone duration plus tail for any
    /// extra latency — locals are typically <100 ms but in whole-home
    /// mode can be up to ~3 s due to the delay-line.
    public static let localCaptureTailMs: Int = 3500

    /// AirPlay chirp parameters. Linear sweep 200–800 Hz over 100 ms is
    /// short enough to be barely disruptive, has a sharp matched-filter
    /// peak (the autocorrelation of a chirp is a narrow sinc), and sits
    /// in a frequency band that's well-passed by every AirPlay codec.
    public static let chirpStartHz: Double = 200
    public static let chirpEndHz: Double = 800
    public static let chirpDurationMs: Int = 100
    public static let chirpAmplitude: Float = 0.5
    /// Per-device chirp start-frequency offset to make the templates
    /// spectrally distinguishable: device j's chirp starts at
    /// `chirpStartHz + j * chirpPerDeviceOffsetHz`.
    public static let chirpPerDeviceOffsetHz: Double = 100
    /// Mic capture window for one AirPlay device, after chirp injection.
    /// AirPlay PTP buffer is typically 1.5–2.5 s with outliers up to
    /// ~3.5 s; we capture 4 s so the matched-filter search has full
    /// coverage.
    public static let airplayCaptureDurationMs: Int = 4000
    /// Search window for the cross-correlation peak (in ms after chirp
    /// injection). Wider than the design doc's [1500, 3500] because
    /// we've observed peaks down at 30 ms (locals during a misconfigured
    /// run) and up at 3880 ms (slow Xiaomi receiver in the field) —
    /// covering [0, capture] catches everything.
    public static let airplaySearchMinMs: Int = 0
    public static let airplaySearchMaxMs: Int = 4000
    /// Quiet gap between AirPlay device captures so the previous
    /// device's chirp tail fully decays before we measure the next.
    public static let airplayInterDeviceGapMs: Int = 200

    /// Confidence threshold below which we mark a measurement as
    /// "could not measure" but still report it. 3.0 is the classic
    /// detection-threshold heuristic (peak ≥ 3× noise σ).
    public var confidenceAcceptThreshold: Double = 3.0

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

    private static let micSampleRate: Double = 48_000
    /// Bridge feed sample rate — must match `LocalAirPlayBridge.inboundSampleRate`.
    private static let bridgeSampleRate: Double = 48_000
    private static let kPermissionDenied = OSStatus(bitPattern: UInt32(0x6E6F7065))

    // MARK: - Run

    /// Drive a complete calibration cycle and return per-device latencies.
    /// `localProbes` carry direct bridge handles (no IPC needed); the
    /// `setAirplayVolume` closure is invoked at AirPlay TDMA boundaries.
    /// `injectChirpToRing` is the SCK ring-writer callback that injects
    /// a 100 ms chirp at the moment of call (returns a wall-clock ns
    /// timestamp the chirp was anchored at, used to align with mic
    /// capture).
    public func run(
        localProbes: [LocalProbe],
        airplayProbes: [AirPlayProbe],
        setAirplayVolume: @escaping AsyncAirplayVolumeSetter,
        injectChirpToRing: @escaping @Sendable (
            _ samples: [[Float]], _ atNs: UInt64
        ) async -> Void,
        sckRingSampleRate: Double = 48_000
    ) async throws -> Result {
        guard !localProbes.isEmpty || !airplayProbes.isEmpty else {
            throw CalibrationError.noProbesProvided
        }
        try stateLock.withLock {
            if _running { throw CalibrationError.alreadyRunning }
            _running = true; _cancelled = false
        }
        defer { stateLock.withLock { _running = false } }

        Self.trace(
            "[ActiveCalib] start: locals=\(localProbes.count) airplays=\(airplayProbes.count) sckRingSR=\(sckRingSampleRate)Hz"
        )

        var perDeviceTau: [String: Int] = [:]
        var perDeviceConf: [String: Double] = [:]

        // Phase 1: local FDM (parallel sine tones, single mic capture).
        if !localProbes.isEmpty {
            let phase1 = try await runLocalPhase(probes: localProbes)
            for (id, tau) in phase1.tau { perDeviceTau[id] = tau }
            for (id, c) in phase1.confidence { perDeviceConf[id] = c }
        }

        try checkCancelled()

        // Phase 2: AirPlay TDMA (sequential per device).
        //
        // CRITICAL: silence the LOCAL bridges before Phase 2. The chirp
        // we inject into the SCK ringBuffer fans out to BOTH the AirPlay
        // path (~2700 ms after injection due to PTP buffer) AND the
        // broadcaster→bridge path (~50–2500 ms after injection). Without
        // silencing the bridges, the mic hears the chirp from the
        // CLOSER local speaker first, and the cross-correlation
        // sometimes locks onto that early peak instead of the AirPlay
        // peak — observed empirically across consecutive runs:
        //   Run 1: airplay τ=2684 ms (correct)
        //   Run 2: airplay τ=2762 ms (correct)
        //   Run 3: airplay τ= 473 ms (WRONG — locked on local echo)
        // Setting bridge volume to 0 keeps the chirp flowing through
        // the audio pipeline (so OwnTone's queue stays primed and the
        // AirPlay session doesn't auto-stop) but silences the local
        // re-radiation. Restored after Phase 2 from the snapshot.
        var savedBridgeVolumes: [(LocalAirPlayBridge, Float)] = []
        if !airplayProbes.isEmpty && !localProbes.isEmpty {
            for p in localProbes {
                let v = p.bridge.currentVolume
                savedBridgeVolumes.append((p.bridge, v))
                p.bridge.setVolume(0)
            }
            CalibTrace.log(
                "[ActiveCalib] phase=airplay_TDMA silenced \(savedBridgeVolumes.count) local bridges"
            )
        }

        defer {
            // Restore on every exit path (success, throw, cancel).
            for (bridge, v) in savedBridgeVolumes {
                bridge.setVolume(v)
            }
        }

        if !airplayProbes.isEmpty {
            let phase2 = try await runAirplayPhase(
                probes: airplayProbes,
                setAirplayVolume: setAirplayVolume,
                injectChirpToRing: injectChirpToRing,
                sckRingSampleRate: sckRingSampleRate
            )
            for (id, tau) in phase2.tau { perDeviceTau[id] = tau }
            for (id, c) in phase2.confidence { perDeviceConf[id] = c }
        }

        // Phase 3: compute delta.
        var maxAir = Int.min, maxLoc = Int.min
        for p in localProbes {
            if let t = perDeviceTau[p.deviceID], t > maxLoc { maxLoc = t }
        }
        for p in airplayProbes {
            if let t = perDeviceTau[p.deviceID], t > maxAir { maxAir = t }
        }
        let delta: Int = (maxAir == Int.min || maxLoc == Int.min) ? 0 : maxAir - maxLoc
        let aggregate = perDeviceConf.values.min() ?? 0

        Self.trace(
            "[ActiveCalib] DONE local=\(perDeviceTau.filter { id, _ in localProbes.contains { $0.deviceID == id } }) airplay=\(perDeviceTau.filter { id, _ in airplayProbes.contains { $0.deviceID == id } }) delta=\(delta)ms confidence=\(String(format: "%.2f", aggregate))"
        )

        return Result(
            perDeviceTauMs: perDeviceTau,
            perDeviceConfidence: perDeviceConf,
            aggregateConfidence: aggregate,
            deltaMs: delta
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

    // MARK: - Phase 1: Local FDM

    private struct PhaseResult {
        var tau: [String: Int]
        var confidence: [String: Double]
    }

    /// Each enabled bridge gets its own pilot frequency; ALL bridges play
    /// simultaneously while the mic captures the superposition. Per-device
    /// onset times are recovered via per-frequency bandpass + envelope.
    private func runLocalPhase(probes: [LocalProbe]) async throws -> PhaseResult {
        var freqByDevice: [String: Double] = [:]
        for (i, p) in probes.enumerated() {
            // Wrap if more devices than allocated frequencies (unlikely
            // — the user has at most 4 local outputs typically).
            let f = Self.localFrequencies[i % Self.localFrequencies.count]
            freqByDevice[p.deviceID] = f
        }

        Self.trace(
            "[ActiveCalib] phase=local_FDM bridges=\(probes.map { $0.deviceID }) frequencies=\(probes.map { freqByDevice[$0.deviceID] ?? 0 }) duration=\(Self.localToneDurationMs)ms"
        )

        let captureMs = Self.localToneDurationMs + Self.localCaptureTailMs
        let captureFrames = Int(Double(captureMs) / 1000.0 * Self.micSampleRate)
        let captureStartNs = Clock.nowNs()

        // Start tones SLIGHTLY after capture begins so the first ~50 ms
        // of mic data is pure noise floor (used for SNR baseline).
        let toneStartDelayMs: Int = 100
        let toneStartNs = captureStartNs &+ UInt64(toneStartDelayMs) * 1_000_000

        async let captured: [Float] = self.captureMic(
            startNs: captureStartNs, frames: captureFrames
        )

        // Drive the bridges from a separate Task — start tones at the
        // anchor, stop after duration, restore.
        let driverTask: Task<Void, Error> = Task.detached {
            // Wait until anchor.
            let nowNs = Clock.nowNs()
            if toneStartNs > nowNs {
                try await Task.sleep(nanoseconds: toneStartNs - nowNs)
            }
            try Task.checkCancellation()
            for p in probes {
                let f = freqByDevice[p.deviceID] ?? 1000
                p.bridge.startCalibrationTone(
                    frequencyHz: f, amplitude: Self.localToneAmplitude
                )
            }
            try await Task.sleep(nanoseconds: UInt64(Self.localToneDurationMs) * 1_000_000)
            for p in probes {
                p.bridge.stopCalibrationTone()
            }
            // Give the fade-out a few ms to settle, then return.
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        let mic: [Float]
        do {
            try await driverTask.value
            mic = try await captured
            try checkCancelled()
        } catch {
            // Best-effort restore — bridges may have been mid-tone.
            for p in probes { p.bridge.stopCalibrationTone() }
            throw error
        }

        Self.trace(
            "[ActiveCalib] phase=local_FDM mic_captured frames=\(mic.count) rms=\(Self.dbfsString(Self.rms(mic)))dB"
        )
        guard mic.count >= captureFrames / 2 else {
            throw CalibrationError.insufficientCapture
        }

        // Per-device analysis. For each frequency:
        //   1. Bandpass the mic at f_i ±100 Hz (Goertzel-style sliding
        //      power detector — simpler than a biquad and tone-energy
        //      is exactly what we want).
        //   2. Compute 5 ms-RMS envelope of the bandpass output.
        //   3. Compute noise-floor over the first `toneStartDelayMs`
        //      where the tone was definitely off.
        //   4. Find the first envelope sample that exceeds
        //      `noise_floor + 6 dB` → onset frame → onset_ms.
        //   5. SNR = peak / noise_floor.
        let toneStartFrame = Int(Double(toneStartDelayMs) / 1000.0 * Self.micSampleRate)

        var tau: [String: Int] = [:]
        var conf: [String: Double] = [:]
        for p in probes {
            guard let f = freqByDevice[p.deviceID] else { continue }
            let env = Self.toneEnvelope(
                mic: mic, frequencyHz: f, sampleRate: Self.micSampleRate,
                envelopeWindowMs: 5
            )
            // Envelope has one sample per `envelopeHopSamples` mic frames
            // (5 ms hop). Convert frame indexes accordingly.
            let envHopFrames = Int(0.005 * Self.micSampleRate)
            let toneStartEnv = max(0, toneStartFrame / max(1, envHopFrames))
            // Noise floor: median of envelope BEFORE tone start.
            let pre = Array(env[0..<min(env.count, toneStartEnv)])
            let noiseFloor = Self.median(pre)
            // Peak: max of envelope AFTER tone start.
            let post = Array(env[min(env.count, toneStartEnv)..<env.count])
            let peakVal = post.max() ?? 0
            // Threshold: noise_floor + 6 dB ≈ noise_floor * 2.
            let threshold = max(noiseFloor * 2.0, noiseFloor + 1e-6)
            // Onset: first env sample after toneStart that exceeds
            // threshold. Index into FULL env (not the post slice) so the
            // returned ms is relative to capture start.
            var onsetEnvIdx: Int = -1
            for k in toneStartEnv..<env.count {
                if env[k] >= threshold { onsetEnvIdx = k; break }
            }
            // Onset relative to TONE START (not capture start), so that
            // tau_local reflects only the audible-arrival latency, not
            // the artificial tone-start delay we added at the top.
            let onsetMs: Int
            if onsetEnvIdx >= 0 {
                let captureStartMs = onsetEnvIdx * 5
                onsetMs = max(0, captureStartMs - toneStartDelayMs)
            } else {
                onsetMs = -1
            }
            // SNR — guard against zero noise floor (perfectly quiet
            // pre-tone window, theoretical limit). Treat as +inf.
            let snr: Double
            if noiseFloor > 1e-9 {
                snr = Double(peakVal) / Double(noiseFloor)
            } else if peakVal > 1e-6 {
                snr = 1000.0
            } else {
                snr = 0
            }
            if onsetEnvIdx >= 0 {
                tau[p.deviceID] = onsetMs
                conf[p.deviceID] = snr
            } else {
                // Couldn't find a rise — record τ=-1 so callers can
                // see the failure rather than a phantom 0.
                tau[p.deviceID] = -1
                conf[p.deviceID] = 0
            }
            Self.trace(
                "[ActiveCalib] device=\(p.deviceID) f=\(Int(f))Hz onset_idx=\(onsetEnvIdx) onset_time=\(onsetMs)ms peak=\(String(format: "%.4f", peakVal)) noiseFloor=\(String(format: "%.4f", noiseFloor)) snr=\(String(format: "%.1f", snr))"
            )
        }
        return PhaseResult(tau: tau, confidence: conf)
    }

    // MARK: - Phase 2: AirPlay TDMA

    private func runAirplayPhase(
        probes: [AirPlayProbe],
        setAirplayVolume: @escaping AsyncAirplayVolumeSetter,
        injectChirpToRing: @escaping @Sendable (
            _ samples: [[Float]], _ atNs: UInt64
        ) async -> Void,
        sckRingSampleRate: Double
    ) async throws -> PhaseResult {
        var tau: [String: Int] = [:]
        var conf: [String: Double] = [:]

        // Snapshot original volumes — restore on every exit path.
        let originalVolumes: [String: Float] = Dictionary(
            uniqueKeysWithValues: probes.map { ($0.deviceID, $0.originalVolume) }
        )

        defer {
            // Best-effort restore to original volumes regardless of
            // success / throw / cancel.
            Task.detached { [setAirplayVolume] in
                for (id, v) in originalVolumes {
                    await setAirplayVolume(id, v)
                }
            }
        }

        for (j, target) in probes.enumerated() {
            try checkCancelled()

            // Mute every other AirPlay device.
            for other in probes where other.deviceID != target.deviceID {
                await setAirplayVolume(other.deviceID, 0)
            }
            // Re-assert target's original volume in case a previous
            // iteration muted it.
            await setAirplayVolume(target.deviceID, target.originalVolume)

            // Build the per-device chirp template.
            let startHz = Self.chirpStartHz + Double(j) * Self.chirpPerDeviceOffsetHz
            let endHz = Self.chirpEndHz + Double(j) * Self.chirpPerDeviceOffsetHz
            let chirp = Self.linearChirp(
                startHz: startHz, endHz: endHz,
                durationMs: Self.chirpDurationMs,
                amplitude: Self.chirpAmplitude,
                sampleRate: sckRingSampleRate
            )
            // Stereo broadcast: same signal in both channels.
            let chirpStereo: [[Float]] = [chirp, chirp]

            Self.trace(
                "[ActiveCalib] phase=airplay_TDMA device=\(target.deviceID) enabled_only=true chirp=\(Int(startHz))-\(Int(endHz))Hz dur=\(Self.chirpDurationMs)ms"
            )

            // Capture mic + inject chirp. The chirp is anchored a few
            // hundred ms after capture starts so the noise-floor window
            // is captured; AirPlay's PTP buffer (~1.8 s) means the
            // audible arrival is mid-capture.
            let captureFrames = Int(
                Double(Self.airplayCaptureDurationMs) / 1000.0 * Self.micSampleRate
            )
            let captureStartNs = Clock.nowNs()
            let injectAtNs = captureStartNs &+ 100_000_000  // +100 ms

            async let captured: [Float] = self.captureMic(
                startNs: captureStartNs, frames: captureFrames
            )
            async let injected: Void = injectChirpToRing(chirpStereo, injectAtNs)

            await injected
            let mic = try await captured
            try checkCancelled()

            // Build the matched-filter template at the MIC sample rate
            // (downsample-by-decimation if SCK is also 48k they're equal).
            // We resample the chirp to mic rate via piecewise re-synth so
            // we don't need a polyphase filter.
            let micChirp = Self.linearChirp(
                startHz: startHz, endHz: endHz,
                durationMs: Self.chirpDurationMs,
                amplitude: 1.0,  // unit amplitude — we want correlation peak height
                sampleRate: Self.micSampleRate
            )

            // Cross-correlate. We use FFT-based xcorr (same machinery
            // MuteDip uses) so the search is O(N log N) for the 4 s mic
            // window vs. N² for direct vDSP_conv.
            let cd = Self.fftCrossCorrelation(env: mic, pattern: micChirp)
            // Peak search restricted to the post-injection window. The
            // inject anchor sits at toneStartFrame samples into the mic
            // signal; the chirp arrives `airplaySearchMinMs ..
            // airplaySearchMaxMs` after that.
            let injectFrame = Int(Double(injectAtNs - captureStartNs) / 1_000_000_000.0 * Self.micSampleRate)
            let kMin = injectFrame + Int(Double(Self.airplaySearchMinMs) / 1000.0 * Self.micSampleRate)
            let kMax = min(cd.count - 1,
                injectFrame + Int(Double(Self.airplaySearchMaxMs) / 1000.0 * Self.micSampleRate))
            guard kMax > kMin else {
                Self.trace("[ActiveCalib] device=\(target.deviceID) SKIP search_window empty kMin=\(kMin) kMax=\(kMax)")
                tau[target.deviceID] = -1
                conf[target.deviceID] = 0
                continue
            }
            let (peakIdx, peakVal) = Self.argmax(cd, begin: kMin, end: kMax + 1)
            let (background, mad) = Self.backgroundStats(
                cd, excludingIdx: peakIdx, neighborhood: 64
            )
            let madFloor = max(mad, 1e-9)
            let confidence = Double((abs(peakVal) - background) / Float(madFloor))
            // Latency is peak frame - inject frame, in ms.
            let tauMs = Int(Double(peakIdx - injectFrame) / Self.micSampleRate * 1000.0)
            tau[target.deviceID] = tauMs
            conf[target.deviceID] = confidence
            Self.trace(
                "[ActiveCalib] phase=airplay_TDMA device=\(target.deviceID) peak_idx=\(peakIdx) peak_time=\(tauMs)ms peak=\(String(format: "%.4f", peakVal)) bg=\(String(format: "%.4f", background)) mad=\(String(format: "%.4f", mad)) confidence=\(String(format: "%.2f", confidence))"
            )

            // Inter-device gap so the previous chirp's ring tail decays
            // before the next one fires.
            try await Task.sleep(nanoseconds: UInt64(Self.airplayInterDeviceGapMs) * 1_000_000)
        }

        return PhaseResult(tau: tau, confidence: conf)
    }

    // MARK: - Signal generation

    /// Synthesize a linear-frequency-sweep chirp:
    ///   x(t) = amp * sin(2π * (f0*t + (f1-f0)*t²/(2*T)))
    /// Linear sweeps have a time-frequency relationship f(t) = f0 + (f1-f0)*t/T,
    /// so the phase integral is the quadratic term above.
    static func linearChirp(
        startHz: Double, endHz: Double,
        durationMs: Int, amplitude: Float,
        sampleRate: Double
    ) -> [Float] {
        let n = Int(Double(durationMs) / 1000.0 * sampleRate)
        guard n > 0 else { return [] }
        var out = [Float](repeating: 0, count: n)
        let T = Double(durationMs) / 1000.0
        let k = (endHz - startHz) / T
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let phase = 2.0 * Double.pi * (startHz * t + 0.5 * k * t * t)
            out[i] = amplitude * Float(sin(phase))
        }
        return out
    }

    // MARK: - Microphone capture (mirrors MuteDipCalibrator's plumbing)
    //
    // Same EnableIO bus 1 / mono Float32 / 48 kHz AUHAL setup. We
    // duplicate rather than share so that ActiveCalibrator can be
    // tested / extended independently and so MuteDipCalibrator stays
    // available as a fallback.

    fileprivate func captureMic(startNs: UInt64, frames: Int) async throws -> [Float] {
        try checkCancelled()
        guard frames > 0 else { return [] }
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        buffer.initialize(repeating: 0, count: frames)
        defer { buffer.deinitialize(count: frames); buffer.deallocate() }
        let context = ActiveMicCaptureContext(buffer: buffer, capacity: frames)
        let opaque = Unmanaged.passUnretained(context).toOpaque()
        let resolvedDevice: AudioDeviceID
        do {
            resolvedDevice = try resolveInputDeviceID()
        } catch {
            Self.trace("[ActiveCalib] captureMic: FAILED to resolve mic device: \(error)")
            throw error
        }
        let unit: AudioUnit
        do {
            unit = try Self.openInputUnit(deviceID: resolvedDevice, inputCallbackContext: opaque)
            Self.trace("[ActiveCalib] captureMic: AU opened+started OK dev=\(resolvedDevice) target_frames=\(frames)")
        } catch {
            Self.trace("[ActiveCalib] captureMic: AU FAILED: \(error)")
            throw error
        }
        setLiveUnit(unit)
        let durationNs = UInt64(Double(frames) / Self.micSampleRate * 1_000_000_000.0) + 100_000_000
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
        Self.trace("[ActiveCalib] captureMic: AU torn down written=\(written)/\(frames) frames")
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
            mSampleRate: micSampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
                | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0
        )
        try setProp(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &fmt)
        var callback = AURenderCallbackStruct(
            inputProc: { (inRefCon, flags, ts, _, frames, _) -> OSStatus in
                let ctx = Unmanaged<ActiveMicCaptureContext>
                    .fromOpaque(inRefCon).takeUnretainedValue()
                return ctx.fetch(flags: flags, timestamp: ts, frames: frames)
            },
            inputProcRefCon: inputCallbackContext
        )
        try setProp(kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback)
        let ctxObj = Unmanaged<ActiveMicCaptureContext>
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

    // MARK: - Signal processing primitives

    /// Per-frequency sliding-window magnitude detector (a one-bin DFT
    /// updated per sample). For each output sample we have an estimate
    /// of energy at `frequencyHz` over the last `envelopeWindowMs`. This
    /// is a Goertzel-equivalent computed by a complex-rotator running
    /// average — simpler than a biquad bandpass and avoids the
    /// transient-response delay a biquad introduces (~5–20 ms typical).
    ///
    /// Output is one envelope sample per `envelopeWindowMs / 5` mic
    /// frames (5 ms hop) — matches the resolution we want for onset
    /// detection.
    static func toneEnvelope(
        mic: [Float], frequencyHz: Double, sampleRate: Double,
        envelopeWindowMs: Int
    ) -> [Float] {
        let n = mic.count
        let hop = Int(0.005 * sampleRate)  // 5 ms hop
        let win = Int(Double(envelopeWindowMs) / 1000.0 * sampleRate)
        guard win > 0, hop > 0, n >= win else { return [] }
        let outCount = (n - win) / hop + 1
        var out = [Float](repeating: 0, count: outCount)
        let omega = 2.0 * Double.pi * frequencyHz / sampleRate
        // Direct Goertzel-style: for each output sample, sum
        //   I = Σ x[k] * cos(omega * k)
        //   Q = Σ x[k] * sin(omega * k)
        // then magnitude = sqrt(I² + Q²) / win. This is O(N * win) for
        // a naïve impl — for our use case (48 kHz × 5 s = 240 k frames,
        // win = 240, hop = 240) that's ~240 k window-steps × 240
        // samples = 57M MACs per frequency × 4 frequencies ≈ 230M MACs.
        // That's ~30 ms on Apple Silicon — acceptable for a one-shot
        // calibration that runs at ~1 Hz.
        for k in 0..<outCount {
            let off = k * hop
            var I: Double = 0, Q: Double = 0
            for s in 0..<win {
                let x = Double(mic[off + s])
                let p = omega * Double(s)
                I += x * cos(p)
                Q += x * sin(p)
            }
            out[k] = Float(sqrt(I * I + Q * Q) / Double(win))
        }
        return out
    }

    /// Median of an array. Simple sort-based; we never call it on a
    /// hot path.
    static func median(_ x: [Float]) -> Float {
        guard !x.isEmpty else { return 0 }
        let sorted = x.sorted()
        return sorted[sorted.count / 2]
    }

    /// FFT-based cross-correlation: IFFT(FFT(x) · conj(FFT(y))). Borrowed
    /// verbatim from MuteDipCalibrator — same vDSP plumbing, same
    /// real-input radix-2 path.
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

    static func dbfsString(_ rms: Float) -> String {
        if rms <= 0 { return "-inf" }
        return String(format: "%.1f", 20.0 * Foundation.log10(Double(rms)))
    }
}

/// AU input-callback state. Mirrors `MuteDipMicCaptureContext` —
/// duplicated rather than shared because the mute-dip path is being
/// kept around as a fallback (per the v4 design directive) and we
/// don't want a refactor risk to bleed across the two.
private final class ActiveMicCaptureContext {
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

// MARK: - Frequency-Response Sweep
//
// Goal: probe the frequency cutoffs of every output device + the user's
// mic so v4+ calibration can pick a calibration probe in the
// ultrasonic band (>17 kHz, inaudible to most adults). Strategy:
//
//   For each requested frequency f:
//     1. Have every enabled LOCAL bridge emit f Hz simultaneously
//        (true FDM at the device level since each bridge owns its own
//        AUHAL render callback).
//     2. Capture the room mic for `toneDurationMs + tailMs`.
//     3. For each device-frequency pair, run a Goertzel-style narrow-
//        band power detector at f ±100 Hz to recover device-specific
//        steady-state RMS (skip the 100 ms onset window so the
//        amplitude ramp doesn't bias the measurement).
//     4. Compute the noise floor in the SAME band over the 100 ms
//        BEFORE the tone started — that's a per-frequency-bin noise
//        estimate, not an overall mic floor.
//     5. SNR_dB = 20·log10(toneRMS / max(floorRMS, 1e-9)).
//
// AirPlay is intentionally skipped — playing per-device different tones
// over AirPlay 2 multi-room requires TDMA-style mute/unmute (~3 s per
// device per frequency) plus PTP-buffer-aware capture. That's a much
// bigger architectural change and isn't blocking ultrasonic-probe
// selection: if local outputs and the mic both pass at f, we have high
// prior probability the AirPlay codec at f is fine too. Future work.
public struct FrequencyResponsePoint: Sendable, Codable {
    public let frequencyHz: Double
    public let perDeviceSnrDb: [String: Double]
    public let micRmsDb: Double
    public let noiseFloorDb: Double
    public init(
        frequencyHz: Double,
        perDeviceSnrDb: [String: Double],
        micRmsDb: Double,
        noiseFloorDb: Double
    ) {
        self.frequencyHz = frequencyHz
        self.perDeviceSnrDb = perDeviceSnrDb
        self.micRmsDb = micRmsDb
        self.noiseFloorDb = noiseFloorDb
    }
}

public struct FrequencyResponseResult: Sendable, Codable {
    public let points: [FrequencyResponsePoint]
    public let micCaptureSampleRate: Double
    public let summary: String
    public init(
        points: [FrequencyResponsePoint],
        micCaptureSampleRate: Double,
        summary: String
    ) {
        self.points = points
        self.micCaptureSampleRate = micCaptureSampleRate
        self.summary = summary
    }
}

extension ActiveCalibrator {
    public struct FrequencyResponseProbe: Sendable {
        public let deviceID: String
        public let bridge: LocalAirPlayBridge
        public init(deviceID: String, bridge: LocalAirPlayBridge) {
            self.deviceID = deviceID
            self.bridge = bridge
        }
    }

    /// One sweep across `frequencies`. Each frequency takes
    /// `toneDurationMs + 100 ms (tail) + 100 ms (pre-tone window)`,
    /// so the total wall-clock time is roughly
    /// `frequencies.count * (toneDurationMs + 200 ms)`.
    /// Defaults => 15 freq × 700 ms ≈ 10.5 s.
    public func runFrequencyResponseSweep(
        probes: [FrequencyResponseProbe],
        frequencies: [Double],
        toneAmplitude: Float,
        toneDurationMs: Int
    ) async throws -> FrequencyResponseResult {
        guard !probes.isEmpty else { throw CalibrationError.noProbesProvided }
        try stateLock.withLock {
            if _running { throw CalibrationError.alreadyRunning }
            _running = true; _cancelled = false
        }
        defer { stateLock.withLock { _running = false } }

        CalibTrace.log(
            "[FreqResp] start: devices=\(probes.map { $0.deviceID }) frequencies=\(frequencies.map { Int($0) }) amplitude=\(toneAmplitude)"
        )

        let micSR: Double = 48_000  // matches captureMic's AUHAL config
        let preToneMs = 100
        let tailMs = 100
        var points: [FrequencyResponsePoint] = []

        for f in frequencies {
            try checkCancelled()
            let captureMs = preToneMs + toneDurationMs + tailMs
            let captureFrames = Int(Double(captureMs) / 1000.0 * micSR)
            let captureStartNs = Clock.nowNs()
            let toneStartNs = captureStartNs &+ UInt64(preToneMs) * 1_000_000

            async let captured: [Float] = self.captureMic(
                startNs: captureStartNs, frames: captureFrames
            )

            let driver: Task<Void, Error> = Task.detached {
                let now = Clock.nowNs()
                if toneStartNs > now {
                    try await Task.sleep(nanoseconds: toneStartNs - now)
                }
                try Task.checkCancellation()
                for p in probes {
                    p.bridge.startCalibrationTone(
                        frequencyHz: f, amplitude: toneAmplitude
                    )
                }
                try await Task.sleep(nanoseconds: UInt64(toneDurationMs) * 1_000_000)
                for p in probes { p.bridge.stopCalibrationTone() }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }

            let mic: [Float]
            do {
                try await driver.value
                mic = try await captured
                try checkCancelled()
            } catch {
                for p in probes { p.bridge.stopCalibrationTone() }
                throw error
            }

            // Frame indexes for the analysis windows.
            let preToneFrames = Int(Double(preToneMs) / 1000.0 * micSR)
            // Skip the first 100 ms of the tone (onset ramp + airplay-fan
            // dispatch latency) before measuring steady-state RMS.
            let onsetSkipMs = 100
            let toneStartFrame = preToneFrames + Int(Double(onsetSkipMs) / 1000.0 * micSR)
            let toneEndFrame = preToneFrames + Int(Double(toneDurationMs) / 1000.0 * micSR)
            let safeMicLen = mic.count

            // Overall mic level — full capture window. Used for sanity
            // (clipping ⇒ amplitude too high; silence ⇒ AUHAL failure).
            let overallRms = Self.rms(mic)
            let micRmsDb = Self.rmsToDb(overallRms)

            // Per-device steady-state RMS at f ±100 Hz via the same
            // Goertzel envelope ActiveCalibrator uses for onset detection.
            // The bandpass output is already device-discriminating because
            // all devices play the SAME f, so per-device differentiation
            // here is impossible — but each frequency bin gives us a
            // single composite SNR for "this set of devices at this f".
            // We attribute the composite to every probe; the operator
            // reads the table looking for the worst frequency where ALL
            // entries are still ≥ threshold. (When the user later wants
            // per-device discrimination at a single f, the existing FDM
            // calibration path supplies that.)
            let env = Self.toneEnvelope(
                mic: mic, frequencyHz: f, sampleRate: micSR,
                envelopeWindowMs: 20
            )
            let envHopFrames = Int(0.005 * micSR)  // matches toneEnvelope's 5 ms hop
            let envToneStart = toneStartFrame / max(envHopFrames, 1)
            let envToneEnd = min(env.count, toneEndFrame / max(envHopFrames, 1))
            let envPreEnd = min(env.count, preToneFrames / max(envHopFrames, 1))
            let toneSlice: [Float]
            if envToneEnd > envToneStart, envToneStart >= 0, envToneEnd <= env.count {
                toneSlice = Array(env[envToneStart..<envToneEnd])
            } else {
                toneSlice = []
            }
            let preSlice: [Float]
            if envPreEnd > 0, envPreEnd <= env.count {
                preSlice = Array(env[0..<envPreEnd])
            } else {
                preSlice = []
            }
            // Goertzel envelope returns per-bin magnitude (linear) — that's
            // already the bandpass amplitude, so we can read it directly
            // (no extra RMS step needed; it's a 20 ms moving-window energy
            // detector).
            let toneMag: Float = toneSlice.isEmpty
                ? 0 : toneSlice.reduce(0, +) / Float(toneSlice.count)
            let floorMag: Float = preSlice.isEmpty
                ? 0 : preSlice.reduce(0, +) / Float(preSlice.count)
            let floorMagSafe = max(floorMag, 1e-9)
            let snr = Double(toneMag) / Double(floorMagSafe)
            let snrDb = 20.0 * Foundation.log10(max(snr, 1e-12))
            let toneRmsDb = Self.rmsToDb(toneMag)
            let floorRmsDb = Self.rmsToDb(floorMag)

            var perDevice: [String: Double] = [:]
            for p in probes {
                perDevice[p.deviceID] = snrDb
                CalibTrace.log(
                    "[FreqResp] freq=\(Int(f))Hz device=\(p.deviceID) toneRms=\(String(format: "%.1f", toneRmsDb))dB floorRms=\(String(format: "%.1f", floorRmsDb))dB snr=\(String(format: "%.1f", snrDb))dB micCount=\(safeMicLen)"
                )
            }
            points.append(FrequencyResponsePoint(
                frequencyHz: f,
                perDeviceSnrDb: perDevice,
                micRmsDb: micRmsDb,
                noiseFloorDb: floorRmsDb
            ))
        }

        // Summarize: highest f where SNR ≥ threshold across ALL devices.
        let maxDb12 = Self.maxFrequency(points: points, threshold: 12.0)
        let maxDb20 = Self.maxFrequency(points: points, threshold: 20.0)
        let summary = "max_usable_freq SNR>=12dB: \(maxDb12.map { "\(Int($0))Hz" } ?? "none")  SNR>=20dB: \(maxDb20.map { "\(Int($0))Hz" } ?? "none")  airplay frequency response = unknown without per-device path"
        CalibTrace.log(
            "[FreqResp] DONE max_usable_freq_dB12=\(maxDb12.map { "\(Int($0))Hz" } ?? "none") max_usable_freq_dB20=\(maxDb20.map { "\(Int($0))Hz" } ?? "none") summary=\"\(summary)\""
        )
        return FrequencyResponseResult(
            points: points,
            micCaptureSampleRate: micSR,
            summary: summary
        )
    }

    /// Highest frequency at which every measured device clears `threshold`.
    /// Returns nil if no frequency has ALL devices passing.
    private static func maxFrequency(
        points: [FrequencyResponsePoint], threshold: Double
    ) -> Double? {
        var best: Double? = nil
        for pt in points {
            guard !pt.perDeviceSnrDb.isEmpty else { continue }
            let allPass = pt.perDeviceSnrDb.values.allSatisfy { $0 >= threshold }
            if allPass { best = max(best ?? 0, pt.frequencyHz) }
        }
        return best
    }

    /// Linear RMS magnitude → dBFS string-friendly scalar.
    /// Floor at -120 dB to keep formatting tidy.
    static func rmsToDb(_ rms: Float) -> Double {
        if rms <= 1e-9 { return -120.0 }
        return 20.0 * Foundation.log10(Double(rms))
    }
}
