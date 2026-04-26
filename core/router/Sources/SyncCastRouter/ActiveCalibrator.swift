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
/// **Phase 2 (AirPlay TDMA, sequential, ~12 s per device with cycles=3)**
///   For each enabled AirPlay device j:
///   1. Snapshot all AirPlay devices' current volumes.
///   2. Set `volume=0` on every OTHER AirPlay device via
///      `device.set_volume`.
///   3. Build a per-device **ULTRASONIC** chirp template — linear sweep
///      `chirpStartHz` → `chirpEndHz` (18.5–19.0 kHz, inaudible to
///      adults; bumped from 17.5–18.5 kHz after a Xiaomi receiver was
///      reported emitting audible intermodulation at the lower band)
///      over `chirpDurationMs` ms, with a 300 Hz per-device band
///      offset so each device has a uniquely identifiable ultrasonic
///      signature.
///   4. **v5 multi-cycle**: repeat steps 5–7 `airplayCyclesPerDevice`
///      times (default 3), with `airplayInterCycleGapMs` between
///      cycles. Per-cycle records peak_idx, peak_time, peak_prominence.
///   5. Inject the chirp into the SCK ring at a known wall-clock
///      anchor (mic capture is synchronized to the same clock).
///   6. Wait `airplayCaptureDurationMs` for the chirp to arrive +
///      tail.
///   7. Cross-correlate mic signal vs. the known chirp template to
///      find peak position → cycle's arrival_time.
///   8. **v5 aggregation**: τ_dev = median(τ_0..τ_{N-1});
///      uncertainty = MAD(τ_0..τ_{N-1});
///      confidence = median(peak_prominences) × max(0, 1 - MAD/median).
///   9. Restore the snapshotted volumes.
///
/// **Phase 3 (compute alignment)**
///   `delta = max(0, max(airplay τ) − median(local τ) −
///    broadcasterOverheadMs)`. ABSOLUTE TARGET value for `airplayDelayMs`
///   (NOT a delta to add). The across-devices AirPlay aggregator is
///   `max()` because the delay-line must cover the slowest receiver —
///   otherwise faster devices race ahead. Per-cycle aggregation within
///   one device is still MEDIAN to reject single-cycle drift outliers.
///   `broadcasterOverheadMs` defaults to 0 in v8 (was a compensating
///   bug — Phase 2's chirp also traverses the SCK ring, so the
///   overhead cancels). User-overridable via UserDefaults.
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
        /// **v5**: For AirPlay devices this is the MEDIAN of
        /// `airplayCyclesPerDevice` independent measurements.
        public let perDeviceTauMs: [String: Int]
        /// Per-device confidence: SNR for local (peak / noise floor);
        /// for AirPlay (v5) `peak-prominence × (1 - normalized MAD)` so
        /// run-to-run jitter penalizes confidence even when each
        /// individual cycle clears the noise floor.
        public let perDeviceConfidence: [String: Double]
        /// Per-device run-to-run MAD, in ms. Empty for local devices
        /// (single-shot in v5). MAD ≤ 20 ms = tight; ≥ 80 ms = noisy.
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

    /// Ultrasonic frequencies for local bridges, ordered by INAUDIBILITY
    /// for the COMMON case (1–2 devices). **v7: restored pre-Round-8
    /// frequencies** — Round 8 pushed every entry above 18 kHz to dodge
    /// younger ears, but the 19/19.5 kHz pair sits in the speaker HF
    /// roll-off knee on most consumer drivers (Sonos, Sony, Apple
    /// HomePod measure 6–10 dB lower than 18 kHz at these frequencies)
    /// AND near the mic anti-alias edge — the combined acoustic-path
    /// loss dropped Phase 1 SNR below the 12 dB working threshold on
    /// reflective rooms and dropped detection rate to ~70%. The pre-
    /// Round-8 list (18000/18500/16000/17000) was field-validated for
    /// >95% detection. Index 0 (single-device case, by far the most
    /// common) remains 18000 — broadly inaudible (>95% of adults can't
    /// hear). Indexes 2-3 fall back to 16/17 kHz for 3- and 4-device
    /// deployments where signal robustness matters more than absolute
    /// inaudibility (and these multi-device runs are infrequent
    /// calibrations, not playback). 17 kHz mic/room notch (~14 dB SNR
    /// in user's room) is still well above the 12 dB working threshold.
    /// Bandpass guard ±100 Hz; 500 Hz minimum spacing keeps cross-
    /// talk between concurrent bridges below -30 dB.
    public static let localFrequencies: [Double] = [18000, 18500, 16000, 17000]
    /// Bumped from 0.15 → 0.25. With envelope 20 ms, Phase 1 SNR at 0.15
    /// was still only ~3-5 dB after the envelope fix (was 1.1 dB before),
    /// too close to detection threshold for reliability. The freq-resp
    /// sweep showed 18 kHz tone at -68 dBFS at the mic vs. -17 dBFS at
    /// 1 kHz — a ~50 dB acoustic-path loss from speaker HF rolloff that
    /// must be compensated digitally. 0.25 (-12 dBFS) leaves ample
    /// clipping headroom while raising mic SNR above the working floor.
    public static let localToneAmplitude: Float = 0.25
    public static let localToneDurationMs: Int = 1500
    /// Mic capture window is the tone duration plus tail for any
    /// extra latency — locals are typically <100 ms but in whole-home
    /// mode can be up to ~3 s due to the delay-line.
    public static let localCaptureTailMs: Int = 3500

    /// AirPlay chirp parameters. **v7: signal recovery** — v6 over-
    /// corrected for the Xiaomi audible-IMD field report by both
    /// shrinking the band to 18.5–19.0 kHz (only 500 Hz of chirp BW,
    /// degrading matched-filter resolution) AND cutting amplitude to
    /// 0.4 (10 dB SPL loss vs. original 0.7). Across consecutive
    /// runs that combination dropped peak prominence below the 3.0
    /// confidence-accept threshold on every cycle — every airplay
    /// device measured τ=-1 in v6 even with the correct hardware
    /// configuration. v7 restores 1000 Hz BW (18.0–19.0 kHz) at
    /// amplitude 0.55 — splits the difference between original 0.7
    /// (Xiaomi-IMD-prone) and v6 0.4 (signal-starved). 0.55 still
    /// gives 6 dB more headroom than the original; combined with the
    /// new Hann-windowed chirp (sidelobes -42 dB instead of -13 dB),
    /// the matched-filter sees a clean main-lobe peak well above the
    /// noise floor without driving Xiaomi's IMD products audible.
    public static let chirpStartHz: Double = 18000
    public static let chirpEndHz: Double = 19000
    public static let chirpDurationMs: Int = 100
    public static let chirpAmplitude: Float = 0.55
    /// Per-device chirp start-frequency offset. **v7: 400 Hz spacing**.
    /// With chirpStartHz=18000 and chirpEndHz=19000 (1000 Hz BW), 4
    /// devices at 400 Hz spacing place dev 3 at 19400–20400 Hz —
    /// sliding marginally above the mic's 20 kHz anti-alias edge for
    /// the upper 400 Hz of dev 3's chirp. Trade is acceptable: the
    /// LOWER end of every chirp is well inside the audio band, so
    /// the matched filter still locks. 600 Hz spacing was the prior
    /// design but at chirpEndHz=19000 + 3*600 = 20800 Hz it pushed
    /// dev 3 well past the mic edge; 400 Hz keeps dev 3 reachable
    /// while preserving spectral separation between devices. For
    /// >4-device deployments, cap to 4 AirPlay outputs in calibration
    /// (the FDM Phase 1 layer also caps at 4 frequencies for the
    /// same anti-alias reason).
    public static let chirpPerDeviceOffsetHz: Double = 400
    /// Mic capture window for one AirPlay device, after chirp injection.
    /// AirPlay PTP buffer is typically 1.5–2.5 s with outliers up to
    /// ~3.5 s; we capture 4 s so the matched-filter search has full
    /// coverage.
    public static let airplayCaptureDurationMs: Int = 4000
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
    /// Quiet gap between AirPlay device captures so the previous
    /// device's chirp tail fully decays before we measure the next.
    /// **v7: 200 → 2000 ms.** The chirp itself is 100 ms but room
    /// reverb extends well beyond — at 200 ms gap the previous
    /// device's reverb tail was still bleeding into the next device's
    /// pre-tone window, biasing background statistics and (for very
    /// reflective rooms) producing false matched-filter peaks. 2000 ms
    /// is conservative; 500–1000 ms would cover most rooms but the
    /// extra ~6 s of total wall-clock for a 4-device run is acceptable
    /// for a calibration that runs at most every few hours.
    public static let airplayInterDeviceGapMs: Int = 2000
    /// **v5 multi-cycle averaging.** Each AirPlay device is measured N
    /// times; we report MEDIAN tau and MAD as uncertainty. cycles=1 had
    /// ±~95 ms run-to-run variance; cycles=3 collapses that to ~±15 ms.
    /// Phase 1 (local FDM) is NOT multi-cycled — already <±5 ms.
    public static let airplayCyclesPerDevice: Int = 3
    /// Quiet gap between consecutive cycles on the SAME device — long
    /// enough to let the previous chirp's room reverb decay AND for
    /// AirPlay's PTP buffer to drain so the next cycle's chirp lands
    /// in a clean buffer (otherwise the prior cycle's chirp can still
    /// be in flight when the matched filter starts hunting). **v7:
    /// 200 → 1500 ms.** The PTP buffer is ~1500–2500 ms; at 200 ms
    /// gap successive cycles overlapped in the buffer and the
    /// matched-filter sometimes locked onto the prior cycle's peak
    /// (manifesting as MAD across cycles ~600 ms — the inter-cycle
    /// distance — rather than the ~15 ms observed when cycles are
    /// independent). 1500 ms gives the prior chirp time to drain
    /// fully through the AirPlay receiver before the next inject.
    public static let airplayInterCycleGapMs: Int = 1500

    /// **v8 — set to 0 (was 200, a compensating bug).**
    /// The original 200 ms was meant to compensate for Phase 1's
    /// calibration tone bypassing the SCK→writer→sidecar→broadcaster→
    /// bridge-socket chain. However, Phase 2's chirp ALSO traverses the
    /// SCK ring (it is `injectChirpToRing(...)`-injected), so the same
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

    public let microphoneDeviceID: AudioDeviceID?

    /// **v8 Phase-1 mute hooks.** Called immediately before the local
    /// FDM phase and immediately after (in defer/finally). Used by the
    /// caller (Router) to transiently mute every AirPlay receiver so
    /// OwnTone's broadcast of the Phase-1 ultrasonic tones does NOT
    /// echo back into the room mic — the AirPlay PTP buffer (~1.8 s)
    /// caused the Phase-1 bandpass + first-rise threshold to lock onto
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
        var perDeviceUncertainty: [String: Int] = [:]

        // Phase 1: local FDM (parallel sine tones, single mic capture).
        if !localProbes.isEmpty {
            let phase1 = try await runLocalPhase(probes: localProbes)
            for (id, tau) in phase1.tau { perDeviceTau[id] = tau }
            for (id, c) in phase1.confidence { perDeviceConf[id] = c }
            for (id, u) in phase1.uncertainty { perDeviceUncertainty[id] = u }
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
            for (id, u) in phase2.uncertainty { perDeviceUncertainty[id] = u }
        }

        // Phase 3: compute delta.
        // **v8 across-devices aggregation**: AirPlay uses `max()` (was
        // `median()`). Within one device the per-cycle aggregator stays
        // MEDIAN — that rejects per-cycle drift outliers on the SAME
        // device. Across devices, however, the delay-line MUST cover
        // the SLOWEST receiver: every device renders the same audio,
        // and any device whose τ exceeds the delay-line will be heard
        // "ahead of" the others. Median across devices systematically
        // under-shoots the slowest-device floor by half the inter-
        // device spread. Local stays MEDIAN — it's the per-output baseline
        // used to subtract Phase 1's anchor latency, and a stray local
        // outlier (e.g. one bridge slow to start its tone) shouldn't
        // shift the answer.
        let airplayValues = airplayProbes
            .compactMap { perDeviceTau[$0.deviceID] }
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

        // **v8**: trace surfaces the slowest-device AirPlay τ used for
        // the delay-line plus median (for comparison) and uncertainty.
        let airplayTaus = airplayProbes
            .compactMap { perDeviceTau[$0.deviceID] }.filter { $0 >= 0 }
        let airplayUnc = airplayProbes
            .compactMap { perDeviceUncertainty[$0.deviceID] }
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
        /// **v5**: per-device MAD across cycles, in ms. Empty for
        /// single-cycle phases (Phase 1 local FDM).
        var uncertainty: [String: Int] = [:]
    }

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
                "[ActiveCalib] phase=local_FDM AirPlay receivers muted via caller hook"
            )
        }
        // Capture the restore closure before the do-block so we can
        // call it on every exit path. (Swift `defer` cannot `await`,
        // so we cannot use the same idiom as the bridge-volume restore.)
        let restoreAirplay = restoreAirplayAfterLocalPhase

        do {
            let result = try await runLocalPhaseBody(probes: probes)
            if let restore = restoreAirplay {
                await restore()
                CalibTrace.log(
                    "[ActiveCalib] phase=local_FDM AirPlay receivers restored via caller hook"
                )
            }
            return result
        } catch {
            if let restore = restoreAirplay {
                await restore()
                CalibTrace.log(
                    "[ActiveCalib] phase=local_FDM AirPlay receivers restored via caller hook (after error)"
                )
            }
            throw error
        }
    }

    /// Inner Phase-1 body — extracted so the outer `runLocalPhase` can
    /// wrap it in the AirPlay-mute / AirPlay-restore async hooks (which
    /// `defer` cannot do, since `defer` blocks cannot `await`).
    private func runLocalPhaseBody(probes: [LocalProbe]) async throws -> PhaseResult {
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

        // **v7: silence the local bridges' MUSIC during Phase 1.**
        // Without this, the mic captures both the calibration tone
        // AND any concurrently-playing music. At ultrasonic
        // frequencies music has very little energy (most program
        // material is band-limited <16 kHz), but transient peaks
        // (cymbals, sibilants, percussion) contain enough energy in
        // the 16–19 kHz band to spike the noise floor and produce
        // false onset triggers — observed empirically as occasional
        // negative tau values on the SNRest-clear runs.
        //
        // Pairs with the LocalAirPlayBridge.render() pipeline change
        // (gain BEFORE tone overlay): setting volume=0 silences only
        // the music path; the calibration tone is overlaid AFTER the
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
                "[ActiveCalib] phase=local_FDM silenced \(savedBridgeVolumesPhase1.count) local bridges (music only — tone unaffected)"
            )
        }
        defer {
            // Restore on every exit path (success, throw, cancel).
            for (bridge, v) in savedBridgeVolumesPhase1 {
                bridge.setVolume(v)
            }
        }

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
            // **v7: envelopeWindowMs 5 → 20.** Phase 1 detects the
            // onset of a steady-state ultrasonic tone, not a transient,
            // so the integration window can grow without smearing the
            // edge we want to find — onset accuracy is bounded by the
            // 5 ms hop, not the window length. Quadrupling the window
            // adds 4× more correlated samples per Goertzel bin →
            // +6 dB gain on the tone, while uncorrelated noise grows
            // only as √4 → +6 dB SNR improvement at 18 kHz where
            // speaker rolloff hurts the most. The 5 ms hop is
            // unchanged so onset resolution stays at 5 ms.
            let env = Self.toneEnvelope(
                mic: mic, frequencyHz: f, sampleRate: Self.micSampleRate,
                envelopeWindowMs: 20
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

        defer {
            // Best-effort restore to original volumes regardless of
            // success / throw / cancel.
            Task.detached { [setAirplayVolume] in
                for (id, v) in originalVolumes {
                    await setAirplayVolume(id, v)
                }
            }
        }

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

            // Build the per-device chirp templates ONCE (identical across
            // every cycle — only the wall-clock anchor changes). Stereo
            // broadcast: same signal in both channels.
            let startHz = Self.chirpStartHz + Double(j) * Self.chirpPerDeviceOffsetHz
            let endHz = Self.chirpEndHz + Double(j) * Self.chirpPerDeviceOffsetHz
            let chirp = Self.linearChirp(
                startHz: startHz, endHz: endHz,
                durationMs: Self.chirpDurationMs,
                amplitude: Self.chirpAmplitude,
                sampleRate: sckRingSampleRate
            )
            let chirpStereo: [[Float]] = [chirp, chirp]
            // Unit-amplitude template at mic rate for matched-filter.
            let micChirp = Self.linearChirp(
                startHz: startHz, endHz: endHz,
                durationMs: Self.chirpDurationMs,
                amplitude: 1.0,
                sampleRate: Self.micSampleRate
            )

            Self.trace(
                "[ActiveCalib] phase=airplay_TDMA device=\(target.deviceID) chirp=\(Int(startHz))-\(Int(endHz))Hz dur=\(Self.chirpDurationMs)ms cycles=\(cycles)"
            )

            // Per-cycle measurement collectors.
            var cycleTaus: [Int] = []
            var cyclePeakProms: [Double] = []

            for k in 0..<cycles {
                try checkCancelled()
                let cycle = try await runAirplayOneCycle(
                    deviceID: target.deviceID,
                    chirpStereo: chirpStereo,
                    micChirp: micChirp,
                    injectChirpToRing: injectChirpToRing
                )
                Self.trace(
                    "[ActiveCalib] phase=airplay_TDMA device=\(target.deviceID) cycle=\(k + 1)/\(cycles) peak_idx=\(cycle.peakIdx) peak_time=\(cycle.tauMs)ms peak=\(String(format: "%.4f", cycle.peakVal)) bg=\(String(format: "%.4f", cycle.background)) mad=\(String(format: "%.4f", cycle.bgMad)) prominence=\(String(format: "%.2f", cycle.peakProminence))"
                )
                if cycle.tauMs >= 0 {
                    cycleTaus.append(cycle.tauMs)
                    cyclePeakProms.append(cycle.peakProminence)
                }
                // Inter-cycle gap: skip after the LAST cycle (we're going
                // to take the inter-DEVICE gap right after).
                if k < cycles - 1 {
                    try await Task.sleep(
                        nanoseconds: UInt64(Self.airplayInterCycleGapMs) * 1_000_000
                    )
                }
            }

            // Aggregate across cycles. If every cycle failed (empty
            // collectors), record τ=-1 / confidence=0 like the v4 path.
            if cycleTaus.isEmpty {
                tau[target.deviceID] = -1
                conf[target.deviceID] = 0
                unc[target.deviceID] = 0
                Self.trace(
                    "[ActiveCalib] device=\(target.deviceID) cycles=\(cycles) ALL_FAILED — recording τ=-1"
                )
            } else {
                let medianTau = Self.medianInt(cycleTaus)
                let madTau = Self.madInt(cycleTaus, median: medianTau)
                let medianProm = Self.medianDouble(cyclePeakProms)
                // Normalized MAD: clip to [0, 1] so a wildly-jittery
                // device (MAD > tau itself) doesn't produce negative
                // confidence.
                let normalizedMad = Double(madTau) / max(Double(medianTau), 1.0)
                let madPenalty = max(0, 1.0 - normalizedMad)
                let confidence = medianProm * madPenalty
                tau[target.deviceID] = medianTau
                conf[target.deviceID] = confidence
                unc[target.deviceID] = madTau
                Self.trace(
                    "[ActiveCalib] device=\(target.deviceID) cycles=\(cycles) median=\(medianTau)ms MAD=\(madTau)ms peak_prominence_med=\(String(format: "%.2f", medianProm)) madPenalty=\(String(format: "%.2f", madPenalty)) confidence=\(String(format: "%.2f", confidence))"
                )
            }

            // Inter-device gap so the previous chirp's ring tail decays
            // before the next device's first cycle fires.
            try await Task.sleep(nanoseconds: UInt64(Self.airplayInterDeviceGapMs) * 1_000_000)
        }

        return PhaseResult(tau: tau, confidence: conf, uncertainty: unc)
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
        /// Latency in ms; -1 if the search window was empty (the ring
        /// shrank below kMin → invalid measurement).
        let tauMs: Int
    }

    /// One TDMA chirp injection + capture + matched-filter pass for a
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

        // Cross-correlate. FFT-based, same machinery as MuteDip.
        let cd = Self.fftCrossCorrelation(env: mic, pattern: micChirp)
        let injectFrame = Int(
            Double(injectAtNs - captureStartNs) / 1_000_000_000.0 * Self.micSampleRate
        )
        let kMin = injectFrame
            + Int(Double(Self.airplaySearchMinMs) / 1000.0 * Self.micSampleRate)
        let kMax = min(
            cd.count - 1,
            injectFrame + Int(
                Double(Self.airplaySearchMaxMs) / 1000.0 * Self.micSampleRate
            )
        )
        guard kMax > kMin else {
            Self.trace(
                "[ActiveCalib] device=\(deviceID) SKIP search_window empty kMin=\(kMin) kMax=\(kMax)"
            )
            return AirplayCycleMeasurement(
                peakIdx: -1, peakVal: 0,
                background: 0, bgMad: 0,
                peakProminence: 0, tauMs: -1
            )
        }
        let (peakIdx, peakVal) = Self.argmax(cd, begin: kMin, end: kMax + 1)
        let (background, mad) = Self.backgroundStats(
            cd, excludingIdx: peakIdx, neighborhood: 64
        )
        let madFloor = max(mad, 1e-9)
        let prominence = Double((abs(peakVal) - background) / Float(madFloor))
        let tauMs = Int(
            Double(peakIdx - injectFrame) / Self.micSampleRate * 1000.0
        )
        return AirplayCycleMeasurement(
            peakIdx: peakIdx,
            peakVal: peakVal,
            background: background,
            bgMad: mad,
            peakProminence: prominence,
            tauMs: tauMs
        )
    }

    // MARK: - Signal generation

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
