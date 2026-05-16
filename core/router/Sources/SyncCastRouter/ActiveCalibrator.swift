import Foundation
import CoreAudio
import AudioToolbox
import Accelerate
import os.lock
import SyncCastDiscovery

/// Mixed-architecture acoustic calibrator. It replaces ambient-music
/// modulation with active per-device probe signals so the room mic can
/// identify when local and AirPlay outputs actually arrive.
///
/// Why a fundamentally different architecture vs. v2/v3:
///   * **Local bridges** each own their AUHAL render callback, so we
///     can synthesize a different finite waveform per device in parallel.
///     vNext uses frequency-hopping coded fingerprints and detects the
///     whole pattern via matched filtering.
///   * **AirPlay** receivers receive a SINGLE PCM stream from OwnTone.
///     AirPlay already owns receiver-to-receiver synchronization, so the
///     default path measures all enabled AirPlay receivers as one group
///     and aligns the local delay-line against that group. A legacy TDMA
///     per-receiver path remains below as a fallback/research tool.
///
/// **Phase 1 (local CODED, parallel)**
///   1. Build one frequency-hopping fingerprint per local bridge.
///   2. All bridges call `startCalibrationProbe(...)` simultaneously.
///   3. Mic captures the superposition.
///   4. For each device: cross-correlate the mic capture against that
///      device's full template and recover the correlation peak time.
///
/// **Phase 2 (AirPlay group)**
///   1. Restore all AirPlay devices to their pre-calibration volumes.
///   2. Inject one coded fingerprint into the shared AirPlay stream.
///   3. Repeat inject/capture/correlate `airplayCyclesPerDevice` times.
///   4. Aggregate by median/MAD and fail closed on unstable cycles.
///   5. Store the measured group τ only as `airplay-group`. This is a
///      group-domain measurement, not per-receiver truth.
///
/// **Phase 3 (compute alignment)**
///   `delta = max(0, max(airplay τ) − median(local τ) −
///    broadcasterOverheadMs)`. ABSOLUTE TARGET value for `airplayDelayMs`
///   (NOT a delta to add). The across-devices AirPlay aggregator is
///   `max()` because the delay-line must cover the slowest receiver —
///   otherwise faster devices race ahead. Per-cycle aggregation within
///   one device is still MEDIAN to reject single-cycle drift outliers.
///   `broadcasterOverheadMs` defaults to 0 in v8 (was a compensating
///   bug — Phase 2's probe also traverses the shared stream, so the
///   overhead cancels). User-overridable via UserDefaults.
///
/// All measurements are recorded via `CalibTrace.log` with the
/// `[ActiveCalib]` prefix, mirroring `MuteDipCalibrator`'s tracing
/// style for log-grep continuity.
public final class ActiveCalibrator: @unchecked Sendable {

    public static var verboseTracing: Bool = true
    public static let airplayGroupDeviceID = "airplay-group"
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
        /// **v5**: For AirPlay devices this is the MEDIAN of
        /// `airplayCyclesPerDevice` independent measurements.
        public let perDeviceTauMs: [String: Int]
        /// Per-device confidence: SNR for local (peak / noise floor);
        /// for AirPlay (v5) `peak-prominence × (1 - normalized MAD)` so
        /// run-to-run jitter penalizes confidence even when each
        /// individual cycle clears the noise floor.
        public let perDeviceConfidence: [String: Double]
        /// Per-device run-to-run MAD, in ms. Local and AirPlay phases both
        /// use repeated coded probes now; low MAD is required before any
        /// automatic apply path can trust the result.
        public let perDeviceUncertaintyMs: [String: Int]
        /// Worst (lowest) per-device confidence in this run.
        public let aggregateConfidence: Double
        /// ABSOLUTE TARGET delay-line value in ms (NOT a delta to add).
        /// Computed as `max(0, max(AirPlay τ) − median(local τ) −
        /// broadcasterOverheadMs)`. Across-devices aggregation uses
        /// `max()` for AirPlay so the delay-line covers the slowest
        /// device (otherwise faster receivers see audio "ahead of"
        /// slower ones). `broadcasterOverheadMs` defaults to 0 in v8 —
        /// the prior 200 ms was a compensating bug since Phase 2's
        /// chirp also traverses the SCK ring. Field name kept for ABI
        /// stability — was wrongly interpreted as an additive delta in
        /// earlier versions.
        public let deltaMs: Int
        public init(
            perDeviceTauMs: [String: Int],
            perDeviceConfidence: [String: Double],
            perDeviceUncertaintyMs: [String: Int] = [:],
            aggregateConfidence: Double, deltaMs: Int
        ) {
            self.perDeviceTauMs = perDeviceTauMs
            self.perDeviceConfidence = perDeviceConfidence
            self.perDeviceUncertaintyMs = perDeviceUncertaintyMs
            self.aggregateConfidence = aggregateConfidence
            self.deltaMs = deltaMs
        }
    }

    public enum CalibrationError: Error {
        case activeDiagnosticsDisabled(String)
        case permissionDenied
        case noInputDevice
        case audioUnitInstantiationFailed(OSStatus)
        case audioUnitConfigurationFailed(OSStatus)
        case audioUnitStartFailed(OSStatus)
        case noProbesProvided
        case alreadyRunning
        case cancelled
        case insufficientCapture
        case insufficientConfidence(String)
    }

    public typealias AsyncAirplayVolumeSetter = @Sendable (
        _ deviceID: String, _ volume: Float
    ) async -> Void

    // MARK: - Configuration

    private struct FingerprintProbeSettings: Sendable {
        let name: String
        let frequencies: [Double]
        let symbols: Int
        let fadeMs: Int
        let transitionMs: Int
        let localAmplitude: Float
        let airplayAmplitude: Float
    }

    private static let fingerprintProbeSettings: FingerprintProbeSettings = {
        let requested = ProcessInfo.processInfo
            .environment["SYNCAST_CALIBRATION_PROBE_PROFILE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if requested == "legacy" || requested == "field-20260505" {
            return FingerprintProbeSettings(
                name: "legacy-19k",
                frequencies: [19050, 19350, 19650, 19950, 20250],
                symbols: 48,
                fadeMs: 10,
                transitionMs: 3,
                localAmplitude: 0.040,
                airplayAmplitude: 0.050
            )
        }
        // Comfort profile: move the carriers farther above the adult
        // audible band and lower the level. Some speakers/mics may roll off
        // here; that is preferable to surprising the user with an audible
        // probe. The longer code gives the matched filter more processing
        // gain, and failures still fail closed before delay writes.
        return FingerprintProbeSettings(
            name: "comfort-21k",
            frequencies: [20850, 21200, 21550, 21900, 22250],
            symbols: 64,
            fadeMs: 18,
            transitionMs: 5,
            localAmplitude: 0.014,
            airplayAmplitude: 0.018
        )
    }()

    /// vNext acoustic fingerprint. Earlier Phase 1 used long steady
    /// ultrasonic sines, which are fragile near speaker/mic rolloff and
    /// can become audible through receiver DSP intermodulation. The probe is
    /// a continuous-phase frequency-hopping code: many high-band symbols,
    /// detected by matched filtering as a whole pattern. Continuous phase
    /// and zero inter-symbol gaps avoid the low-frequency on/off cadence
    /// that users heard as a repeating thump on some AirPlay speakers.
    /// This is still an explicit calibration probe, not an inaudibility
    /// guarantee.
    public static var fingerprintProbeProfileName: String {
        fingerprintProbeSettings.name
    }
    public static var fingerprintFrequencies: [Double] {
        fingerprintProbeSettings.frequencies
    }
    public static let fingerprintSymbolMs: Int = 24
    public static let fingerprintGapMs: Int = 0
    public static var fingerprintSymbols: Int { fingerprintProbeSettings.symbols }
    public static var fingerprintFadeMs: Int { fingerprintProbeSettings.fadeMs }
    public static var fingerprintTransitionMs: Int {
        fingerprintProbeSettings.transitionMs
    }
    public static var fingerprintLocalAmplitude: Float {
        fingerprintProbeSettings.localAmplitude
    }
    public static var fingerprintAirplayAmplitude: Float {
        fingerprintProbeSettings.airplayAmplitude
    }
    public static var fingerprintDurationMs: Int {
        fingerprintSymbols * (fingerprintSymbolMs + fingerprintGapMs)
    }
    /// Mic AUHAL startup can take a few hundred ms to produce trustworthy
    /// host timestamps under load or immediately after switching capture
    /// backends. Keep a real pre-roll before every acoustic probe so the
    /// probe anchor lands inside a stable captured window instead of racing
    /// the first callback.
    public static let micProbePreRollMs: Int = 600
    public static let micCaptureDeadlineSlackMs: Int = 1000
    public static let micReadyTimeoutMs: Int = 2000
    public static let micProbeScheduleLeadMs: Int = 50
    public static var localToneAmplitude: Float { fingerprintLocalAmplitude }
    public static var localToneDurationMs: Int { fingerprintDurationMs }
    /// Mic capture window is the tone duration plus tail for any
    /// extra latency — locals are typically <100 ms but in whole-home
    /// mode can be up to ~3 s due to the delay-line.
    public static let localCaptureTailMs: Int = 3500

    /// AirPlay now uses the same coded fingerprint family as local
    /// calibration. Keep these aliases for older diagnostics and docs that
    /// still refer to the old chirp path.
    public static var chirpStartHz: Double { fingerprintFrequencies.min() ?? 0 }
    public static var chirpEndHz: Double { fingerprintFrequencies.max() ?? 0 }
    public static var chirpDurationMs: Int { fingerprintDurationMs }
    public static var chirpAmplitude: Float { fingerprintAirplayAmplitude }
    /// Retained only for ABI/source compatibility with older diagnostics.
    /// vNext coded probes use `fingerprintFrequencies` and per-device
    /// code shifts, not a chirp band offset.
    public static let chirpPerDeviceOffsetHz: Double = 400
    /// Mic capture window for one AirPlay device, after chirp injection.
    /// AirPlay PTP buffer is typically 1.5–2.5 s with outliers up to
    /// ~3.5 s; capture must also include the ~1 s fingerprint tail.
    public static let airplayCaptureDurationMs: Int = 5200
    /// Search window for the cross-correlation peak (in ms after chirp
    /// injection). **v7: tightened from [0, 4000] to [1500, 3500]** —
    /// the broad [0, 4000] window was admitting two failure modes:
    /// (1) early-peak false positives from local-bridge re-radiation
    /// at ~30–500 ms (the Phase 2 silencing block sets local volume
    /// to 0 to suppress this, but the chirp still takes one render
    /// block to silence and bleeds through), and (2) tail-end peaks
    /// from prior-device room reverb leaking into the current capture.
    /// AirPlay PTP buffer is 1500–2500 ms with ~1000 ms outlier head-
    /// room; [1500, 3500] covers slow Xiaomi-class receivers (peak at
    /// ~2700 ms field-observed) without admitting the early/late false
    /// peaks. If the receiver's PTP buffer falls outside [1500, 3500],
    /// the tau is recorded as kMin/kMax-clipped — better than a
    /// wrong answer from a spurious peak.
    public static let airplaySearchMinMs: Int = 1500
    public static let airplaySearchMaxMs: Int = 3500
    /// Search padding keeps the effective accepted range at
    /// [airplaySearchMinMs, airplaySearchMaxMs] after `airplayEdgeGuardMs`
    /// is applied. Without padding, the guard would silently narrow the
    /// documented acceptance window to ~[1650, 3350] ms.
    public static let airplaySearchPaddingMs: Int = airplayEdgeGuardMs
    /// Quiet gap between AirPlay device captures so the previous device's
    /// coded probe and room tail decay before we measure the next.
    public static let airplayInterDeviceGapMs: Int = 2000
    /// **v5 multi-cycle averaging.** Each AirPlay device is measured N
    /// times; we report MEDIAN tau and MAD as uncertainty. cycles=1 had
    /// ±~95 ms run-to-run variance. v9 raises the default to 5 and
    /// fails closed unless enough cycles agree tightly.
    public static let airplayCyclesPerDevice: Int = 5
    /// Quiet gap between consecutive cycles on the SAME device — long
    /// enough to let the previous coded probe's room tail decay and for
    /// AirPlay's PTP buffer to drain before the next probe is injected.
    public static let airplayInterCycleGapMs: Int = 1500

    /// **v8 — set to 0 (was 200, a compensating bug).**
    /// The original 200 ms was meant to compensate for Phase 1's
    /// local probe bypassing the SCK→writer→sidecar→broadcaster→
    /// bridge-socket chain. However, Phase 2's probe also traverses the
    /// shared writer path, so the same
    /// broadcaster overhead exists on the AirPlay path and it cancels
    /// out of `airplay_τ − local_τ`. Subtracting an extra 200 ms from
    /// the delta consistently under-estimated the recommended delay by
    /// ~200 ms vs. the user-measured ground truth (~2300 ms).
    ///
    /// Default 0; UserDefaults key `syncast.broadcasterOverheadMs`
    /// remains available for users whose setup genuinely has an
    /// uncompensated bias.
    public static let broadcasterOverheadMs: Int = 0

    /// Resolves the broadcaster-overhead constant, allowing user
    /// override via UserDefaults key `syncast.broadcasterOverheadMs`.
    /// Returns the static default if no override is set or the value
    /// is non-positive (treated as "unset").
    public static func resolvedBroadcasterOverheadMs() -> Int {
        let v = UserDefaults.standard.integer(forKey: "syncast.broadcasterOverheadMs")
        return v > 0 ? v : broadcasterOverheadMs
    }

    /// Confidence threshold below which we mark a measurement as
    /// "could not measure" but still report it. 3.0 is the classic
    /// detection-threshold heuristic (peak ≥ 3× noise σ).
    public var confidenceAcceptThreshold: Double = 3.0
    public static let localCyclesPerDevice: Int = 3
    public static let localInterCycleGapMs: Int = 250
    public static let localMaxMadMs: Int = 15
    public static let localMaxRangeMs: Int = 50
    public static let airplayMinValidCycles: Int = 4
    /// Group mode measures AirPlay's shared clock/buffer domain, not each
    /// receiver independently. Three strong, tightly clustered detections
    /// are enough; MAD/range/slope gates still reject unstable runs.
    public static let airplayGroupMinValidCycles: Int = 3
    /// AirPlay receivers occasionally produce a weak false peak in one
    /// capture window while the surrounding captures remain tightly locked.
    /// Group mode may extend beyond the nominal 5 cycles to recover from
    /// those one-off misses without asking the user to rerun calibration.
    public static let airplayGroupMaxCycles: Int = 8
    public static let airplayGroupClusterWindowMs: Int = 60
    public static let airplayMaxMadMs: Int = 25
    public static let airplayMaxRangeMs: Int = 75
    public static let airplayMaxSlopeMsPerCycle: Double = 20
    public static let airplayEdgeGuardMs: Int = 150
    public static let localSearchMaxMs: Int = 700
    public static let localLateEdgeGuardMs: Int = 75
    public static let correlationGuardMs: Int = 120
    public static let airplayMinPeakToSecondPeakRatio: Double = 1.10
    public static let airplayGroupMinMedianPeakToSecondPeakRatio: Double = 1.03
    /// Group mode gets a second safety net from the dominant-cluster
    /// gate. Keep marginal-but-strong peaks around long enough for the
    /// cluster/MAD/range gates to accept or reject the run as a whole;
    /// otherwise a real stable cluster can fail just because individual
    /// cycles have competing reflections with second_ratio ≈ 1.0.
    public static let airplayGroupCandidatePeakToSecondPeakRatio: Double = 1.0

    private static func airplayGroupRequiredClusterCycles(cyclesRun: Int) -> Int {
        let majority = cyclesRun / 2 + 1
        return min(cyclesRun, max(Self.airplayGroupMinValidCycles, majority))
    }
    /// Local probes should lock to the direct path, not the loudest late
    /// reflection. Pick the earliest correlation peak that is both above
    /// the noise floor and a meaningful fraction of the largest peak.
    public static let localEarliestPeakFraction: Double = 0.35

    public let microphoneDeviceID: AudioDeviceID?

    /// **v8 Phase-1 mute hooks.** Called immediately before the local
    /// FDM phase and immediately after (in defer/finally). Used by the
    /// caller (Router) to transiently mute every AirPlay receiver so
    /// OwnTone's broadcast of Phase-1 probe/music does NOT
    /// echo back into the room mic — the AirPlay PTP buffer (~1.8 s)
    /// caused local measurement to lock onto
    /// the AirPlay echo instead of the direct local-speaker arrival,
    /// inflating local τ by ~1500–1800 ms and zeroing the calibration.
    /// Both default to `nil` for backward compatibility — when not
    /// wired up, behavior is identical to v7.
    public typealias AsyncSideEffect = @Sendable () async -> Void
    public let muteAirplayBeforeLocalPhase: AsyncSideEffect?
    public let restoreAirplayAfterLocalPhase: AsyncSideEffect?

    // MARK: - State

    private let stateLock = OSAllocatedUnfairLock()
    private var _running = false
    private var _cancelled = false
    private var _liveUnit: AudioUnit?

    public init(
        microphoneDeviceID: AudioDeviceID? = nil,
        muteAirplayBeforeLocalPhase: AsyncSideEffect? = nil,
        restoreAirplayAfterLocalPhase: AsyncSideEffect? = nil
    ) {
        self.microphoneDeviceID = microphoneDeviceID
        self.muteAirplayBeforeLocalPhase = muteAirplayBeforeLocalPhase
        self.restoreAirplayAfterLocalPhase = restoreAirplayAfterLocalPhase
    }

    // MARK: - Constants

    private static let micSampleRate: Double = 48_000
    /// Bridge feed sample rate — must match `LocalAirPlayBridge.inboundSampleRate`.
    private static let bridgeSampleRate: Double = 48_000
    private static let kPermissionDenied = OSStatus(bitPattern: UInt32(0x6E6F7065))

    // MARK: - Run

    /// Drive a complete calibration cycle and return per-device latencies.
    /// `localProbes` carry direct bridge handles (no IPC needed); the
    /// `setAirplayVolume` closure restores AirPlay group volumes around
    /// active probe windows.
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
        guard ActiveAcousticDiagnosticsGate.isEnabled() else {
            throw CalibrationError.activeDiagnosticsDisabled(
                ActiveAcousticDiagnosticsGate.disabledMessage
            )
        }
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
        var perDeviceUncertainty: [String: Int] = [:]

        // Phase 1: local coded probes (parallel, single mic capture).
        if !localProbes.isEmpty {
            let phase1 = try await runLocalPhase(probes: localProbes)
            for (id, tau) in phase1.tau { perDeviceTau[id] = tau }
            for (id, c) in phase1.confidence { perDeviceConf[id] = c }
            for (id, u) in phase1.uncertainty { perDeviceUncertainty[id] = u }
        }

        try checkCancelled()

        // Phase 2: AirPlay group measurement.
        //
        // CRITICAL: silence the LOCAL bridges before Phase 2. The probe
        // we inject into the SCK ringBuffer fans out to BOTH the AirPlay
        // path (~2700 ms after injection due to PTP buffer) AND the
        // broadcaster→bridge path (~50–2500 ms after injection). Without
        // silencing the bridges, the mic hears the probe from the
        // CLOSER local speaker first, and the cross-correlation
        // sometimes locks onto that early peak instead of the AirPlay
        // peak — observed empirically across consecutive runs:
        //   Run 1: airplay τ=2684 ms (correct)
        //   Run 2: airplay τ=2762 ms (correct)
        //   Run 3: airplay τ= 473 ms (WRONG — locked on local echo)
        // Setting bridge volume to 0 keeps the probe flowing through
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
                "[ActiveCalib] phase=airplay_GROUP silenced \(savedBridgeVolumes.count) local bridges"
            )
        }

        defer {
            // Restore on every exit path (success, throw, cancel).
            for (bridge, v) in savedBridgeVolumes {
                bridge.setVolume(v)
            }
        }

        if !airplayProbes.isEmpty {
            let phase2 = try await runAirplayGroupPhase(
                probes: airplayProbes,
                setAirplayVolume: setAirplayVolume,
                injectChirpToRing: injectChirpToRing,
                sckRingSampleRate: sckRingSampleRate
            )
            for (id, tau) in phase2.tau { perDeviceTau[id] = tau }
            for (id, c) in phase2.confidence { perDeviceConf[id] = c }
            for (id, u) in phase2.uncertainty { perDeviceUncertainty[id] = u }
        }

        let invalidLocal = localProbes.compactMap { probe -> String? in
            let tau = perDeviceTau[probe.deviceID] ?? -1
            let conf = perDeviceConf[probe.deviceID] ?? 0
            return (tau >= 0 && conf >= confidenceAcceptThreshold)
                ? nil : probe.deviceID
        }
        let invalidAirplay: [String]
        if airplayProbes.isEmpty {
            invalidAirplay = []
        } else {
            let tau = perDeviceTau[Self.airplayGroupDeviceID] ?? -1
            let conf = perDeviceConf[Self.airplayGroupDeviceID] ?? 0
            invalidAirplay = (tau >= 0 && conf >= confidenceAcceptThreshold)
                ? [] : [Self.airplayGroupDeviceID]
        }
        if !invalidLocal.isEmpty || !invalidAirplay.isEmpty {
            let msg = "invalid local=\(invalidLocal.map { String($0.prefix(8)) }) airplay=\(invalidAirplay.map { String($0.prefix(8)) })"
            Self.trace("[ActiveCalib] FAIL insufficient confidence: \(msg)")
            throw CalibrationError.insufficientConfidence(msg)
        }

        // Phase 3: compute delta.
        // AirPlay receivers are treated as one high-latency clock domain.
        // Phase 2 exposes one `airplay-group` tau. It is deliberately not
        // copied onto individual receiver ids because group measurement
        // cannot prove per-receiver latency or identify the slowest member.
        // Local stays MEDIAN — it's the per-output baseline used to subtract
        // Phase 1's anchor latency, and a stray local outlier shouldn't shift
        // the answer.
        let airplayValues = [perDeviceTau[Self.airplayGroupDeviceID]]
            .compactMap { $0 }
            .filter { $0 >= 0 }
        let localValues = localProbes
            .compactMap { perDeviceTau[$0.deviceID] }
            .filter { $0 >= 0 }
        let overheadMs = Self.resolvedBroadcasterOverheadMs()
        let delta: Int
        if airplayValues.isEmpty || localValues.isEmpty {
            delta = 0
        } else {
            let airSlowest = airplayValues.max() ?? 0
            let locMed = Self.medianInt(localValues)
            // Defensive clamp: never recommend a negative delay-line. 0 means
            // "delay-line not needed" — e.g. user has only local devices, or
            // the AirPlay path is somehow already faster than the local path.
            delta = max(0, airSlowest - locMed - overheadMs)
        }
        let aggregate = perDeviceConf.values.min() ?? 0

        // Trace surfaces the AirPlay group τ used for the delay-line plus
        // median (for comparison) and uncertainty.
        let airplayTaus = [perDeviceTau[Self.airplayGroupDeviceID]]
            .compactMap { $0 }
            .filter { $0 >= 0 }
        let airplayUnc = [perDeviceUncertainty[Self.airplayGroupDeviceID]]
            .compactMap { $0 }
        let maxStr = airplayTaus.isEmpty ? "n/a" : "\(airplayTaus.max() ?? 0)ms"
        let medStr = airplayTaus.isEmpty ? "n/a" : "\(Self.medianInt(airplayTaus))ms"
        let uncStr = airplayUnc.isEmpty ? "n/a" : "\(Self.medianInt(airplayUnc))ms"
        let localMedStr = localValues.isEmpty ? "n/a" : "\(Self.medianInt(localValues))ms"
        let localStr = perDeviceTau.filter { id, _ in
            localProbes.contains { $0.deviceID == id }
        }
        Self.trace(
            "[ActiveCalib] DONE local=\(localStr) local_median=\(localMedStr) airplay_max=\(maxStr) airplay_median=\(medStr) airplay_uncertainty=\(uncStr) overhead=\(overheadMs)ms delta=\(delta)ms confidence=\(String(format: "%.2f", aggregate))"
        )

        return Result(
            perDeviceTauMs: perDeviceTau,
            perDeviceConfidence: perDeviceConf,
            perDeviceUncertaintyMs: perDeviceUncertainty,
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
        /// Per-device MAD across cycles, in ms. Populated for both
        /// local and AirPlay phases when repeated measurements run.
        var uncertainty: [String: Int] = [:]
    }

    private struct MicCapture {
        let samples: [Float]
        let firstSampleHostNs: UInt64?

        func anchorFrame(for hostTimeNs: UInt64, sampleRate: Double) -> Int? {
            guard let firstSampleHostNs else { return nil }
            guard hostTimeNs >= firstSampleHostNs else { return nil }
            return Int(
                Double(hostTimeNs - firstSampleHostNs) /
                    1_000_000_000.0 * sampleRate
            )
        }

        func anchorFailureDescription(for hostTimeNs: UInt64) -> String {
            guard let firstSampleHostNs else {
                return "mic host timestamp/cadence was not trusted before probe anchor"
            }
            return "mic first sample arrived after probe anchor first_host=\(firstSampleHostNs) anchor=\(hostTimeNs)"
        }
    }

    private actor MicReadyGate {
        private var firstTrustedHostNs: UInt64?

        func markReady(_ hostNs: UInt64) {
            if firstTrustedHostNs == nil {
                firstTrustedHostNs = hostNs
            }
        }

        func hostTimeNs() -> UInt64? {
            firstTrustedHostNs
        }
    }

    private func waitForMicReady(
        _ gate: MicReadyGate,
        phase: String
    ) async throws -> UInt64 {
        let deadlineNs = Clock.nowNs()
            &+ UInt64(Self.micReadyTimeoutMs) * 1_000_000
        while true {
            try checkCancelled()
            if let hostNs = await gate.hostTimeNs() {
                Self.trace(
                    "[ActiveCalib] \(phase) mic_ready first_host=\(hostNs)"
                )
                return hostNs
            }
            if Clock.nowNs() >= deadlineNs {
                Self.trace(
                    "[ActiveCalib] \(phase) REJECT mic did not report trusted host timestamp within \(Self.micReadyTimeoutMs)ms before probe"
                )
                throw CalibrationError.insufficientCapture
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    private static func probeAnchorNs(afterMicReadyHostNs hostNs: UInt64) -> UInt64 {
        let preferred = hostNs
            &+ UInt64(micProbePreRollMs) * 1_000_000
        let minFuture = Clock.nowNs()
            &+ UInt64(micProbeScheduleLeadMs) * 1_000_000
        return max(preferred, minFuture)
    }

    private typealias AcceptedAirplayCycle = (
        index: Int,
        tau: Int,
        prominence: Double,
        secondRatio: Double
    )

    /// Each enabled bridge gets its own pilot frequency; ALL bridges play
    /// simultaneously while the mic captures the superposition. Per-device
    /// onset times are recovered via per-frequency bandpass + envelope.
    private func runLocalPhase(probes: [LocalProbe]) async throws -> PhaseResult {
        // **v8 mute-AirPlay-during-Phase-1 hook.** OwnTone broadcasts
        // anything that hits the SCK ring to every AirPlay receiver,
        // and although Phase 1's tones are written directly into each
        // local bridge's render callback (NOT through the SCK ring),
        // any music currently flowing through SCK is still re-radiated
        // by the AirPlay devices. The ~1.8 s PTP buffer means the mic
        // hears that re-radiation 1.5–2 s after capture starts —
        // overlapping the post-tone-start envelope window. Bandpass +
        // first-rise threshold can lock onto the AirPlay echo's
        // ultrasonic tail, inflating local τ by ~1500–1800 ms and
        // erasing the calibration. The hook is owned by the caller
        // (Router) and defaults to nil for backward compatibility.
        if let mute = muteAirplayBeforeLocalPhase {
            await mute()
            CalibTrace.log(
                    "[ActiveCalib] phase=local_CODED AirPlay receivers muted via caller hook"
            )
        }
        // Capture the restore closure before the do-block so we can
        // call it on every exit path. (Swift `defer` cannot `await`,
        // so we cannot use the same idiom as the bridge-volume restore.)
        let restoreAirplay = restoreAirplayAfterLocalPhase

        do {
            var cycleResults: [PhaseResult] = []
            let cycles = max(1, Self.localCyclesPerDevice)
            for cycle in 0..<cycles {
                try checkCancelled()
                let result = try await runLocalPhaseBody(probes: probes)
                cycleResults.append(result)
                if cycle < cycles - 1 {
                    try await Task.sleep(
                        nanoseconds: UInt64(Self.localInterCycleGapMs) * 1_000_000
                    )
                }
            }
            let result = aggregateLocalPhaseCycles(cycleResults, probes: probes)
            if let restore = restoreAirplay {
                await restore()
                CalibTrace.log(
                    "[ActiveCalib] phase=local_CODED AirPlay receivers restored via caller hook"
                )
            }
            return result
        } catch {
            if let restore = restoreAirplay {
                await restore()
                CalibTrace.log(
                    "[ActiveCalib] phase=local_CODED AirPlay receivers restored via caller hook (after error)"
                )
            }
            throw error
        }
    }

    private func aggregateLocalPhaseCycles(
        _ cycles: [PhaseResult], probes: [LocalProbe]
    ) -> PhaseResult {
        var tau: [String: Int] = [:]
        var conf: [String: Double] = [:]
        var unc: [String: Int] = [:]
        let requiredCycles = min(max(2, Self.localCyclesPerDevice - 1), cycles.count)

        for probe in probes {
            var taus: [Int] = []
            var confidences: [Double] = []
            for cycle in cycles {
                let t = cycle.tau[probe.deviceID] ?? -1
                let c = cycle.confidence[probe.deviceID] ?? 0
                if t >= 0 && c >= confidenceAcceptThreshold {
                    taus.append(t)
                    confidences.append(c)
                }
            }
            guard taus.count >= requiredCycles else {
                tau[probe.deviceID] = -1
                conf[probe.deviceID] = 0
                unc[probe.deviceID] = 0
                Self.trace(
                    "[ActiveCalib] phase=local_CODED device=\(probe.deviceID) REJECT valid_cycles=\(taus.count)/\(cycles.count)"
                )
                continue
            }

            let acceptedCycles: [AcceptedAirplayCycle] = zip(taus.indices, taus).map { offset, tau in
                (
                    index: offset,
                    tau: tau,
                    prominence: confidences.indices.contains(offset)
                        ? confidences[offset]
                        : 0,
                    secondRatio: Double.greatestFiniteMagnitude
                )
            }
            let clusteredCycles = Self.dominantTauCluster(
                acceptedCycles,
                windowMs: Self.localMaxRangeMs
            )
            let inlierTaus = clusteredCycles.map { $0.tau }
            guard inlierTaus.count >= requiredCycles else {
                let initialMedian = Self.medianInt(taus)
                tau[probe.deviceID] = -1
                conf[probe.deviceID] = 0
                unc[probe.deviceID] = Self.madInt(taus, median: initialMedian)
                Self.trace(
                    "[ActiveCalib] phase=local_CODED device=\(probe.deviceID) REJECT taus=\(taus) median=\(initialMedian)ms cluster=\(inlierTaus)"
                )
                continue
            }
            if clusteredCycles.count < acceptedCycles.count {
                let clusteredIndexes = Set(clusteredCycles.map { $0.index })
                let dropped = acceptedCycles
                    .filter { !clusteredIndexes.contains($0.index) }
                    .map { $0.tau }
                Self.trace(
                    "[ActiveCalib] phase=local_CODED device=\(probe.deviceID) clustered taus=\(inlierTaus) dropped=\(dropped)"
                )
            }
            let medianTau = Self.medianInt(inlierTaus)
            let madTau = Self.madInt(inlierTaus, median: medianTau)
            let rangeTau = (inlierTaus.max() ?? medianTau)
                - (inlierTaus.min() ?? medianTau)
            guard madTau <= Self.localMaxMadMs,
                  rangeTau <= Self.localMaxRangeMs
            else {
                tau[probe.deviceID] = -1
                conf[probe.deviceID] = 0
                unc[probe.deviceID] = madTau
                Self.trace(
                    "[ActiveCalib] phase=local_CODED device=\(probe.deviceID) REJECT taus=\(taus) inliers=\(inlierTaus) median=\(medianTau)ms MAD=\(madTau)ms range=\(rangeTau)ms"
                )
                continue
            }

            let medianConf = Self.medianDouble(clusteredCycles.map { $0.prominence })
            tau[probe.deviceID] = medianTau
            conf[probe.deviceID] = medianConf
            unc[probe.deviceID] = madTau
            Self.trace(
                "[ActiveCalib] phase=local_CODED device=\(probe.deviceID) cycles=\(cycles.count) median=\(medianTau)ms MAD=\(madTau)ms range=\(rangeTau)ms confidence=\(String(format: "%.2f", medianConf))"
            )
        }
        return PhaseResult(tau: tau, confidence: conf, uncertainty: unc)
    }

    /// Inner Phase-1 body — extracted so the outer `runLocalPhase` can
    /// wrap it in the AirPlay-mute / AirPlay-restore async hooks (which
    /// `defer` cannot do, since `defer` blocks cannot `await`).
    private func runLocalPhaseBody(probes: [LocalProbe]) async throws -> PhaseResult {
        var probeByDevice: [String: [Float]] = [:]
        var templateByDevice: [String: [Float]] = [:]
        for (i, p) in probes.enumerated() {
            probeByDevice[p.deviceID] = Self.acousticFingerprintProbe(
                deviceIndex: i,
                amplitude: Self.fingerprintLocalAmplitude,
                sampleRate: Self.bridgeSampleRate
            )
            templateByDevice[p.deviceID] = Self.acousticFingerprintProbe(
                deviceIndex: i,
                amplitude: 1.0,
                sampleRate: Self.micSampleRate
            )
        }

        Self.trace(
            "[ActiveCalib] phase=local_CODED profile=\(Self.fingerprintProbeProfileName) bridges=\(probes.map { $0.deviceID }) tones=\(Self.fingerprintFrequencies.map { Int($0) }) symbols=\(Self.fingerprintSymbols) duration=\(Self.fingerprintDurationMs)ms amp=\(String(format: "%.3f", Self.fingerprintLocalAmplitude))"
        )

        // **v7: silence the local bridges' MUSIC during Phase 1.**
        // Without this, the mic captures both the calibration fingerprint
        // AND any concurrently-playing music. The coded probe has
        // processing gain, but reducing program content still sharpens the
        // correlation peak and lowers false locks.
        //
        // Pairs with the LocalAirPlayBridge.render() pipeline change
        // (gain BEFORE probe overlay): setting volume=0 silences only
        // the music path; the calibration probe is overlaid AFTER the
        // gain multiply so it drives the speaker at fixed amplitude
        // regardless of the user's volume slider OR this Phase 1
        // silencing. Restored on every exit path via defer.
        var savedBridgeVolumesPhase1: [(LocalAirPlayBridge, Float)] = []
        for p in probes {
            let v = p.bridge.currentVolume
            savedBridgeVolumesPhase1.append((p.bridge, v))
            p.bridge.setVolume(0)
        }
        if !savedBridgeVolumesPhase1.isEmpty {
            CalibTrace.log(
                "[ActiveCalib] phase=local_CODED silenced \(savedBridgeVolumesPhase1.count) local bridges (music only — probe unaffected)"
            )
        }
        defer {
            // Restore on every exit path (success, throw, cancel).
            for (bridge, v) in savedBridgeVolumesPhase1 {
                bridge.setVolume(v)
            }
        }

        let captureMs = Self.micReadyTimeoutMs
            + Self.micProbePreRollMs
            + Self.fingerprintDurationMs
            + Self.localCaptureTailMs
        let captureFrames = Int(Double(captureMs) / 1000.0 * Self.micSampleRate)
        let captureStartNs = Clock.nowNs()
        let micReadyGate = MicReadyGate()

        async let captured: MicCapture = self.captureMic(
            startNs: captureStartNs,
            frames: captureFrames,
            readinessGate: micReadyGate
        )

        let toneStartNs: UInt64
        let micReadyHostNs: UInt64
        let driverTask: Task<Void, Error>
        do {
            micReadyHostNs = try await waitForMicReady(
                micReadyGate,
                phase: "phase=local_CODED"
            )
            // Start probes only after the mic has produced trusted host-time
            // callbacks. This keeps a slow AUHAL startup from emitting an
            // audible/ultrasonic probe that we later have to reject.
            toneStartNs = Self.probeAnchorNs(afterMicReadyHostNs: micReadyHostNs)
            Self.trace(
                "[ActiveCalib] phase=local_CODED probe_anchor=\(toneStartNs) mic_ready_host=\(micReadyHostNs)"
            )

            // Drive the bridges from a separate Task — start probes at the
            // anchor, stop after duration, restore.
            driverTask = Task.detached {
                // Wait until anchor.
                let nowNs = Clock.nowNs()
                if toneStartNs > nowNs {
                    try await Task.sleep(nanoseconds: toneStartNs - nowNs)
                }
                try Task.checkCancellation()
                for p in probes {
                    if let probe = probeByDevice[p.deviceID] {
                        p.bridge.startCalibrationProbe(samples: probe)
                    }
                }
                try await Task.sleep(nanoseconds: UInt64(Self.fingerprintDurationMs) * 1_000_000)
                for p in probes {
                    p.bridge.stopCalibrationTone()
                }
                // Give the fade-out a few ms to settle, then return.
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        } catch {
            for p in probes {
                p.bridge.stopCalibrationTone()
            }
            throw error
        }

        let micCapture: MicCapture
        do {
            try await driverTask.value
            micCapture = try await captured
            try checkCancelled()
        } catch {
            // Best-effort restore — bridges may have been mid-probe.
            for p in probes { p.bridge.stopCalibrationTone() }
            throw error
        }
        let mic = micCapture.samples

        Self.trace(
            "[ActiveCalib] phase=local_CODED mic_captured frames=\(mic.count) rms=\(Self.dbfsString(Self.rms(mic)))dB"
        )
        guard mic.count >= captureFrames / 2 else {
            throw CalibrationError.insufficientCapture
        }

        // Per-device analysis. Correlate the mic against each bridge's
        // full coded fingerprint. This is a spread-spectrum-style timing
        // detector: the useful evidence is integrated over ~1 second of
        // frequency hops, so we do not depend on one fragile ultrasonic bin
        // crossing an envelope threshold.
        guard let toneStartFrame = micCapture.anchorFrame(
            for: toneStartNs,
            sampleRate: Self.micSampleRate
        ) else {
            Self.trace(
                "[ActiveCalib] phase=local_CODED REJECT \(micCapture.anchorFailureDescription(for: toneStartNs))"
            )
            throw CalibrationError.insufficientCapture
        }

        var tau: [String: Int] = [:]
        var conf: [String: Double] = [:]
        for p in probes {
            guard let template = templateByDevice[p.deviceID] else { continue }
            let cd = Self.fftCrossCorrelation(env: mic, pattern: template)
            let kMin = toneStartFrame
            let kMax = min(
                cd.count - 1,
                toneStartFrame + Int(Double(Self.localSearchMaxMs) / 1000.0 * Self.micSampleRate)
            )
            guard kMax > kMin else {
                tau[p.deviceID] = -1
                conf[p.deviceID] = 0
                continue
            }
            let measurement = Self.measureCorrelationPeak(
                correlation: cd,
                searchMin: kMin,
                searchMax: kMax,
                anchorFrame: toneStartFrame,
                sampleRate: Self.micSampleRate,
                earliestStrongPeakFraction: Self.localEarliestPeakFraction,
                confidenceFloor: confidenceAcceptThreshold
            )
            let localLateEdgeMs = Int(
                Double(max(0, kMax - measurement.peakIdx)) / Self.micSampleRate * 1000.0
            )
            if measurement.tauMs >= 0,
               measurement.peakProminence >= confidenceAcceptThreshold,
               localLateEdgeMs >= Self.localLateEdgeGuardMs {
                tau[p.deviceID] = measurement.tauMs
                conf[p.deviceID] = measurement.peakProminence
            } else {
                tau[p.deviceID] = -1
                conf[p.deviceID] = 0
            }
            Self.trace(
                "[ActiveCalib] phase=local_CODED device=\(p.deviceID) peak_idx=\(measurement.peakIdx) peak_time=\(measurement.tauMs)ms peak=\(String(format: "%.4f", measurement.peakVal)) bg=\(String(format: "%.4f", measurement.background)) mad=\(String(format: "%.4f", measurement.bgMad)) prominence=\(String(format: "%.2f", measurement.peakProminence)) second_ratio=\(String(format: "%.2f", measurement.peakToSecondPeakRatio)) late_edge=\(localLateEdgeMs)ms"
            )
        }
        return PhaseResult(tau: tau, confidence: conf)
    }

    // MARK: - Phase 2: AirPlay TDMA
    //
    // **v5 algorithm** — for each device, N = `airplayCyclesPerDevice`
    // cycles of inject-capture-correlate (each cycle implemented in
    // `runAirplayOneCycle`). Aggregation:
    //   tau_med  = median(τ_0..τ_{N-1})
    //   tau_mad  = median(|τ_k − tau_med|)
    //   peak_med = median(peak_prominence_0..peak_prominence_{N-1})
    //   confidence = peak_med * max(0, 1 − tau_mad / max(tau_med, 1))
    // High confidence requires BOTH a sharp matched-filter peak AND
    // tight cross-cycle agreement.

    private func runAirplayGroupPhase(
        probes: [AirPlayProbe],
        setAirplayVolume: @escaping AsyncAirplayVolumeSetter,
        injectChirpToRing: @escaping @Sendable (
            _ samples: [[Float]], _ atNs: UInt64
        ) async -> Void,
        sckRingSampleRate: Double
    ) async throws -> PhaseResult {
        var tau: [String: Int] = [:]
        var conf: [String: Double] = [:]
        var unc: [String: Int] = [:]

        let originalVolumes: [String: Float] = Dictionary(
            uniqueKeysWithValues: probes.map { ($0.deviceID, $0.originalVolume) }
        )

        func recordGroupFailure(reason: String) {
            tau[Self.airplayGroupDeviceID] = -1
            conf[Self.airplayGroupDeviceID] = 0
            unc[Self.airplayGroupDeviceID] = 0
            Self.trace("[ActiveCalib] phase=airplay_GROUP REJECT \(reason)")
        }

        do {
            let baseCycles = max(1, Self.airplayCyclesPerDevice)
            let maxCycles = max(baseCycles, Self.airplayGroupMaxCycles)
            let probe = Self.acousticFingerprintProbe(
                deviceIndex: 0,
                amplitude: Self.fingerprintAirplayAmplitude,
                sampleRate: sckRingSampleRate
            )
            let probeStereo: [[Float]] = [probe, probe]
            let micProbe = Self.acousticFingerprintProbe(
                deviceIndex: 0,
                amplitude: 1.0,
                sampleRate: Self.micSampleRate
            )

            Self.trace(
                "[ActiveCalib] phase=airplay_GROUP profile=\(Self.fingerprintProbeProfileName) devices=\(probes.map { $0.deviceID }) tones=\(Self.fingerprintFrequencies.map { Int($0) }) symbols=\(Self.fingerprintSymbols) dur=\(Self.fingerprintDurationMs)ms amp=\(String(format: "%.3f", Self.fingerprintAirplayAmplitude)) cycles=\(baseCycles) max_cycles=\(maxCycles)"
            )

            var acceptedCycles: [AcceptedAirplayCycle] = []
            var cyclesRun = 0

            while cyclesRun < maxCycles {
                try checkCancelled()
                let cycleIndex = cyclesRun
                let cycle = try await runAirplayOneCycle(
                    deviceID: Self.airplayGroupDeviceID,
                    chirpStereo: probeStereo,
                    micChirp: micProbe,
                    injectChirpToRing: injectChirpToRing
                )
                Self.trace(
                    "[ActiveCalib] phase=airplay_GROUP cycle=\(cycleIndex + 1)/\(Self.cycleLogTotal(cycleIndex: cycleIndex, baseCycles: baseCycles, maxCycles: maxCycles)) peak_idx=\(cycle.peakIdx) peak_time=\(cycle.tauMs)ms peak=\(String(format: "%.4f", cycle.peakVal)) bg=\(String(format: "%.4f", cycle.background)) mad=\(String(format: "%.4f", cycle.bgMad)) prominence=\(String(format: "%.2f", cycle.peakProminence)) second_ratio=\(String(format: "%.2f", cycle.peakToSecondPeakRatio)) edge=\(cycle.edgeDistanceMs)ms"
                )
                let passesPhysicalGates = cycle.tauMs >= 0 &&
                    cycle.peakProminence >= confidenceAcceptThreshold &&
                    cycle.edgeDistanceMs >= Self.airplayEdgeGuardMs
                let passesStrictRatio =
                    cycle.peakToSecondPeakRatio >=
                        Self.airplayMinPeakToSecondPeakRatio
                let passesGroupCandidateRatio =
                    cycle.peakToSecondPeakRatio >=
                        Self.airplayGroupCandidatePeakToSecondPeakRatio
                if passesPhysicalGates && passesGroupCandidateRatio {
                    acceptedCycles.append((
                        index: cycleIndex,
                        tau: cycle.tauMs,
                        prominence: cycle.peakProminence,
                        secondRatio: cycle.peakToSecondPeakRatio
                    ))
                    if !passesStrictRatio {
                        Self.trace(
                            "[ActiveCalib] phase=airplay_GROUP cycle=\(cycleIndex + 1)/\(Self.cycleLogTotal(cycleIndex: cycleIndex, baseCycles: baseCycles, maxCycles: maxCycles)) MARGINAL tau=\(cycle.tauMs)ms prominence=\(String(format: "%.2f", cycle.peakProminence)) second_ratio=\(String(format: "%.2f", cycle.peakToSecondPeakRatio)) — kept for cluster gate"
                        )
                    }
                } else {
                    Self.trace(
                        "[ActiveCalib] phase=airplay_GROUP cycle=\(cycleIndex + 1)/\(Self.cycleLogTotal(cycleIndex: cycleIndex, baseCycles: baseCycles, maxCycles: maxCycles)) REJECT tau=\(cycle.tauMs)ms prominence=\(String(format: "%.2f", cycle.peakProminence)) second_ratio=\(String(format: "%.2f", cycle.peakToSecondPeakRatio)) edge=\(cycle.edgeDistanceMs)ms"
                    )
                }
                cyclesRun += 1
                if cyclesRun >= baseCycles {
                    let clusteredCycles = Self.dominantTauCluster(
                        acceptedCycles,
                        windowMs: Self.airplayGroupClusterWindowMs
                    )
                    let requiredCycles = Self.airplayGroupRequiredClusterCycles(
                        cyclesRun: cyclesRun
                    )
                    if clusteredCycles.count >= requiredCycles {
                        break
                    }
                    if cyclesRun < maxCycles {
                        Self.trace(
                            "[ActiveCalib] phase=airplay_GROUP extending cycles: valid_cluster=\(clusteredCycles.count)/\(requiredCycles) accepted=\(acceptedCycles.map { $0.tau })"
                        )
                    }
                }
                if cyclesRun < maxCycles {
                    try await Task.sleep(
                        nanoseconds: UInt64(Self.airplayInterCycleGapMs) * 1_000_000
                    )
                }
            }

            let clusteredCycles = Self.dominantTauCluster(
                acceptedCycles,
                windowMs: Self.airplayGroupClusterWindowMs
            )
            let requiredCycles = Self.airplayGroupRequiredClusterCycles(
                cyclesRun: cyclesRun
            )
            if clusteredCycles.count < requiredCycles {
                recordGroupFailure(
                    reason: "valid_cycles=\(clusteredCycles.count)/\(cyclesRun) required=\(requiredCycles) accepted=\(acceptedCycles.map { $0.tau })"
                )
            } else {
                let cycleTaus = clusteredCycles.map { $0.tau }
                let cyclePeakProms = clusteredCycles.map { $0.prominence }
                let cycleSecondRatios = clusteredCycles.map { $0.secondRatio }
                let validCycleIndexes = clusteredCycles.map { $0.index }
                if clusteredCycles.count < acceptedCycles.count {
                    let clusteredIndexes = Set(validCycleIndexes)
                    let droppedTaus = acceptedCycles
                        .filter { !clusteredIndexes.contains($0.index) }
                        .map { $0.tau }
                    Self.trace(
                        "[ActiveCalib] phase=airplay_GROUP clustered taus=\(cycleTaus) dropped=\(droppedTaus)"
                    )
                }
                let medianTau = Self.medianInt(cycleTaus)
                let madTau = Self.madInt(cycleTaus, median: medianTau)
                let medianProm = Self.medianDouble(cyclePeakProms)
                let medianSecondRatio = Self.medianDouble(cycleSecondRatios)
                let rangeTau = (cycleTaus.max() ?? medianTau)
                    - (cycleTaus.min() ?? medianTau)
                let slope: Double
                if let firstTau = cycleTaus.first,
                   let lastTau = cycleTaus.last,
                   let firstIdx = validCycleIndexes.first,
                   let lastIdx = validCycleIndexes.last,
                   lastIdx > firstIdx {
                    slope = Double(lastTau - firstTau) / Double(lastIdx - firstIdx)
                } else {
                    slope = 0
                }
                if medianSecondRatio < Self.airplayGroupMinMedianPeakToSecondPeakRatio ||
                    madTau > Self.airplayMaxMadMs ||
                    rangeTau > Self.airplayMaxRangeMs ||
                    abs(slope) > Self.airplayMaxSlopeMsPerCycle {
                    recordGroupFailure(
                        reason: "taus=\(cycleTaus) median=\(medianTau)ms MAD=\(madTau)ms range=\(rangeTau)ms slope=\(String(format: "%.1f", slope))ms/cycle median_second_ratio=\(String(format: "%.2f", medianSecondRatio))"
                    )
                } else {
                    let madPenalty = max(
                        0,
                        1.0 - Double(madTau) / max(Double(Self.airplayMaxMadMs), 1.0)
                    )
                    let confidence = medianProm * madPenalty
                    tau[Self.airplayGroupDeviceID] = medianTau
                    conf[Self.airplayGroupDeviceID] = confidence
                    unc[Self.airplayGroupDeviceID] = madTau
                    Self.trace(
                        "[ActiveCalib] phase=airplay_GROUP cycles=\(cyclesRun) cluster=\(clusteredCycles.count)/\(cyclesRun) required=\(requiredCycles) median=\(medianTau)ms MAD=\(madTau)ms range=\(rangeTau)ms slope=\(String(format: "%.1f", slope))ms/cycle peak_prominence_med=\(String(format: "%.2f", medianProm)) second_ratio_med=\(String(format: "%.2f", medianSecondRatio)) madPenalty=\(String(format: "%.2f", madPenalty)) confidence=\(String(format: "%.2f", confidence))"
                    )
                }
            }

            for (id, v) in originalVolumes {
                await setAirplayVolume(id, v)
            }
            return PhaseResult(tau: tau, confidence: conf, uncertainty: unc)
        } catch {
            for (id, v) in originalVolumes {
                await setAirplayVolume(id, v)
            }
            throw error
        }
    }

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
        var unc: [String: Int] = [:]

        // Snapshot original volumes — restore on every exit path.
        let originalVolumes: [String: Float] = Dictionary(
            uniqueKeysWithValues: probes.map { ($0.deviceID, $0.originalVolume) }
        )

        do {
        let cycles = max(1, Self.airplayCyclesPerDevice)

        for (j, target) in probes.enumerated() {
            try checkCancelled()

            // Mute every other AirPlay device for the full duration of
            // this device's cycle set (no need to re-mute between cycles
            // — they stay muted as long as we're on this target).
            for other in probes where other.deviceID != target.deviceID {
                await setAirplayVolume(other.deviceID, 0)
            }
            // Re-assert target's original volume in case a previous
            // iteration muted it.
            await setAirplayVolume(target.deviceID, target.originalVolume)

            // Build the per-device coded fingerprint templates ONCE
            // (identical across every cycle — only the wall-clock anchor
            // changes). Stereo broadcast: same signal in both channels.
            let probe = Self.acousticFingerprintProbe(
                deviceIndex: j,
                amplitude: Self.fingerprintAirplayAmplitude,
                sampleRate: sckRingSampleRate
            )
            let probeStereo: [[Float]] = [probe, probe]
            // Unit-amplitude template at mic rate for matched-filter.
            let micProbe = Self.acousticFingerprintProbe(
                deviceIndex: j,
                amplitude: 1.0,
                sampleRate: Self.micSampleRate
            )

        Self.trace(
            "[ActiveCalib] phase=airplay_CODED profile=\(Self.fingerprintProbeProfileName) device=\(target.deviceID) tones=\(Self.fingerprintFrequencies.map { Int($0) }) symbols=\(Self.fingerprintSymbols) dur=\(Self.fingerprintDurationMs)ms amp=\(String(format: "%.3f", Self.fingerprintAirplayAmplitude)) cycles=\(cycles)"
        )

            // Per-cycle measurement collectors.
            var cycleTaus: [Int] = []
            var cyclePeakProms: [Double] = []
            var validCycleIndexes: [Int] = []

            for k in 0..<cycles {
                try checkCancelled()
                let cycle = try await runAirplayOneCycle(
                    deviceID: target.deviceID,
                    chirpStereo: probeStereo,
                    micChirp: micProbe,
                    injectChirpToRing: injectChirpToRing
                )
                Self.trace(
                    "[ActiveCalib] phase=airplay_CODED device=\(target.deviceID) cycle=\(k + 1)/\(cycles) peak_idx=\(cycle.peakIdx) peak_time=\(cycle.tauMs)ms peak=\(String(format: "%.4f", cycle.peakVal)) bg=\(String(format: "%.4f", cycle.background)) mad=\(String(format: "%.4f", cycle.bgMad)) prominence=\(String(format: "%.2f", cycle.peakProminence)) second_ratio=\(String(format: "%.2f", cycle.peakToSecondPeakRatio)) edge=\(cycle.edgeDistanceMs)ms"
                )
                if cycle.tauMs >= 0,
                   cycle.peakProminence >= confidenceAcceptThreshold,
                   cycle.peakToSecondPeakRatio >= Self.airplayMinPeakToSecondPeakRatio,
                   cycle.edgeDistanceMs >= Self.airplayEdgeGuardMs {
                    cycleTaus.append(cycle.tauMs)
                    cyclePeakProms.append(cycle.peakProminence)
                    validCycleIndexes.append(k)
                } else {
                    Self.trace(
                        "[ActiveCalib] phase=airplay_CODED device=\(target.deviceID) cycle=\(k + 1)/\(cycles) REJECT tau=\(cycle.tauMs)ms prominence=\(String(format: "%.2f", cycle.peakProminence)) second_ratio=\(String(format: "%.2f", cycle.peakToSecondPeakRatio)) edge=\(cycle.edgeDistanceMs)ms"
                    )
                }
                // Inter-cycle gap: skip after the LAST cycle (we're going
                // to take the inter-DEVICE gap right after).
                if k < cycles - 1 {
                    try await Task.sleep(
                        nanoseconds: UInt64(Self.airplayInterCycleGapMs) * 1_000_000
                    )
                }
            }

            // Aggregate across cycles. If too few cycles survive the
            // physical gates, record τ=-1 / confidence=0. Fail closed:
            // a plausible-looking single peak is worse than no result.
            if cycleTaus.count < min(Self.airplayMinValidCycles, cycles) {
                tau[target.deviceID] = -1
                conf[target.deviceID] = 0
                unc[target.deviceID] = 0
                Self.trace(
                    "[ActiveCalib] device=\(target.deviceID) cycles=\(cycles) REJECT valid_cycles=\(cycleTaus.count)/\(cycles) — recording τ=-1"
                )
            } else {
                let medianTau = Self.medianInt(cycleTaus)
                let madTau = Self.madInt(cycleTaus, median: medianTau)
                let medianProm = Self.medianDouble(cyclePeakProms)
                let rangeTau = (cycleTaus.max() ?? medianTau)
                    - (cycleTaus.min() ?? medianTau)
                let slope: Double
                if let firstTau = cycleTaus.first,
                   let lastTau = cycleTaus.last,
                   let firstIdx = validCycleIndexes.first,
                   let lastIdx = validCycleIndexes.last,
                   lastIdx > firstIdx {
                    slope = Double(lastTau - firstTau) / Double(lastIdx - firstIdx)
                } else {
                    slope = 0
                }
                guard madTau <= Self.airplayMaxMadMs,
                      rangeTau <= Self.airplayMaxRangeMs,
                      abs(slope) <= Self.airplayMaxSlopeMsPerCycle
                else {
                    tau[target.deviceID] = -1
                    conf[target.deviceID] = 0
                    unc[target.deviceID] = madTau
                    Self.trace(
                        "[ActiveCalib] device=\(target.deviceID) cycles=\(cycles) REJECT taus=\(cycleTaus) median=\(medianTau)ms MAD=\(madTau)ms range=\(rangeTau)ms slope=\(String(format: "%.1f", slope))ms/cycle"
                    )
                    try checkCancelled()
                    try await Task.sleep(
                        nanoseconds: UInt64(Self.airplayInterDeviceGapMs) * 1_000_000
                    )
                    continue
                }
                let madPenalty = max(
                    0,
                    1.0 - Double(madTau) / max(Double(Self.airplayMaxMadMs), 1.0)
                )
                let confidence = medianProm * madPenalty
                tau[target.deviceID] = medianTau
                conf[target.deviceID] = confidence
                unc[target.deviceID] = madTau
                Self.trace(
                    "[ActiveCalib] device=\(target.deviceID) cycles=\(cycles) median=\(medianTau)ms MAD=\(madTau)ms range=\(rangeTau)ms slope=\(String(format: "%.1f", slope))ms/cycle peak_prominence_med=\(String(format: "%.2f", medianProm)) madPenalty=\(String(format: "%.2f", madPenalty)) confidence=\(String(format: "%.2f", confidence))"
                )
            }

            // Inter-device gap so the previous probe tail decays
            // before the next device's first cycle fires.
            try await Task.sleep(nanoseconds: UInt64(Self.airplayInterDeviceGapMs) * 1_000_000)
        }

        let result = PhaseResult(tau: tau, confidence: conf, uncertainty: unc)
        for (id, v) in originalVolumes {
            await setAirplayVolume(id, v)
        }
        return result
        } catch {
            for (id, v) in originalVolumes {
                await setAirplayVolume(id, v)
            }
            throw error
        }
    }

    // MARK: - Phase 2 helpers

    /// Per-cycle measurement output. Decoupled from the run-aggregator
    /// so the inner loop is self-contained and easy to unit-test.
    private struct AirplayCycleMeasurement {
        let peakIdx: Int
        let peakVal: Float
        let background: Float
        let bgMad: Float
        let peakProminence: Double
        let peakToSecondPeakRatio: Double
        let edgeDistanceMs: Int
        /// Latency in ms; -1 if the search window was empty (the ring
        /// shrank below kMin → invalid measurement).
        let tauMs: Int
    }

    /// One TDMA coded-probe injection + capture + matched-filter pass for a
    /// single AirPlay device. Identical to the v4 inner block; broken
    /// out as a method so the v5 multi-cycle loop can call it N times.
    private func runAirplayOneCycle(
        deviceID: String,
        chirpStereo: [[Float]],
        micChirp: [Float],
        injectChirpToRing: @escaping @Sendable (
            _ samples: [[Float]], _ atNs: UInt64
        ) async -> Void
    ) async throws -> AirplayCycleMeasurement {
        // Capture mic + inject probe. The probe waits for a trusted mic
        // host-time origin before it is anchored; AirPlay's PTP buffer
        // (~1.8 s) means the audible arrival is still mid-capture.
        let paddedSearchMaxMs =
            Self.airplaySearchMaxMs + Self.airplaySearchPaddingMs
        let requiredCaptureMs = Self.micReadyTimeoutMs
            + Self.micProbePreRollMs
            + paddedSearchMaxMs
            + Self.fingerprintDurationMs
            + 250
        let captureFrames = Int(
            Double(max(Self.airplayCaptureDurationMs, requiredCaptureMs))
                / 1000.0 * Self.micSampleRate
        )
        let captureStartNs = Clock.nowNs()
        let micReadyGate = MicReadyGate()

        async let captured: MicCapture = self.captureMic(
            startNs: captureStartNs,
            frames: captureFrames,
            readinessGate: micReadyGate
        )
        let micReadyHostNs = try await waitForMicReady(
            micReadyGate,
            phase: "device=\(deviceID)"
        )
        // Do not inject into the AirPlay ring until the mic has a trusted
        // host-time origin. The injection is still future-dated so the
        // noise-floor window remains available for matched filtering.
        let injectAtNs = Self.probeAnchorNs(afterMicReadyHostNs: micReadyHostNs)
        Self.trace(
            "[ActiveCalib] device=\(deviceID) probe_anchor=\(injectAtNs) mic_ready_host=\(micReadyHostNs)"
        )

        await injectChirpToRing(chirpStereo, injectAtNs)
        let micCapture = try await captured
        let mic = micCapture.samples
        try checkCancelled()

        // Cross-correlate. FFT-based, same machinery as MuteDip.
        let cd = Self.fftCrossCorrelation(env: mic, pattern: micChirp)
        guard let injectFrame = micCapture.anchorFrame(
            for: injectAtNs,
            sampleRate: Self.micSampleRate
        ) else {
            Self.trace(
                "[ActiveCalib] device=\(deviceID) SKIP \(micCapture.anchorFailureDescription(for: injectAtNs))"
            )
            return AirplayCycleMeasurement(
                peakIdx: -1, peakVal: 0,
                background: 0, bgMad: 0,
                peakProminence: 0, peakToSecondPeakRatio: 0,
                edgeDistanceMs: 0, tauMs: -1
            )
        }
        let paddedSearchMinMs = max(
            0,
            Self.airplaySearchMinMs - Self.airplaySearchPaddingMs
        )
        let kMin = injectFrame
            + Int(Double(paddedSearchMinMs) / 1000.0 * Self.micSampleRate)
        let kMax = min(
            cd.count - 1,
            injectFrame + Int(
                Double(paddedSearchMaxMs) / 1000.0 * Self.micSampleRate
            )
        )
        guard kMax > kMin else {
            Self.trace(
                "[ActiveCalib] device=\(deviceID) SKIP search_window empty kMin=\(kMin) kMax=\(kMax)"
            )
            return AirplayCycleMeasurement(
                peakIdx: -1, peakVal: 0,
                background: 0, bgMad: 0,
                peakProminence: 0, peakToSecondPeakRatio: 0,
                edgeDistanceMs: 0, tauMs: -1
            )
        }
        let measurement = Self.measureCorrelationPeak(
            correlation: cd,
            searchMin: kMin,
            searchMax: kMax,
            anchorFrame: injectFrame,
            sampleRate: Self.micSampleRate
        )
        return AirplayCycleMeasurement(
            peakIdx: measurement.peakIdx,
            peakVal: measurement.peakVal,
            background: measurement.background,
            bgMad: measurement.bgMad,
            peakProminence: measurement.peakProminence,
            peakToSecondPeakRatio: measurement.peakToSecondPeakRatio,
            edgeDistanceMs: measurement.edgeDistanceMs,
            tauMs: measurement.tauMs
        )
    }

    private struct CorrelationPeakMeasurement {
        let peakIdx: Int
        let peakVal: Float
        let background: Float
        let bgMad: Float
        let peakProminence: Double
        let peakToSecondPeakRatio: Double
        let edgeDistanceMs: Int
        let tauMs: Int
    }

    private static func measureCorrelationPeak(
        correlation cd: [Float],
        searchMin: Int,
        searchMax: Int,
        anchorFrame: Int,
        sampleRate: Double,
        earliestStrongPeakFraction: Double? = nil,
        confidenceFloor: Double = 3.0
    ) -> CorrelationPeakMeasurement {
        guard !cd.isEmpty else {
            return .init(
                peakIdx: -1, peakVal: 0, background: 0, bgMad: 0,
                peakProminence: 0, peakToSecondPeakRatio: 0,
                edgeDistanceMs: 0, tauMs: -1
            )
        }
        let begin = max(0, min(searchMin, cd.count - 1))
        let endInclusive = max(begin, min(searchMax, cd.count - 1))
        let (maxPeakIdx, maxPeakVal) = Self.argmax(cd, begin: begin, end: endInclusive + 1)
        let guardFrames = max(
            1,
            Int(Double(Self.correlationGuardMs) / 1000.0 * sampleRate)
        )
        let (background, mad) = Self.backgroundStats(
            cd,
            begin: begin,
            end: endInclusive + 1,
            excludingIdx: maxPeakIdx,
            neighborhood: guardFrames
        )
        let madFloor = max(mad, 1e-9)
        var peakIdx = maxPeakIdx
        var peakVal = maxPeakVal
        if let fraction = earliestStrongPeakFraction {
            let floorByPeak = abs(maxPeakVal) * Float(max(0, min(1, fraction)))
            let floorByProminence = background + Float(confidenceFloor) * madFloor
            let threshold = max(floorByPeak, floorByProminence)
            for i in begin...endInclusive where abs(cd[i]) >= threshold {
                peakIdx = i
                peakVal = cd[i]
                break
            }
        }
        var secondPeak: Float = 0
        for i in begin...endInclusive where abs(i - peakIdx) > guardFrames {
            secondPeak = max(secondPeak, abs(cd[i]))
        }
        let prominence = Double((abs(peakVal) - background) / Float(madFloor))
        let secondRatio = Double(abs(peakVal)) / Double(max(secondPeak, 1e-9))
        let tauMs = Int(
            Double(peakIdx - anchorFrame) / sampleRate * 1000.0
        )
        let edgeDistanceFrames = min(peakIdx - begin, endInclusive - peakIdx)
        let edgeDistanceMs = Int(
            Double(max(0, edgeDistanceFrames)) / sampleRate * 1000.0
        )
        return .init(
            peakIdx: peakIdx,
            peakVal: peakVal,
            background: background,
            bgMad: mad,
            peakProminence: prominence,
            peakToSecondPeakRatio: secondRatio,
            edgeDistanceMs: edgeDistanceMs,
            tauMs: tauMs
        )
    }

    // MARK: - Signal generation

    /// Build a deterministic continuous-phase frequency-hopping acoustic
    /// fingerprint.
    ///
    /// This is deliberately closer to a communications preamble than a
    /// "play one tone and wait for the envelope to rise" probe:
    ///  * each device gets a different pseudo-random FSK codebook;
    ///  * phase is carried across symbol boundaries, so the waveform does
    ///    not restart at zero 48 times per probe;
    ///  * carrier frequency is slewed over a few milliseconds between
    ///    symbols to reduce speaker/DSP intermodulation artifacts;
    ///  * the whole probe, not each symbol, gets a Hann attack/release;
    ///  * detection correlates against the complete pattern, so weak symbols
    ///    add coherently while room noise/music mostly averages out.
    static func acousticFingerprintProbe(
        deviceIndex: Int,
        amplitude: Float,
        sampleRate: Double
    ) -> [Float] {
        let symbolFrames = max(
            1,
            Int(Double(fingerprintSymbolMs) / 1000.0 * sampleRate)
        )
        let gapFrames = max(
            0,
            Int(Double(fingerprintGapMs) / 1000.0 * sampleRate)
        )
        let fadeFrames = max(
            1,
            Int(Double(fingerprintFadeMs) / 1000.0 * sampleRate)
        )
        let transitionFrames = max(
            0,
            Int(Double(fingerprintTransitionMs) / 1000.0 * sampleRate)
        )
        let strideFrames = symbolFrames + gapFrames
        let totalFrames = fingerprintSymbols * strideFrames
        guard totalFrames > 0, !fingerprintFrequencies.isEmpty else { return [] }

        let code = acousticFingerprintCode(deviceIndex: deviceIndex)
        let amp = max(0, min(1, amplitude))
        var out = [Float](repeating: 0, count: totalFrames)
        var phase = 0.0
        var previousFrequency: Double?
        for symbol in 0..<fingerprintSymbols {
            let toneIndex = code[symbol % code.count] % fingerprintFrequencies.count
            let frequency = fingerprintFrequencies[toneIndex]
            let prior = previousFrequency ?? frequency
            let offset = symbol * strideFrames
            for i in 0..<symbolFrames {
                let globalIndex = offset + i
                let edge = min(globalIndex, totalFrames - 1 - globalIndex)
                let envelope: Double
                if edge < fadeFrames {
                    envelope = 0.5 - 0.5 * cos(
                        Double.pi * Double(edge) / Double(max(1, fadeFrames))
                    )
                } else {
                    envelope = 1.0
                }
                let f: Double
                if transitionFrames > 0, i < transitionFrames {
                    let t = Double(i) / Double(max(1, transitionFrames))
                    let smooth = t * t * (3.0 - 2.0 * t)
                    f = prior + (frequency - prior) * smooth
                } else {
                    f = frequency
                }
                out[globalIndex] = amp * Float(envelope) * Float(sin(phase))
                phase += 2.0 * Double.pi * f / sampleRate
                if phase > 2.0 * Double.pi {
                    phase.formTruncatingRemainder(dividingBy: 2.0 * Double.pi)
                }
            }
            previousFrequency = frequency
        }
        return out
    }

    private static func acousticFingerprintCode(deviceIndex: Int) -> [Int] {
        let count = max(1, fingerprintFrequencies.count)
        let deviceSalt = UInt32(truncatingIfNeeded: deviceIndex)
            &* 0xA511_E9B3
        var state = UInt32(0x6D2B79F5) &+ deviceSalt
        var out: [Int] = []
        out.reserveCapacity(fingerprintSymbols)
        var previous = -1
        for symbol in 0..<fingerprintSymbols {
            state &+= 0x9E3779B9
            var z = state
            z = (z ^ (z >> 16)) &* 0x85EBCA6B
            z = (z ^ (z >> 13)) &* 0xC2B2AE35
            z = z ^ (z >> 16)
            // Seed by device index and also Latin-shift the sequence so the
            // first few local bridges avoid same-symbol frequency collisions.
            // The per-device seed prevents indexes 0 and 5 from sharing an
            // identical codebook when the default codebook has five bins.
            var idx = (Int(z % UInt32(count)) + deviceIndex * 2) % count
            if idx == previous {
                idx = (idx + 1 + symbol + deviceIndex) % count
            }
            out.append(idx)
            previous = idx
        }
        return out
    }

    /// Synthesize a linear-frequency-sweep chirp with a Hann amplitude
    /// envelope:
    ///   x(t) = amp * w_hann(t) * sin(2π * (f0*t + (f1-f0)*t²/(2*T)))
    /// where w_hann(t) = 0.5 * (1 - cos(2π * t / T)).
    /// Linear sweeps have a time-frequency relationship f(t) = f0 + (f1-f0)*t/T,
    /// so the phase integral is the quadratic term above.
    ///
    /// **v7: Hann window added.** The bare rectangular window has -13 dB
    /// peak sidelobes which limit the matched-filter dynamic range and,
    /// in reverberant rooms, produce false correlation peaks at the
    /// sidelobe-spacing offsets. Hann windowing drops the peak sidelobe
    /// to -42 dB at the cost of ~1 dB of main-lobe SNR (Hann coherent
    /// gain is 0.5 vs. 1.0 for rectangular, but the matched filter
    /// recovers most of that since it correlates against the SAME
    /// windowed template). The window is multiplicative on top of
    /// `amplitude`, so peak amplitude is `amplitude * 1.0` at the
    /// chirp midpoint and tapers to 0 at both ends — naturally fade-
    /// in / fade-out, which also reduces audible click artifacts on
    /// chirp boundaries.
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
        // Pre-compute Hann denominator. For n == 1 the window collapses
        // to a single sample; we just emit zero (the standard Hann
        // definition is undefined for N=1, and a 1-sample chirp is
        // useless anyway).
        let hannDenom = Double(max(1, n - 1))
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let phase = 2.0 * Double.pi * (startHz * t + 0.5 * k * t * t)
            // Hann window: 0.5 * (1 - cos(2π * i / (N - 1))) — zero at
            // i=0 and i=N-1, peaks at i=(N-1)/2.
            let w = 0.5 * (1.0 - cos(2.0 * Double.pi * Double(i) / hannDenom))
            out[i] = amplitude * Float(w) * Float(sin(phase))
        }
        return out
    }

    // MARK: - Microphone capture (mirrors MuteDipCalibrator's plumbing)
    //
    // Same EnableIO bus 1 / mono Float32 / 48 kHz AUHAL setup. We
    // duplicate rather than share so that ActiveCalibrator can be
    // tested / extended independently and so MuteDipCalibrator stays
    // available as a fallback.

    private func captureMic(
        startNs: UInt64,
        frames: Int,
        readinessGate: MicReadyGate? = nil
    ) async throws -> MicCapture {
        try checkCancelled()
        guard frames > 0 else {
            return MicCapture(samples: [], firstSampleHostNs: nil)
        }
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        buffer.initialize(repeating: 0, count: frames)
        defer { buffer.deinitialize(count: frames); buffer.deallocate() }
        let context = ActiveMicCaptureContext(
            buffer: buffer,
            capacity: frames,
            sampleRate: Self.micSampleRate
        )
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
        let captureDeadlineStartNs = Clock.nowNs()
        let durationNs =
            UInt64(Double(frames) / Self.micSampleRate * 1_000_000_000.0)
            + UInt64(Self.micCaptureDeadlineSlackMs) * 1_000_000
        let endNs = captureDeadlineStartNs &+ durationNs
        var readinessReported = false
        do {
            while !context.isFull {
                try checkCancelled()
                if !readinessReported,
                   let readinessGate,
                   let readyHostNs = context.readyForProbeHostNs() {
                    await readinessGate.markReady(readyHostNs)
                    readinessReported = true
                }
                if Clock.nowNs() >= endNs { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if !readinessReported,
               let readinessGate,
               let readyHostNs = context.readyForProbeHostNs() {
                await readinessGate.markReady(readyHostNs)
            }
        } catch {
            disposeLiveUnit(); throw error
        }
        disposeLiveUnit()
        let written = min(frames, context.writtenFrameCount())
        let hostTimeSanity = context.hostTimeSanity()
        Self.trace(
            "[ActiveCalib] captureMic: AU torn down written=\(written)/\(frames) frames first_host=\(hostTimeSanity.firstSampleHostNs.map(String.init) ?? "nil") callbacks=\(hostTimeSanity.callbackCount) host_mismatch=\(hostTimeSanity.mismatchCount) max_host_err=\(String(format: "%.2f", hostTimeSanity.maxDeltaErrorMs))ms flags=0x\(String(hostTimeSanity.lastFlagsRaw, radix: 16))"
        )
        let samples = [Float](unsafeUninitializedCapacity: written) { ptr, count in
            ptr.baseAddress!.update(from: buffer, count: written)
            count = written
        }
        return MicCapture(
            samples: samples,
            firstSampleHostNs: hostTimeSanity.isTrusted
                ? hostTimeSanity.firstSampleHostNs
                : nil
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

    /// **v8: standard median** — average of the two middle elements
    /// for even N, middle element for odd N. The prior `(count-1)/2`
    /// lower-median was systematically biased low: N=2 returned the
    /// minimum, N=4 returned element 1 of 4 (33rd-percentile-ish),
    /// pulling cross-device aggregations toward the fastest receiver.
    /// `cycles=3` (odd) is unaffected; cross-device counts ∈ {1, 2, 4}
    /// are common and ARE affected.
    static func medianInt(_ x: [Int]) -> Int {
        guard !x.isEmpty else { return 0 }
        let sorted = x.sorted()
        let count = sorted.count
        if count % 2 == 0 {
            return (sorted[count / 2 - 1] + sorted[count / 2]) / 2
        } else {
            return sorted[count / 2]
        }
    }
    static func medianDouble(_ x: [Double]) -> Double {
        guard !x.isEmpty else { return 0 }
        let sorted = x.sorted()
        let count = sorted.count
        if count % 2 == 0 {
            return (sorted[count / 2 - 1] + sorted[count / 2]) / 2.0
        } else {
            return sorted[count / 2]
        }
    }
    /// Median absolute deviation — robust dispersion estimator. A
    /// single outlier shifts σ arbitrarily; MAD's nested-median caps
    /// influence at half a sample.
    static func madInt(_ x: [Int], median: Int) -> Int {
        guard !x.isEmpty else { return 0 }
        return medianInt(x.map { abs($0 - median) })
    }

    private static func cycleLogTotal(
        cycleIndex: Int,
        baseCycles: Int,
        maxCycles: Int
    ) -> Int {
        cycleIndex < baseCycles ? baseCycles : maxCycles
    }

    /// Select the densest AirPlay tau cluster before applying final
    /// MAD/range/slope gates. This lets one matched-filter false peak be
    /// dropped when most cycles agree, but still fails closed when no
    /// dominant cluster exists.
    private static func dominantTauCluster(
        _ cycles: [AcceptedAirplayCycle],
        windowMs: Int
    ) -> [AcceptedAirplayCycle] {
        guard cycles.count > 1 else { return cycles }
        let sorted = cycles.sorted {
            if $0.tau == $1.tau { return $0.index < $1.index }
            return $0.tau < $1.tau
        }
        var bestStart = 0
        var bestEnd = 0
        var bestCount = 0
        var bestRange = Int.max
        var bestProminence = -Double.greatestFiniteMagnitude
        var end = 0

        for start in sorted.indices {
            if end < start { end = start }
            while end + 1 < sorted.count &&
                sorted[end + 1].tau - sorted[start].tau <= windowMs {
                end += 1
            }
            let count = end - start + 1
            let range = sorted[end].tau - sorted[start].tau
            let prominence = sorted[start...end].reduce(0.0) {
                $0 + $1.prominence
            }
            if count > bestCount ||
                (count == bestCount &&
                    (range < bestRange ||
                     (range == bestRange && prominence > bestProminence))) {
                bestStart = start
                bestEnd = end
                bestCount = count
                bestRange = range
                bestProminence = prominence
            }
        }

        return Array(sorted[bestStart...bestEnd]).sorted {
            $0.index < $1.index
        }
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
        backgroundStats(
            x,
            begin: 0,
            end: x.count,
            excludingIdx: excludingIdx,
            neighborhood: neighborhood
        )
    }

    static func backgroundStats(
        _ x: [Float],
        begin: Int,
        end: Int,
        excludingIdx: Int,
        neighborhood: Int
    ) -> (median: Float, mad: Float) {
        guard !x.isEmpty else { return (0, 0) }
        let rangeBegin = max(0, min(begin, x.count))
        let rangeEnd = max(rangeBegin, min(end, x.count))
        let lo = max(0, excludingIdx - neighborhood)
        let hi = min(x.count, excludingIdx + neighborhood + 1)
        var bg: [Float] = []
        bg.reserveCapacity(rangeEnd - rangeBegin)
        for i in rangeBegin..<rangeEnd where i < lo || i >= hi {
            bg.append(abs(x[i]))
        }
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
    struct HostTimeSanity {
        let firstSampleHostNs: UInt64?
        let callbackCount: Int
        let mismatchCount: Int
        let maxDeltaErrorMs: Double
        let lastFlagsRaw: UInt32

        var isTrusted: Bool {
            firstSampleHostNs != nil && mismatchCount == 0
        }

        var isReadyForProbe: Bool {
            isTrusted && callbackCount >= 2
        }
    }

    let buffer: UnsafeMutablePointer<Float>
    let capacity: Int
    private let sampleRate: Double
    var unit: AudioUnit?

    private let lock = OSAllocatedUnfairLock()
    private var written: Int = 0
    private var firstHostTimeNs: UInt64?
    private var callbackCount: Int = 0
    private var previousCallbackHostNs: UInt64?
    private var previousCallbackFrameCount: Int?
    private var previousSampleTime: Double?
    private var hostTimeMismatchCount: Int = 0
    private var maxHostTimeDeltaErrorMs: Double = 0
    private var lastTimestampFlagsRaw: UInt32 = 0
    private let abl: UnsafeMutablePointer<AudioBufferList>
    private let scratch: UnsafeMutablePointer<Float>
    private let scratchCapacity: Int = 8192

    init(buffer: UnsafeMutablePointer<Float>, capacity: Int, sampleRate: Double) {
        self.buffer = buffer; self.capacity = capacity
        self.sampleRate = sampleRate
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
    func hostTimeSanity() -> HostTimeSanity {
        lock.withLock {
            HostTimeSanity(
                firstSampleHostNs: firstHostTimeNs,
                callbackCount: callbackCount,
                mismatchCount: hostTimeMismatchCount,
                maxDeltaErrorMs: maxHostTimeDeltaErrorMs,
                lastFlagsRaw: lastTimestampFlagsRaw
            )
        }
    }

    func readyForProbeHostNs() -> UInt64? {
        let sanity = hostTimeSanity()
        return sanity.isReadyForProbe ? sanity.firstSampleHostNs : nil
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
        let stamp = timestamp.pointee
        let flags = stamp.mFlags
        let sampleTime: Double?
        if flags.contains(.sampleTimeValid) {
            sampleTime = stamp.mSampleTime
        } else {
            sampleTime = nil
        }
        let callbackFirstHostNs: UInt64?
        if flags.contains(.hostTimeValid) {
            callbackFirstHostNs = Clock.hostTimeToNs(stamp.mHostTime)
        } else {
            callbackFirstHostNs = nil
        }
        let start: Int = lock.withLock {
            let avail = capacity - written
            return avail > 0 ? written : -1
        }
        if start < 0 { return noErr }
        let take = min(n, capacity - start)
        buffer.advanced(by: start).update(from: scratch, count: take)
        lock.withLock {
            callbackCount += 1
            lastTimestampFlagsRaw = flags.rawValue
            if let callbackFirstHostNs {
                if let previousCallbackHostNs,
                   let previousCallbackFrameCount {
                    let observedNs = callbackFirstHostNs >= previousCallbackHostNs
                        ? callbackFirstHostNs - previousCallbackHostNs
                        : 0
                    let expectedNs = UInt64(
                        Double(previousCallbackFrameCount) /
                            sampleRate * 1_000_000_000.0
                    )
                    recordHostDeltaError(
                        abs(Double(observedNs) - Double(expectedNs)) /
                            1_000_000.0
                    )
                }
                if let sampleTime,
                   let previousSampleTime,
                   let previousCallbackHostNs {
                    let observedNs = callbackFirstHostNs >= previousCallbackHostNs
                        ? callbackFirstHostNs - previousCallbackHostNs
                        : 0
                    let sampleDelta = max(0, sampleTime - previousSampleTime)
                    let expectedNs = sampleDelta / sampleRate * 1_000_000_000.0
                    recordHostDeltaError(
                        abs(Double(observedNs) - expectedNs) / 1_000_000.0
                    )
                }
                previousCallbackHostNs = callbackFirstHostNs
            }
            if let sampleTime {
                previousSampleTime = sampleTime
            }
            previousCallbackFrameCount = n
            if firstHostTimeNs == nil, let callbackFirstHostNs {
                let copiedFrameOffset = UInt64(max(0, start))
                let copiedFrameOffsetNs = UInt64(
                    Double(copiedFrameOffset) /
                        sampleRate * 1_000_000_000.0
                )
                firstHostTimeNs = callbackFirstHostNs &- copiedFrameOffsetNs
            }
            written = start + take
        }
        return noErr
    }

    private func recordHostDeltaError(_ errorMs: Double) {
        maxHostTimeDeltaErrorMs = max(maxHostTimeDeltaErrorMs, errorMs)
        if errorMs > 5.0 {
            hostTimeMismatchCount += 1
        }
    }
}

// MARK: - Frequency-Response Sweep
//
// Goal: probe the frequency cutoffs of every output device + the user's
// mic so v4+ calibration can pick a high-band calibration probe. High
// frequency lowers audibility risk but is not a universal inaudibility
// guarantee. Strategy:
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
        guard ActiveAcousticDiagnosticsGate.isEnabled() else {
            throw CalibrationError.activeDiagnosticsDisabled(
                ActiveAcousticDiagnosticsGate.disabledMessage
            )
        }
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

            async let captured: MicCapture = self.captureMic(
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
            let micCapture: MicCapture
            do {
                try await driver.value
                micCapture = try await captured
                mic = micCapture.samples
                try checkCancelled()
            } catch {
                for p in probes { p.bridge.stopCalibrationTone() }
                throw error
            }

            // Frame indexes for the analysis windows.
            let preToneFrames = micCapture.anchorFrame(
                for: toneStartNs,
                sampleRate: micSR
            ) ?? Int(Double(preToneMs) / 1000.0 * micSR)
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
