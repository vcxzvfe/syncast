import AppKit
import AVFoundation
import CoreAudio
import Darwin
import Foundation
import Observation
import SyncCastDiscovery
import SyncCastRouter

/// Lock state for the whole-home AirPlay delay slider. `.unlocked` is the
/// default (free-running); `.locked(at:)` carries the millisecond target
/// the user has pinned. Calibrators consult this before applying any
/// automated correction.
public enum DelayLockState: Equatable {
    case unlocked
    case locked(at: Int)  // ms
}

/// Product-level state for the Local + AirPlay synchronization context.
/// This is intentionally separate from the old active calibration status:
/// route and AirPlay events can make a previously acceptable delay
/// "suspect" even when no probe or microphone task is running.
public enum SyncContextState: String, Equatable, Sendable {
    case valid
    case suspect
    case measuring
    case readyToDryRun
    case dryRunReady
    case applied
    case locked
}

/// App-owned passive no-probe controller state. This is separate from the
/// lab-gated active calibration status because it must be safe for normal
/// playback: no emitted probes and no direct delay write.
public enum PassiveAutosyncState: Equatable, Sendable {
    case idle
    case requestingPermission(startedAt: Date)
    case running(startedAt: Date, output: String)
    case canceling(startedAt: Date, output: String?)
    case completed(verdict: String, detail: String)
    case failed(verdict: String, detail: String)
}

/// A/B side identifier for the audition state machine. The audition flips
/// the broadcast delay between baseline-150 ms (A) and baseline+150 ms (B)
/// every 1.2 s within a single round.
public enum AuditionSide: String, Equatable { case A, B }

/// Audition state machine. Idle by default. `.running(round:side:)` carries
/// the current round (1...4) and the side currently being played. Round 5
/// auto-stops, restoring `airplayDelayMs` to the baseline that was active
/// when `startAudition()` was first called.
public enum AuditionState: Equatable {
    case idle
    case running(round: Int, side: AuditionSide)  // round 1...4
}

/// Top-level UI view-model. Owns the `DiscoveryService` and a `Router`,
/// surfaces a snapshot of devices + routing for the SwiftUI tree.
///
/// `@Observable` (Swift 5.9 macros): mutations to any stored property are
/// observed by views automatically.
@Observable
@MainActor
final class AppModel {
    private static let requestedCaptureBackend: String = ProcessInfo.processInfo
        .environment["SYNCAST_CAPTURE_BACKEND"]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased() ?? "sck"

    private static let selectedStereoOutputPath =
        StereoOutputPathPolicy.selectedPath()

    private static let requestedInitialMode: String? = ProcessInfo.processInfo
        .environment["SYNCAST_INITIAL_MODE"]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()

    private static let activeAcousticCalibrationEnabled: Bool = {
        ActiveAcousticDiagnosticsGate.isEnabled()
    }()
    private static let activeAcousticCalibrationDisabledMessage =
        ActiveAcousticDiagnosticsGate.disabledMessage

    private static let passiveAutosyncAllowsAcceptedDelayApply: Bool = {
        let raw = ProcessInfo.processInfo
            .environment["SYNCAST_PASSIVE_AUTOSYNC_ALLOW_DELAY_APPLY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return raw == "1" || raw == "true" || raw == "yes" || raw == "accepted"
    }()

    var activeAcousticDiagnosticsEnabled: Bool {
        Self.activeAcousticCalibrationEnabled
    }

    private static var startsInWholeHome: Bool {
        requestedInitialMode == "wholehome" || requestedInitialMode == "whole_home"
    }

    private static var initialPathNeedsScreenRecording: Bool {
        if requestedCaptureBackend == "tap" { return false }
        if selectedStereoOutputPath == .direct && !startsInWholeHome { return false }
        return true
    }

    var devices: [Device] = []
    var routing: [String: DeviceRouting] = [:]
    /// Per-device connection state, mirrored from the Router's actor
    /// state. Populated by `subscribeConnectionStates` polling the
    /// router every second; SwiftUI invalidates dependent views
    /// (DeviceRow.syncDot) when this dict mutates.
    ///
    /// v1 polls instead of pushing — sufficient for "user clicks
    /// device, sees state move grey → yellow → green within 1-2 sec".
    /// We can switch to an event push model later if the latency
    /// becomes user-visible; the Router actor's recordConnectionState
    /// is already the single source of truth for that future migration.
    var connectionStates: [String: DeviceConnectionState] = [:]
    /// Per-device "last_error" string from the most recent failed
    /// event. Surfaced as a one-line message under failed device rows.
    var connectionFailureReasons: [String: String] = [:]
    /// The fundamental architectural choice: which audio path is active.
    /// These are mutually exclusive. Switching requires a full pipeline
    /// teardown + rebuild (a few hundred ms of silence on transition,
    /// well under user-perceptible UI latency).
    ///
    /// Why two modes — the latency budgets are incompatible. AirPlay 2's
    /// PTP-anchored playback runs ~1.8 s behind realtime. Local AUHAL
    /// runs ~50 ms. There is no useful middle ground because the only way
    /// to sync them is to delay the local path by 1.8 s, which destroys
    /// the reason to use it. Every commercial multi-room product
    /// (Sonos, Apple Music + AirPlay 2, Roon) makes this same split.
    var mode: Mode = .stereo
    var streamingState: StreamingState = .idle
    var lastError: String?
    /// Screen Recording TCC permission state. We replaced the old
    /// "BlackHole microphone" gate with this.
    var screenRecordingGranted: Bool = false

    // MARK: - Calibration mic plumbing
    //
    // The active diagnostic calibration flow plays test tones through each
    // configured output and listens with a microphone to measure the
    // round-trip latency. The user picks WHICH input to listen with via
    // the picker driven by these fields. The actual capture / DSP
    // pipeline lives in `Calibration.swift` and `CalibrationRunner.swift`
    // — this view-model only surfaces the available devices, the user's
    // choice, and the TCC permission status.

    /// Live list of input-capable CoreAudio devices, refreshed on hot-plug.
    /// Populated by `refreshInputDevices()`; the first refresh runs at
    /// bootstrap and a `kAudioHardwarePropertyDevices` listener keeps it
    /// current. Sort order: system default first, then alphabetical.
    var availableInputDevices: [InputDeviceInfo] = []

    /// User-selected calibration mic. `nil` means "use system default
    /// input" — that is the bootstrap value if `userDefaultsMicUID` is
    /// unset OR if the persisted UID no longer maps to an attached
    /// device (e.g. user unplugged that USB mic). The resolution is
    /// done by `effectiveMicID`, which falls back to the system default
    /// when this is nil or unresolvable.
    ///
    /// Persisted via `UserDefaults` key `"syncast.calibrationMicID"` —
    /// stored as the device UID (a stable string set by the kernel),
    /// NOT the live `AudioDeviceID` (a UInt32 that changes on replug).
    /// `selectedMicID` itself is the LIVE id, resolved at refresh time.
    var selectedMicID: AudioDeviceID? {
        didSet {
            persistSelectedMic()
        }
    }

    /// Effective mic id used by the calibration runner: either
    /// `selectedMicID` if set + still attached, or the current system
    /// default input. Returns `nil` only on a system with no input
    /// device at all (vanishingly rare).
    var effectiveMicID: AudioDeviceID? {
        if let chosen = selectedMicID,
           availableInputDevices.contains(where: { $0.id == chosen }) {
            return chosen
        }
        return InputDeviceEnumerator.defaultInputDeviceID()
    }

    /// Synchronous read of `AVCaptureDevice.authorizationStatus(for:.audio)`.
    /// Cheap; safe to call from view body. Drives the "Auto-calibrate"
    /// button's enabled / "Grant access…" affordance.
    var hasMicrophonePermission: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// UserDefaults key for the persisted calibration-mic preference.
    /// Stored as the device UID string, not the live AudioDeviceID.
    private static let micUIDDefaultsKey = "syncast.calibrationMicID"

    /// CoreAudio HAL listener that fires on `kAudioHardwarePropertyDevices`
    /// changes (device hot-plug). Held strongly here so it survives until
    /// the AppModel itself is torn down. Calls back to `refreshInputDevices`
    /// on the main queue so re-resolution of `selectedMicID` and
    /// `availableInputDevices` happens on `@MainActor`.
    private var inputDeviceListener: InputDeviceListener?

    // MARK: - Whole-home delay-line tuning
    //
    // User-tunable broadcast-side delay aligning local bridges with
    // AirPlay 2's PTP-anchored playout (~1.8 s). The slider in the
    // popover writes into `airplayDelayMs`; a debounced setter pushes
    // the change to the sidecar via JSON-RPC `local_fifo.set_delay_ms`.
    // The auto-calibration flow above writes here too with its
    // `recommendedDelayMs` result.

    /// User-tunable broadcast-side delay (ms) for the whole-home FIFO,
    /// aligning local bridges with AirPlay 2's ~1.8 s PTP playout.
    /// Persisted to `UserDefaults` so user-dialed drift survives launches.
    var airplayDelayMs: Int = AppModel.loadPersistedDelayMs()
    /// Last sidecar `actual_delivery_lag_ms` reading; nil before first
    /// sample or outside whole-home. Drives the slider's caption.
    var measuredLagMs: Int? = nil
    /// Current trust state for Local + AirPlay delay evidence. A route,
    /// AirPlay timing-domain, volume, wake, or manual-delay change moves
    /// this to `.suspect` until passive evidence can establish a new
    /// baseline or repeat-confirmed correction. Stereo mode uses `.valid`
    /// because there is no Local + AirPlay context to guard.
    var syncContextState: SyncContextState = .valid
    var syncContextReason: String = "stereo path; no Local+AirPlay baseline active"
    var syncContextUpdatedAt: Date = Date()
    var syncContextRevision: UInt64 = 0
    var syncContextDelayMs: Int = AppModel.loadPersistedDelayMs()

    var passiveAutosyncState: PassiveAutosyncState = .idle
    var passiveAutosyncArtifactPath: String?
    var passiveAutosyncSessionRoot: String?

    var passiveAutosyncRunning: Bool {
        if case .running = passiveAutosyncState { return true }
        return false
    }

    var passiveAutosyncRequestingPermission: Bool {
        if case .requestingPermission = passiveAutosyncState { return true }
        return false
    }

    var passiveAutosyncCanceling: Bool {
        if case .canceling = passiveAutosyncState { return true }
        return false
    }

    var passiveAutosyncNeedsMicrophoneGrant: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
    }

    private var passiveAutosyncBusy: Bool {
        switch passiveAutosyncState {
        case .requestingPermission, .running, .canceling:
            return true
        case .idle, .completed, .failed:
            return false
        }
    }

    private var canRequestOrUseMicrophoneForPassiveAutosync: Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized, .notDetermined:
            return true
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    var canRunPassiveAutosync: Bool {
        guard mode == .wholeHome,
              streamingState == .running,
              hasEnabledLocalAndAirPlayOutputs,
              hasEnabledAirPlayOutputNotKnownDisconnected,
              canRequestOrUseMicrophoneForPassiveAutosync,
              !passiveAutosyncBusy
        else { return false }
        guard case .unlocked = delayLockState else { return false }
        return true
    }

    var passiveAutosyncStatusText: String? {
        switch passiveAutosyncState {
        case .idle:
            return nil
        case .requestingPermission:
            return "Passive check waiting for microphone permission"
        case .running(let startedAt, _):
            let elapsed = max(0, Int(Date().timeIntervalSince(startedAt)))
            return "Passive check running (\(elapsed)s)"
        case .canceling:
            return "Passive check stopping"
        case .completed(let verdict, let detail):
            return detail.isEmpty ? "Passive check: \(verdict)" : "\(verdict): \(detail)"
        case .failed(let verdict, let detail):
            return detail.isEmpty ? "Passive check failed: \(verdict)" : "\(verdict): \(detail)"
        }
    }

    var passiveAutosyncStatusIsError: Bool {
        if case .failed = passiveAutosyncState { return true }
        return false
    }

    static let airplayDelayMsKey = "syncast.airplayDelayMs"
    static let defaultAirplayDelayMs: Int = 1750
    /// UI cap. Bumped from 3000 to 5000 ms because empirical AirPlay
    /// measurements (v4 ActiveCalibrator) found total command-to-mic
    /// latencies of 2300–2700 ms. With local at ~10 ms, the recommended
    /// delay-line value is in that 2300–2700 ms range, plus headroom
    /// for slower AirPlay receivers (some HomePod variants buffer
    /// 3–4 s). Sidecar still clamps to [0, 10000] for an absolute
    /// safety bound.
    static let airplayDelayMsRange: ClosedRange<Int> =
        CalibrationDiagnosticServer.autoApplyDelayRange

    private static func loadPersistedDelayMs() -> Int {
        // If the user previously locked the delay, prefer the locked value.
        // The lock key stores 0 to mean "no lock", so guard on > 0.
        let lockedAt = UserDefaults.standard.integer(forKey: airplayDelayLockedAtKey)
        if lockedAt > 0 {
            return min(max(lockedAt, airplayDelayMsRange.lowerBound),
                       airplayDelayMsRange.upperBound)
        }
        guard let raw = UserDefaults.standard.object(forKey: airplayDelayMsKey) as? Int
        else { return defaultAirplayDelayMs }
        return min(max(raw, airplayDelayMsRange.lowerBound),
                   airplayDelayMsRange.upperBound)
    }

    /// Read the persisted lock target (ms). Returns 0 when no lock has
    /// been set. Used by init() to seed `delayLockState` so a user's
    /// pinned value survives a relaunch.
    private static func loadPersistedLockedAt() -> Int {
        let raw = UserDefaults.standard.integer(forKey: airplayDelayLockedAtKey)
        if raw <= 0 { return 0 }
        return min(max(raw, airplayDelayMsRange.lowerBound),
                   airplayDelayMsRange.upperBound)
    }

    // MARK: - Background continuous v4 active calibration
    // Replaces the previous PassiveCalibrator-based engine, which used
    // GCC-PHAT against shared music — that approach can't distinguish
    // per-device latencies and produced ±100 ms run-to-run noise plus
    // bad absolute values. The new path drives `ActiveCalibrator`
    // (per-device unique probes, FDM for locals + TDMA mute-dip for
    // AirPlay) on a fixed cadence and applies the corrected delay
    // when measured drift exceeds 30 ms with sufficient confidence.
    // Automatic apply is intentionally conservative: the user's field
    // feedback showed that a single bad mic run can overwrite a usable
    // hand-tuned Local + AirPlay delay.
    var backgroundCalibrationEnabled: Bool = AppModel.loadPersistedBgEnabled() {
        didSet {
            if backgroundCalibrationEnabled &&
                !AppModel.activeAcousticCalibrationEnabled {
                backgroundCalibrationEnabled = false
                UserDefaults.standard.set(false, forKey: AppModel.bgEnabledKey)
                eventDrivenCalibrationTask?.cancel()
                postApplyValidationTask?.cancel()
                pendingEventDrivenCalibrationReason = nil
                SyncCastLog.log(
                    "bgCalib: active acoustic diagnostics disabled; ignoring Continuous"
                )
                return
            }
            UserDefaults.standard.set(backgroundCalibrationEnabled, forKey: AppModel.bgEnabledKey)
            if !backgroundCalibrationEnabled {
                eventDrivenCalibrationTask?.cancel()
                postApplyValidationTask?.cancel()
                pendingEventDrivenCalibrationReason = nil
            }
            reconcileBackgroundCalibration()
            if backgroundCalibrationEnabled {
                scheduleEventDrivenCalibration(reason: "continuous enabled")
            }
        }
    }
    /// Sample interval (seconds, clamped to `bgIntervalRange`). Live
    /// changes restart the engine.
    var backgroundCalibrationIntervalS: Int = AppModel.loadPersistedBgInterval() {
        didSet {
            let r = AppModel.bgIntervalRange
            let v = min(max(backgroundCalibrationIntervalS, r.lowerBound), r.upperBound)
            if v != backgroundCalibrationIntervalS { backgroundCalibrationIntervalS = v; return }
            UserDefaults.standard.set(v, forKey: AppModel.bgIntervalKey)
            restartBackgroundCalibrationIfActive()
        }
    }
    /// Most recent Sample emitted by the continuous loop. The popover
    /// renders this in the "Continuous" status caption.
    var lastCalibrationSample: ContinuousActiveCalibrator.Sample? = nil
    /// Sliding-window history of the last `calibrationHistoryCapacity`
    /// samples emitted by the continuous calibrator. Drives the trend
    /// timeline + drift indicators in `MainPopover.liveStatusBlock`.
    /// Append-and-trim happens in `handleBackgroundCalibrationSample`;
    /// cleared whenever the engine stops so a fresh start doesn't show
    /// stale post-restart drift.
    var calibrationSampleHistory: [ContinuousActiveCalibrator.Sample] = []
    static let calibrationHistoryCapacity: Int = 20
    /// Most recent non-zero delta the continuous calibrator pushed into
    /// `airplayDelayMs`. Computed as the signed difference of the two
    /// latest samples' `appliedDelayMs`. `nil` until at least two
    /// samples have arrived OR when the latest delta was zero (steady
    /// state).
    var lastAppliedDelta: Int? {
        guard calibrationSampleHistory.count >= 2 else { return nil }
        let n = calibrationSampleHistory.count
        let delta = calibrationSampleHistory[n - 1].appliedDelayMs
                  - calibrationSampleHistory[n - 2].appliedDelayMs
        return delta == 0 ? nil : delta
    }
    /// True iff the engine is running (toggle on + bad preconditions → false).
    var backgroundCalibrationActive: Bool = false
    /// Toggle on but mic permission denied/restricted.
    var backgroundCalibrationMicDenied: Bool = false
    /// Pause while a one-shot manual run is in flight, so the click
    /// pulses don't pollute the continuous correlator.
    private var continuousPausedForManual: Bool = false

    private struct PendingAutoCalibrationApply {
        let targetMs: Int
        let timestamp: Date
        let contextSignature: String
    }

    private struct PendingPassiveDryRunCandidate {
        let targetDelayMs: Int
        let currentDelayMs: Int
        let contextSignature: String
        let captureBackend: String
        let enabledAirplayCount: Int
        let activeAirplayCount: Int
        let airplayTimingEpoch: UInt64
        let acceptedFromSyncContextState: String
        let acceptedFromSyncContextRevision: UInt64
        let acceptedSyncContextRevision: UInt64
        let sessionRoot: String?
        let controlReport: String?
        let acceptedUnix: Double
    }

    private var pendingAutoCalibrationApply: PendingAutoCalibrationApply?
    private var pendingPassiveDryRunCandidate: PendingPassiveDryRunCandidate?
    private var passiveDryRunExpiryTask: Task<Void, Never>?
    private var eventDrivenCalibrationTask: Task<Void, Never>?
    private var postApplyValidationTask: Task<Void, Never>?
    private var pendingEventDrivenCalibrationReason: String?
    private var lastEventDrivenCalibrationAt: Date?
    private var eventDrivenCalibrationRetryCount: Int = 0
    private var eventDrivenRetryScheduledForCurrentAttempt: Bool = false
    private var userDelayRevision: UInt64 = 0
    private var lastLocalFifoRunning: Bool?
    private var lastLocalFifoClientCount: Int?
    private var lastLocalFifoOverflowDrops: Int?
    private var lastLocalFifoPerClientDrops: Int?
    private var lastLocalFifoDelayMs: Int?
    private var lastLocalBridgeResyncCounts: [String: UInt64] = [:]
    private var passiveAutosyncTask: Task<Void, Never>?
    private var passiveAutosyncProcess: Process?
    private var passiveAutosyncRunID: UUID?
    private var passiveAutosyncEventTask: Task<Void, Never>?
    private var pendingPassiveAutosyncReason: String?
    private var lastPassiveAutosyncFinishedAt: Date?
    private var lastPassiveAutosyncFinishedRevision: UInt64?

    private struct PassiveAutosyncLaunchContext: Sendable {
        let syncContextState: SyncContextState
        let syncContextRevision: UInt64
        let routeSignature: String
    }

    // ActiveCalibrator already fails closed below 3.0 and requires stable
    // repeated cycles. A 4.0 UI gate rejected real field-stable runs whose
    // local direct-path confidence was 3.1-3.4 despite AirPlay group MAD
    // being only a few milliseconds. Single-run writes are now capped at
    // a tiny direct correction and must have low uncertainty; anything
    // bigger needs repeat agreement in the same route/mic/volume context.
    static let autoApplyConfidenceFloor: Double =
        CalibrationDiagnosticServer.autoApplyConfidenceFloor
    static let autoApplyMaxSingleJumpMs: Int =
        CalibrationDiagnosticServer.autoApplyMaxSingleJumpMs
    static let autoApplyRepeatAgreementMs: Int =
        CalibrationDiagnosticServer.autoApplyRepeatAgreementMs
    static let autoApplyMaxUncertaintyMs: Int =
        CalibrationDiagnosticServer.autoApplyMaxUncertaintyMs
    static let autoApplyMaxAirplayReceivers: Int =
        CalibrationDiagnosticServer.autoApplyMaxAirplayReceivers
    static let autoApplyRepeatWindowS: TimeInterval = 180
    static let eventDrivenCalibrationSettleS: TimeInterval = 10
    static let eventDrivenCalibrationCooldownS: TimeInterval = 90
    static let eventDrivenCalibrationRetrySettleS: TimeInterval = 25
    static let postApplyValidationSettleS: TimeInterval = 45
    static let maxEventDrivenCalibrationRetries: Int = 1

    static let bgEnabledKey = "syncast.bgCalibrationEnabled"
    static let bgIntervalKey = "syncast.bgCalibrationIntervalS"
    /// 1200 s (20 min). Continuous mode is lab-gated because even
    /// high-band Phase-1 probes were audible on user hardware. The disruptive
    /// Phase-2 AirPlay TDMA mute-dip is reserved for the manual
    /// Auto-calibrate button, so we no longer need to probe every 30 s
    /// to keep up with drift; thermal/network drift in AirPlay shows
    /// up only on the manual cadence anyway.
    static let defaultBgIntervalS: Int = 1200
    /// 60 s … 3600 s (1 min … 60 min). Floor raised from 10 s because
    /// even lab-only Phase-1 probes should not run more than once a
    /// minute; ceiling raised from 300 s because long-idle setups can
    /// happily wait 1 h between drift checks.
    static let bgIntervalRange: ClosedRange<Int> = 60...3600

    private static func loadPersistedBgEnabled() -> Bool {
        guard activeAcousticCalibrationEnabled else { return false }
        return UserDefaults.standard.bool(forKey: bgEnabledKey)
    }
    private static func loadPersistedBgInterval() -> Int {
        guard let raw = UserDefaults.standard.object(forKey: bgIntervalKey) as? Int
        else { return defaultBgIntervalS }
        // Persisted values from the old 10…300 range are clamped into
        // the new 60…3600 floor/ceiling on first load.
        return min(max(raw, bgIntervalRange.lowerBound), bgIntervalRange.upperBound)
    }

    // MARK: - Manual delay lock + audition state machine
    //
    // The whole-home delay slider has two ergonomic problems we solve here:
    //   1. Background calibrators (continuous v4) and prior closed-loop
    //      drivers occasionally jitter the delay value while the user is
    //      happy with what they hear. The lock pins the broadcast-side
    //      delay to a user-chosen value; calibrators can still RUN, but
    //      external code can check `delayLockState` before applying any
    //      automated correction.
    //   2. Picking the "right" delay by feel is hard. The audition state
    //      machine A/B-tests ±150 ms around a baseline, then narrows the
    //      baseline by 75 ms on each user choice for 4 rounds. Total
    //      ~10 s of A/B with deterministic convergence.

    /// Persistence key for the manual lock target. Stored in milliseconds.
    /// 0 means "no lock" — chosen because the slider's lower bound is 0
    /// so there's no risk of confusing 0-as-locked with 0-as-not-locked
    /// from a user-centric perspective (zero delay is rarely useful in
    /// whole-home anyway). loadPersistedLockedAt() returns the canonical
    /// "lock on / lock off" interpretation.
    static let airplayDelayLockedAtKey = "syncast.airplayDelayLockedAt"

    /// Locked-delay state. `.locked(at:)` carries the slider value (ms)
    /// the user pinned. Persisted via `airplayDelayLockedAtKey` and
    /// restored at init.
    ///
    /// `@Published` is intentionally omitted: this class is `@Observable`
    /// (Swift 5.9 macros), which auto-observes all `var` mutations and
    /// is incompatible with Combine's `@Published` property wrapper.
    public private(set) var delayLockState: DelayLockState = .unlocked

    /// Audition state machine. Idle until `startAudition()`; transitions
    /// through 4 rounds of A/B side switching at 1.2 s cadence. Each
    /// `chooseAuditionA` / `chooseAuditionB` narrows the baseline by
    /// 75 ms before kicking off the next round.
    public private(set) var auditionState: AuditionState = .idle

    /// Snapshot of `airplayDelayMs` taken at `startAudition()` and
    /// adjusted by the chooser methods. Restored on `stopAudition()`
    /// (or when round 5 auto-stops). Private to keep the contract
    /// surface small.
    private var auditionBaselineMs: Int = 0

    /// In-flight side-switching Task. Cancelled by stopAudition / chooseX
    /// before launching a fresh per-round Task.
    private var auditionSideSwitchTask: Task<Void, Never>?

    enum Mode: String, Sendable, CaseIterable, Identifiable {
        /// Local CoreAudio outputs only, ~50 ms latency, video sync OK.
        /// AirPlay receivers are hidden / unselectable in this mode.
        /// Drives audio through a private CoreAudio Aggregate Device with
        /// kernel-level drift correction so the physical speakers stay
        /// sample-accurately aligned.
        case stereo
        /// All outputs go through OwnTone's player at AirPlay 2's
        /// ~1.8 s latency. Local CoreAudio outputs participate by
        /// receiving PCM from OwnTone's "fifo" output via a sidecar
        /// broadcast → Swift LocalAirPlayBridge. AirPlay 2 receivers
        /// receive the same audio over the network. AirPlay receivers
        /// stay in AirPlay's timing domain; local outputs are delay-padded
        /// to that group. Video sync is impossible in this mode.
        case wholeHome

        public var id: String { rawValue }
        public var displayName: String {
            switch self {
            case .stereo:    return "立体声 (本地, 低延迟)"
            case .wholeHome: return "AirPlay 实验模式"
            }
        }
        public var subtitle: String {
            switch self {
            case .stereo:    return "本地扬声器, ≈50ms 延迟, 适合视频"
            case .wholeHome: return "本地 + AirPlay 对齐实验中, ≈1.8s+, 仅适合音乐"
            }
        }
    }

    enum StreamingState: String, Sendable {
        case idle, starting, running, stopping, error
    }

    /// Status-bar icon identifier. Custom asset names resolve through the
    /// SwiftPM resource bundle; SF Symbol fallbacks are prefixed with `sf:`
    /// so the view layer can route to `Image(systemName:)`.
    var statusIconName: String {
        switch streamingState {
        case .idle:     return "MenubarIcon"
        case .starting: return "MenubarIcon"
        case .running:  return "MenubarIcon"
        case .stopping: return "MenubarIcon"
        case .error:    return "sf:speaker.slash"
        }
    }

    /// Is at least one local-output device enabled? Used to decide whether
    /// the audio engine should be running.
    var hasEnabledOutputs: Bool {
        routing.values.contains { $0.enabled }
    }

    private let discovery: DiscoveryService
    private let router: Router
    private let sidecarLauncher = SidecarLauncher()
    var sidecarRunning: Bool = false

    /// Debounce guard for `reconcileEngine`. Each call cancels the
    /// previous timer; only the last call within an 80 ms quiet window
    /// actually fires the reconciler. Keeps "user mashes toggle rows" from
    /// generating 30+ reconcile passes in 2 seconds (observed in
    /// launch.log before this guard was added).
    private var reconcileTimer: Task<Void, Never>?

    /// Single-flight guard for setMode. Even with the streamingState =
    /// .stopping race fix in setMode, a rapid double-click of the
    /// segmented mode picker (e.g. wholeHome → stereo → wholeHome over
    /// ~150 ms) can queue THREE Tasks in sequence: each one observes a
    /// transient .idle state between transitions and spawns its own
    /// router.stop / reconcile pair, leading to overlapping engine
    /// teardowns. This flag rate-limits mode transitions to one at a
    /// time — extra clicks during a transition are dropped, and the
    /// user-visible behavior is "your last click is honored after the
    /// current transition finishes". Security Review C2.
    private var modeTransitioning: Bool = false

    /// Debounce coalescer for `setAirplayDelay` — only the value 200 ms
    /// after the last drag fires the IPC + UserDefaults write.
    private var airplayDelayCommitTask: Task<Void, Never>?

    init() {
        self.discovery = DiscoveryService()
        self.router = Router()
        AppTerminationCoordinator.shared.model = self
        // Restore manual lock from UserDefaults. When a lock is persisted,
        // `loadPersistedDelayMs()` already chose the locked value so the
        // slider matches the lock; we only need to seed the state enum.
        let lockedAt = AppModel.loadPersistedLockedAt()
        if lockedAt > 0 {
            self.delayLockState = .locked(at: lockedAt)
            self.syncContextState = .locked
            self.syncContextReason = "persisted delay lock"
            self.syncContextDelayMs = lockedAt
        }
        // One-shot cleanup of the legacy hybrid-tracker pref. The
        // toggle/engine has been removed; leaving the key behind would
        // simply clutter the user's defaults plist forever.
        UserDefaults.standard.removeObject(forKey: "syncast.hybridTrackingEnabled")
        if !Self.activeAcousticCalibrationEnabled {
            UserDefaults.standard.set(false, forKey: Self.bgEnabledKey)
        }
        Task { await self.bootstrap() }
    }

    private func bootstrap() async {
        SyncCastLog.log("bootstrap start")
        SyncCastLog.log(
            "active acoustic diagnostics: "
            + ActiveAcousticDiagnosticsGate.startupLogState()
        )
        // Check Screen Recording permission state only when the launch path
        // can use ScreenCaptureKit. Direct Stereo and Process Tap validation
        // must not be polluted by Screen Recording prompts or scary logs.
        if AppModel.initialPathNeedsScreenRecording {
            screenRecordingGranted = (ScreenRecordingTCC.current == .granted)
            SyncCastLog.log("screen-recording status: \(ScreenRecordingTCC.current.rawValue)")
        } else {
            screenRecordingGranted = true
            SyncCastLog.log("screen-recording status: not required for initial path capture=\(AppModel.requestedCaptureBackend) stereoPath=\(AppModel.selectedStereoOutputPath.rawValue)")
        }
        // Populate the calibration-mic picker. We do NOT prompt for TCC
        // here — enumeration is read-only HAL property work and does not
        // require microphone access; the actual TCC prompt is deferred
        // until the user explicitly taps "Auto-calibrate".
        startInputDeviceWatch()
        // Auto-recover the local audio driver after display sleep / system
        // wake. Display DPMS sleep yanks HDMI/DP audio sub-devices from
        // CoreAudio entirely; on wake the device reappears with the same
        // UID but a fresh AudioDeviceID. Without this watch the user has
        // to deselect + reselect both outputs to recover. See Round 12.
        startPowerEventWatch()
        // Tahoe sometimes lies: the System Settings switch shows ON but
        // CGPreflightScreenCaptureAccess returns false. Poll every 2s
        // and update the model when the runtime path actually needs SCK,
        // so Direct Stereo / Tap validation stays out of Screen Recording
        // while later mode switches back into SCK still self-heal.
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self else { return }
                let (needsScreenRecording, was) = await MainActor.run {
                    (self.runtimePathNeedsScreenRecording, self.screenRecordingGranted)
                }
                let now = needsScreenRecording
                    ? (ScreenRecordingTCC.current == .granted)
                    : true
                if now != was {
                    await MainActor.run { self.screenRecordingGranted = now }
                    SyncCastLog.log("screen-recording state changed: \(was) → \(now)")
                    if now {
                        // Just got granted. Trigger reconcile so a previously
                        // queued toggle takes effect without app restart.
                        await MainActor.run {
                            if self.runtimePathNeedsScreenRecording {
                                self.reconcileEngine()
                            }
                        }
                    }
                }
            }
        }
        // 1. Spawn the bundled sidecar (which in turn spawns OwnTone).
        do {
            let paths = try sidecarLauncher.start()
            sidecarRunning = true
            SyncCastLog.log("[SyncCast] sidecar started, control=\(paths.controlSocket.path)".replacingOccurrences(of: "[SyncCast] ", with: ""))
            // Retry attach with exponential backoff. The PyInstaller
            // onefile binary can need up to a couple of seconds on first
            // run to extract its archive before the Python interpreter
            // gets to asyncio.start_unix_server.
            var lastErr: Error?
            for attempt in 0..<10 {
                do {
                    try await router.attachSidecar(.init(
                        control: paths.controlSocket,
                        audio:   paths.audioSocket
                    ))
                    SyncCastLog.log("[SyncCast] attachSidecar OK on attempt \(attempt + 1)".replacingOccurrences(of: "[SyncCast] ", with: ""))
                    lastErr = nil
                    break
                } catch {
                    lastErr = error
                    SyncCastLog.log("[SyncCast] attachSidecar attempt \(attempt + 1) failed: \(error)".replacingOccurrences(of: "[SyncCast] ", with: ""))
                    try? await Task.sleep(nanoseconds: UInt64(200_000_000) << min(attempt, 4))
                }
            }
            if let e = lastErr { throw e }
            // Push persisted FIFO delay before the user can hit play.
            // Skip when default, to keep launch logs quiet.
            if airplayDelayMs != AppModel.defaultAirplayDelayMs {
                Task { [weak self] in
                    guard let self else { return }
                    await self.commitAirplayDelay(self.airplayDelayMs)
                }
            }
        } catch {
            SyncCastLog.log("[SyncCast] sidecar attach gave up: \(error)".replacingOccurrences(of: "[SyncCast] ", with: ""))
            lastError = "sidecar: \(error.localizedDescription)"
        }
        // 2. Start discovery (CoreAudio + Bonjour).
        SyncCastLog.log("[SyncCast] starting discovery".replacingOccurrences(of: "[SyncCast] ", with: ""))
        await discovery.start()
        let stream = await discovery.subscribe()
        Task { [weak self] in
            for await event in stream {
                guard let self else { break }
                await self.applyEvent(event)
            }
        }
        // 3. Poll the router for per-device connection state once a
        //    second. The router caches what the sidecar has emitted
        //    via event.device_state; the UI's sync-dot depends on the
        //    cached value. v1 polls — see AppModel.connectionStates.
        //    Same loop also samples the sidecar's `actual_delivery_lag_ms`
        //    so the Sync slider's "Measured lag" caption stays live
        //    without spinning a second timer.
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                await self.refreshConnectionStates()
                await self.refreshLocalFifoLag()
            }
        }
        SyncCastLog.log("[SyncCast] bootstrap complete".replacingOccurrences(of: "[SyncCast] ", with: ""))

        // SYNCAST_INITIAL_MODE=wholehome|stereo flips the engine into the
        // requested mode at bootstrap, BEFORE SYNCAST_AUTO_TEST starts
        // toggling devices. Used for whole-home end-to-end verification —
        // dev only. Default is whatever `mode` is initialized to.
        if let modeEnv = ProcessInfo.processInfo.environment["SYNCAST_INITIAL_MODE"] {
            let normalized = modeEnv.lowercased()
            let target: Mode? = {
                if normalized == "wholehome" || normalized == "whole_home" { return .wholeHome }
                if normalized == "stereo" { return .stereo }
                return nil
            }()
            if let target = target, target != mode {
                SyncCastLog.log("INITIAL_MODE env: \(mode.rawValue) → \(target.rawValue)")
                // We're inside bootstrap which itself runs in a Task. Schedule
                // setMode shortly after so all the discovery + sidecar
                // attach is in place; otherwise mode.set IPC could race
                // attachSidecar.
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    await MainActor.run { self?.setMode(target) }
                }
            }
        }

        // SYNCAST_AUTO_TEST=mbp triggers an automated toggle of the MBP
        // built-in speaker 4 seconds after bootstrap. Used for shell-driven
        // end-to-end audio verification — strictly dev only.
        if let env = ProcessInfo.processInfo.environment["SYNCAST_AUTO_TEST"] {
            // Comma-separated list. e.g.  mbp,xiaomi,display
            // Each token is matched case-insensitively against device.name.
            let targets = env.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard let self else { return }
                await MainActor.run {
                    for target in targets {
                        let match = self.autoTestDevice(matching: target)
                        if let dev = match {
                            SyncCastLog.log("AUTO_TEST: toggling \(dev.name) ON")
                            self.toggleDevice(dev.id)
                        } else {
                            SyncCastLog.log("AUTO_TEST: no device matched '\(target)'")
                        }
                    }
                }
            }
        }

        // Optional extra scripted actions for long-running hardware tests.
        // Format: comma-separated `verb:target:value:delaySec`, e.g.
        // `volume:xiaomi:0.70:260` or `mute:xiaomi:1:260`.
        if let env = ProcessInfo.processInfo.environment["SYNCAST_AUTO_TEST_ACTIONS"] {
            let actions = env.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            for action in actions {
                scheduleAutoTestAction(action)
            }
        }
    }

    private func autoTestDevice(matching token: String) -> Device? {
        devices.first { d in
            d.name.localizedCaseInsensitiveContains(token) ||
            (token == "mbp" && d.name.contains("MacBook Pro扬声器")) ||
            (token == "display" && d.name.contains("PG27"))
        }
    }

    private func scheduleAutoTestAction(_ spec: String) {
        let parts = spec.split(separator: ":").map(String.init)
        guard parts.count == 4 else {
            SyncCastLog.log("AUTO_TEST_ACTION: invalid '\(spec)'")
            return
        }
        let verb = parts[0].lowercased()
        let target = parts[1]
        let value = parts[2]
        guard let delay = Double(parts[3]), delay >= 0 else {
            SyncCastLog.log("AUTO_TEST_ACTION: invalid delay '\(spec)'")
            return
        }
        Task { [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(delay * 1_000_000_000)
            )
            guard let self else { return }
            await MainActor.run {
                guard let dev = self.autoTestDevice(matching: target) else {
                    SyncCastLog.log(
                        "AUTO_TEST_ACTION: no device matched '\(target)' for \(spec)"
                    )
                    return
                }
                switch verb {
                case "volume":
                    guard let vol = Float(value) else {
                        SyncCastLog.log(
                            "AUTO_TEST_ACTION: invalid volume '\(spec)'"
                        )
                        return
                    }
                    let clamped = max(0, min(1, vol))
                    SyncCastLog.log(
                        "AUTO_TEST_ACTION: setting volume \(dev.name) to \(String(format: "%.2f", clamped))"
                    )
                    self.setVolume(clamped, for: dev.id)
                case "mute":
                    if let desired = Self.parseAutoTestBool(value) {
                        SyncCastLog.log(
                            "AUTO_TEST_ACTION: setting mute \(dev.name) to \(desired ? "on" : "off")"
                        )
                        self.setMute(desired, for: dev.id)
                    } else {
                        SyncCastLog.log("AUTO_TEST_ACTION: toggling mute \(dev.name)")
                        self.toggleMute(dev.id)
                    }
                case "toggle":
                    SyncCastLog.log("AUTO_TEST_ACTION: toggling \(dev.name)")
                    self.toggleDevice(dev.id)
                case "enable":
                    SyncCastLog.log("AUTO_TEST_ACTION: enabling \(dev.name)")
                    self.setDeviceEnabled(true, for: dev.id)
                case "disable":
                    SyncCastLog.log("AUTO_TEST_ACTION: disabling \(dev.name)")
                    self.setDeviceEnabled(false, for: dev.id)
                default:
                    SyncCastLog.log("AUTO_TEST_ACTION: unknown verb '\(verb)' in \(spec)")
                }
            }
        }
    }

    private static func parseAutoTestBool(_ value: String) -> Bool? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on", "mute", "muted", "enable", "enabled":
            return true
        case "0", "false", "no", "off", "unmute", "unmuted", "disable", "disabled":
            return false
        default:
            return nil
        }
    }

    private func applyEvent(_ event: DiscoveryEvent) async {
        await MainActor.run {
            switch event {
            case .appeared(let dev):
                SyncCastLog.log("[SyncCast] device appeared: \(dev.name) (\(dev.transport.rawValue))".replacingOccurrences(of: "[SyncCast] ", with: ""))
                // Round 12: device came back. Clear it from the
                // "transiently missing while user-intent-enabled" set
                // (used by the post-wake recovery handler).
                if let uid = dev.coreAudioUID {
                    transientlyMissingEnabledCoreAudioUIDs.remove(uid)
                }
                // If a logical device with the same coreAudioUID / host+name
                // already exists under a DIFFERENT id (e.g. discovery layer
                // minted a fresh UUID after a rename or socket flap), migrate
                // its routing entry rather than orphan it. Without this, the
                // routing dict keeps an entry under the OLD id while the row
                // taps drive the NEW id, and the user perceives "click does
                // nothing" because the AUHAL state is keyed off the orphan.
                if let existingIdx = devices.firstIndex(where: { sameLogicalDevice($0, dev) }) {
                    let oldID = devices[existingIdx].id
                    if oldID != dev.id {
                        SyncCastLog.log("device id migration: \(dev.name) \(oldID.prefix(8)) → \(dev.id.prefix(8))")
                        let wasEnabled = routing[oldID]?.enabled == true
                        devices[existingIdx] = dev
                        if var oldR = routing.removeValue(forKey: oldID) {
                            oldR.deviceID = dev.id
                            routing[dev.id] = oldR
                        } else if routing[dev.id] == nil {
                            routing[dev.id] = DeviceRouting(deviceID: dev.id, enabled: false)
                        }
                        devices.sort { $0.name < $1.name }
                        detectBlackHole(in: dev)
                        if wasEnabled {
                            markSyncContextSuspect(
                                reason: "device reconnected \(dev.name)"
                            )
                            reconcileEngine()
                            reconcileBackgroundCalibration()
                            scheduleEventDrivenCalibration(
                                reason: "device reconnected \(dev.name)"
                            )
                        }
                        return
                    }
                }
                if !devices.contains(where: { $0.id == dev.id }) {
                    devices.append(dev)
                    devices.sort { $0.name < $1.name }
                }
                if routing[dev.id] == nil {
                    routing[dev.id] = DeviceRouting(deviceID: dev.id, enabled: false)
                }
                detectBlackHole(in: dev)
            case .updated(let dev):
                if let idx = devices.firstIndex(where: { $0.id == dev.id }) {
                    let previous = devices[idx]
                    let wasEnabled = routing[dev.id]?.enabled == true
                    devices[idx] = dev
                    if wasEnabled,
                       mode == .wholeHome,
                       previous.transport == .airplay2,
                       (
                           previous.host != dev.host
                           || previous.port != dev.port
                           || previous.name != dev.name
                       ) {
                        markSyncContextSuspect(
                            reason: "AirPlay endpoint updated \(dev.name)"
                        )
                        reconcileEngine()
                        reconcileBackgroundCalibration()
                        scheduleEventDrivenCalibration(
                            reason: "AirPlay endpoint updated \(dev.name)"
                        )
                    }
                } else if let idx = devices.firstIndex(where: { sameLogicalDevice($0, dev) }) {
                    // Same physical device, new SyncCast id. Migrate the
                    // routing slot so user toggles don't drop on the floor.
                    let oldID = devices[idx].id
                    SyncCastLog.log("device id migration on update: \(dev.name) \(oldID.prefix(8)) → \(dev.id.prefix(8))")
                    let wasEnabled = routing[oldID]?.enabled == true
                    devices[idx] = dev
                    if var oldR = routing.removeValue(forKey: oldID) {
                        oldR.deviceID = dev.id
                        routing[dev.id] = oldR
                    }
                    if wasEnabled {
                        markSyncContextSuspect(
                            reason: "device updated/reconnected \(dev.name)"
                        )
                        reconcileEngine()
                        reconcileBackgroundCalibration()
                        scheduleEventDrivenCalibration(
                            reason: "device updated/reconnected \(dev.name)"
                        )
                    }
                }
                detectBlackHole(in: dev)
            case .disappeared(let id):
                // Round 12: capture the device's coreAudioUID before we
                // remove it, so the wake handler can recover the user's
                // intended routing even when DPMS sleep transiently drops
                // an HDMI subdevice. Codex caught this race: without this
                // shadow set, wake handler sees an empty enabled list and
                // silently no-ops in the canonical bug scenario.
                let goneDevice = devices.first(where: { $0.id == id })
                let goneName = goneDevice?.name ?? String(id.prefix(8))
                let wasEnabled = routing[id]?.enabled ?? false
                if let goneDev = goneDevice,
                   let goneUID = goneDev.coreAudioUID,
                   goneDev.transport == .coreAudio,
                   wasEnabled {
                    transientlyMissingEnabledCoreAudioUIDs.insert(goneUID)
                }
                devices.removeAll { $0.id == id }
                // Drop the routing entry for the gone device too. Otherwise
                // it sits orphan in the dict and shows up as "?=on/off" in
                // every routingSummary() because routingSummary's name
                // lookup goes through `devices`, which no longer has this
                // id. Far worse than cosmetic: an orphan stuck at
                // enabled=true keeps `hasEnabledOutputs` true after every
                // physical device is gone, so the engine never quiesces.
                if routing.removeValue(forKey: id) != nil {
                    SyncCastLog.log("device disappeared: dropping routing entry [id=\(id.prefix(8))]")
                    // CRITICAL: trigger a reconcile so the engine actually
                    // observes the routing change. Without this, removing
                    // the dict entry alone is insufficient — the Router
                    // actor's mirror of `routing` still has the gone id at
                    // enabled=true, the AUHAL/bridge for the dead device
                    // keeps rendering to a stale AudioObjectID, and if it
                    // was the ONLY enabled output the engine fails to
                    // notice `hasEnabledOutputs` flipped false and never
                    // takes the (.running, false) → stop arm. Reviewer-
                    // flagged ship-blocker.
                    if wasEnabled {
                        stopPassiveAutosyncForRouteChange(
                            reason: "enabled device disappeared \(goneName)"
                        )
                        markSyncContextSuspect(
                            reason: "enabled device disappeared \(goneName)"
                        )
                        reconcileEngine()
                        reconcileBackgroundCalibration()
                    }
                }
            case .error(let msg):
                SyncCastLog.log("[SyncCast] discovery error: \(msg)".replacingOccurrences(of: "[SyncCast] ", with: ""))
                lastError = msg
            }
        }
    }

    /// Refresh the cached per-device connection states from the router.
    /// Pull-based: see `connectionStates` doc + the AppModel.bootstrap
    /// 1-second poller for the rationale.
    private func refreshConnectionStates() async {
        let snap = await router.connectionStatesSnapshot()
        await MainActor.run {
            let prior = self.connectionStates
            self.connectionStates = snap.states
            self.connectionFailureReasons = snap.reasons
            guard self.mode == .wholeHome else { return }
            let enabledAirPlayIDs = self.devices
                .filter {
                    $0.transport == .airplay2
                        && (self.routing[$0.id]?.enabled ?? false)
                }
                .map(\.id)
            for id in enabledAirPlayIDs {
                let old = prior[id] ?? .unknown
                let new = snap.states[id] ?? .unknown
                if old != .connected, new == .connected {
                    self.scheduleEventDrivenCalibration(
                        reason: "AirPlay receiver connected \(id.prefix(8))"
                    )
                    break
                }
            }
            if let changedID = enabledAirPlayIDs.first(where: {
                (prior[$0] ?? .unknown) != (snap.states[$0] ?? .unknown)
            }) {
                let old = prior[changedID] ?? .unknown
                let new = snap.states[changedID] ?? .unknown
                self.markSyncContextSuspect(
                    reason: "AirPlay connection state changed \(changedID.prefix(8)) \(old.rawValue)->\(new.rawValue)"
                )
                self.reconcileBackgroundCalibration()
            }
        }
    }

    /// Sample the sidecar's `actual_delivery_lag_ms` for the Sync caption.
    /// Only meaningful in whole-home + broadcaster running; everywhere
    /// else we clear the published value so the caption shows "—".
    private func refreshLocalFifoLag() async {
        guard mode == .wholeHome,
              let diag = await router.localFifoDiagnostics(),
              (diag["running"] as? Bool) == true else {
            if measuredLagMs != nil { measuredLagMs = nil }
            if mode == .wholeHome, lastLocalFifoRunning == true {
                markSyncContextSuspect(
                    reason: "local FIFO broadcaster stopped or diagnostics disappeared"
                )
                reconcileBackgroundCalibration()
            }
            lastLocalFifoRunning = false
            lastLocalBridgeResyncCounts.removeAll()
            return
        }
        let bridgeTiming = await router.localBridgeTimingDiagnostics()
        if let lag = diag["actual_delivery_lag_ms"] as? Double {
            measuredLagMs = Int(lag.rounded())
        } else if let lagInt = diag["actual_delivery_lag_ms"] as? Int {
            measuredLagMs = lagInt  // JSON sometimes ships int when float is exact
        }
        let running = (diag["running"] as? Bool) == true
        let clients = Self.diagnosticInt(diag["clients_connected"])
        let overflowDrops = Self.diagnosticInt(
            diag["chunks_dropped_due_to_overflow"]
        )
        let perClientDrops = Self.localFifoPerClientDropCount(diag)
        let currentDelay = Self.diagnosticInt(diag["current_delay_ms"])
            ?? Self.diagnosticInt(diag["delay_ms"])
        if mode == .wholeHome {
            if lastLocalFifoRunning == false, running {
                markSyncContextSuspect(
                    reason: "local FIFO broadcaster restarted"
                )
            }
            if let last = lastLocalFifoClientCount,
               let clients,
               last != clients {
                markSyncContextSuspect(
                    reason: "local FIFO bridge client count changed \(last)->\(clients)"
                )
            }
            if let last = lastLocalFifoOverflowDrops,
               let overflowDrops,
               overflowDrops > last {
                markSyncContextSuspect(
                    reason: "local FIFO overflow drops increased \(last)->\(overflowDrops)"
                )
            }
            if let last = lastLocalFifoPerClientDrops,
               let perClientDrops,
               perClientDrops > last {
                markSyncContextSuspect(
                    reason: "local FIFO per-client drops increased \(last)->\(perClientDrops)"
                )
            }
            if let last = lastLocalFifoDelayMs,
               let currentDelay,
               abs(last - currentDelay) > 20,
               currentDelay != airplayDelayMs {
                markSyncContextSuspect(
                    reason: "local FIFO reported delay changed \(last)->\(currentDelay)"
                )
            }
            for (id, timing) in bridgeTiming {
                guard let last = lastLocalBridgeResyncCounts[id],
                      timing.driftResyncCount > last else { continue }
                let reason = (
                    "local bridge resynced \(id.prefix(8)) "
                    + "\(last)->\(timing.driftResyncCount) "
                    + "reason=\(timing.driftResyncReason) "
                    + "frames=\(timing.driftResyncFrameDelta)"
                )
                markSyncContextSuspect(reason: reason)
                await router.noteWholeHomeTimingInstability(reason: reason)
            }
        }
        lastLocalFifoRunning = running
        lastLocalFifoClientCount = clients
        lastLocalFifoOverflowDrops = overflowDrops
        lastLocalFifoPerClientDrops = perClientDrops
        lastLocalFifoDelayMs = currentDelay
        lastLocalBridgeResyncCounts = bridgeTiming.mapValues {
            $0.driftResyncCount
        }
    }

    private static func diagnosticInt(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Double, value.isFinite {
            return Int(value.rounded())
        }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private static func localFifoPerClientDropCount(_ diag: [String: Any]) -> Int? {
        guard let clients = diag["per_client"] as? [[String: Any]] else {
            return nil
        }
        return clients.reduce(0) { total, row in
            total + (diagnosticInt(row["chunks_dropped"]) ?? 0)
        }
    }

    /// Two `Device` values describe the same physical/logical device when
    /// their stable transport identity matches: coreAudioUID for local,
    /// host+name for AirPlay. Used by `applyEvent` to detect when discovery
    /// minted a new SyncCast id for a device we've already seen, so we can
    /// migrate the routing entry instead of stranding it under the old id.
    private func sameLogicalDevice(_ a: Device, _ b: Device) -> Bool {
        guard a.transport == b.transport else { return false }
        switch a.transport {
        case .coreAudio:
            if let ua = a.coreAudioUID, let ub = b.coreAudioUID {
                return ua == ub
            }
            return false
        case .airplay2:
            // Bonjour service name is unique per receiver; combined with host
            // it's effectively the receiver's stable identity for our needs.
            // We deliberately do NOT match on id/UUID here — this function
            // exists precisely to bridge the case where the SyncCast id
            // differs.
            return a.name == b.name && (a.host ?? "") == (b.host ?? "")
        }
    }

    // BlackHole detection removed — SCK doesn't need it.
    private func detectBlackHole(in dev: Device) { /* no-op, retained for call-site compat */ }

    /// When the set of enabled devices changes (or whole-house mode flips),
    /// reconcile the audio engine: start it if we have BlackHole + at least
    /// one enabled output, stop it otherwise.
    private func reconcileEngine() {
        // Coalesce rapid-fire callers (toggleDevice / setVolume / toggleMute /
        // permission watcher). 30 ms is short enough that single-tap toggles
        // feel instant but still absorbs the 4-5 redundant calls that one
        // tap can fan out to (Observable invalidations, slider drag bursts).
        // We deliberately keep this short to avoid the user-reported
        // "click did nothing" symptom, which an 80 ms window made worse.
        reconcileTimer?.cancel()
        reconcileTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000)
            if Task.isCancelled { return }
            await self?.reconcileEngineAsync()
        }
    }

    /// Compact one-line dump of the current `routing` dict, with every
    /// device's name + enabled flag. Used in toggleDevice logs so we can
    /// diagnose UI ↔ model desync (user reports "tapped X but Y toggled").
    /// If the log line shows the right id was toggled but the user saw
    /// the wrong row react, the bug is in the SwiftUI layer, not the
    /// model. If the wrong id was toggled, the bug is in MainPopover's
    /// row→id binding.
    private func routingSummary() -> String {
        routing.map { (id, r) -> String in
            let name = devices.first(where: { $0.id == id })?.name ?? "?"
            return "\(name)=\(r.enabled ? "ON" : "off")"
        }
        .sorted()
        .joined(separator: ", ")
    }

    private var hasEnabledLocalAndAirPlayOutputs: Bool {
        let enabled = devices.filter { routing[$0.id]?.enabled == true }
        return enabled.contains(where: { $0.transport == .coreAudio })
            && enabled.contains(where: { $0.transport == .airplay2 })
    }

    private var hasEnabledConnectedAirPlayOutput: Bool {
        devices.contains { device in
            guard device.transport == .airplay2,
                  let route = routing[device.id],
                  route.enabled,
                  !route.muted,
                  route.volume > 0.01
            else {
                return false
            }
            return connectionStates[device.id] == .connected
        }
    }

    private var hasEnabledAirPlayOutputNotKnownDisconnected: Bool {
        devices.contains { device in
            guard device.transport == .airplay2,
                  let route = routing[device.id],
                  route.enabled,
                  !route.muted,
                  route.volume > 0.01
            else {
                return false
            }
            let state = connectionStates[device.id] ?? .unknown
            return state != .failed && state != .disconnected
        }
    }

    private func passiveAutosyncRouteSignature() -> String {
        devices.compactMap { device -> String? in
            guard let route = routing[device.id], route.enabled else { return nil }
            let transport = device.transport.rawValue
            let stableID = device.coreAudioUID ?? device.id
            let volume = Int((route.volume * 1000).rounded())
            let muted = route.muted ? "m" : "u"
            let state = connectionStates[device.id]?.rawValue ?? "unknown"
            return "\(transport):\(stableID):v\(volume):\(muted):\(state)"
        }
        .sorted()
        .joined(separator: "|")
    }

    private func passiveAutosyncLaunchContextStillCurrent(
        _ context: PassiveAutosyncLaunchContext
    ) -> Bool {
        guard mode == .wholeHome,
              streamingState == .running,
              hasEnabledLocalAndAirPlayOutputs,
              hasEnabledAirPlayOutputNotKnownDisconnected,
              passiveAutosyncRouteSignature() == context.routeSignature
        else { return false }
        guard case .unlocked = delayLockState else { return false }
        if syncContextRevision == context.syncContextRevision,
           syncContextState == context.syncContextState {
            return true
        }
        switch (context.syncContextState, syncContextState) {
        case (.suspect, .valid), (.suspect, .applied), (.valid, .applied):
            return true
        default:
            return false
        }
    }

    private var enabledAirPlayOutputNotKnownDisconnectedCount: Int {
        devices.filter { device in
            guard device.transport == .airplay2,
                  let route = routing[device.id],
                  route.enabled,
                  !route.muted,
                  route.volume > 0.01
            else {
                return false
            }
            let state = connectionStates[device.id] ?? .unknown
            return state != .failed && state != .disconnected
        }.count
    }

    private var activeAirPlayOutputCount: Int {
        devices.filter { device in
            guard device.transport == .airplay2,
                  let route = routing[device.id],
                  route.enabled,
                  !route.muted,
                  route.volume > 0.01
            else {
                return false
            }
            return connectionStates[device.id] == .connected
        }.count
    }

    private var runtimeAudioPathLabel: String {
        if mode == .stereo, AppModel.selectedStereoOutputPath == .direct {
            return "Direct Stereo"
        }
        if AppModel.requestedCaptureBackend == "tap" {
            return "Process Tap capture"
        }
        return "SCK capture"
    }

    private var runtimePathNeedsScreenRecording: Bool {
        if AppModel.requestedCaptureBackend == "tap" {
            return false
        }
        if mode == .stereo, AppModel.selectedStereoOutputPath == .direct {
            return false
        }
        return true
    }

    private func refreshScreenRecordingStatusForRuntimePath(reason: String) {
        if runtimePathNeedsScreenRecording {
            let status = ScreenRecordingTCC.current
            let granted = status == .granted
            if screenRecordingGranted != granted {
                screenRecordingGranted = granted
                SyncCastLog.log("screen-recording state changed: \(!granted) → \(granted)")
            }
            SyncCastLog.log("screen-recording status: \(status.rawValue) reason=\(reason) path=\(runtimeAudioPathLabel)")
        } else {
            if !screenRecordingGranted {
                screenRecordingGranted = true
                SyncCastLog.log("screen-recording state changed: false → true")
            }
            SyncCastLog.log("screen-recording status: not required reason=\(reason) path=\(runtimeAudioPathLabel)")
        }
    }

    private func setSyncContext(
        _ state: SyncContextState,
        reason: String,
        delayMs: Int? = nil
    ) {
        let effectiveDelayMs = delayMs ?? airplayDelayMs
        let changed = syncContextState != state
            || syncContextReason != reason
            || syncContextDelayMs != effectiveDelayMs
        if state != .dryRunReady {
            passiveDryRunExpiryTask?.cancel()
            passiveDryRunExpiryTask = nil
            pendingPassiveDryRunCandidate = nil
        }
        syncContextState = state
        syncContextReason = reason
        syncContextUpdatedAt = Date()
        syncContextDelayMs = effectiveDelayMs
        if changed {
            syncContextRevision &+= 1
            SyncCastLog.log(
                "syncContext: state=\(state.rawValue) rev=\(syncContextRevision) delay=\(effectiveDelayMs)ms reason=\(reason)"
            )
        }
    }

    private func expirePassiveDryRunCandidateIfNeeded(
        now: Date = Date(),
        source: String
    ) {
        guard syncContextState == .dryRunReady,
              let candidate = pendingPassiveDryRunCandidate
        else { return }
        let nowUnix = now.timeIntervalSince1970
        let age = nowUnix - candidate.acceptedUnix
        let maxAge = PassiveApplyGuard.acceptedDryRunMaxAgeSeconds
        let futureSkew = PassiveApplyGuard.acceptedDryRunFutureSkewSeconds
        guard nowUnix.isFinite,
              candidate.acceptedUnix.isFinite,
              age >= -futureSkew,
              age <= maxAge
        else {
            let reason: String
            if !candidate.acceptedUnix.isFinite || !nowUnix.isFinite {
                reason = "passive dry-run candidate timestamp invalid; remeasure Local+AirPlay latency"
            } else if age < -futureSkew {
                reason = "passive dry-run candidate timestamp is in the future; remeasure Local+AirPlay latency"
            } else {
                reason = "passive dry-run candidate expired after \(Int(age.rounded()))s; remeasure Local+AirPlay latency"
            }
            SyncCastLog.log(
                "passiveAutosync: \(reason) source=\(source)"
            )
            setSyncContext(.suspect, reason: reason, delayMs: candidate.currentDelayMs)
            schedulePassiveAutosync(reason: reason)
            return
        }
    }

    private func schedulePassiveDryRunCandidateExpiryCheck(
        acceptedUnix: Double,
        syncContextRevision revision: UInt64
    ) {
        passiveDryRunExpiryTask?.cancel()
        let remaining = max(
            0,
            PassiveApplyGuard.acceptedDryRunMaxAgeSeconds
                - (Date().timeIntervalSince1970 - acceptedUnix)
                + 0.25
        )
        let nanoseconds = UInt64((remaining * 1_000_000_000).rounded())
        passiveDryRunExpiryTask = Task { [weak self] in
            do {
                if nanoseconds > 0 {
                    try await Task.sleep(nanoseconds: nanoseconds)
                }
            } catch {
                return
            }
            await MainActor.run { [weak self] in
                guard let self,
                      self.syncContextState == .dryRunReady,
                      self.syncContextRevision == revision,
                      let candidate = self.pendingPassiveDryRunCandidate,
                      abs(candidate.acceptedUnix - acceptedUnix) <= 0.001
                else { return }
                self.expirePassiveDryRunCandidateIfNeeded(source: "expiry timer")
            }
        }
    }

    private func markSyncContextSuspect(
        reason: String,
        cancelPendingApply: Bool = true
    ) {
        if cancelPendingApply {
            pendingAutoCalibrationApply = nil
        }
        guard mode == .wholeHome else { return }
        if case .locked = delayLockState {
            setSyncContext(.locked, reason: "delay locked; \(reason)")
        } else {
            setSyncContext(.suspect, reason: reason)
            schedulePassiveAutosync(reason: reason)
        }
    }

    private func markSyncContextApplied(reason: String, delayMs: Int) {
        guard mode == .wholeHome else { return }
        if case .locked = delayLockState {
            setSyncContext(.locked, reason: "delay locked after apply; \(reason)", delayMs: delayMs)
        } else {
            setSyncContext(.applied, reason: reason, delayMs: delayMs)
        }
    }

    private func markPassiveBaselineValidFromDiagnostic(
        reason: String,
        request: PassiveBaselineMarkRequest
    ) async throws -> CalibrationDiagnosticServer.SyncContextMarkResult {
        guard mode == .wholeHome else {
            throw Router.CalibrationFailure.engineFailed("router not in whole-home mode")
        }
        guard case .unlocked = delayLockState else {
            throw Router.CalibrationFailure.engineFailed("delay is locked")
        }
        guard request.syncContextState == syncContextState.rawValue else {
            throw Router.CalibrationFailure.engineFailed(
                "sync context state changed before baseline mark"
            )
        }
        guard request.syncContextRevision == syncContextRevision else {
            throw Router.CalibrationFailure.engineFailed(
                "sync context revision changed before baseline mark"
            )
        }
        let currentDelay = await router.localFifoCurrentDelayMsForDiagnostics()
            ?? airplayDelayMs
        guard request.currentDelayMs == currentDelay else {
            throw Router.CalibrationFailure.engineFailed(
                "current delay changed before baseline mark"
            )
        }
        guard request.contextSignature == autoCalibrationContextSignature() else {
            throw Router.CalibrationFailure.engineFailed(
                "route context changed before baseline mark"
            )
        }
        switch syncContextState {
        case .locked, .measuring, .readyToDryRun, .dryRunReady:
            throw Router.CalibrationFailure.engineFailed(
                "sync context cannot be marked valid from state \(syncContextState.rawValue)"
            )
        case .valid, .suspect, .applied:
            break
        }
        pendingAutoCalibrationApply = nil
        setSyncContext(.valid, reason: reason)
        return CalibrationDiagnosticServer.SyncContextMarkResult(
            state: syncContextState.rawValue,
            reason: syncContextReason,
            revision: syncContextRevision,
            updatedUnix: syncContextUpdatedAt.timeIntervalSince1970
        )
    }

    private func scheduleEventDrivenCalibration(
        reason: String,
        isRetry: Bool = false,
        settleDelayS: TimeInterval? = nil
    ) {
        guard AppModel.activeAcousticCalibrationEnabled else {
            SyncCastLog.log(
                "autoCalib event skipped: active acoustic diagnostics disabled reason=\(reason)"
            )
            return
        }
        let effectiveSettleDelayS =
            settleDelayS ?? AppModel.eventDrivenCalibrationSettleS
        guard mode == .wholeHome else { return }
        guard backgroundCalibrationEnabled else {
            SyncCastLog.log(
                "autoCalib event skipped: Continuous disabled reason=\(reason)"
            )
            return
        }
        guard hasEnabledLocalAndAirPlayOutputs else {
            SyncCastLog.log(
                "autoCalib event skipped: needs local+AirPlay reason=\(reason)"
            )
            return
        }
        guard hasEnabledAirPlayOutputNotKnownDisconnected else {
            SyncCastLog.log(
                "autoCalib event skipped: AirPlay receiver failed/disconnected reason=\(reason)"
            )
            return
        }
        let eligibleAirPlayCount =
            enabledAirPlayOutputNotKnownDisconnectedCount
        guard eligibleAirPlayCount <= AppModel.autoApplyMaxAirplayReceivers else {
            SyncCastLog.log(
                "autoCalib event skipped: \(eligibleAirPlayCount) AirPlay receivers need manual diagnostics; group auto-apply is disabled reason=\(reason)"
            )
            return
        }
        guard case .unlocked = delayLockState else {
            SyncCastLog.log(
                "autoCalib event skipped: delay locked reason=\(reason)"
            )
            return
        }
        guard hasMicrophonePermission else {
            SyncCastLog.log(
                "autoCalib event skipped: microphone permission missing reason=\(reason)"
            )
            return
        }
        switch calibrationStatus {
        case .running, .requestingPermission:
            // Do not cancel the task that is already inside
            // runAutoCalibrate. Route/volume churn during measurement
            // must be observed by Router's route-revision guard so stale
            // measurements fail closed instead of surfacing as a generic
            // CancellationError.
            pendingEventDrivenCalibrationReason = reason
            SyncCastLog.log(
                "autoCalib event deferred: calibration already running reason=\(reason)"
            )
            return
        default:
            break
        }
        if !isRetry {
            eventDrivenCalibrationRetryCount = 0
        }
        eventDrivenCalibrationTask?.cancel()
        SyncCastLog.log(
            "autoCalib event scheduled in \(Int(effectiveSettleDelayS))s reason=\(reason)"
        )
        eventDrivenCalibrationTask = Task { [weak self] in
            let delayNs = UInt64(
                effectiveSettleDelayS * 1_000_000_000
            )
            do {
                try await Task.sleep(nanoseconds: delayNs)
            } catch {
                return
            }
            guard let self else { return }
            await self.runEventDrivenCalibrationIfStillValid(reason: reason)
        }
    }

    private func runEventDrivenCalibrationIfStillValid(reason: String) async {
        if Task.isCancelled { return }
        guard mode == .wholeHome,
              streamingState == .running,
              backgroundCalibrationEnabled,
              hasEnabledLocalAndAirPlayOutputs,
              hasEnabledAirPlayOutputNotKnownDisconnected,
              enabledAirPlayOutputNotKnownDisconnectedCount <=
                AppModel.autoApplyMaxAirplayReceivers,
              hasMicrophonePermission
        else {
            SyncCastLog.log(
                "autoCalib event aborted: preconditions changed reason=\(reason)"
            )
            return
        }
        guard case .unlocked = delayLockState else {
            SyncCastLog.log(
                "autoCalib event aborted: delay locked reason=\(reason)"
            )
            return
        }
        switch calibrationStatus {
        case .running, .requestingPermission:
            // Coalesce route/volume/connect churn while a full
            // calibration is already in flight. We only need the latest
            // reason for logging; after the current run finishes, the
            // route snapshot is re-read before a follow-up is scheduled.
            pendingEventDrivenCalibrationReason = reason
            SyncCastLog.log(
                "autoCalib event deferred: calibration already running reason=\(reason)"
            )
            return
        default:
            break
        }
        if let last = lastEventDrivenCalibrationAt,
           Date().timeIntervalSince(last) <
                AppModel.eventDrivenCalibrationCooldownS {
            let elapsed = Date().timeIntervalSince(last)
            let remaining = max(
                5,
                AppModel.eventDrivenCalibrationCooldownS - elapsed
            )
            SyncCastLog.log(
                "autoCalib event deferred \(Int(remaining))s: cooldown active reason=\(reason)"
            )
            eventDrivenCalibrationTask = Task { [weak self] in
                let delayNs = UInt64(remaining * 1_000_000_000)
                do {
                    try await Task.sleep(nanoseconds: delayNs)
                } catch {
                    return
                }
                guard let self else { return }
                await self.runEventDrivenCalibrationIfStillValid(reason: reason)
            }
            return
        }
        let delayRevision = userDelayRevision
        SyncCastLog.log("autoCalib event running reason=\(reason)")
        await runAutoCalibrate(
            requiresContinuousOptIn: true,
            requiredUserDelayRevision: delayRevision
        )
    }

    private func reconcileEngineAsync() async {
        SyncCastLog.log("reconcile: scrRec=\(screenRecordingGranted) state=\(streamingState.rawValue) hasEnabled=\(hasEnabledOutputs) mode=\(mode.rawValue) path=\(runtimeAudioPathLabel)")
        // We DON'T gate on screenRecordingGranted any more.
        // Reason: the only way to make macOS show the user-facing
        // Screen Recording prompt on Tahoe is to actually attempt SCK
        // (SCShareableContent / SCStream.startCapture). If we refuse to
        // try capture until "granted=true", the prompt never appears,
        // and the user is stuck. Instead we let router.start try; if it
        // throws .permissionDenied, we surface the message in lastError.
        // Engine should run when at least one output is enabled. The mode
        // determines WHICH path runs (stereo = local aggregate; wholeHome
        // = SCK → OwnTone → AirPlay receivers + local FIFO bridges), not
        // WHETHER it runs.
        let shouldRun = hasEnabledOutputs
        switch (streamingState, shouldRun) {
        case (.idle, true), (.error, true):
            streamingState = .starting
            lastError = nil
            SyncCastLog.log("reconcile: starting router (\(runtimeAudioPathLabel))")
            do {
                let snapshot = devices
                // Push routing BEFORE start so Router.start's "for dev
                // where routing[dev.id].enabled" loop actually opens
                // AUHAL for the user's selections.
                for (id, r) in routing {
                    await router.setRouting(r)
                    if r.enabled { await router.enable(deviceID: id) }
                }
                // Tell the router which mode it's in BEFORE start. The
                // sidecar uses this to decide whether to spin up the
                // local-fifo broadcaster, and the router uses it to skip
                // the local-aggregate path in whole-home mode (audio
                // there flows through OwnTone, not direct AUHAL).
                await router.setMode(mode == .wholeHome ? .wholeHome : .stereo)

                // Push AirPlay state BEFORE SCK start. AirPlay activation
                // (OwnTone spawn) is independent of SCK and must not be
                // gated by it. If SCK is slow / failing / waiting on a
                // TCC prompt, AirPlay should still kick off.
                await pushAirplayState()
                try await router.start(devices: snapshot)
                SyncCastLog.log("reconcile: router.start OK")

                // In whole-home mode, after the router has SCK capture +
                // OwnTone running, open one LocalAirPlayBridge per
                // user-enabled local CoreAudio device. These connect to
                // the sidecar's broadcast socket and render OwnTone's
                // player-clock-driven PCM through AUHAL on each device,
                // putting them on the SAME PTP timeline as the AirPlay
                // receivers.
                if mode == .wholeHome {
                    await router.startWholeHome(devices: snapshot)
                    await installCalibrationDiagnosticSocket()
                    markSyncContextSuspect(
                        reason: "whole-home route started; passive baseline required"
                    )
                }

                // Log capture health after startup. If callbacks stay at 0,
                // the active backend is not delivering audio.
                Task { [weak self] in
                    for delay in [1, 2, 4, 6] as [UInt64] {
                        try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                        guard let self else { return }
                        let report = await self.router.diagnosticCaptureReport()
                        SyncCastLog.log("capture report @ \(delay)s: \(report)")
                    }
                }
                for (id, r) in routing {
                    if r.enabled { await router.enable(deviceID: id) }
                    else         { await router.disable(deviceID: id) }
                    await router.setRouting(r)
                }
                await pushAirplayState()
                streamingState = .running
                SyncCastLog.log("reconcile: state=running")
                reconcileBackgroundCalibration()
                scheduleEventDrivenCalibration(
                    reason: "router started with whole-home AirPlay route"
                )
                if mode == .wholeHome {
                    schedulePassiveAutosync(
                        reason: "router started with whole-home AirPlay route"
                    )
                }
            } catch {
                SyncCastLog.log("reconcile: router.start FAILED: \(error)")
                lastError = "engine: \(error.localizedDescription)"
                streamingState = .error
                reconcileBackgroundCalibration()
            }
        case (.running, false):
            SyncCastLog.log("reconcile: stopping (no enabled outputs)")
            stopPassiveAutosyncForRouteChange(reason: "routing stopped")
            await router.setActiveAirplayDevices([])
            await router.stop()
            streamingState = .idle
            setSyncContext(.valid, reason: "no enabled Local+AirPlay route")
            reconcileBackgroundCalibration()
        case (.running, true):
            // ORDER MATTERS. Router holds its own copy of `routing`
            // (Router.routing) which `syncLocalOutputs` reads to decide
            // which AUHALs to open/close. If we call syncLocalOutputs
            // BEFORE pushing the latest routing snapshot, it sees stale
            // enabled-flags and leaves a just-disabled output's AUHAL
            // running — symptom the user reports as "I turned MBP off
            // but it kept playing while only Xiaomi should have been on".
            // Push routing first, THEN reconcile the AUHAL set, THEN
            // push AirPlay state.
            SyncCastLog.log("reconcile: pushing routing updates + syncing local outputs")
            for (_, r) in routing {
                await router.setRouting(r)
            }
            // Mode-specific reconciliation:
            //   - .stereo: syncLocalOutputs opens/closes per-device AUHAL
            //     and the private aggregate as needed (existing path).
            //   - .wholeHome: skip local AUHAL reconciliation; instead
            //     update the bridge set against the new enabled-device
            //     list. AirPlay receivers are handled by pushAirplayState
            //     below (same path as before).
            switch mode {
            case .stereo:
                await router.syncLocalOutputs(devices: devices)
            case .wholeHome:
                await router.startWholeHome(devices: devices)
                // Re-install calibration diagnostic socket. The Router's
                // installer is idempotent (returns early if a server is
                // already bound), so this is safe on every reconcile and
                // also self-healing if some prior transition tore the
                // socket down without an immediate reinstall.
                await installCalibrationDiagnosticSocket()
            }
            await pushAirplayState()
            reconcileBackgroundCalibration()
        default:
            SyncCastLog.log("reconcile: no-op (state=\(streamingState.rawValue) shouldRun=\(shouldRun))")
            break
        }
    }

    func shutdownForTermination() async -> Bool {
        SyncCastLog.log("AppModel: termination cleanup requested")
        await stopPassiveAutosyncForTermination()
        await router.stop()
        let routerState = await router.state
        if routerState == .error {
            let error = await router.lastError ?? "unknown router stop failure"
            SyncCastLog.log("AppModel: termination cleanup blocked: \(error)")
            lastError = error
            streamingState = .error
            return false
        }
        return true
    }

    private func stopPassiveAutosyncForTermination() async {
        passiveAutosyncEventTask?.cancel()
        passiveAutosyncEventTask = nil
        pendingPassiveAutosyncReason = nil
        passiveAutosyncTask?.cancel()
        passiveAutosyncTask = nil
        guard let process = passiveAutosyncProcess else {
            passiveAutosyncRunID = nil
            if case .requestingPermission = passiveAutosyncState {
                passiveAutosyncState = .failed(
                    verdict: "terminated",
                    detail: "passive check stopped during app quit"
                )
            }
            return
        }
        let pid = process.processIdentifier
        SyncCastLog.log(
            "passiveAutosync: terminating controller during app quit pid=\(pid)"
        )
        process.terminate()
        let exited = await Task.detached(priority: .utility) { () -> Bool in
            for _ in 0..<20 {
                if !process.isRunning { return true }
                usleep(50_000)
            }
            return !process.isRunning
        }.value
        if !exited && process.isRunning {
            SyncCastLog.log(
                "passiveAutosync: force killing controller during app quit pid=\(pid)"
            )
            _ = Darwin.kill(pid, SIGKILL)
        }
        passiveAutosyncProcess = nil
        passiveAutosyncRunID = nil
        passiveAutosyncState = .failed(
            verdict: "terminated",
            detail: "passive check stopped during app quit"
        )
    }

    /// Sync the enabled AirPlay devices over to the sidecar / OwnTone.
    private func pushAirplayState() async {
        let enabledAirplay = devices.filter {
            $0.transport == .airplay2 && (routing[$0.id]?.enabled ?? false)
        }
        let beforeTimingEpoch: UInt64
        if mode == .wholeHome {
            beforeTimingEpoch = await router.airplayTimingEpochForDiagnostics()
        } else {
            beforeTimingEpoch = 0
        }
        SyncCastLog.log("pushAirplayState: enabledAirplay=\(enabledAirplay.map { $0.name })")
        for dev in enabledAirplay {
            SyncCastLog.log("  registerAirplayDevice: \(dev.name) host=\(dev.host ?? "?") port=\(dev.port ?? 7000)")
            await router.registerAirplayDevice(
                id: dev.id,
                name: dev.name,
                host: dev.host ?? "",
                port: dev.port ?? 7000
            )
            if let r = routing[dev.id] {
                await router.setAirplayVolume(
                    id: dev.id,
                    volume: r.muted ? 0 : r.volume
                )
            }
        }
        SyncCastLog.log("setActiveAirplayDevices: ids=\(enabledAirplay.map { $0.id.prefix(8) })")
        await router.setActiveAirplayDevices(enabledAirplay.map { $0.id })
        if mode == .wholeHome, !enabledAirplay.isEmpty {
            let afterTimingEpoch = await router.airplayTimingEpochForDiagnostics()
            if afterTimingEpoch != beforeTimingEpoch {
                markSyncContextSuspect(
                    reason: "AirPlay timing epoch changed \(beforeTimingEpoch)->\(afterTimingEpoch)"
                )
                reconcileBackgroundCalibration()
            }
        }
    }

    // MARK: - Intents

    /// Switch between stereo and whole-home modes. Tears down the current
    /// pipeline (silence for ~200 ms during transition is acceptable),
    /// disables every device that's not selectable in the new mode, then
    /// reconciles the engine so the new mode's path comes up.
    ///
    /// Why disable non-selectable devices automatically: if the user had
    /// MBP扬声器 enabled in stereo mode and switches to whole-home, that
    /// device is still selectable (whole-home covers everything). But if
    /// they had Xiaomi enabled in whole-home and switch to stereo, Xiaomi
    /// is no longer reachable — leaving its routing.enabled=true would
    /// surface as `lastError` on every reconcile. Cleaner to flip it off
    /// at mode-switch time and let the user re-pick the next time they
    /// switch back.
    func setMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        // Single-flight: if a previous setMode is still running its async
        // stop+reconcile, drop this call. Without this, three quick
        // clicks (whole-home → stereo → whole-home over ~150 ms) can
        // each spawn their own Task — and the .stopping → .idle window
        // mid-transition lets the second click see streamingState != .stopping
        // and spawn an overlapping teardown that races with the first.
        // Security Review C2.
        if modeTransitioning {
            SyncCastLog.log("setMode: dropping \(newMode.rawValue) — transition in flight")
            return
        }
        SyncCastLog.log("setMode: \(mode.rawValue) → \(newMode.rawValue)")
        mode = newMode
        if newMode == .wholeHome {
            markSyncContextSuspect(reason: "mode switched to whole-home")
        } else {
            stopPassiveAutosyncForRouteChange(reason: "mode switched out of whole-home")
            setSyncContext(.valid, reason: "stereo path; no Local+AirPlay baseline active")
            lastLocalFifoRunning = nil
            lastLocalFifoClientCount = nil
            lastLocalFifoOverflowDrops = nil
            lastLocalFifoPerClientDrops = nil
            lastLocalFifoDelayMs = nil
            lastLocalBridgeResyncCounts.removeAll()
        }
        refreshScreenRecordingStatusForRuntimePath(reason: "mode changed")
        pendingAutoCalibrationApply = nil
        // Disable any device that the new mode can't drive.
        for dev in devices {
            if !isSelectableInMode(dev, mode: newMode),
               var r = routing[dev.id], r.enabled {
                r.enabled = false
                routing[dev.id] = r
            }
        }
        // Force a full pipeline restart by stopping the engine, then
        // reconciling. The two modes have different audio paths
        // (stereo: local Aggregate AUHAL; wholeHome: SCK→OwnTone→
        // bridges + AirPlay) and switching live without a full stop
        // would leave us in an inconsistent state — e.g. an aggregate
        // still open while OwnTone is also driving the same physical
        // devices via bridges, which would double-play. The brief
        // (~200 ms) silence during transition is well below the
        // user-perceptible UI feedback threshold.
        //
        // Race avoidance: set streamingState = .stopping BEFORE we
        // launch the async stop Task. While the stop is in flight,
        // any concurrent toggle/setVolume that fires reconcileEngine
        // hits the (.stopping, _) → default arm in reconcileEngineAsync
        // and is a no-op, instead of the (.idle, true) arm which
        // would otherwise double-start the router (Code Review H1).
        if streamingState == .running || streamingState == .starting {
            streamingState = .stopping
            modeTransitioning = true
            Task { [weak self] in
                guard let self else { return }
                await self.router.stop()
                await MainActor.run {
                    self.streamingState = .idle
                    self.modeTransitioning = false
                    self.reconcileEngine()
                    self.reconcileBackgroundCalibration()
                }
            }
        } else {
            // No engine to stop — the new mode just needs reconciliation.
            // No async work, so no need to flip the transition flag here.
            reconcileEngine()
            reconcileBackgroundCalibration()
        }
        if newMode == .wholeHome {
            scheduleEventDrivenCalibration(reason: "mode switched to whole-home")
        } else {
            eventDrivenCalibrationTask?.cancel()
            postApplyValidationTask?.cancel()
        }
    }

    func toggleDevice(_ id: String) {
        let r = routing[id] ?? DeviceRouting(deviceID: id)
        setDeviceEnabled(!r.enabled, for: id)
    }

    func setDeviceEnabled(_ enabled: Bool, for id: String) {
        var r = routing[id] ?? DeviceRouting(deviceID: id)
        let oldEnabled = r.enabled
        if oldEnabled == enabled {
            let name = devices.first(where: { $0.id == id })?.name ?? id
            SyncCastLog.log("setDeviceEnabled: \(name) [id=\(id.prefix(8))] already \(enabled ? "ON" : "off"). routing: { \(routingSummary()) }")
            return
        }
        r.enabled = enabled
        routing[id] = r
        pendingAutoCalibrationApply = nil
        let name = devices.first(where: { $0.id == id })?.name ?? id
        // Emit BOTH the toggled id and the post-toggle full routing so
        // we can prove or disprove the user-reported "click X but Y
        // toggled" symptom from the log alone (no Console.app needed).
        SyncCastLog.log("toggleDevice: \(name) [id=\(id.prefix(8))] \(oldEnabled ? "ON" : "off") → \(r.enabled ? "ON" : "off"). routing: { \(routingSummary()) }")
        markSyncContextSuspect(reason: "device toggled \(name)")
        reconcileEngine()
        reconcileBackgroundCalibration()
        scheduleEventDrivenCalibration(reason: "device toggled \(name)")
    }

    func setVolume(_ value: Float, for id: String) {
        var r = routing[id] ?? DeviceRouting(deviceID: id)
        let old = r.volume
        r.volume = max(0, min(1, value))
        routing[id] = r
        let crossedAudibleGate = (old > 0.01) != (r.volume > 0.01)
        let changedEnoughForResync =
            abs(old - r.volume) > 0.03 || crossedAudibleGate
        if changedEnoughForResync {
            pendingAutoCalibrationApply = nil
        }
        reconcileEngine()
        reconcileBackgroundCalibration()
        if changedEnoughForResync {
            let name = devices.first(where: { $0.id == id })?.name ?? id
            markSyncContextSuspect(reason: "volume changed \(name)")
            scheduleEventDrivenCalibration(reason: "volume changed \(name)")
        }
    }

    func toggleMute(_ id: String) {
        let r = routing[id] ?? DeviceRouting(deviceID: id)
        setMute(!r.muted, for: id)
    }

    func setMute(_ muted: Bool, for id: String) {
        var r = routing[id] ?? DeviceRouting(deviceID: id)
        let oldMuted = r.muted
        if oldMuted == muted {
            let name = devices.first(where: { $0.id == id })?.name ?? id
            SyncCastLog.log("setMute: \(name) [id=\(id.prefix(8))] already \(muted ? "muted" : "unmuted")")
            return
        }
        r.muted = muted
        routing[id] = r
        pendingAutoCalibrationApply = nil
        reconcileEngine()
        reconcileBackgroundCalibration()
        let name = devices.first(where: { $0.id == id })?.name ?? id
        SyncCastLog.log("setMute: \(name) [id=\(id.prefix(8))] \(oldMuted ? "muted" : "unmuted") → \(muted ? "muted" : "unmuted")")
        markSyncContextSuspect(reason: "mute changed \(name)")
        scheduleEventDrivenCalibration(reason: "mute changed \(name)")
    }

    /// Live-tune the whole-home FIFO delay. In-memory update is immediate
    /// (snappy UI); IPC + UserDefaults write is debounced 200 ms so a
    /// continuous drag doesn't spam either subsystem.
    func setAirplayDelay(_ ms: Int) {
        let clamped = min(max(ms, AppModel.airplayDelayMsRange.lowerBound),
                          AppModel.airplayDelayMsRange.upperBound)
        if clamped != airplayDelayMs {
            userDelayRevision &+= 1
            pendingAutoCalibrationApply = nil
            eventDrivenCalibrationTask?.cancel()
            postApplyValidationTask?.cancel()
            markSyncContextSuspect(reason: "manual delay changed")
            if case .locked = delayLockState {
                delayLockState = .locked(at: clamped)
                UserDefaults.standard.set(
                    clamped, forKey: AppModel.airplayDelayLockedAtKey
                )
                SyncCastLog.log("delayLock: moved locked target to \(clamped)ms")
            }
        }
        airplayDelayMs = clamped
        airplayDelayCommitTask?.cancel()
        airplayDelayCommitTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }
            await self?.commitAirplayDelay(clamped)
        }
    }

    /// Push the debounced value, then persist on success. On failure we
    /// leave the in-memory value as-is so the next drag retries.
    @discardableResult
    private func commitAirplayDelay(
        _ ms: Int,
        shouldStillApply: (() -> Bool)? = nil
    ) async -> Bool {
        let rollbackMs = airplayDelayMs
        if let shouldStillApply, !shouldStillApply() {
            return false
        }
        do {
            let applied = try await router.setLocalFifoDelayMs(ms)
            if let shouldStillApply, !shouldStillApply() {
                do {
                    let restored = try await router.setLocalFifoDelayMs(rollbackMs)
                    airplayDelayMs = restored
                    UserDefaults.standard.set(
                        restored, forKey: AppModel.airplayDelayMsKey
                    )
                    SyncCastLog.log(
                        "airplayDelay auto-apply aborted after commit; restored \(restored)ms"
                    )
                } catch {
                    lastError = "restore delay: \(error.localizedDescription)"
                    SyncCastLog.log(
                        "airplayDelay restore failed after aborted auto-apply: \(error.localizedDescription)"
                    )
                }
                return false
            }
            if applied != airplayDelayMs { airplayDelayMs = applied }
            UserDefaults.standard.set(applied, forKey: AppModel.airplayDelayMsKey)
            SyncCastLog.log("airplayDelay applied: \(applied)ms")
            return true
        } catch {
            lastError = "set delay: \(error.localizedDescription)"
            SyncCastLog.log("airplayDelay apply failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Reset the slider to the canonical default — same path as a drag.
    func resetAirplayDelayToDefault() {
        setAirplayDelay(AppModel.defaultAirplayDelayMs)
    }

    // MARK: - Auto-calibration UI flow
    //
    // Pipeline: ensure mic permission → call Router.runCalibration →
    // apply returned delta to airplayDelayMs (which already pushes via
    // the debounced setter, including persistence). We surface progress
    // and completion via the `calibrationStatus` enum so the popover
    // can show a spinner / result text.

    enum CalibrationStatus: Equatable, Sendable {
        case idle
        case requestingPermission
        case running
        case completed(deltaMs: Int, confidence: Double, applied: Bool)
        case failed(String)
    }

    var calibrationStatus: CalibrationStatus = .idle
    /// Live "Calibrating <Device> (n/total)…" progress string emitted by
    /// Router.runCalibration's per-device sequential loop. nil unless the
    /// runner is mid-sweep. The MainPopover renders this as a sub-caption
    /// under the spinner so the user sees which device is being measured
    /// (sequential calibration takes ≈30s for 4 devices, vs the previous
    /// ≈15s simultaneous run that produced unusable output).
    var calibrationProgress: String? = nil

    /// Kick off auto-calibration. Safe to call from the main actor on a
    /// button tap. Uses `effectiveMicID` (W3) as the input device.
    func runAutoCalibrate(
        requiresContinuousOptIn: Bool = false,
        requiredUserDelayRevision: UInt64? = nil,
        isPostApplyValidation: Bool = false
    ) async {
        eventDrivenRetryScheduledForCurrentAttempt = false
        var pausedContinuousForThisRun = false
        defer {
            if pausedContinuousForThisRun && continuousPausedForManual {
                continuousPausedForManual = false
                reconcileBackgroundCalibration()
            }
        }
        switch calibrationStatus {
        case .running, .requestingPermission:
            SyncCastLog.log("autoCalib: ignored duplicate start request")
            return
        default:
            break
        }
        guard AppModel.activeAcousticCalibrationEnabled else {
            SyncCastLog.log("autoCalib: blocked because active acoustic diagnostics are disabled")
            calibrationStatus = .failed(
                AppModel.activeAcousticCalibrationDisabledMessage
            )
            return
        }
        defer { finishAutoCalibrateAttempt() }
        defer { calibrationProgress = nil }
        guard mode == .wholeHome else {
            calibrationStatus = .failed("Switch to whole-home mode first")
            return
        }
        guard streamingState == .running else {
            calibrationStatus = .failed("Audio capture isn't running")
            return
        }
        let enabledForCalibration = devices.filter {
            routing[$0.id]?.enabled == true
        }
        let enabledAirplayCount = enabledForCalibration.filter {
            $0.transport == .airplay2
        }.count
        guard enabledForCalibration.contains(where: { $0.transport == .coreAudio }),
              enabledForCalibration.contains(where: { $0.transport == .airplay2 }) else {
            calibrationStatus = .failed(
                "Auto-calibration needs at least one local speaker and one AirPlay speaker"
            )
            return
        }
        // Permission gate. AVCaptureDevice never re-prompts after a deny,
        // so on .denied we tell the user to open System Settings.
        let auth = AVCaptureDevice.authorizationStatus(for: .audio)
        switch auth {
        case .denied, .restricted:
            calibrationStatus = .failed(
                "Microphone access denied — open System Settings → Privacy → Microphone"
            )
            return
        case .notDetermined:
            calibrationStatus = .requestingPermission
            let granted = await requestMicrophonePermission()
            if !granted {
                calibrationStatus = .failed("Microphone access not granted")
                return
            }
        case .authorized:
            break
        @unknown default:
            calibrationStatus = .failed("Unexpected microphone permission state")
            return
        }

        // Pause continuous calibration while the manual run plays click
        // pulses; resume after (success OR failure).
        if backgroundCalibrationActive || backgroundCalibrationEnabled {
            continuousPausedForManual = true
            pausedContinuousForThisRun = true
            reconcileBackgroundCalibration()
        }

        calibrationStatus = .running
        setSyncContext(.measuring, reason: "active diagnostic calibration running")
        calibrationProgress = "Preparing…"
        let snapshot = devices  // immutable Sendable copy
        let micID = effectiveMicID
        do {
            let delta = try await router.runCalibration(
                devices: snapshot,
                microphoneDeviceID: micID,
                pulseCount: 5,
                progress: { [weak self] msg in
                    Task { @MainActor [weak self] in
                        self?.calibrationProgress = msg
                    }
                }
            )
            // `deltaMs` is the ABSOLUTE TARGET delay-line value
            // (= max(airplay τ) − max(local τ_bridge_bypass)), NOT a
            // delta to add. SET the slider directly. The previous
            // `+= delta` was wrong: Phase 1 measures local τ via the
            // bridge's direct calibration-tone synthesis which bypasses
            // the broadcaster delay-line, so re-runs would double up
            // until clamped. See `Router.CalibrationDelta.deltaMs`.
            let next = max(
                AppModel.airplayDelayMsRange.lowerBound,
                min(AppModel.airplayDelayMsRange.upperBound, delta.deltaMs)
            )
            if requiresContinuousOptIn &&
                !eventDrivenCalibrationCanStillApply(
                    stage: "apply",
                    requiredUserDelayRevision: requiredUserDelayRevision
                ) {
                pendingAutoCalibrationApply = nil
                calibrationStatus = .failed("Event calibration canceled")
                return
            }
            var finalDeltaMs = delta.deltaMs
            var finalConfidence = delta.confidence
            let allowPostApplyValidation =
                requiresContinuousOptIn && !isPostApplyValidation
            var applied = await applyAutoCalibrationTargetIfTrusted(
                next, confidence: delta.confidence,
                perDeviceUncertaintyMs: delta.perDeviceUncertaintyMs,
                enabledAirplayCount: enabledAirplayCount,
                requiresContinuousOptIn: requiresContinuousOptIn,
                requiredUserDelayRevision: requiredUserDelayRevision,
                allowPostApplyValidation: allowPostApplyValidation
            )
            if !applied,
               shouldAutoVerifyHeldCalibrationTarget(
                   next, confidence: delta.confidence,
                   perDeviceUncertaintyMs: delta.perDeviceUncertaintyMs
               ) {
                if requiresContinuousOptIn &&
                    !eventDrivenCalibrationCanStillApply(
                        stage: "verify",
                        requiredUserDelayRevision: requiredUserDelayRevision
                    ) {
                    pendingAutoCalibrationApply = nil
                    calibrationStatus = .failed("Event calibration canceled")
                    return
                }
                let verifyContext = autoCalibrationContextSignature()
                calibrationProgress = "Verifying stable AirPlay delay..."
                let verifyDelta = try await router.runCalibration(
                    devices: snapshot,
                    microphoneDeviceID: micID,
                    pulseCount: 5,
                    progress: { [weak self] msg in
                        Task { @MainActor [weak self] in
                            self?.calibrationProgress = "Verify: \(msg)"
                        }
                    }
                )
                let verifyNext = max(
                    AppModel.airplayDelayMsRange.lowerBound,
                    min(AppModel.airplayDelayMsRange.upperBound,
                        verifyDelta.deltaMs)
                )
                finalDeltaMs = verifyDelta.deltaMs
                finalConfidence = min(delta.confidence, verifyDelta.confidence)
                if autoCalibrationContextSignature() == verifyContext {
                    applied = await applyAutoCalibrationTargetIfTrusted(
                        verifyNext, confidence: verifyDelta.confidence,
                        perDeviceUncertaintyMs: verifyDelta.perDeviceUncertaintyMs,
                        enabledAirplayCount: enabledAirplayCount,
                        requiresContinuousOptIn: requiresContinuousOptIn,
                        requiredUserDelayRevision: requiredUserDelayRevision,
                        allowPostApplyValidation: allowPostApplyValidation
                    )
                } else {
                    pendingAutoCalibrationApply = nil
                    applied = false
                    SyncCastLog.log(
                        "autoCalib: verify result ignored because route context changed"
                    )
                }
            }
            if !applied {
                markSyncContextSuspect(
                    reason: "active diagnostic measurement did not apply; passive evidence still required",
                    cancelPendingApply: false
                )
            }
            calibrationStatus = .completed(
                deltaMs: finalDeltaMs,
                confidence: finalConfidence,
                applied: applied,
            )
        } catch {
            SyncCastLog.log("autoCalib: failed \(error)")
            markSyncContextSuspect(
                reason: "active diagnostic calibration failed: \(error)",
                cancelPendingApply: false
            )
            calibrationStatus = .failed("\(error)")
            if requiresContinuousOptIn {
                scheduleEventDrivenCalibrationRetryIfUseful(
                    error,
                    requiredUserDelayRevision: requiredUserDelayRevision
                )
            }
        }
        calibrationProgress = nil

    }

    private func scheduleEventDrivenCalibrationRetryIfUseful(
        _ error: Error,
        requiredUserDelayRevision: UInt64?
    ) {
        guard eventDrivenCalibrationCanStillApply(
                stage: "retry",
                requiredUserDelayRevision: requiredUserDelayRevision
              ),
              eventDrivenCalibrationRetryCount <
                AppModel.maxEventDrivenCalibrationRetries,
              shouldRetryEventDrivenCalibration(after: error)
        else { return }
        eventDrivenCalibrationRetryCount += 1
        eventDrivenRetryScheduledForCurrentAttempt = true
        let reason = "retry \(eventDrivenCalibrationRetryCount) after insufficient confidence"
        SyncCastLog.log("autoCalib event retry scheduled: \(reason)")
        scheduleEventDrivenCalibration(
            reason: reason,
            isRetry: true,
            settleDelayS: AppModel.eventDrivenCalibrationRetrySettleS
        )
    }

    private func shouldRetryEventDrivenCalibration(after error: Error) -> Bool {
        String(describing: error).contains("insufficientConfidence")
    }

    private func schedulePostApplySettleValidation(
        appliedMs: Int,
        requiredUserDelayRevision: UInt64?
    ) {
        guard eventDrivenCalibrationCanStillApply(
            stage: "post-apply schedule",
            requiredUserDelayRevision: requiredUserDelayRevision
        ) else { return }
        postApplyValidationTask?.cancel()
        let settle = AppModel.postApplyValidationSettleS
        SyncCastLog.log(
            "autoCalib post-apply validation scheduled in \(Int(settle))s after applying \(appliedMs)ms"
        )
        postApplyValidationTask = Task { [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(settle * 1_000_000_000)
                )
            } catch {
                return
            }
            guard let self else { return }
            guard self.eventDrivenCalibrationCanStillApply(
                stage: "post-apply validation",
                requiredUserDelayRevision: requiredUserDelayRevision
            ) else { return }
            await self.runPostApplySettleValidation(
                appliedMs: appliedMs,
                requiredUserDelayRevision: requiredUserDelayRevision
            )
        }
    }

    private func runPostApplySettleValidation(
        appliedMs: Int,
        requiredUserDelayRevision: UInt64?
    ) async {
        postApplyValidationTask = nil
        SyncCastLog.log(
            "autoCalib post-apply validation running after applying \(appliedMs)ms"
        )
        await runAutoCalibrate(
            requiresContinuousOptIn: true,
            requiredUserDelayRevision: requiredUserDelayRevision,
            isPostApplyValidation: true
        )
        SyncCastLog.log(
            "autoCalib post-apply validation finished after applying \(appliedMs)ms; current=\(airplayDelayMs)ms"
        )
    }

    private func eventDrivenCalibrationCanStillApply(
        stage: String,
        requiredUserDelayRevision: UInt64? = nil
    ) -> Bool {
        if Task.isCancelled {
            SyncCastLog.log("autoCalib event \(stage) aborted: task cancelled")
            return false
        }
        if let requiredUserDelayRevision,
           userDelayRevision != requiredUserDelayRevision {
            SyncCastLog.log(
                "autoCalib event \(stage) aborted: user changed delay during calibration"
            )
            return false
        }
        guard mode == .wholeHome,
              streamingState == .running,
              backgroundCalibrationEnabled,
              hasEnabledLocalAndAirPlayOutputs,
              hasEnabledAirPlayOutputNotKnownDisconnected,
              enabledAirPlayOutputNotKnownDisconnectedCount <=
                AppModel.autoApplyMaxAirplayReceivers,
              hasMicrophonePermission
        else {
            SyncCastLog.log(
                "autoCalib event \(stage) aborted: preconditions changed"
            )
            return false
        }
        guard case .unlocked = delayLockState else {
            SyncCastLog.log("autoCalib event \(stage) aborted: delay locked")
            return false
        }
        return true
    }

    private func finishAutoCalibrateAttempt() {
        if case .completed = calibrationStatus {
            lastEventDrivenCalibrationAt = Date()
            eventDrivenCalibrationRetryCount = 0
        }
        if let reason = pendingEventDrivenCalibrationReason {
            guard !eventDrivenRetryScheduledForCurrentAttempt else {
                SyncCastLog.log(
                    "autoCalib event pending reason held until retry completes: \(reason)"
                )
                return
            }
            pendingEventDrivenCalibrationReason = nil
            scheduleEventDrivenCalibration(
                reason: "pending after calibration: \(reason)"
            )
        }
    }

    /// Clear a non-idle status. Bound to the popover's "Dismiss" button
    /// on completed/failed states.
    func dismissCalibrationStatus() {
        calibrationStatus = .idle
    }

    private func applyAutoCalibrationTargetIfTrusted(
        _ targetMs: Int,
        confidence: Double,
        perDeviceUncertaintyMs: [String: Int],
        enabledAirplayCount: Int,
        requiresContinuousOptIn: Bool = false,
        requiredUserDelayRevision: UInt64? = nil,
        allowPostApplyValidation: Bool = false
    ) async -> Bool {
        if requiresContinuousOptIn &&
            !eventDrivenCalibrationCanStillApply(
                stage: "apply",
                requiredUserDelayRevision: requiredUserDelayRevision
            ) {
            pendingAutoCalibrationApply = nil
            return false
        }
        guard case .unlocked = delayLockState else {
            SyncCastLog.log(
                "autoCalib: recommended \(targetMs)ms conf=\(String(format: "%.2f", confidence)) but delay is locked"
            )
            pendingAutoCalibrationApply = nil
            return false
        }
        guard confidence >= AppModel.autoApplyConfidenceFloor else {
            SyncCastLog.log(
                "autoCalib: recommended \(targetMs)ms rejected: low confidence \(String(format: "%.2f", confidence))"
            )
            pendingAutoCalibrationApply = nil
            return false
        }
        guard enabledAirplayCount <= AppModel.autoApplyMaxAirplayReceivers else {
            SyncCastLog.log(
                "autoCalib: recommended \(targetMs)ms held: AirPlay group has \(enabledAirplayCount) receivers and group mic measurement cannot prove every receiver contributed"
            )
            pendingAutoCalibrationApply = nil
            return false
        }
        guard autoCalibrationUncertaintyIsAcceptable(perDeviceUncertaintyMs) else {
            let reason = autoCalibrationMaxUncertainty(perDeviceUncertaintyMs)
                .map { "high uncertainty \($0)ms" } ?? "missing uncertainty"
            SyncCastLog.log(
                "autoCalib: recommended \(targetMs)ms rejected: \(reason)"
            )
            pendingAutoCalibrationApply = nil
            return false
        }

        let current = airplayDelayMs
        let jump = abs(targetMs - current)
        if jump <= AppModel.autoApplyMaxSingleJumpMs {
            pendingAutoCalibrationApply = nil
            airplayDelayCommitTask?.cancel()
            let applied = await commitAirplayDelay(
                targetMs,
                shouldStillApply: requiresContinuousOptIn
                    ? { [weak self] in
                        self?.eventDrivenCalibrationCanStillApply(
                            stage: "commit",
                            requiredUserDelayRevision: requiredUserDelayRevision
                        ) ?? false
                    }
                    : nil
            )
            guard applied else {
                return false
            }
            SyncCastLog.log(
                "autoCalib: applied \(targetMs)ms conf=\(String(format: "%.2f", confidence)) jump=\(jump)ms"
            )
            markSyncContextApplied(
                reason: "active diagnostic applied small correction",
                delayMs: targetMs
            )
            if allowPostApplyValidation {
                schedulePostApplySettleValidation(
                    appliedMs: targetMs,
                    requiredUserDelayRevision: requiredUserDelayRevision
                )
            }
            return true
        }

        let now = Date()
        let context = autoCalibrationContextSignature()
        if let pending = pendingAutoCalibrationApply,
           pending.contextSignature == context,
           now.timeIntervalSince(pending.timestamp) <= AppModel.autoApplyRepeatWindowS,
           abs(pending.targetMs - targetMs) <= AppModel.autoApplyRepeatAgreementMs {
            pendingAutoCalibrationApply = nil
            airplayDelayCommitTask?.cancel()
            let applied = await commitAirplayDelay(
                targetMs,
                shouldStillApply: requiresContinuousOptIn
                    ? { [weak self] in
                        self?.eventDrivenCalibrationCanStillApply(
                            stage: "commit",
                            requiredUserDelayRevision: requiredUserDelayRevision
                        ) ?? false
                    }
                    : nil
            )
            guard applied else {
                return false
            }
            SyncCastLog.log(
                "autoCalib: applied repeated large correction \(targetMs)ms conf=\(String(format: "%.2f", confidence)) prior=\(pending.targetMs)ms jump=\(jump)ms"
            )
            markSyncContextApplied(
                reason: "active diagnostic applied repeat-confirmed correction",
                delayMs: targetMs
            )
            if allowPostApplyValidation {
                schedulePostApplySettleValidation(
                    appliedMs: targetMs,
                    requiredUserDelayRevision: requiredUserDelayRevision
                )
            }
            return true
        }

        pendingAutoCalibrationApply = PendingAutoCalibrationApply(
            targetMs: targetMs, timestamp: now,
            contextSignature: context
        )
        SyncCastLog.log(
            "autoCalib: recommended \(targetMs)ms held for repeat confirmation; current=\(current)ms jump=\(jump)ms conf=\(String(format: "%.2f", confidence))"
        )
        return false
    }

    private func shouldAutoVerifyHeldCalibrationTarget(
        _ targetMs: Int,
        confidence: Double,
        perDeviceUncertaintyMs: [String: Int]
    ) -> Bool {
        guard case .unlocked = delayLockState else { return false }
        guard confidence >= AppModel.autoApplyConfidenceFloor else {
            return false
        }
        guard autoCalibrationUncertaintyIsAcceptable(perDeviceUncertaintyMs) else {
            return false
        }
        guard abs(targetMs - airplayDelayMs) >
            AppModel.autoApplyMaxSingleJumpMs else {
            return false
        }
        guard let pending = pendingAutoCalibrationApply else {
            return false
        }
        guard pending.contextSignature == autoCalibrationContextSignature() else {
            return false
        }
        return abs(pending.targetMs - targetMs) <=
            AppModel.autoApplyRepeatAgreementMs
    }

    private func autoCalibrationMaxUncertainty(_ values: [String: Int]) -> Int? {
        values.values.filter { $0 >= 0 }.max()
    }

    private func autoCalibrationUncertaintyIsAcceptable(_ values: [String: Int]) -> Bool {
        guard let max = autoCalibrationMaxUncertainty(values) else {
            return false
        }
        return max <= AppModel.autoApplyMaxUncertaintyMs
    }

    private func autoCalibrationContextSignature() -> String {
        let enabled = devices.compactMap { dev -> String? in
            guard let route = routing[dev.id], route.enabled else {
                return nil
            }
            let volumeBucket = Int((route.volume * 100).rounded())
            return [
                dev.id,
                dev.transport.rawValue,
                dev.host ?? "",
                "\(dev.port ?? 0)",
                "v\(volumeBucket)",
                route.muted ? "muted" : "unmuted",
                "d\(route.manualDelayMs)",
            ].joined(separator: ":")
        }
        .sorted()
        .joined(separator: ";")
        return [
            "mode=\(mode.rawValue)",
            "mic=\(effectiveMicID.map(String.init) ?? "default")",
            "enabled=\(enabled)",
        ].joined(separator: "|")
    }

    /// Install the calibration diagnostic socket. Used by
    /// `scripts/calibration_test.sh` to drive a one-shot calibration
    /// from the CLI without touching the menubar UI. Whole-home only;
    /// the Router tears the socket down on stop / mode-leave.
    ///
    /// Path is `/tmp/syncast-<uid>.calibration.sock` to mirror the
    /// existing sidecar control-socket convention.
    private func installCalibrationDiagnosticSocket() async {
        let path = AppModel.calibrationDiagnosticSocketURL
        // Provider closure: hops to the MainActor to snapshot the live
        // device list + selected mic. Returning nil tells the server
        // to reply with an error (router not ready).
        await router.startCalibrationDiagnosticServer(
            socketPath: path,
            provider: { [weak self] in
                guard let self else { return nil }
                let routerStates = await self.router.connectionStatesSnapshot()
                let appliedDelayMs = await self.router
                    .localFifoCurrentDelayMsForDiagnostics()
                let airplayTimingEpoch = await self.router
                    .airplayTimingEpochForDiagnostics()
                return await MainActor.run { [weak self] () -> CalibrationDiagnosticServer.Snapshot? in
                    guard let self else { return nil }
                    guard self.mode == .wholeHome,
                          self.streamingState == .running else { return nil }
                    self.expirePassiveDryRunCandidateIfNeeded(
                        source: "diagnostic snapshot"
                    )
                    let enabled = self.devices.filter {
                        self.routing[$0.id]?.enabled == true
                    }
                    let enabledAirPlay = enabled.filter {
                        $0.transport == .airplay2
                    }
                    let activeAirPlay = enabledAirPlay.filter {
                        routerStates.states[$0.id] == .connected
                    }
                    let airplayConnectionStates = Dictionary(
                        uniqueKeysWithValues: enabledAirPlay.map {
                            (
                                $0.id,
                                (routerStates.states[$0.id] ?? .unknown).rawValue
                            )
                        }
                    )
                    guard enabled.contains(where: { $0.transport == .coreAudio }),
                          !enabledAirPlay.isEmpty
                    else {
                        return nil
                    }
                    return CalibrationDiagnosticServer.Snapshot(
                        devices: self.devices,
                        microphoneDeviceID: self.effectiveMicID,
                        currentDelayMs: appliedDelayMs ?? self.airplayDelayMs,
                        contextSignature: self.autoCalibrationContextSignature(),
                        delayLocked: {
                            if case .locked = self.delayLockState { return true }
                            return false
                        }(),
                        enabledAirplayCount: enabledAirPlay.count,
                        activeAirplayCount: activeAirPlay.count,
                        airplayTimingEpoch: airplayTimingEpoch,
                        airplayConnectionStates: airplayConnectionStates,
                        syncContextState: self.syncContextState.rawValue,
                        syncContextReason: self.syncContextReason,
                        syncContextRevision: self.syncContextRevision,
                        syncContextUpdatedUnix: self.syncContextUpdatedAt
                            .timeIntervalSince1970,
                        passiveDryRunTargetDelayMs: self
                            .pendingPassiveDryRunCandidate?.targetDelayMs,
                        passiveDryRunCurrentDelayMs: self
                            .pendingPassiveDryRunCandidate?.currentDelayMs,
                        passiveDryRunContextSignature: self
                            .pendingPassiveDryRunCandidate?.contextSignature,
                        passiveDryRunCaptureBackend: self
                            .pendingPassiveDryRunCandidate?.captureBackend,
                        passiveDryRunEnabledAirplayCount: self
                            .pendingPassiveDryRunCandidate?
                            .enabledAirplayCount,
                        passiveDryRunActiveAirplayCount: self
                            .pendingPassiveDryRunCandidate?
                            .activeAirplayCount,
                        passiveDryRunAirplayTimingEpoch: self
                            .pendingPassiveDryRunCandidate?
                            .airplayTimingEpoch,
                        passiveDryRunAcceptedFromSyncContextState: self
                            .pendingPassiveDryRunCandidate?
                            .acceptedFromSyncContextState,
                        passiveDryRunAcceptedFromSyncContextRevision: self
                            .pendingPassiveDryRunCandidate?
                            .acceptedFromSyncContextRevision,
                        passiveDryRunAcceptedSyncContextRevision: self
                            .pendingPassiveDryRunCandidate?
                            .acceptedSyncContextRevision,
                        passiveDryRunSessionRoot: self
                            .pendingPassiveDryRunCandidate?.sessionRoot,
                        passiveDryRunControlReport: self
                            .pendingPassiveDryRunCandidate?.controlReport,
                        passiveDryRunAcceptedUnix: self
                            .pendingPassiveDryRunCandidate?.acceptedUnix
                    )
                }
            },
            activeProbeMethodsEnabled: AppModel.activeAcousticCalibrationEnabled,
            delayApplier: { [weak self] ms in
                guard let self else {
                    throw Router.CalibrationFailure.engineFailed("app gone")
                }
                return try await self.applyCalibrationDelayFromDiagnostic(ms)
            },
            passiveDelayApplier: { [weak self] candidate in
                guard let self else {
                    throw Router.CalibrationFailure.engineFailed("app gone")
                }
                return try await self.applyPassiveDelayCandidateFromDiagnostic(candidate)
            },
            syncContextMarker: { [weak self] reason, request in
                guard let self else {
                    throw Router.CalibrationFailure.engineFailed("app gone")
                }
                return try await self.markPassiveBaselineValidFromDiagnostic(
                    reason: reason,
                    request: request
                )
            }
        )
    }

    private func applyCalibrationDelayFromDiagnostic(_ ms: Int) async throws -> Int {
        guard case .unlocked = delayLockState else {
            throw Router.CalibrationFailure.engineFailed("delay is locked")
        }
        let clamped = min(max(ms, AppModel.airplayDelayMsRange.lowerBound),
                          AppModel.airplayDelayMsRange.upperBound)
        airplayDelayCommitTask?.cancel()
        let applied = try await router.setLocalFifoDelayMs(clamped)
        airplayDelayMs = applied
        UserDefaults.standard.set(applied, forKey: AppModel.airplayDelayMsKey)
        pendingAutoCalibrationApply = nil
        SyncCastLog.log("airplayDelay applied by diagnostic calibration: \(applied)ms")
        markSyncContextApplied(
            reason: "diagnostic passive/app RPC applied delay",
            delayMs: applied
        )
        return applied
    }

    private func applyPassiveDelayCandidateFromDiagnostic(
        _ candidate: PassiveApplyCandidate
    ) async throws -> Int {
        guard let candidateState = candidate.syncContextState,
              candidateState == syncContextState.rawValue
        else {
            throw Router.CalibrationFailure.engineFailed(
                "sync context state changed before passive delay apply"
            )
        }
        guard let candidateRevision = candidate.syncContextRevision,
              candidateRevision == syncContextRevision
        else {
            throw Router.CalibrationFailure.engineFailed(
                "sync context revision changed before passive delay apply"
            )
        }
        let currentDelay = await router.localFifoCurrentDelayMsForDiagnostics()
            ?? airplayDelayMs
        guard candidate.currentDelayMs == currentDelay else {
            throw Router.CalibrationFailure.engineFailed(
                "current delay changed before passive delay apply"
            )
        }
        guard candidate.contextSignature == autoCalibrationContextSignature() else {
            throw Router.CalibrationFailure.engineFailed(
                "route context changed before passive delay apply"
            )
        }
        let enabledAirPlay = devices.filter { device in
            guard device.transport == .airplay2,
                  let route = routing[device.id],
                  route.enabled,
                  !route.muted,
                  route.volume > 0.01
            else {
                return false
            }
            let state = connectionStates[device.id] ?? .unknown
            return state != .failed && state != .disconnected
        }
        guard candidate.enabledAirplayCount == enabledAirPlay.count else {
            throw Router.CalibrationFailure.engineFailed(
                "enabled AirPlay count changed before passive delay apply"
            )
        }
        let routerStates = await router.connectionStatesSnapshot()
        let activeAirPlayCount = enabledAirPlay.filter {
            routerStates.states[$0.id] == .connected
        }.count
        guard activeAirPlayCount == enabledAirPlay.count else {
            throw Router.CalibrationFailure.engineFailed(
                "AirPlay outputs are not fully connected before passive delay apply"
            )
        }
        let liveEpoch = await router.airplayTimingEpochForDiagnostics()
        guard candidate.airplayTimingEpoch == liveEpoch else {
            throw Router.CalibrationFailure.engineFailed(
                "AirPlay timing epoch changed before passive delay apply"
            )
        }
        if let candidateBackend = candidate.captureBackend?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() {
            let liveBackend = await router.captureBackendNameForDiagnostics()
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard candidateBackend == liveBackend else {
                throw Router.CalibrationFailure.engineFailed(
                    "capture backend changed before passive delay apply"
                )
            }
        }
        guard candidateState == syncContextState.rawValue,
              candidateRevision == syncContextRevision,
              candidate.contextSignature == autoCalibrationContextSignature()
        else {
            throw Router.CalibrationFailure.engineFailed(
                "sync context changed during passive delay apply freshness check"
            )
        }
        return try await applyCalibrationDelayFromDiagnostic(candidate.targetDelayMs)
    }

    // MARK: - Passive no-probe autosync

    private struct PassiveAutosyncRunSummary {
        let verdict: String
        let detail: String
        let sessionRoot: String?
        let controlReport: String?
        let stage: String?
        let nextAction: String?
        let safetyIssue: Bool
        let dryRunWouldApply: Bool
        let targetDelayMs: Int?
        let currentDelayMs: Int?
        let contextSignature: String?
        let captureBackend: String?
        let enabledAirplayCount: Int?
        let activeAirplayCount: Int?
        let airplayTimingEpoch: UInt64?
        let candidateSyncContextState: String?
        let candidateSyncContextRevision: UInt64?
    }

    private static let passiveAutosyncSamples = 3
    private static let passiveAutosyncSampleIntervalSec = 20
    private static let passiveAutosyncDurationSec = 4
    private static var passiveAutosyncMaxSteps: Int {
        passiveAutosyncAllowsAcceptedDelayApply ? 7 : 4
    }
    private static let passiveAutosyncEventSettleS: TimeInterval = 15
    private static let passiveAutosyncEventCooldownS: TimeInterval = 180
    private static let passiveAutosyncCancelKillDelayS: TimeInterval = 5

    func runPassiveAutosyncOnce() {
        Task { await runManualPassiveAutosync() }
    }

    private func runManualPassiveAutosync() async {
        guard !passiveAutosyncBusy else { return }
        guard passiveAutosyncCorePreflightAllowsMicRequest() else { return }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            runPassiveAutosync(reason: "manual Passive Check")
        case .notDetermined:
            let permissionRunID = UUID()
            passiveAutosyncRunID = permissionRunID
            passiveAutosyncState = .requestingPermission(startedAt: Date())
            SyncCastLog.log(
                "passiveAutosync: requesting microphone permission for manual Passive Check"
            )
            let granted = await requestMicrophonePermission()
            guard passiveAutosyncRunID == permissionRunID else {
                SyncCastLog.log(
                    "passiveAutosync: microphone permission result ignored after cancel/stale run"
                )
                return
            }
            guard granted else {
                passiveAutosyncRunID = nil
                passiveAutosyncState = .failed(
                    verdict: "mic_denied",
                    detail: "microphone access was not granted"
                )
                SyncCastLog.log(
                    "passiveAutosync: microphone permission not granted"
                )
                return
            }
            passiveAutosyncRunID = nil
            pendingPassiveAutosyncReason = nil
            passiveAutosyncState = .idle
            runPassiveAutosync(reason: "manual Passive Check")
        case .denied, .restricted:
            passiveAutosyncState = .failed(
                verdict: "mic_denied",
                detail: "microphone access is not available"
            )
        @unknown default:
            passiveAutosyncState = .failed(
                verdict: "mic_denied",
                detail: "unexpected microphone permission state"
            )
        }
    }

    private func passiveAutosyncCorePreflightAllowsMicRequest() -> Bool {
        guard passiveAutosyncActiveProbeLaneAvailable() else {
            passiveAutosyncState = .failed(
                verdict: "active_diagnostics_running",
                detail: "turn off active acoustic diagnostics before Passive Check"
            )
            return false
        }
        guard mode == .wholeHome else {
            passiveAutosyncState = .failed(
                verdict: "not_ready",
                detail: "switch to AirPlay experimental mode first"
            )
            return false
        }
        guard streamingState == .running else {
            passiveAutosyncState = .failed(
                verdict: "not_ready",
                detail: "start playback routing before passive sync check"
            )
            return false
        }
        guard hasEnabledLocalAndAirPlayOutputs else {
            passiveAutosyncState = .failed(
                verdict: "not_ready",
                detail: "enable at least one local output and one AirPlay output"
            )
            return false
        }
        guard hasEnabledAirPlayOutputNotKnownDisconnected else {
            passiveAutosyncState = .failed(
                verdict: "not_ready",
                detail: "AirPlay receiver is not available"
            )
            return false
        }
        guard case .unlocked = delayLockState else {
            passiveAutosyncState = .failed(
                verdict: "delay_locked",
                detail: "unlock the manual delay before passive sync check"
            )
            return false
        }
        return true
    }

    private func runPassiveAutosync(reason: String) {
        guard !passiveAutosyncBusy else { return }
        guard passiveAutosyncActiveProbeLaneAvailable() else {
            passiveAutosyncState = .failed(
                verdict: "active_diagnostics_running",
                detail: "turn off active acoustic diagnostics before Passive Check"
            )
            return
        }
        guard mode == .wholeHome else {
            passiveAutosyncState = .failed(
                verdict: "not_ready",
                detail: "switch to AirPlay experimental mode first"
            )
            return
        }
        guard streamingState == .running else {
            passiveAutosyncState = .failed(
                verdict: "not_ready",
                detail: "start playback routing before passive sync check"
            )
            return
        }
        guard hasEnabledLocalAndAirPlayOutputs else {
            passiveAutosyncState = .failed(
                verdict: "not_ready",
                detail: "enable at least one local output and one AirPlay output"
            )
            return
        }
        guard hasEnabledAirPlayOutputNotKnownDisconnected else {
            passiveAutosyncState = .failed(
                verdict: "not_ready",
                detail: "AirPlay receiver is not available"
            )
            return
        }
        guard case .unlocked = delayLockState else {
            passiveAutosyncState = .failed(
                verdict: "delay_locked",
                detail: "unlock the manual delay before passive sync check"
            )
            return
        }
        guard hasMicrophonePermission else {
            passiveAutosyncState = .failed(
                verdict: "mic_denied",
                detail: "microphone access is not available"
            )
            return
        }
        guard let toolRoot = AppModel.resolvePassiveToolRoot() else {
            passiveAutosyncState = .failed(
                verdict: "tools_missing",
                detail: "passive tools were not found in the app bundle or ~/syncast"
            )
            return
        }
        guard let python = AppModel.resolvePassivePython() else {
            passiveAutosyncState = .failed(
                verdict: "python_missing",
                detail: "python3 runtime was not found"
            )
            return
        }

        let stateRoot = AppModel.passiveAutosyncStateRoot()
        let runsRoot = stateRoot.appendingPathComponent("runs", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: runsRoot,
            withIntermediateDirectories: true
        )
        let runID = UUID()
        passiveAutosyncRunID = runID
        let stamp = "\(Int(Date().timeIntervalSince1970))-\(getpid())-\(runID.uuidString.prefix(8))"
        let output = runsRoot.appendingPathComponent("autosync-\(stamp).json")
        let stdout = runsRoot.appendingPathComponent("autosync-\(stamp).stdout")
        let stderr = runsRoot.appendingPathComponent("autosync-\(stamp).stderr")
        let launchContext = PassiveAutosyncLaunchContext(
            syncContextState: syncContextState,
            syncContextRevision: syncContextRevision,
            routeSignature: passiveAutosyncRouteSignature()
        )

        passiveAutosyncArtifactPath = output.path
        passiveAutosyncSessionRoot = nil
        passiveAutosyncState = .running(startedAt: Date(), output: output.path)
        SyncCastLog.log(
            "passiveAutosync: starting no-probe controller reason=\(reason) output=\(output.path) tools=\(toolRoot.path)"
        )

        passiveAutosyncTask = Task { [weak self] in
            guard let self else { return }
            await self.runPassiveAutosyncProcess(
                python: python,
                toolRoot: toolRoot,
                stateRoot: stateRoot,
                output: output,
                stdout: stdout,
                stderr: stderr,
                runID: runID,
                launchContext: launchContext
            )
        }
    }

    private func passiveAutosyncActiveProbeLaneAvailable() -> Bool {
        guard AppModel.activeAcousticCalibrationEnabled else { return true }
        switch calibrationStatus {
        case .running, .requestingPermission:
            return false
        case .idle, .completed, .failed:
            break
        }
        return !backgroundCalibrationActive
            && !backgroundCalibrationEnabled
            && postApplyValidationTask == nil
    }

    private func schedulePassiveAutosync(
        reason: String,
        settleDelayS: TimeInterval? = nil
    ) {
        guard mode == .wholeHome else { return }
        guard streamingState == .running else {
            SyncCastLog.log(
                "passiveAutosync event skipped: engine not running reason=\(reason)"
            )
            return
        }
        guard hasEnabledLocalAndAirPlayOutputs else {
            SyncCastLog.log(
                "passiveAutosync event skipped: needs local+AirPlay reason=\(reason)"
            )
            return
        }
        guard hasEnabledAirPlayOutputNotKnownDisconnected else {
            SyncCastLog.log(
                "passiveAutosync event skipped: AirPlay receiver failed/disconnected reason=\(reason)"
            )
            return
        }
        guard case .unlocked = delayLockState else {
            SyncCastLog.log(
                "passiveAutosync event skipped: delay locked reason=\(reason)"
            )
            return
        }
        guard syncContextState == .suspect else {
            SyncCastLog.log(
                "passiveAutosync event skipped: sync context \(syncContextState.rawValue) is not suspect reason=\(reason)"
            )
            return
        }
        guard hasMicrophonePermission else {
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                pendingPassiveAutosyncReason = reason
            }
            SyncCastLog.log(
                "passiveAutosync event skipped: microphone permission missing reason=\(reason)"
            )
            return
        }
        if passiveAutosyncBusy {
            pendingPassiveAutosyncReason = reason
            SyncCastLog.log(
                "passiveAutosync event deferred: check already running reason=\(reason)"
            )
            return
        }
        let now = Date()
        if let last = lastPassiveAutosyncFinishedAt,
           now.timeIntervalSince(last) <
                AppModel.passiveAutosyncEventCooldownS,
           lastPassiveAutosyncFinishedRevision == syncContextRevision {
            let remaining = max(
                5,
                AppModel.passiveAutosyncEventCooldownS
                    - now.timeIntervalSince(last)
            )
            passiveAutosyncEventTask?.cancel()
            SyncCastLog.log(
                "passiveAutosync event deferred \(Int(remaining))s: cooldown active reason=\(reason)"
            )
            let expectedSyncContextState = syncContextState
            let expectedSyncContextRevision = syncContextRevision
            passiveAutosyncEventTask = Task { [weak self] in
                do {
                    try await Task.sleep(
                        nanoseconds: UInt64(remaining * 1_000_000_000)
                    )
                } catch {
                    return
                }
                guard let self else { return }
                await self.runScheduledPassiveAutosyncIfStillValid(
                    reason: reason,
                    expectedSyncContextState: expectedSyncContextState,
                    expectedSyncContextRevision: expectedSyncContextRevision
                )
            }
            return
        } else if let last = lastPassiveAutosyncFinishedAt,
                  now.timeIntervalSince(last) <
                    AppModel.passiveAutosyncEventCooldownS,
                  let lastRevision = lastPassiveAutosyncFinishedRevision {
            SyncCastLog.log(
                "passiveAutosync event bypassing cooldown: sync revision changed last=\(lastRevision) current=\(syncContextRevision) reason=\(reason)"
            )
        }

        let settle = settleDelayS ?? AppModel.passiveAutosyncEventSettleS
        passiveAutosyncEventTask?.cancel()
        SyncCastLog.log(
            "passiveAutosync event scheduled in \(Int(settle))s reason=\(reason)"
        )
        let expectedSyncContextState = syncContextState
        let expectedSyncContextRevision = syncContextRevision
        passiveAutosyncEventTask = Task { [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(settle * 1_000_000_000)
                )
            } catch {
                return
            }
            guard let self else { return }
            await self.runScheduledPassiveAutosyncIfStillValid(
                reason: reason,
                expectedSyncContextState: expectedSyncContextState,
                expectedSyncContextRevision: expectedSyncContextRevision
            )
        }
    }

    private func runScheduledPassiveAutosyncIfStillValid(
        reason: String,
        expectedSyncContextState: SyncContextState,
        expectedSyncContextRevision: UInt64
    ) async {
        if Task.isCancelled { return }
        passiveAutosyncEventTask = nil
        guard syncContextState == expectedSyncContextState,
              syncContextRevision == expectedSyncContextRevision
        else {
            SyncCastLog.log(
                "passiveAutosync event aborted: stale sync context expected=\(expectedSyncContextState.rawValue)#\(expectedSyncContextRevision) actual=\(syncContextState.rawValue)#\(syncContextRevision) reason=\(reason)"
            )
            return
        }
        guard mode == .wholeHome,
              streamingState == .running,
              hasEnabledLocalAndAirPlayOutputs,
              hasEnabledAirPlayOutputNotKnownDisconnected,
              hasMicrophonePermission
        else {
            SyncCastLog.log(
                "passiveAutosync event aborted: preconditions changed reason=\(reason)"
            )
            return
        }
        guard case .unlocked = delayLockState else {
            SyncCastLog.log(
                "passiveAutosync event aborted: delay locked reason=\(reason)"
            )
            return
        }
        guard !passiveAutosyncBusy else {
            pendingPassiveAutosyncReason = reason
            SyncCastLog.log(
                "passiveAutosync event deferred: check already running reason=\(reason)"
            )
            return
        }
        runPassiveAutosync(reason: "auto: \(reason)")
    }

    func cancelPassiveAutosync() {
        passiveAutosyncEventTask?.cancel()
        passiveAutosyncEventTask = nil
        pendingPassiveAutosyncReason = nil
        if let process = passiveAutosyncProcess {
            passiveAutosyncState = .canceling(
                startedAt: Date(),
                output: passiveAutosyncArtifactPath
            )
            let runID = passiveAutosyncRunID
            let pid = process.processIdentifier
            process.terminate()
            SyncCastLog.log("passiveAutosync: cancel requested")
            Task { [weak self, weak process] in
                do {
                    try await Task.sleep(
                        nanoseconds: UInt64(
                            AppModel.passiveAutosyncCancelKillDelayS
                                * 1_000_000_000
                        )
                    )
                } catch {
                    return
                }
                guard let self,
                      let process,
                      self.passiveAutosyncRunID == runID,
                      self.passiveAutosyncProcess === process,
                      process.isRunning
                else { return }
                SyncCastLog.log(
                    "passiveAutosync: force killing canceled controller pid=\(pid)"
                )
                _ = Darwin.kill(pid, SIGKILL)
            }
            return
        }
        passiveAutosyncTask?.cancel()
        passiveAutosyncTask = nil
        passiveAutosyncRunID = nil
        passiveAutosyncState = .failed(
            verdict: "canceled",
            detail: "passive check canceled"
        )
        SyncCastLog.log("passiveAutosync: canceled before process launch")
    }

    private func runPassiveAutosyncProcess(
        python: URL,
        toolRoot: URL,
        stateRoot: URL,
        output: URL,
        stdout: URL,
        stderr: URL,
        runID: UUID,
        launchContext: PassiveAutosyncLaunchContext
    ) async {
        let process = Process()
        process.executableURL = python
        process.currentDirectoryURL = toolRoot
        var arguments = [
            "scripts/passive_autosync_controller.py",
            "--state-root", stateRoot.path,
            "--socket", AppModel.calibrationDiagnosticSocketURL.path,
            "--samples", "\(AppModel.passiveAutosyncSamples)",
            "--sample-interval-sec", "\(AppModel.passiveAutosyncSampleIntervalSec)",
            "--duration-sec", "\(AppModel.passiveAutosyncDurationSec)",
            "--output", output.path,
            "--execute",
            "--max-steps", "\(AppModel.passiveAutosyncMaxSteps)",
        ]
        if AppModel.passiveAutosyncAllowsAcceptedDelayApply {
            arguments.append("--allow-accepted-delay-apply")
        }
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("SYNCAST_PASSIVE_") {
            environment.removeValue(forKey: key)
        }
        environment["PYTHONPATH"] = "scripts"
        environment["PATH"] =
            "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        environment["SYNCAST_PASSIVE_SOCKET"] =
            AppModel.calibrationDiagnosticSocketURL.path
        environment["SYNCAST_PASSIVE_WORKFLOW_GUARD"] = "enforce"
        environment.removeValue(forKey: "SYNCAST_ENABLE_ACTIVE_CALIBRATION")
        environment.removeValue(forKey: "SYNCAST_ALLOW_AUDIBLE_PROBES")
        environment.removeValue(forKey: "SYNCAST_CONFIRM_AUDIBLE_PROBE_TEST")
        environment.removeValue(forKey: "SYNCAST_ACTIVE_PROBE_LAB_SESSION")
        environment.removeValue(forKey: "SYNCAST_ACTIVE_PROBE_LAB_SESSION_FILE")
        process.environment = environment

        FileManager.default.createFile(atPath: stdout.path, contents: nil)
        FileManager.default.createFile(atPath: stderr.path, contents: nil)
        let stdoutHandle = try? FileHandle(forWritingTo: stdout)
        let stderrHandle = try? FileHandle(forWritingTo: stderr)
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle

        guard !Task.isCancelled, passiveAutosyncRunID == runID else {
            stdoutHandle?.closeFile()
            stderrHandle?.closeFile()
            return
        }
        passiveAutosyncProcess = process

        do {
            try process.run()
        } catch {
            stdoutHandle?.closeFile()
            stderrHandle?.closeFile()
            guard passiveAutosyncRunID == runID else { return }
            passiveAutosyncProcess = nil
            passiveAutosyncTask = nil
            passiveAutosyncRunID = nil
            passiveAutosyncState = .failed(
                verdict: "launch_failed",
                detail: "\(error)"
            )
            SyncCastLog.log("passiveAutosync: launch failed \(error)")
            return
        }

        let exitCode = await Task.detached(priority: .utility) {
            process.waitUntilExit()
            return process.terminationStatus
        }.value
        stdoutHandle?.closeFile()
        stderrHandle?.closeFile()
        guard passiveAutosyncRunID == runID else { return }
        let wasCanceling: Bool
        if case .canceling = passiveAutosyncState {
            wasCanceling = true
        } else {
            wasCanceling = false
        }
        passiveAutosyncProcess = nil
        passiveAutosyncTask = nil
        passiveAutosyncRunID = nil
        lastPassiveAutosyncFinishedAt = Date()
        lastPassiveAutosyncFinishedRevision = launchContext.syncContextRevision

        if wasCanceling {
            passiveAutosyncState = .failed(
                verdict: "canceled",
                detail: "passive check canceled"
            )
            SyncCastLog.log(
                "passiveAutosync: canceled exit=\(exitCode) artifact=\(output.path)"
            )
            return
        }

        if Task.isCancelled { return }
        guard passiveAutosyncLaunchContextStillCurrent(launchContext) else {
            passiveAutosyncState = .failed(
                verdict: "stale_context",
                detail: "route, delay, or sync context changed during passive check"
            )
            SyncCastLog.log(
                "passiveAutosync: stale context after run expected=\(launchContext.syncContextState.rawValue)#\(launchContext.syncContextRevision) actual=\(syncContextState.rawValue)#\(syncContextRevision) artifact=\(output.path)"
            )
            drainPendingPassiveAutosync(reason: "stale context after passive check")
            return
        }
        let summary = AppModel.readPassiveAutosyncSummary(
            output: output,
            exitCode: exitCode
        )
        passiveAutosyncSessionRoot = summary.sessionRoot
        if let controlReport = summary.controlReport {
            passiveAutosyncArtifactPath = controlReport
        } else {
            passiveAutosyncArtifactPath = output.path
        }
        if exitCode == 0 {
            passiveAutosyncState = .completed(
                verdict: summary.verdict,
                detail: summary.detail
            )
            await markPassiveDryRunReadyIfCurrent(summary)
        } else {
            passiveAutosyncState = .failed(
                verdict: summary.verdict,
                detail: summary.detail
            )
        }
        SyncCastLog.log(
            "passiveAutosync: finished exit=\(exitCode) verdict=\(summary.verdict) stage=\(summary.stage ?? "") next=\(summary.nextAction ?? "") detail=\(summary.detail) artifact=\(passiveAutosyncArtifactPath ?? output.path)"
        )
        if let pending = pendingPassiveAutosyncReason {
            drainPendingPassiveAutosync(
                reason: "passive check finished",
                pendingReason: pending
            )
        }
    }

    private func drainPendingPassiveAutosync(
        reason: String,
        pendingReason: String? = nil
    ) {
        guard let pending = pendingReason ?? pendingPassiveAutosyncReason else { return }
        pendingPassiveAutosyncReason = nil
        schedulePassiveAutosync(
            reason: "pending after \(reason): \(pending)",
            settleDelayS: 5
        )
    }

    private func stopPassiveAutosyncForRouteChange(reason: String) {
        passiveAutosyncEventTask?.cancel()
        passiveAutosyncEventTask = nil
        pendingPassiveAutosyncReason = nil
        guard let process = passiveAutosyncProcess else {
            if passiveAutosyncTask != nil {
                passiveAutosyncTask?.cancel()
                passiveAutosyncTask = nil
                passiveAutosyncRunID = nil
                passiveAutosyncState = .failed(
                    verdict: "canceled",
                    detail: "passive check canceled: \(reason)"
                )
                SyncCastLog.log(
                    "passiveAutosync: canceled before controller launch after route change reason=\(reason)"
                )
                return
            }
            if case .requestingPermission = passiveAutosyncState {
                passiveAutosyncRunID = nil
                passiveAutosyncState = .failed(
                    verdict: "canceled",
                    detail: "passive check canceled: \(reason)"
                )
            }
            return
        }
        let pid = process.processIdentifier
        process.terminate()
        passiveAutosyncTask?.cancel()
        passiveAutosyncTask = nil
        passiveAutosyncProcess = nil
        passiveAutosyncRunID = nil
        passiveAutosyncState = .failed(
            verdict: "canceled",
            detail: "passive check canceled: \(reason)"
        )
        SyncCastLog.log(
            "passiveAutosync: terminating controller after route change pid=\(pid) reason=\(reason)"
        )
        Task { [weak process] in
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(
                        AppModel.passiveAutosyncCancelKillDelayS
                            * 1_000_000_000
                    )
                )
            } catch {
                return
            }
            guard let process, process.isRunning else { return }
            SyncCastLog.log(
                "passiveAutosync: force killing route-change controller pid=\(pid)"
            )
            _ = Darwin.kill(pid, SIGKILL)
        }
    }

    private static func readPassiveAutosyncSummary(
        output: URL,
        exitCode: Int32
    ) -> PassiveAutosyncRunSummary {
        guard let data = try? Data(contentsOf: output),
              let raw = try? JSONSerialization.jsonObject(with: data),
              let payload = raw as? [String: Any]
        else {
            return PassiveAutosyncRunSummary(
                verdict: "exit_\(exitCode)",
                detail: "controller did not write a readable JSON report",
                sessionRoot: nil,
                controlReport: nil,
                stage: "controller_report",
                nextAction: "inspect stdout/stderr and rerun Passive Check",
                safetyIssue: true,
                dryRunWouldApply: false,
                targetDelayMs: nil,
                currentDelayMs: nil,
                contextSignature: nil,
                captureBackend: nil,
                enabledAirplayCount: nil,
                activeAirplayCount: nil,
                airplayTimingEpoch: nil,
                candidateSyncContextState: nil,
                candidateSyncContextRevision: nil
            )
        }
        let execution = payload["execution"] as? [String: Any]
        let chainSummary = payload["chainSummary"] as? [String: Any]
        let sessionRoot =
            stringField(execution, "sessionRoot")
            ?? stringField(payload, "sessionRoot")
        let controlReport =
            stringField(execution, "controlReport")
            ?? sessionRoot.map { URL(fileURLWithPath: $0)
                .appendingPathComponent("control_report.json").path
            }
        let controlPayload: [String: Any]?
        if let controlReport {
            controlPayload = jsonDictionary(at: URL(fileURLWithPath: controlReport))
        } else {
            controlPayload = nil
        }
        let passiveApplyResult =
            dictionaryField(execution, "passiveApplyResult")
            ?? dictionaryField(controlPayload, "passiveApplyResult")
        let passiveAcceptedApplyResult =
            dictionaryField(execution, "passiveAcceptedApplyResult")
        let passiveRollbackResult =
            dictionaryField(execution, "passiveRollbackResult")
        let passiveAcceptedApplyVerdict =
            stringField(execution, "passiveAcceptedApplyVerdict")
        let passiveRollbackVerdict =
            stringField(execution, "passiveRollbackVerdict")
        let verdict =
            stringField(execution, "verdict")
            ?? stringField(chainSummary, "finalVerdict")
            ?? stringField(controlPayload, "verdict")
            ?? stringField(payload, "verdict")
            ?? "exit_\(exitCode)"
        let reason =
            stringField(execution, "reason")
            ?? stringField(controlPayload, "reason")
            ?? stringField(payload, "reason")
            ?? ""
        let nextAction =
            stringField(execution, "nextAction")
            ?? stringField(chainSummary, "finalNextAction")
            ?? stringField(controlPayload, "nextAction")
            ?? stringField(payload, "nextAction")
        let stage =
            stringField(execution, "blockingStage")
            ?? stringField(controlPayload, "blockingStage")
            ?? stringField(execution, "phase")
            ?? stringField(controlPayload, "phase")
            ?? stringField(controlPayload, "readinessStage")
            ?? stringField(payload, "readinessStage")
        let workflow =
            stringField(execution, "readinessRecommendedWorkflow")
            ?? stringField(controlPayload, "readinessRecommendedWorkflow")
            ?? stringField(payload, "recommendedWorkflow")
        let emittedAudio =
            boolField(execution, "emitsAudio")
            || boolField(controlPayload, "emitsAudio")
            || boolField(chainSummary, "emitsAudio")
        let appliedDelay =
            boolField(execution, "appliesDelay")
            || boolField(controlPayload, "appliesDelay")
            || boolField(chainSummary, "appliesDelay")
            || boolField(passiveApplyResult, "applied")
            || boolField(passiveAcceptedApplyResult, "applied")
            || boolField(passiveRollbackResult, "applied")
        let acceptedApplySummary = passiveAcceptedApplyVerdict.map { verdict in
            "acceptedApply=\(verdict)"
        }
        let rollbackSummary = passiveRollbackVerdict.map { verdict in
            var value = "rollback=\(verdict)"
            if let previous = intField(passiveRollbackResult, "previousDelayMs"),
               let applied = intField(passiveRollbackResult, "appliedDelayMs") {
                value += " \(previous)->\(applied)ms"
            }
            return value
        }
        let safetyIssue =
            boolField(execution, "safetyIssue")
            || boolField(controlPayload, "safetyIssue")
            || emittedAudio
            || (appliedDelay && !AppModel.passiveAutosyncAllowsAcceptedDelayApply)
        let safety = [
            "mic=\(boolField(execution, "opensMicrophone") || boolField(controlPayload, "opensMicrophone") || boolField(chainSummary, "opensMicrophone"))",
            "audio=\(emittedAudio)",
            "delay=\(appliedDelay)",
        ].joined(separator: "/")
        let essentialDetailParts = [
            safetyIssue ? "SAFETY issue reported" : nil,
            stage.map { "stage=\($0)" },
            workflow.map { "workflow=\($0)" },
            acceptedApplySummary,
            rollbackSummary,
        ]
            .compactMap { value -> String? in
                guard let value,
                      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { return nil }
                return value
            }
        let secondaryDetailParts = [
            reason,
            nextAction.map { "next=\($0)" },
        ]
            .compactMap { value -> String? in
                guard let value,
                      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { return nil }
                return value
            }
        let detailParts = essentialDetailParts + secondaryDetailParts + [safety]
        let detail: String
        if detailParts.count > 6 {
            let secondaryBudget = max(0, 5 - essentialDetailParts.count)
            detail = (
                essentialDetailParts
                + Array(secondaryDetailParts.prefix(secondaryBudget))
                + [safety]
            ).joined(separator: " | ")
        } else {
            detail = detailParts.joined(separator: " | ")
        }
        return PassiveAutosyncRunSummary(
            verdict: verdict,
            detail: detail,
            sessionRoot: sessionRoot,
            controlReport: controlReport,
            stage: stage,
            nextAction: nextAction,
            safetyIssue: safetyIssue,
            dryRunWouldApply: boolField(passiveApplyResult, "wouldApply"),
            targetDelayMs: intField(passiveApplyResult, "targetDelayMs"),
            currentDelayMs: intField(passiveApplyResult, "currentDelayMs"),
            contextSignature: stringField(passiveApplyResult, "contextSignature"),
            captureBackend: stringField(passiveApplyResult, "captureBackend"),
            enabledAirplayCount: intField(passiveApplyResult, "enabledAirplayCount"),
            activeAirplayCount: intField(passiveApplyResult, "activeAirplayCount"),
            airplayTimingEpoch: uint64Field(passiveApplyResult, "airplayTimingEpoch"),
            candidateSyncContextState: stringField(passiveApplyResult, "syncContextState"),
            candidateSyncContextRevision: uint64Field(passiveApplyResult, "syncContextRevision")
        )
    }

    private func markPassiveDryRunReadyIfCurrent(
        _ summary: PassiveAutosyncRunSummary
    ) async {
        guard summary.verdict == "dry_run_ready" else { return }
        guard !summary.safetyIssue, summary.dryRunWouldApply else {
            SyncCastLog.log(
                "passiveAutosync: dry-run ready not promoted safety=\(summary.safetyIssue) wouldApply=\(summary.dryRunWouldApply)"
            )
            return
        }
        guard mode == .wholeHome else { return }
        guard case .unlocked = delayLockState else { return }
        guard let targetDelayMs = summary.targetDelayMs,
              let currentDelayMs = summary.currentDelayMs,
              let contextSignature = summary.contextSignature,
              let captureBackend = summary.captureBackend,
              let enabledAirplayCount = summary.enabledAirplayCount,
              let activeAirplayCount = summary.activeAirplayCount,
              let airplayTimingEpoch = summary.airplayTimingEpoch
        else {
            SyncCastLog.log(
                "passiveAutosync: dry-run ready ignored; missing accepted-candidate context"
            )
            return
        }
        guard syncContextState != .locked,
              syncContextState != .measuring,
              syncContextState != .dryRunReady
        else { return }
        if let candidateState = summary.candidateSyncContextState,
           candidateState != syncContextState.rawValue {
            SyncCastLog.log(
                "passiveAutosync: dry-run ready ignored after sync state changed candidate=\(candidateState) current=\(syncContextState.rawValue)"
            )
            return
        }
        if let candidateRevision = summary.candidateSyncContextRevision,
           candidateRevision != syncContextRevision {
            SyncCastLog.log(
                "passiveAutosync: dry-run ready ignored after sync revision changed candidate=\(candidateRevision) current=\(syncContextRevision)"
            )
            return
        }
        let liveDelay = await router.localFifoCurrentDelayMsForDiagnostics()
            ?? airplayDelayMs
        guard currentDelayMs == liveDelay else {
            SyncCastLog.log(
                "passiveAutosync: dry-run ready ignored after delay changed candidate=\(currentDelayMs)ms current=\(liveDelay)ms"
            )
            return
        }
        guard contextSignature == autoCalibrationContextSignature() else {
            SyncCastLog.log(
                "passiveAutosync: dry-run ready ignored after context changed"
            )
            return
        }
        guard enabledAirplayCount == enabledAirPlayOutputNotKnownDisconnectedCount
        else {
            SyncCastLog.log(
                "passiveAutosync: dry-run ready ignored after AirPlay count changed candidate=\(enabledAirplayCount) current=\(enabledAirPlayOutputNotKnownDisconnectedCount)"
            )
            return
        }
        guard activeAirplayCount == activeAirPlayOutputCount,
              activeAirplayCount == enabledAirplayCount
        else {
            SyncCastLog.log(
                "passiveAutosync: dry-run ready ignored after active AirPlay count changed candidate=\(activeAirplayCount)/\(enabledAirplayCount) current=\(activeAirPlayOutputCount)/\(enabledAirPlayOutputNotKnownDisconnectedCount)"
            )
            return
        }
        let liveEpoch = await router.airplayTimingEpochForDiagnostics()
        guard airplayTimingEpoch == liveEpoch else {
            SyncCastLog.log(
                "passiveAutosync: dry-run ready ignored after AirPlay epoch changed candidate=\(airplayTimingEpoch) current=\(liveEpoch)"
            )
            return
        }
        let fromState = syncContextState.rawValue
        let fromRevision = syncContextRevision
        let acceptedUnix = Date().timeIntervalSince1970
        setSyncContext(
            .dryRunReady,
            reason: "passive dry-run accepted candidate \(currentDelayMs)ms -> \(targetDelayMs)ms",
            delayMs: currentDelayMs
        )
        pendingPassiveDryRunCandidate = PendingPassiveDryRunCandidate(
            targetDelayMs: targetDelayMs,
            currentDelayMs: currentDelayMs,
            contextSignature: contextSignature,
            captureBackend: captureBackend,
            enabledAirplayCount: enabledAirplayCount,
            activeAirplayCount: activeAirplayCount,
            airplayTimingEpoch: airplayTimingEpoch,
            acceptedFromSyncContextState: fromState,
            acceptedFromSyncContextRevision: fromRevision,
            acceptedSyncContextRevision: syncContextRevision,
            sessionRoot: summary.sessionRoot,
            controlReport: summary.controlReport,
            acceptedUnix: acceptedUnix
        )
        schedulePassiveDryRunCandidateExpiryCheck(
            acceptedUnix: acceptedUnix,
            syncContextRevision: syncContextRevision
        )
    }

    private static func jsonDictionary(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        return raw as? [String: Any]
    }

    private static func stringField(
        _ payload: [String: Any]?,
        _ key: String
    ) -> String? {
        guard let value = payload?[key] else { return nil }
        if let string = value as? String { return string }
        if value is NSNull { return nil }
        return "\(value)"
    }

    private static func dictionaryField(
        _ payload: [String: Any]?,
        _ key: String
    ) -> [String: Any]? {
        payload?[key] as? [String: Any]
    }

    private static func intField(
        _ payload: [String: Any]?,
        _ key: String
    ) -> Int? {
        guard let value = payload?[key] else { return nil }
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String {
            return Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func uint64Field(
        _ payload: [String: Any]?,
        _ key: String
    ) -> UInt64? {
        guard let value = payload?[key] else { return nil }
        if let uint = value as? UInt64 { return uint }
        if let int = value as? Int, int >= 0 { return UInt64(int) }
        if let number = value as? NSNumber { return number.uint64Value }
        if let string = value as? String {
            return UInt64(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func boolField(
        _ payload: [String: Any]?,
        _ key: String
    ) -> Bool {
        guard let value = payload?[key] else { return false }
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            return ["1", "true", "yes"].contains(string.lowercased())
        }
        return false
    }

    private static func passiveAutosyncStateRoot() -> URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
        return support
            .appendingPathComponent("SyncCast", isDirectory: true)
            .appendingPathComponent("PassiveAutosync", isDirectory: true)
    }

    private static func resolvePassiveToolRoot() -> URL? {
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment["SYNCAST_PASSIVE_TOOL_ROOT"]
        let candidates: [URL?] = [
            env.map(URL.init(fileURLWithPath:)),
            Bundle.main.resourceURL?.appendingPathComponent(
                "passive-tools",
                isDirectory: true
            ),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("syncast", isDirectory: true),
        ]
        return candidates.compactMap { $0 }.first { root in
            fm.fileExists(
                atPath: root
                    .appendingPathComponent("scripts/passive_autosync_controller.py")
                    .path
            )
        }
    }

    private static func resolvePassivePython() -> URL? {
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment["SYNCAST_PASSIVE_PYTHON"]
        let candidates = [
            env,
            "/usr/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
        ]
        return candidates.compactMap { $0 }.map(URL.init(fileURLWithPath:))
            .first { fm.isExecutableFile(atPath: $0.path) }
    }

    /// Where the diagnostic socket lives. UID-scoped to match
    /// `SidecarLauncher`'s convention so multiple users on the same
    /// machine don't collide.
    static var calibrationDiagnosticSocketURL: URL {
        URL(fileURLWithPath: "/tmp/syncast-\(getuid()).calibration.sock")
    }

    // MARK: - Background continuous calibration lifecycle

    /// Drive the calibrator engine on or off. Idempotent. Wired into
    /// mode/streamingState/permission/toggle observers. ACTIVE iff:
    /// wholeHome AND running AND enabled AND mic-OK AND an eligible
    /// Local+connected-AirPlay route is live. The Router runs
    /// the v4 ContinuousActiveCalibrator loop which periodically
    /// drives ActiveCalibrator and pushes corrected delay values
    /// through setLocalFifoDelayMs internally; this AppModel layer
    /// just records samples for the UI caption.
    func reconcileBackgroundCalibration() {
        guard AppModel.activeAcousticCalibrationEnabled else {
            if backgroundCalibrationEnabled {
                backgroundCalibrationEnabled = false
                UserDefaults.standard.set(false, forKey: AppModel.bgEnabledKey)
            }
            if backgroundCalibrationActive {
                SyncCastLog.log("bgCalib: stopping active-probe loop; diagnostics disabled")
                stopBackgroundCalibration(thenReconcile: false)
            }
            return
        }
        // Pause for manual one-shot: stop engine, hold here.
        if continuousPausedForManual {
            if backgroundCalibrationActive { stopBackgroundCalibration(thenReconcile: false) }
            return
        }
        let delayUnlocked: Bool = {
            if case .unlocked = delayLockState { return true }
            return false
        }()
        let shouldRun = mode == .wholeHome && streamingState == .running
            && backgroundCalibrationEnabled && hasMicrophonePermission
            && delayUnlocked
            && hasEnabledLocalAndAirPlayOutputs
            && hasEnabledConnectedAirPlayOutput

        // Surface mic-denied separately so the UI can show Settings hint.
        let permDenied: Bool = backgroundCalibrationEnabled && {
            let a = AVCaptureDevice.authorizationStatus(for: .audio)
            return a == .denied || a == .restricted
        }()
        if permDenied != backgroundCalibrationMicDenied {
            backgroundCalibrationMicDenied = permDenied
        }

        switch (backgroundCalibrationActive, shouldRun) {
        case (false, true):
            backgroundCalibrationActive = true
            let interval = backgroundCalibrationIntervalS
            let micID = effectiveMicID
            let initialDelay = airplayDelayMs
            SyncCastLog.log("bgCalib: starting (v4 active) interval=\(interval)s mic=\(micID.map(String.init) ?? "default") initialDelay=\(initialDelay)ms")
            Task { [weak self] in
                guard let self else { return }
                // Provider closure: captured weakly so a torn-down
                // AppModel doesn't hold the loop alive. Returns the
                // empty list on shutdown — the runner will fail with
                // noEnabledDevices and the next cycle will retry.
                let deviceProvider: @Sendable () async -> [Device] = {
                    [weak self] in
                    guard let self else { return [] }
                    return await MainActor.run { self.devices }
                }
                do {
                    try await self.router.startContinuousActiveCalibration(
                        intervalSeconds: interval,
                        microphoneDeviceID: micID,
                        initialDelayMs: initialDelay,
                        deviceProvider: deviceProvider,
                        onSample: { sample in
                            Task { @MainActor [weak self] in
                                self?.handleBackgroundCalibrationSample(sample)
                            }
                        }
                    )
                } catch {
                    SyncCastLog.log("bgCalib: start failed: \(error)")
                    await MainActor.run {
                        self.backgroundCalibrationActive = false
                    }
                }
            }
        case (true, false):
            SyncCastLog.log("bgCalib: stopping (preconditions no longer hold)")
            stopBackgroundCalibration(thenReconcile: false)
        default:
            break
        }
    }

    /// Stop the engine. Optionally re-reconcile after — used when an
    /// interval change requires a stop+start cycle.
    private func stopBackgroundCalibration(thenReconcile: Bool) {
        Task { [weak self] in
            guard let self else { return }
            await self.router.stopContinuousActiveCalibration()
            await MainActor.run {
                self.backgroundCalibrationActive = false
                self.lastCalibrationSample = nil
                // Drop history too; if we keep it, the trend timeline
                // mixes stale-pre-restart values with fresh post-restart
                // ones and the user reads phantom drift.
                self.calibrationSampleHistory = []
                if thenReconcile { self.reconcileBackgroundCalibration() }
            }
        }
    }

    private func restartBackgroundCalibrationIfActive() {
        guard backgroundCalibrationActive else { return }
        stopBackgroundCalibration(thenReconcile: true)
    }

    /// Receive a Sample from the continuous loop. Router has already
    /// pushed any delay-line correction through setLocalFifoDelayMs
    /// (when |delta| ≥ 30 ms AND confidence ≥ floor); we just mirror
    /// the applied value into airplayDelayMs so the slider reflects
    /// reality and surface the sample for the UI caption.
    private func handleBackgroundCalibrationSample(_ sample: ContinuousActiveCalibrator.Sample) {
        lastCalibrationSample = sample
        guard case .unlocked = delayLockState else {
            SyncCastLog.log(
                "bgCalib sample ignored while delay locked: measured=\(sample.measuredDeltaMs)ms applied=\(sample.appliedDelayMs)ms"
            )
            return
        }
        // Ring-buffer semantics: append, then drop the oldest when over
        // capacity. We replace the array (vs in-place mutation) so the
        // @Observable invalidation fires on every cycle, redrawing the
        // trend timeline + drift indicators in MainPopover.
        var next = calibrationSampleHistory
        next.append(sample)
        if next.count > AppModel.calibrationHistoryCapacity {
            next.removeFirst(next.count - AppModel.calibrationHistoryCapacity)
        }
        calibrationSampleHistory = next
        SyncCastLog.log("bgCalib sample: drift=\(sample.measuredDeltaMs)ms applied=\(sample.appliedDelayMs)ms conf=\(String(format: "%.2f", sample.confidence))")
        let previousDelayMs = airplayDelayMs
        // Mirror the loop-applied value so the slider stays in sync.
        // We bypass `setAirplayDelay`'s debounced sidecar push — the
        // loop already pushed via setLocalFifoDelayMs — and just
        // update the UI-facing field + persist.
        if previousDelayMs != sample.appliedDelayMs {
            airplayDelayMs = sample.appliedDelayMs
            UserDefaults.standard.set(
                sample.appliedDelayMs, forKey: AppModel.airplayDelayMsKey
            )
            markSyncContextApplied(
                reason: "continuous active calibration applied delay",
                delayMs: sample.appliedDelayMs
            )
        }
    }

    /// Permission flow when the user toggles Continuous on. Mirrors
    /// `runAutoCalibrate` — prompt if undetermined, surface denied banner.
    func ensureMicPermissionForBackgroundCalibration() async {
        guard AppModel.activeAcousticCalibrationEnabled else {
            backgroundCalibrationEnabled = false
            UserDefaults.standard.set(false, forKey: AppModel.bgEnabledKey)
            backgroundCalibrationMicDenied = false
            SyncCastLog.log("bgCalib: microphone request skipped; active diagnostics disabled")
            return
        }
        let auth = AVCaptureDevice.authorizationStatus(for: .audio)
        switch auth {
        case .authorized:
            scheduleEventDrivenCalibration(
                reason: "microphone permission available"
            )
            return
        case .denied, .restricted:
            backgroundCalibrationMicDenied = true
        case .notDetermined:
            let granted = await requestMicrophonePermission()
            backgroundCalibrationMicDenied = !granted
            reconcileBackgroundCalibration()
            if granted {
                scheduleEventDrivenCalibration(
                    reason: "microphone permission granted"
                )
            }
        @unknown default:
            return
        }
    }

    // MARK: - Manual delay lock

    /// Pin the broadcast-side AirPlay delay to the current `airplayDelayMs`.
    /// Subsequent calibrators / closed-loop drivers can read
    /// `delayLockState` to decide whether to apply an automated correction.
    /// The locked value is persisted in UserDefaults so it survives a
    /// relaunch (see `loadPersistedDelayMs` + `loadPersistedLockedAt`).
    public func lockAirplayDelay() {
        let value = airplayDelayMs
        UserDefaults.standard.set(value, forKey: AppModel.airplayDelayLockedAtKey)
        delayLockState = .locked(at: value)
        userDelayRevision &+= 1
        pendingAutoCalibrationApply = nil
        eventDrivenCalibrationTask?.cancel()
        postApplyValidationTask?.cancel()
        pendingEventDrivenCalibrationReason = nil
        reconcileBackgroundCalibration()
        setSyncContext(.locked, reason: "user locked Local+AirPlay delay", delayMs: value)
        SyncCastLog.log("delayLock: locked at \(value)ms")
    }

    /// Release the lock so calibrators can drive the slider again. Stores
    /// 0 as the persisted lock target so a future launch sees "no lock".
    public func unlockAirplayDelay() {
        UserDefaults.standard.set(0, forKey: AppModel.airplayDelayLockedAtKey)
        delayLockState = .unlocked
        userDelayRevision &+= 1
        pendingAutoCalibrationApply = nil
        eventDrivenCalibrationTask?.cancel()
        postApplyValidationTask?.cancel()
        pendingEventDrivenCalibrationReason = nil
        reconcileBackgroundCalibration()
        markSyncContextSuspect(reason: "delay unlocked")
        scheduleEventDrivenCalibration(reason: "delay unlocked")
        SyncCastLog.log("delayLock: unlocked")
    }

    /// Bump the broadcast delay by an integer ms delta (positive or
    /// negative). Clamped to `airplayDelayMsRange` and routed through the
    /// existing debounced setter so the sidecar gets the change. If the
    /// delay is locked, manual nudges move the locked target too; otherwise
    /// the UI could claim one pinned value while persisting another.
    public func nudgeAirplayDelay(by deltaMs: Int) {
        let next = airplayDelayMs + deltaMs
        let clamped = max(
            AppModel.airplayDelayMsRange.lowerBound,
            min(AppModel.airplayDelayMsRange.upperBound, next)
        )
        setAirplayDelay(clamped)
    }

    // MARK: - Audition state machine

    /// Side-switch cadence (seconds). The audition flips between A and B
    /// every 1.2 s within a single round.
    private static let auditionSideSwitchSeconds: Double = 1.2

    /// Bracket size around the baseline (ms). Side A plays at
    /// baseline-150 ms, side B at baseline+150 ms.
    private static let auditionBracketMs: Int = 150

    /// Per-choice baseline narrowing (ms). chooseAuditionA shifts the
    /// baseline down by 75 ms; chooseAuditionB shifts it up.
    private static let auditionNarrowingMs: Int = 75

    /// Total user-decision rounds before auto-stop. Round 5 triggers
    /// `stopAudition()`.
    private static let auditionTotalRounds: Int = 4

    /// Begin the A/B audition loop. No-op if an audition is already
    /// running or if the slider is otherwise unavailable. The current
    /// `airplayDelayMs` becomes the baseline; round 1 / side A is
    /// applied immediately and the side-switching Task is started.
    public func startAudition() {
        guard auditionState == .idle else { return }
        auditionBaselineMs = airplayDelayMs
        SyncCastLog.log("audition: start baseline=\(auditionBaselineMs)ms")
        auditionState = .running(round: 1, side: .A)
        applyAuditionSide(.A)
        startAuditionSideSwitchLoop()
    }

    /// Cancel any in-flight audition and restore the original baseline.
    /// Idempotent — safe to call from `idle`. Matches the implicit
    /// auto-stop that fires after round 4 chooses.
    public func stopAudition() {
        auditionSideSwitchTask?.cancel()
        auditionSideSwitchTask = nil
        if auditionState != .idle {
            SyncCastLog.log("audition: stop, restoring baseline=\(auditionBaselineMs)ms")
            // Restore the slider to whatever was active when start was
            // called. Goes through the debounced setter so the sidecar
            // is updated.
            setAirplayDelay(auditionBaselineMs)
        }
        auditionState = .idle
    }

    /// User picked side A this round. Narrow the baseline downward by
    /// 75 ms, advance to the next round, or auto-stop after round 4.
    public func chooseAuditionA() {
        chooseAuditionSide(narrowBy: -AppModel.auditionNarrowingMs)
    }

    /// User picked side B this round. Narrow the baseline upward by
    /// 75 ms, advance to the next round, or auto-stop after round 4.
    public func chooseAuditionB() {
        chooseAuditionSide(narrowBy: +AppModel.auditionNarrowingMs)
    }

    /// Shared body for chooseAuditionA / chooseAuditionB. The sign of
    /// `narrowBy` determines which way the baseline shifts.
    private func chooseAuditionSide(narrowBy delta: Int) {
        guard case .running(let round, _) = auditionState else { return }
        let nextBaseline = max(
            AppModel.airplayDelayMsRange.lowerBound,
            min(AppModel.airplayDelayMsRange.upperBound,
                auditionBaselineMs + delta)
        )
        auditionBaselineMs = nextBaseline
        SyncCastLog.log("audition: round=\(round) choose Δ=\(delta)ms → baseline=\(nextBaseline)ms")
        // Round 5 means we just heard the 4th pair and chose; auto-stop.
        let nextRound = round + 1
        if nextRound > AppModel.auditionTotalRounds {
            // Apply final baseline as the new airplayDelayMs (NOT the
            // restore behaviour — the user's choices are the result).
            auditionSideSwitchTask?.cancel()
            auditionSideSwitchTask = nil
            setAirplayDelay(nextBaseline)
            auditionState = .idle
            SyncCastLog.log("audition: complete after \(AppModel.auditionTotalRounds) rounds at \(nextBaseline)ms")
            return
        }
        // Otherwise restart the side-switch loop with the new baseline.
        auditionState = .running(round: nextRound, side: .A)
        applyAuditionSide(.A)
        startAuditionSideSwitchLoop()
    }

    /// Apply baseline ± bracket to the slider. Bypasses the debounced
    /// IPC path used by user drags because the audition wants the change
    /// to land instantly; it still goes through `setAirplayDelay` to
    /// share the clamp + sidecar push.
    private func applyAuditionSide(_ side: AuditionSide) {
        let target: Int
        switch side {
        case .A: target = auditionBaselineMs - AppModel.auditionBracketMs
        case .B: target = auditionBaselineMs + AppModel.auditionBracketMs
        }
        setAirplayDelay(target)
    }

    /// Kick off (or restart) the 1.2 s flip Task for the current round.
    /// The Task alternates side every 1.2 s and updates `auditionState`
    /// in place. Cancelled by stopAudition / chooseX before each new
    /// round and on app teardown via Task.isCancelled checks.
    ///
    /// The Task inherits `@MainActor` isolation from its surrounding
    /// context (this method is on the `@MainActor`-isolated AppModel),
    /// so the body runs on the main actor without an explicit hop.
    private func startAuditionSideSwitchLoop() {
        auditionSideSwitchTask?.cancel()
        auditionSideSwitchTask = Task { [weak self] in
            while !Task.isCancelled {
                let nanos = UInt64(AppModel.auditionSideSwitchSeconds * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                if Task.isCancelled { return }
                guard let self else { return }
                guard case .running(let round, let side) = self.auditionState else { return }
                let nextSide: AuditionSide = (side == .A) ? .B : .A
                self.auditionState = .running(round: round, side: nextSide)
                self.applyAuditionSide(nextSide)
            }
        }
    }

    /// Devices the user can plausibly target. Excludes:
    ///   - BlackHole (virtual capture sink — routing audio TO it could
    ///     feedback into our SCK capture path).
    ///   - Our own private aggregate devices (UID prefix
    ///     `io.syncast.aggregate.v1.`) — these are created by the Router
    ///     to drive multi-output sync; user must never see them.
    ///
    /// Notably we DO show user-created aggregate / multi-output devices
    /// from Audio MIDI Setup. Earlier versions filtered these blanket-
    /// style as a feedback safeguard, but with the Router now operating
    /// its own aggregate, blanket-filtering would surprise users who
    /// built their own. Routing into a USER-created aggregate that
    /// happens to include the system input would feedback, so we still
    /// rely on SCK's `excludesCurrentProcessAudio` defense at the
    /// capture layer.
    private func isUserSelectableOutput(_ d: Device) -> Bool {
        if let uid = d.coreAudioUID, uid.contains("BlackHole") { return false }
        // Our own private aggregate (created by Router.reconcileLocalDriver)
        // is invisible-by-construction (kAudioAggregateDeviceIsPrivateKey=1)
        // but as a belt-and-braces filter in case macOS ever surfaces it,
        // hide it by UID prefix.
        if let uid = d.coreAudioUID,
           uid.hasPrefix("io.syncast.aggregate.v1.") {
            return false
        }
        let lower = d.name.lowercased()
        if lower.contains("blackhole") { return false }
        return true
    }

    /// Whether this device is reachable in a given mode.
    /// - .stereo  : only local CoreAudio outputs are usable (low-latency path)
    /// - .wholeHome : every output is usable (AirPlay receivers natively;
    ///   local CoreAudio outputs participate via the FIFO bridge)
    func isSelectableInMode(_ d: Device, mode: Mode) -> Bool {
        guard isUserSelectableOutput(d) else { return false }
        switch mode {
        case .stereo:
            return d.transport == .coreAudio
        case .wholeHome:
            return true
        }
    }

    /// Devices visible in the UI for the CURRENT mode. Filters by both
    /// the global "is targetable at all" check and the mode-specific
    /// reachability.
    var localDevices: [Device] {
        devices.filter {
            $0.transport == .coreAudio && isSelectableInMode($0, mode: mode)
        }
    }
    var airPlayDevices: [Device] {
        devices.filter {
            $0.transport == .airplay2 && isSelectableInMode($0, mode: mode)
        }
    }
    var enabledDeviceCount: Int { routing.values.filter(\.enabled).count }

    // MARK: - Calibration mic intents

    /// Re-query CoreAudio for the current set of input-capable devices
    /// and update `availableInputDevices`. Also resolves the persisted
    /// UID preference back to a live `AudioDeviceID` and assigns it to
    /// `selectedMicID` if the device is still attached. Idempotent and
    /// cheap (only HAL property reads, no IOProc work).
    ///
    /// Called at bootstrap, on hot-plug events from the HAL listener,
    /// and any time the UI wants a manual refresh (the calibration sheet
    /// can call this when it appears).
    func refreshInputDevices() {
        let fresh = InputDeviceEnumerator.enumerate()
        availableInputDevices = fresh
        // Resolve persisted UID → live AudioDeviceID.
        let persistedUID = UserDefaults.standard.string(
            forKey: AppModel.micUIDDefaultsKey
        )
        let resolvedFromPersist = persistedUID.flatMap { uid in
            fresh.first(where: { $0.uid == uid })
        }
        // Drop any selection that no longer matches an attached device.
        // The didSet for selectedMicID re-persists, so set the underlying
        // value carefully — assigning resolvedFromPersist?.id rewrites
        // the same UID back to UserDefaults, which is fine. Assigning nil
        // when persistedUID is set but the device is gone DELIBERATELY
        // leaves the persisted UID alone (so replug restores selection).
        if let resolved = resolvedFromPersist {
            if selectedMicID != resolved.id {
                // Bypass the didSet — this is a refresh-driven re-binding,
                // not a user choice. Re-persisting the same UID is a no-op
                // but we still want the assignment to flow through observers.
                selectedMicID = resolved.id
            }
        } else if persistedUID == nil {
            // No persisted preference at all → fall through to default.
            // Leave selectedMicID == nil; effectiveMicID handles fallback.
            if selectedMicID != nil { selectedMicID = nil }
        } else {
            // Persisted UID set but device not attached. Surface as nil
            // (effectiveMicID falls back to system default), but DO NOT
            // wipe the persisted UID — replug should restore selection.
            if selectedMicID != nil {
                // Suppress the persistence side-effect for this path so
                // we don't overwrite the saved UID with nil.
                suppressMicPersist = true
                selectedMicID = nil
                suppressMicPersist = false
            }
        }
    }

    /// User picked a specific input device. Pass `nil` to clear the
    /// override and revert to the system default. The choice is persisted
    /// by UID so it survives replug / restart.
    func setSelectedMic(_ id: AudioDeviceID?) {
        // Validate: if a non-nil id was passed but it's not in the live
        // list, treat it as "clear". Avoids storing a junk id.
        if let id, !availableInputDevices.contains(where: { $0.id == id }) {
            selectedMicID = nil
            pendingAutoCalibrationApply = nil
            return
        }
        selectedMicID = id
        pendingAutoCalibrationApply = nil
    }

    /// Request mic access (TCC class `kTCCServiceMicrophone`). Returns
    /// `true` if the user has granted access (already-authorized counts
    /// as `true` and does NOT re-prompt). Returns `false` if denied or
    /// restricted. Wraps `AVCaptureDevice.requestAccess(for:.audio)`,
    /// which blocks until the user dismisses the prompt — call from
    /// the calibrate-button handler, not from view body.
    func requestMicrophonePermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return true
        case .denied, .restricted:
            // Already a hard "no". Don't prompt again — the OS won't
            // show a second prompt once the user has denied. The UI is
            // expected to surface a "Open System Settings → Privacy"
            // affordance in this state.
            return false
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        @unknown default:
            return false
        }
    }

    /// Persist `selectedMicID` as a UID string. UID, not AudioDeviceID:
    /// the live id is reassigned by CoreAudio on every hot-plug, so
    /// storing it would silently lose the user's pick. UID survives.
    private func persistSelectedMic() {
        if suppressMicPersist { return }
        let defaults = UserDefaults.standard
        if let id = selectedMicID,
           let info = availableInputDevices.first(where: { $0.id == id }),
           !info.uid.isEmpty {
            defaults.set(info.uid, forKey: AppModel.micUIDDefaultsKey)
        } else {
            defaults.removeObject(forKey: AppModel.micUIDDefaultsKey)
        }
    }

    /// One-shot suppression flag for `persistSelectedMic`. Used by
    /// `refreshInputDevices` to clear the live id when a previously-
    /// selected USB mic is unplugged WITHOUT discarding the persisted
    /// UID (so replug restores the selection automatically).
    private var suppressMicPersist: Bool = false

    /// Install the CoreAudio device-list listener and run the first
    /// refresh. Called from `bootstrap`. The listener is held on
    /// `inputDeviceListener` so it lives for the AppModel's lifetime.
    fileprivate func startInputDeviceWatch() {
        refreshInputDevices()
        inputDeviceListener = InputDeviceListener(queue: .main) { [weak self] in
            // HAL callback runs on .main (DispatchQueue). MainActor
            // requires explicit hop because we're in a Sendable closure
            // outside any actor context.
            Task { @MainActor [weak self] in
                self?.refreshInputDevices()
            }
        }
    }

    // MARK: - Sleep/wake auto-recovery (Round 12)
    //
    // Symptom: in stereo (local) mode with HDMI/DisplayPort speakers as
    // a sub-device of the private aggregate, the user's monitor went to
    // DPMS sleep after ~20 minutes of inactivity. On wake, audio was
    // silent. The manual workaround was to deselect + reselect each
    // CoreAudio device, which deterministically recovered.
    //
    // Root cause: when the display goes to DPMS sleep, the HDMI audio
    // sub-device disappears from `kAudioHardwarePropertyDevices` entirely.
    // On wake, it reappears with the SAME `coreAudioUID` (stable property)
    // but a FRESH `AudioDeviceID` (a transient UInt32 the kernel assigns
    // per-attach). The active AggregateDevice still references the dead
    // AudioDeviceID; AUHAL render doesn't error, it just produces silence.
    //
    // `reconcileLocalDriver`'s `alreadyCorrect` short-circuit looks at the
    // enabled UID set, sees no change, and skips the rebuild — so even a
    // toggle of an unrelated property won't recover. The deselect+reselect
    // dance forced two `tearDownLocalDriver` + rebuild rounds, which is
    // why it worked.
    //
    // Fix: observe BOTH `NSWorkspace.didWakeNotification` (full system
    // sleep, e.g. lid close) AND `screensDidWakeNotification` (display-only
    // sleep, the user's case). On wake, debounce, wait 1.5 s for
    // coreaudiod IPC to settle, then call `router.forceLocalDriverRebuild`
    // which bypasses the short-circuit.
    //
    // Stereo still gets the stronger local-driver rebuild because DPMS can
    // leave AUHAL wired to dead AudioDeviceIDs. Whole-home takes the safer
    // recovery path: mark the AirPlay timing domain suspect, bump the Router
    // AirPlay timing epoch, and reconcile bridges/receiver selection/socket
    // without running any microphone capture or acoustic probe.

    /// Holds NSWorkspace observer tokens (`NSObjectProtocol`). One per
    /// notification name we subscribe to. Kept as `[Any]` per the
    /// `NSObjectProtocol` token contract (these are not the same type
    /// as our other listener storage).
    private var sleepWakeObservers: [NSObjectProtocol] = []

    /// Timestamp of the most recent post-wake forceLocalDriverRebuild.
    /// Used to debounce: HAL fires both `didWake` and `screensDidWake`
    /// within ~100 ms of a single physical wake, plus CoreAudio sends
    /// 3–6 device-change callbacks per logical change. Skipping when we
    /// just rebuilt < 1 s ago coalesces the burst into one rebuild.
    private var lastWakeRebuildAt: Date = .distantPast

    /// Single-flight wake recovery task. Cancel-and-replace pattern: a
    /// second wake event during an in-flight recovery cancels the prior
    /// retry loop and starts fresh. Without this, two waves <1s apart
    /// could stack two parallel recoveries fighting each other.
    private var wakeRecoveryTask: Task<Void, Never>?

    /// Round 12 — Codex-found race fix. When DPMS sleep transiently
    /// drops an HDMI subdevice, the discovery `.disappeared` path
    /// removes the routing entry. Without this shadow set, the wake
    /// handler would see an empty enabled-CoreAudio list and silently
    /// no-op. We capture the UID here on disappearance (only if the
    /// user had it enabled), and the wake handler treats it as a
    /// "must come back" target. `.appeared` path clears the entry.
    private var transientlyMissingEnabledCoreAudioUIDs: Set<String> = []

    /// Subscribe to NSWorkspace sleep/wake notifications. Idempotent —
    /// safe to call from `bootstrap` once. Observers live until the
    /// AppModel itself is torn down (see `deinit`).
    fileprivate func startPowerEventWatch() {
        // Dedup guard: re-bootstrap (hot-reload during dev, or future
        // bootstrap-retry path) must not double-register observers.
        guard sleepWakeObservers.isEmpty else {
            SyncCastLog.log("AppModel: startPowerEventWatch skipped (observers already registered)")
            return
        }
        let nc = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
        ]
        for name in names {
            // The observer block runs on the main queue (queue: .main).
            // We hop to MainActor explicitly because the stored closure
            // is `@Sendable` from NSWorkspace's perspective and not
            // implicitly bound to MainActor.
            let token = nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                Task { @MainActor [weak self] in
                    self?.handleWake(notification: note)
                }
            }
            sleepWakeObservers.append(token)
        }
        SyncCastLog.log("AppModel: registered NSWorkspace sleep/wake observers (didWake + screensDidWake)")
    }

    /// Wake-event handler. Runs on MainActor.
    /// - Debounces tight bursts of wake notifications.
    /// - Waits 1.5 s for `coreaudiod` to finish its post-wake IPC catch-up
    ///   (empirically the window when HAL calls block or return stale ids).
    /// - Stereo mode forces a full local-driver tear-down + rebuild via
    ///   `Router.forceLocalDriverRebuild`, bypassing the
    ///   `alreadyCorrect` short-circuit.
    /// - Whole-home mode invalidates the AirPlay timing domain and
    ///   reconciles route state without opening the mic or emitting probes.
    private func handleWake(notification: Notification) {
        SyncCastLog.log("AppModel: wake event \(notification.name.rawValue)")
        let now = Date()
        guard now.timeIntervalSince(lastWakeRebuildAt) > 1.0 else {
            SyncCastLog.log("AppModel: wake event debounced (< 1s since last rebuild)")
            return
        }
        lastWakeRebuildAt = now

        // Single-flight: cancel any in-flight recovery from a prior
        // wake event and replace with a fresh task. Codex caught this
        // race where two waves <1s apart could stack parallel recovery
        // loops fighting each other.
        wakeRecoveryTask?.cancel()
        wakeRecoveryTask = Task { [weak self] in
            // Wait for coreaudiod IPC to settle. Empirically ~1.5 s on
            // M1/M2 hardware after display DPMS wake; full-system wake
            // (S3) can take a touch longer but 1.5 s covers both.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self else { return }
            // Snapshot all the predicates + the device list on MainActor
            // in one hop, so we don't race with a user toggle that
            // could change the gate state mid-rebuild.
            // Snapshot all the predicates + the device list on MainActor
            // in one hop, so we don't race with a user toggle. Capture
            // each gate predicate separately so the skip log can name
            // the actual reason instead of lumping all causes together.
            let snapshot: (
                isStereo: Bool,
                isWholeHome: Bool,
                isRunning: Bool,
                hasEnabledRouting: Bool,
                modeName: String,
                stateName: String,
                devices: [Device]
            ) = await MainActor.run {
                let isStereo = self.mode == .stereo
                let isWholeHome = self.mode == .wholeHome
                let isRunning = self.streamingState == .running
                let hasEnabledRouting = self.routing.values.contains(where: { $0.enabled })
                let snap = self.devices.filter { dev in
                    dev.transport == .coreAudio &&
                        (self.routing[dev.id]?.enabled ?? false)
                }
                return (
                    isStereo,
                    isWholeHome,
                    isRunning,
                    hasEnabledRouting,
                    String(describing: self.mode),
                    String(describing: self.streamingState),
                    snap
                )
            }
            guard snapshot.isStereo else {
                guard snapshot.isWholeHome else {
                    SyncCastLog.log("AppModel: post-wake recovery skipped (mode=\(snapshot.modeName))")
                    return
                }
                SyncCastLog.log("AppModel: post-wake whole-home timing invalidated; reconciling AirPlay route state")
                await self.router.noteWholeHomeTimingInstability(
                    reason: "wake event; AirPlay timing domain may have relocked"
                )
                await MainActor.run {
                    if self.mode == .wholeHome {
                        self.markSyncContextSuspect(
                            reason: "wake event; AirPlay timing domain may have relocked"
                        )
                        if snapshot.isRunning && snapshot.hasEnabledRouting {
                            self.reconcileEngine()
                            self.reconcileBackgroundCalibration()
                        } else {
                            SyncCastLog.log("AppModel: post-wake whole-home reconcile skipped (engine \(snapshot.stateName), hasEnabled=\(snapshot.hasEnabledRouting))")
                        }
                    }
                }
                return
            }
            guard snapshot.isRunning else {
                SyncCastLog.log("AppModel: post-wake rebuild skipped (engine \(snapshot.stateName), nothing to recover)")
                return
            }
            // Round 12 — Codex race fix: also include UIDs that
            // disappeared while the user had them enabled. DPMS sleep
            // can transiently drop HDMI subdevices; without merging
            // these, snapshot.devices may be empty and recovery would
            // silently no-op in the canonical bug scenario.
            let transientUIDs = await MainActor.run { Array(self.transientlyMissingEnabledCoreAudioUIDs) }
            let liveTargetUIDs = snapshot.devices.compactMap(\.coreAudioUID)
            let allTargetUIDs = Array(Set(liveTargetUIDs + transientUIDs))

            guard snapshot.hasEnabledRouting || !transientUIDs.isEmpty else {
                SyncCastLog.log("AppModel: post-wake rebuild skipped (no enabled outputs in routing)")
                return
            }
            guard !allTargetUIDs.isEmpty else {
                SyncCastLog.log("AppModel: post-wake rebuild skipped (no target UIDs — neither live nor transiently-missing)")
                return
            }

            SyncCastLog.log("AppModel: post-wake force rebuild local driver (live=\(liveTargetUIDs.count), transient=\(transientUIDs.count) UIDs)")
            // Pass the FULL device list (not just enabled) — the Router
            // mirrors AppModel's call sites for `reconcileLocalDriver`,
            // which itself filters by `routing[dev.id].enabled`.
            // Retry-with-backoff fixed off-by-one (codex Cycle 1 #2): sleep
            // BEFORE the next attempt, not after the previous one. This
            // way the final 5s wait isn't wasted — if the UID returns
            // during it, the next attempt observes success.
            let backoffs: [UInt64] = [
                1_000_000_000,  // before attempt 2: 1s
                3_000_000_000,  // before attempt 3: 3s
                5_000_000_000,  // before attempt 4: 5s
            ]
            let maxAttempts = backoffs.count + 1  // 4 total
            for attempt in 0..<maxAttempts {
                if Task.isCancelled {
                    SyncCastLog.log("AppModel: post-wake rebuild cancelled (newer wake event)")
                    return
                }
                if attempt > 0 {
                    SyncCastLog.log("AppModel: post-wake rebuild attempt \(attempt) — recovery incomplete, sleeping \(backoffs[attempt - 1] / 1_000_000_000)s")
                    try? await Task.sleep(nanoseconds: backoffs[attempt - 1])
                    if Task.isCancelled { return }
                }
                // Codex Cycle 2 must-fix: re-snapshot device list each
                // attempt. If a device reappears during backoff, the
                // rebuild MUST include it, otherwise captureOK && allResolved
                // can both go true while the rebuilt driver still uses
                // the stale list missing the new device.
                let allDevices = await MainActor.run { self.devices }
                let captureOK = await self.router.forceLocalDriverRebuild(devices: allDevices)
                let allResolved = await Self.allUIDsResolveToLiveDeviceID(allTargetUIDs)
                // Codex must-fix #3: success requires BOTH capture restart
                // AND every target UID resolving. If only UIDs resolve but
                // capture is dead, the driver is silent — must retry.
                if captureOK && allResolved {
                    if attempt > 0 {
                        SyncCastLog.log("AppModel: post-wake rebuild succeeded on retry attempt \(attempt + 1)/\(maxAttempts) (capture=ok, uids=live)")
                    } else {
                        SyncCastLog.log("AppModel: post-wake rebuild succeeded first try (capture=ok, uids=live)")
                    }
                    return
                }
                SyncCastLog.log("AppModel: post-wake attempt \(attempt + 1) incomplete — capture=\(captureOK ? "ok" : "FAIL"), uids=\(allResolved ? "live" : "stale")")
            }
            SyncCastLog.log("AppModel: post-wake rebuild gave up after \(maxAttempts) attempts")
        }
    }

    /// Verify each UID resolves to a non-zero `AudioDeviceID` via the
    /// HAL `kAudioHardwarePropertyTranslateUIDToDevice` translator. If
    /// any UID still maps to `kAudioObjectUnknown` (0), the post-wake
    /// device republish hasn't completed and the rebuild can't be
    /// trusted. Returns true only when all target UIDs resolve.
    ///
    /// `nonisolated` per codex #3 — `AudioObjectGetPropertyData` blocks
    /// on coreaudiod IPC after wake, would stall the MainActor otherwise.
    nonisolated private static func allUIDsResolveToLiveDeviceID(_ uids: [String]) async -> Bool {
        for uid in uids {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var deviceID: AudioDeviceID = kAudioObjectUnknown
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            let cfUID = uid as CFString
            let status = withUnsafePointer(to: cfUID) { uidPtr -> OSStatus in
                AudioObjectGetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject),
                    &addr,
                    UInt32(MemoryLayout<CFString>.size),
                    uidPtr,
                    &size,
                    &deviceID
                )
            }
            if status != noErr || deviceID == kAudioObjectUnknown {
                return false
            }
        }
        return true
    }

    // No `deinit` cleanup for `sleepWakeObservers`: AppModel is
    // process-lifetime (the menubar app's only top-level model), so
    // the observers naturally die with the process. The same convention
    // applies to `inputDeviceListener` above. Adding a deinit would
    // require unsafe-isolation gymnastics around `@MainActor` for zero
    // real benefit (NSWorkspace's notification center cleans up
    // observers on process exit anyway).
}
