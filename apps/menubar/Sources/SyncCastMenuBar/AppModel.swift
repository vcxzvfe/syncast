import AppKit
import AVFoundation
import CoreAudio
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
    // The auto-calibration flow plays brief click sounds through each
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

    static let airplayDelayMsKey = "syncast.airplayDelayMs"
    static let defaultAirplayDelayMs: Int = 1750
    /// UI cap. Bumped from 3000 to 5000 ms because empirical AirPlay
    /// measurements (v4 ActiveCalibrator) found total command-to-mic
    /// latencies of 2300–2700 ms. With local at ~10 ms, the recommended
    /// delay-line value is in that 2300–2700 ms range, plus headroom
    /// for slower AirPlay receivers (some HomePod variants buffer
    /// 3–4 s). Sidecar still clamps to [0, 10000] for an absolute
    /// safety bound.
    static let airplayDelayMsRange: ClosedRange<Int> = 0...5000

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
    var backgroundCalibrationEnabled: Bool = AppModel.loadPersistedBgEnabled() {
        didSet {
            UserDefaults.standard.set(backgroundCalibrationEnabled, forKey: AppModel.bgEnabledKey)
            reconcileBackgroundCalibration()
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

    static let bgEnabledKey = "syncast.bgCalibrationEnabled"
    static let bgIntervalKey = "syncast.bgCalibrationIntervalS"
    /// 1200 s (20 min). Continuous mode now runs Phase 1 only (~1.5 s
    /// of inaudible 18–20 kHz tones on local bridges). The disruptive
    /// Phase-2 AirPlay TDMA mute-dip is reserved for the manual
    /// Auto-calibrate button, so we no longer need to probe every 30 s
    /// to keep up with drift; thermal/network drift in AirPlay shows
    /// up only on the manual cadence anyway.
    static let defaultBgIntervalS: Int = 1200
    /// 60 s … 3600 s (1 min … 60 min). Floor raised from 10 s because
    /// even the inaudible Phase-1 probe shouldn't run more than once a
    /// minute; ceiling raised from 300 s because long-idle setups can
    /// happily wait 1 h between drift checks.
    static let bgIntervalRange: ClosedRange<Int> = 60...3600

    private static func loadPersistedBgEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: bgEnabledKey)
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
        /// receive the same audio over the network. Everything PTP-
        /// synced. Video sync is impossible in this mode.
        case wholeHome

        public var id: String { rawValue }
        public var displayName: String {
            switch self {
            case .stereo:    return "立体声 (本地, 低延迟)"
            case .wholeHome: return "全屋同步 (AirPlay)"
            }
        }
        public var subtitle: String {
            switch self {
            case .stereo:    return "本地扬声器, ≈50ms 延迟, 适合视频"
            case .wholeHome: return "全设备同步, ≈1.8s 延迟, 仅适合音乐"
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
        // Restore manual lock from UserDefaults. When a lock is persisted,
        // `loadPersistedDelayMs()` already chose the locked value so the
        // slider matches the lock; we only need to seed the state enum.
        let lockedAt = AppModel.loadPersistedLockedAt()
        if lockedAt > 0 {
            self.delayLockState = .locked(at: lockedAt)
        }
        // One-shot cleanup of the legacy hybrid-tracker pref. The
        // toggle/engine has been removed; leaving the key behind would
        // simply clutter the user's defaults plist forever.
        UserDefaults.standard.removeObject(forKey: "syncast.hybridTrackingEnabled")
        Task { await self.bootstrap() }
    }

    private func bootstrap() async {
        SyncCastLog.log("bootstrap start")
        // Check Screen Recording permission state. SyncCast captures system
        // audio via ScreenCaptureKit; Screen Recording is the TCC gate.
        screenRecordingGranted = (ScreenRecordingTCC.current == .granted)
        SyncCastLog.log("screen-recording status: \(ScreenRecordingTCC.current.rawValue)")
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
        // and update the model when the state flips, so the user doesn't
        // have to manually quit-and-reopen.
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self else { return }
                let now = (ScreenRecordingTCC.current == .granted)
                let was = await MainActor.run { self.screenRecordingGranted }
                if now != was {
                    await MainActor.run { self.screenRecordingGranted = now }
                    SyncCastLog.log("screen-recording state changed: \(was) → \(now)")
                    if now {
                        // Just got granted. Trigger reconcile so a previously
                        // queued toggle takes effect without app restart.
                        await MainActor.run { self.reconcileEngine() }
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
                        let match = self.devices.first { d in
                            d.name.localizedCaseInsensitiveContains(target) ||
                            (target == "mbp" && d.name.contains("MacBook Pro扬声器")) ||
                            (target == "display" && d.name.contains("PG27"))
                        }
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
                        devices[existingIdx] = dev
                        if var oldR = routing.removeValue(forKey: oldID) {
                            oldR.deviceID = dev.id
                            routing[dev.id] = oldR
                        } else if routing[dev.id] == nil {
                            routing[dev.id] = DeviceRouting(deviceID: dev.id, enabled: false)
                        }
                        devices.sort { $0.name < $1.name }
                        detectBlackHole(in: dev)
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
                    devices[idx] = dev
                } else if let idx = devices.firstIndex(where: { sameLogicalDevice($0, dev) }) {
                    // Same physical device, new SyncCast id. Migrate the
                    // routing slot so user toggles don't drop on the floor.
                    let oldID = devices[idx].id
                    SyncCastLog.log("device id migration on update: \(dev.name) \(oldID.prefix(8)) → \(dev.id.prefix(8))")
                    devices[idx] = dev
                    if var oldR = routing.removeValue(forKey: oldID) {
                        oldR.deviceID = dev.id
                        routing[dev.id] = oldR
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
                if let goneDev = devices.first(where: { $0.id == id }),
                   let goneUID = goneDev.coreAudioUID,
                   goneDev.transport == .coreAudio,
                   (routing[id]?.enabled ?? false) {
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
                let wasEnabled = routing[id]?.enabled ?? false
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
                        reconcileEngine()
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
            self.connectionStates = snap.states
            self.connectionFailureReasons = snap.reasons
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
            return
        }
        if let lag = diag["actual_delivery_lag_ms"] as? Double {
            measuredLagMs = Int(lag.rounded())
        } else if let lagInt = diag["actual_delivery_lag_ms"] as? Int {
            measuredLagMs = lagInt  // JSON sometimes ships int when float is exact
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

    private func reconcileEngineAsync() async {
        SyncCastLog.log("reconcile: scrRec=\(screenRecordingGranted) state=\(streamingState.rawValue) hasEnabled=\(hasEnabledOutputs) mode=\(mode.rawValue)")
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
            SyncCastLog.log("reconcile: starting router (SCK capture)")
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
                }

                // After 1.5s, log the IOProc tick count to confirm CoreAudio
                // is actually pumping data. If still 0 → TCC denied mic.
                Task { [weak self] in
                    for delay in [1, 2, 4, 6] as [UInt64] {
                        try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                        guard let self else { return }
                        let report = await self.router.diagnosticSCKReport()
                        SyncCastLog.log("SCK report @ \(delay)s: \(report)")
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
            } catch {
                SyncCastLog.log("reconcile: router.start FAILED: \(error)")
                lastError = "engine: \(error.localizedDescription)"
                streamingState = .error
                reconcileBackgroundCalibration()
            }
        case (.running, false):
            SyncCastLog.log("reconcile: stopping (no enabled outputs)")
            await router.setActiveAirplayDevices([])
            await router.stop()
            streamingState = .idle
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
        default:
            SyncCastLog.log("reconcile: no-op (state=\(streamingState.rawValue) shouldRun=\(shouldRun))")
            break
        }
    }

    /// Sync the enabled AirPlay devices over to the sidecar / OwnTone.
    private func pushAirplayState() async {
        let enabledAirplay = devices.filter {
            $0.transport == .airplay2 && (routing[$0.id]?.enabled ?? false)
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
                await router.setAirplayVolume(id: dev.id, volume: r.volume)
            }
        }
        SyncCastLog.log("setActiveAirplayDevices: ids=\(enabledAirplay.map { $0.id.prefix(8) })")
        await router.setActiveAirplayDevices(enabledAirplay.map { $0.id })
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
    }

    func toggleDevice(_ id: String) {
        var r = routing[id] ?? DeviceRouting(deviceID: id)
        let oldEnabled = r.enabled
        r.enabled.toggle()
        routing[id] = r
        let name = devices.first(where: { $0.id == id })?.name ?? id
        // Emit BOTH the toggled id and the post-toggle full routing so
        // we can prove or disprove the user-reported "click X but Y
        // toggled" symptom from the log alone (no Console.app needed).
        SyncCastLog.log("toggleDevice: \(name) [id=\(id.prefix(8))] \(oldEnabled ? "ON" : "off") → \(r.enabled ? "ON" : "off"). routing: { \(routingSummary()) }")
        reconcileEngine()
    }

    func setVolume(_ value: Float, for id: String) {
        var r = routing[id] ?? DeviceRouting(deviceID: id)
        r.volume = max(0, min(1, value))
        routing[id] = r
        reconcileEngine()
    }

    func toggleMute(_ id: String) {
        var r = routing[id] ?? DeviceRouting(deviceID: id)
        r.muted.toggle()
        routing[id] = r
        reconcileEngine()
    }

    /// Live-tune the whole-home FIFO delay. In-memory update is immediate
    /// (snappy UI); IPC + UserDefaults write is debounced 200 ms so a
    /// continuous drag doesn't spam either subsystem.
    func setAirplayDelay(_ ms: Int) {
        let clamped = min(max(ms, AppModel.airplayDelayMsRange.lowerBound),
                          AppModel.airplayDelayMsRange.upperBound)
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
    private func commitAirplayDelay(_ ms: Int) async {
        do {
            let applied = try await router.setLocalFifoDelayMs(ms)
            if applied != airplayDelayMs { airplayDelayMs = applied }
            UserDefaults.standard.set(applied, forKey: AppModel.airplayDelayMsKey)
        } catch {
            lastError = "set delay: \(error.localizedDescription)"
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
        case completed(deltaMs: Int, confidence: Double)
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
    func runAutoCalibrate() async {
        guard mode == .wholeHome else {
            calibrationStatus = .failed("Switch to whole-home mode first")
            return
        }
        guard streamingState == .running else {
            calibrationStatus = .failed("Audio capture isn't running")
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
            reconcileBackgroundCalibration()
        }

        calibrationStatus = .running
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
            setAirplayDelay(next)
            calibrationStatus = .completed(
                deltaMs: delta.deltaMs,
                confidence: delta.confidence,
            )
        } catch {
            calibrationStatus = .failed("\(error)")
        }
        calibrationProgress = nil

        if continuousPausedForManual {
            continuousPausedForManual = false
            reconcileBackgroundCalibration()
        }
    }

    /// Clear a non-idle status. Bound to the popover's "Dismiss" button
    /// on completed/failed states.
    func dismissCalibrationStatus() {
        calibrationStatus = .idle
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
                await MainActor.run { [weak self] () -> CalibrationDiagnosticServer.Snapshot? in
                    guard let self else { return nil }
                    guard self.mode == .wholeHome,
                          self.streamingState == .running else { return nil }
                    return CalibrationDiagnosticServer.Snapshot(
                        devices: self.devices,
                        microphoneDeviceID: self.effectiveMicID
                    )
                }
            }
        )
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
    /// wholeHome AND running AND enabled AND mic-OK. The Router runs
    /// the v4 ContinuousActiveCalibrator loop which periodically
    /// drives ActiveCalibrator and pushes corrected delay values
    /// through setLocalFifoDelayMs internally; this AppModel layer
    /// just records samples for the UI caption.
    func reconcileBackgroundCalibration() {
        // Pause for manual one-shot: stop engine, hold here.
        if continuousPausedForManual {
            if backgroundCalibrationActive { stopBackgroundCalibration(thenReconcile: false) }
            return
        }
        let shouldRun = mode == .wholeHome && streamingState == .running
            && backgroundCalibrationEnabled && hasMicrophonePermission

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
        // Mirror the loop-applied value so the slider stays in sync.
        // We bypass `setAirplayDelay`'s debounced sidecar push — the
        // loop already pushed via setLocalFifoDelayMs — and just
        // update the UI-facing field + persist.
        if airplayDelayMs != sample.appliedDelayMs {
            airplayDelayMs = sample.appliedDelayMs
            UserDefaults.standard.set(
                sample.appliedDelayMs, forKey: AppModel.airplayDelayMsKey
            )
        }
    }

    /// Permission flow when the user toggles Continuous on. Mirrors
    /// `runAutoCalibrate` — prompt if undetermined, surface denied banner.
    func ensureMicPermissionForBackgroundCalibration() async {
        let auth = AVCaptureDevice.authorizationStatus(for: .audio)
        switch auth {
        case .authorized:
            return
        case .denied, .restricted:
            backgroundCalibrationMicDenied = true
        case .notDetermined:
            let granted = await requestMicrophonePermission()
            backgroundCalibrationMicDenied = !granted
            reconcileBackgroundCalibration()
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
        SyncCastLog.log("delayLock: locked at \(value)ms")
    }

    /// Release the lock so calibrators can drive the slider again. Stores
    /// 0 as the persisted lock target so a future launch sees "no lock".
    public func unlockAirplayDelay() {
        UserDefaults.standard.set(0, forKey: AppModel.airplayDelayLockedAtKey)
        delayLockState = .unlocked
        SyncCastLog.log("delayLock: unlocked")
    }

    /// Bump the broadcast delay by an integer ms delta (positive or
    /// negative). Clamped to `airplayDelayMsRange` and routed through the
    /// existing debounced setter so the sidecar gets the change. Lock
    /// state is left untouched — a "nudge while locked" intentionally
    /// drifts the in-memory slider without changing the locked target.
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
            return
        }
        selectedMicID = id
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
    // We do NOT auto-rebuild in whole-home mode: AirPlay receivers have
    // their own RTSP reconnect logic in OwnTone, and the local CoreAudio
    // bridges are driven by the sidecar's broadcaster (different code
    // path). The user only reported the issue in stereo mode.

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
    /// - Only acts in stereo mode + when streaming is running + at least
    ///   one CoreAudio output is enabled. Other states have nothing to
    ///   recover.
    /// - Forces a full local-driver tear-down + rebuild via the new
    ///   `Router.forceLocalDriverRebuild` API, which bypasses the
    ///   `alreadyCorrect` short-circuit.
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
                isRunning: Bool,
                hasEnabledRouting: Bool,
                modeName: String,
                stateName: String,
                devices: [Device]
            ) = await MainActor.run {
                let isStereo = self.mode == .stereo
                let isRunning = self.streamingState == .running
                let hasEnabledRouting = self.routing.values.contains(where: { $0.enabled })
                let snap = self.devices.filter { dev in
                    dev.transport == .coreAudio &&
                        (self.routing[dev.id]?.enabled ?? false)
                }
                return (
                    isStereo,
                    isRunning,
                    hasEnabledRouting,
                    String(describing: self.mode),
                    String(describing: self.streamingState),
                    snap
                )
            }
            guard snapshot.isStereo else {
                SyncCastLog.log("AppModel: post-wake rebuild skipped (mode=\(snapshot.modeName) — only stereo auto-rebuilds; AirPlay self-heals via OwnTone RTSP retry)")
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
            let allDevices = await MainActor.run { self.devices }

            // Retry-with-backoff fixed off-by-one (codex #2): sleep
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
                    SyncCastLog.log("AppModel: post-wake rebuild attempt \(attempt) — UIDs not all live yet, sleeping \(backoffs[attempt - 1] / 1_000_000_000)s")
                    try? await Task.sleep(nanoseconds: backoffs[attempt - 1])
                    if Task.isCancelled { return }
                }
                await self.router.forceLocalDriverRebuild(devices: allDevices)
                let allResolved = await Self.allUIDsResolveToLiveDeviceID(allTargetUIDs)
                if allResolved {
                    if attempt > 0 {
                        SyncCastLog.log("AppModel: post-wake rebuild succeeded on retry attempt \(attempt + 1)/\(maxAttempts)")
                    }
                    return
                }
            }
            SyncCastLog.log("AppModel: post-wake rebuild gave up after \(maxAttempts) attempts — UID(s) never returned")
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
