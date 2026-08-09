import AppKit
import CoreAudio
import Foundation
import Observation
import SyncCastDiscovery
import SyncCastRouter

/// Lock state for the whole-home AirPlay delay slider. `.unlocked` is the
/// default (free-running); `.locked(at:)` carries the millisecond target
/// the user has pinned.
public enum DelayLockState: Equatable {
    case unlocked
    case locked(at: Int)  // ms
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

    // MARK: - Whole-home local output selection (direction B)

    /// CoreAudio UIDs of the local outputs the user picked for whole-home, in
    /// their chosen order. Stored as UIDs (never names, never indices) so the
    /// selection survives moving between an office display and a home display.
    /// Under direction B these are plain OwnTone outputs, not AirPlay targets:
    /// no pairing, no PIN.
    var wholeHomeLocalMemberUIDs: [String] = []
    /// AirPlay pairing state per stable device key.
    var pairingStates: [String: PairingState] = [:]
    var pairingErrors: [String: String] = [:]
    /// Drives the two-stage pairing sheet. nil when no attempt is running.
    var pairingSheet: PairingSheetState?
    /// Owns the window that hosts the pairing flow. Created on first pairing
    /// attempt, then reused. Not observed: it is UI plumbing, not state, and
    /// tracking it would make every view that reads the model depend on it.
    @ObservationIgnored var pairingWindowController: PairingWindowController?
    /// Enabled-device memory per mode, keyed by the device's STABLE key
    /// rather than by its per-launch id.
    ///
    /// Switching modes disables devices the new mode cannot drive. Without
    /// this, switching to stereo and back silently cleared every AirPlay
    /// selection — and once selections became persistent, a mode round trip
    /// would have eaten the persisted value too.
    var rememberedEnabledKeysByMode: [Mode: Set<String>] = [:]
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
    var mode: Mode = .stereo {
        didSet { updateVolumeKeyEligibility(reason: "mode → \(mode.rawValue)") }
    }
    var streamingState: StreamingState = .idle {
        didSet {
            updateVolumeKeyEligibility(
                reason: "streamingState → \(streamingState.rawValue)"
            )
        }
    }
    var lastError: String?
    /// Screen Recording TCC permission state.
    var screenRecordingGranted: Bool = false

    // MARK: - Whole-home delay-line tuning
    //
    // User-tunable broadcast-side delay aligning local bridges with
    // AirPlay 2's PTP-anchored playout (~1.8 s). The slider in the
    // popover writes into `airplayDelayMs`; a debounced setter pushes
    // the change to the sidecar via JSON-RPC `local_fifo.set_delay_ms`.

    /// User-tunable broadcast-side delay (ms) for the whole-home FIFO,
    /// aligning local bridges with AirPlay 2's ~1.8 s PTP playout.
    /// Persisted to `UserDefaults` so user-dialed drift survives launches.
    var airplayDelayMs: Int = AppModel.loadPersistedDelayMs()
    /// Last sidecar `actual_delivery_lag_ms` reading; nil before first
    /// sample or outside whole-home. Drives the slider's caption.
    var measuredLagMs: Int? = nil
    static let airplayDelayMsKey = "syncast.airplayDelayMs"
    /// Fresh-install broadcast-delay default. CORRECTED to 0 to match the
    /// Direction-B timing model (sidecar `DEFAULT_LOCAL_FIFO_DELAY_MS`):
    /// OwnTone's fifo pipe already releases each byte at the AirPlay-2
    /// playout instant, so no positive broadcaster delay is needed — the
    /// residual local pipeline latency is trimmed EARLIER via the OwnTone
    /// fifo `offset_ms`, and long-term drift is handled by the Swift
    /// Layer-2 clock-following PLL, not this fixed value. (A user who
    /// previously pinned a large delay under the old 1750 model still has
    /// that value persisted; resetting the Sync slider re-derives from 0.)
    static let defaultAirplayDelayMs: Int = 0
    /// UI cap for the global local-fifo delay slider. 5000 ms leaves
    /// headroom for slow AirPlay receivers (some HomePod variants buffer
    /// 3–4 s). The sidecar still clamps to [0, 10000] as an absolute
    /// safety bound.
    static let localFifoDelayMsRange: ClosedRange<Int> = 0...5000
    static let airplayDelayMsRange: ClosedRange<Int> = localFifoDelayMsRange

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

    /// UserDefaults keys written by features that have since been removed
    /// (legacy hybrid tracker, microphone-based acoustic calibration).
    /// Leaving them behind would clutter the user's defaults plist forever.
    private static let retiredDefaultsKeys = [
        "syncast.hybridTrackingEnabled",
        "syncast.bgCalibrationEnabled",
        "syncast.bgCalibrationIntervalS",
        "syncast.calibrationMicID",
    ]

    /// One-shot cleanup of `retiredDefaultsKeys`. Idempotent: removing an
    /// absent key is a no-op, so this can run on every launch.
    private static func removeRetiredDefaults() {
        for key in retiredDefaultsKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private var userDelayRevision: UInt64 = 0
    /// Last-seen drift-resync counter per local bridge. The only fifo/bridge
    /// diagnostic the app still consumes: an increase means that device had
    /// to snap its read cursor, which `refreshLocalFifoLag` reports to the
    /// router as whole-home timing instability.
    private var lastLocalBridgeResyncCounts: [String: UInt64] = [:]
    // MARK: - Manual delay lock
    //
    // The lock pins the broadcast-side delay to a user-chosen value so
    // nothing else can move it out from under the user.

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
        // Always the branded icon, including in `.error`. A mute-slash system
        // symbol reads as "SyncCast turned your audio off", which is both
        // alarming and wrong — the fault is surfaced in words via `lastError`
        // in the popover, not by mutating the menu-bar identity. Users find
        // the app by its icon; changing it on every transient error loses them.
        "MenubarIcon"
    }

    /// Is at least one local-output device enabled? Used to decide whether
    /// the audio engine should be running.
    var hasEnabledOutputs: Bool {
        routing.values.contains { $0.enabled }
    }

    private let discovery: DiscoveryService
    let router: Router
    private let sidecarLauncher = SidecarLauncher()
    var sidecarRunning: Bool = false
    private var systemVolumeKeyController: SystemVolumeKeyController?

    /// How media volume keys are currently captured (event tap / monitor
    /// fallback / permission missing). Mirrored from the controller so
    /// the popover can render the Accessibility hint reactively.
    private(set) var volumeKeyCaptureState: SystemVolumeKeyCaptureState =
        .needsPermission

    /// Per-device hardware volume backend for the Direct Stereo covered
    /// set, keyed by SyncCast device id (NOT CoreAudio UID). `.none`
    /// devices get a "volume not controllable" hint in their row.
    /// Populated by `refreshDirectStereoVolumeState`.
    private(set) var directStereoVolumeBackends:
        [String: DirectStereoVolumeBackend] = [:]

    /// Watches covered devices' hardware volume/mute so external changes
    /// (System Settings, Audio MIDI Setup) flow back into `routing` and
    /// the popover sliders stay truthful. Lazily created on first Direct
    /// Stereo run.
    private var hardwareVolumeObserver: HardwareVolumeObserver?

    /// In-flight hardware-state snapshot task; cancelled by the next
    /// refresh so a stale read never overwrites a newer one.
    private var directStereoVolumeSyncTask: Task<Void, Never>?

    /// Media-key gate on the enter-running hardware snapshot (Codex P2):
    /// eligibility flips on synchronously, but until the async snapshot
    /// lands the routing values are last session's persisted sliders — a
    /// key press in that window would step from and WRITE those stale
    /// levels to hardware. Pure transitions live in
    /// `DirectStereoVolumeLogic.SnapshotGate` (harness-checked); this is
    /// just the live state plus the fallback timer that guarantees keys
    /// can never stay dead when a snapshot stalls or fails.
    private var volumeKeySnapshotGate = DirectStereoVolumeLogic.SnapshotGate.State()
    private var volumeKeySnapshotGateFallbackTask: Task<Void, Never>?
    /// Episode that already logged a dropped key, so holding a volume key
    /// (autorepeat ~33 ms) during the gate window logs once, not 70 times.
    private var volumeKeyGateDropLoggedEpisode: UInt64?
    /// Upper bound on how long the gate may hold keys. Generous against
    /// `DDCDisplayVolumeController.settleTimeoutSeconds` (2 s) plus the
    /// HAL reads, yet short enough that a wedged snapshot degrades to the
    /// old behavior (keys live on possibly-stale routing) instead of
    /// permanently dead keys.
    private static let volumeKeySnapshotGateFallbackSeconds: Double = 2.5

    /// Covered-set fingerprint — (SyncCast device id, CoreAudio UID)
    /// pairs — captured by the last hardware snapshot. The reconcile path
    /// re-snapshots ONLY when this changes; `nil` (never snapshotted /
    /// left eligibility) always triggers. Rationale: plain volume/mute
    /// writes also funnel through `reconcileEngine`, but DDC writes are
    /// queued and CoreAudio writes are async on the router actor — a
    /// snapshot racing such a write reads the OLD hardware value and
    /// writes it back into `routing`, visibly yanking the slider the user
    /// just dragged. Snapshots are therefore gated to (a) direct stereo
    /// entering running (`updateVolumeKeyEligibility`), (b) covered-set
    /// changes (here), and (c) explicit events like wake (`handleWake`).
    ///
    /// The fingerprint must include the device id, not just the UID:
    /// discovery can republish the same UID under a new device id while
    /// playback continues, and `directStereoVolumeBackends` plus the
    /// hardware observer are keyed by device id — a UID-only fingerprint
    /// left both on the dead id (see
    /// `DirectStereoVolumeLogic.coveredSetFingerprint`).
    private var lastDirectStereoSnapshotFingerprint:
        Set<DirectStereoVolumeLogic.CoveredDeviceKey>?

    /// One-shot flag key for the Accessibility permission prompt — the
    /// system dialog should appear at most once, on the first "direct
    /// stereo running without permission" transition.
    private static let accessibilityPromptShownKey =
        "syncast.accessibilityPromptShown"

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
        }
        AppModel.removeRetiredDefaults()
        let volumeController = SystemVolumeKeyController(
            onAction: { [weak self] action in
                // Called from the tap thread (or an NSEvent monitor) —
                // hop to the main actor before touching model state.
                Task { @MainActor [weak self] in
                    self?.handleSystemVolumeKey(action)
                }
            },
            onStateChange: { [weak self] state in
                Task { @MainActor [weak self] in
                    self?.volumeKeyCaptureState = state
                }
            }
        )
        volumeController.start()
        self.systemVolumeKeyController = volumeController
        updateVolumeKeyEligibility(reason: "init")
        Task { await self.bootstrap() }
    }

    private func bootstrap() async {
        SyncCastLog.log("bootstrap start")
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
        // 1b. Restore the remembered whole-home local-output selection before
        //     the first engine reconcile, so the very first whole-home start
        //     already knows which local outputs the user picked. It is applied
        //     to the routing table once discovery has reported the devices
        //     that are actually connected (see `applyEvent`).
        loadWholeHomeLocalOutputSelection()
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
                await self.refreshPairingStates()
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
            // Re-seed per-device delay trims from the persisted store after
            // EVERY event, including the ones that `return` early from the
            // migration paths below — hence `defer` rather than a trailing
            // call. A device that just appeared, or was just re-keyed under a
            // fresh `Device.id`, has to pick its remembered trim back up here
            // or the user's tuning silently reverts to zero.
            defer {
                if applyPersistedDeviceTrims() {
                    // Re-seeding moved the normalisation baseline; both legs
                    // have to be re-driven or only the local one moves. Goes
                    // through the same debounce as a stepper press, so a
                    // burst of discovery events costs one commit.
                    scheduleDeviceTrimCommitTask()
                }
            }
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
                            reconcileEngine()
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
                // Direction B: a local output the user previously picked for
                // whole-home has just (re)appeared — the office display came
                // back, or the app relaunched and discovery caught up. Re-enable
                // it so the remembered selection is honoured. Only enables; a
                // device the user disabled is removed from the remembered set at
                // that moment (see `persistWholeHomeLocalOutputSelection`), so
                // this never resurrects a deliberate off.
                if mode == .wholeHome,
                   dev.transport == .coreAudio,
                   let uid = dev.coreAudioUID,
                   wholeHomeLocalMemberUIDs.contains(uid),
                   isSelectableInMode(dev, mode: .wholeHome),
                   routing[dev.id]?.enabled == false {
                    routing[dev.id]?.enabled = true
                    reconcileEngine()
                }
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
                        reconcileEngine()
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
                        reconcileEngine()
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
            lastLocalBridgeResyncCounts.removeAll()
            return
        }
        let bridgeTiming = await router.localBridgeTimingDiagnostics()
        if let lag = diag["actual_delivery_lag_ms"] as? Double {
            measuredLagMs = Int(lag.rounded())
        } else if let lagInt = diag["actual_delivery_lag_ms"] as? Int {
            measuredLagMs = lagInt  // JSON sometimes ships int when float is exact
        }
        // A local bridge that had to snap its read cursor lost waveform
        // continuity on that device, which is exactly the whole-home timing
        // instability the router wants to hear about. The other fifo
        // counters (client count, overflow drops, delay) are reported by the
        // sidecar's own diagnostics and have no consumer here.
        for (id, timing) in bridgeTiming {
            guard let last = lastLocalBridgeResyncCounts[id],
                  timing.driftResyncCount > last else { continue }
            let reason = (
                "local bridge resynced \(id.prefix(8)) "
                + "\(last)->\(timing.driftResyncCount) "
                + "reason=\(timing.driftResyncReason) "
                + "frames=\(timing.driftResyncFrameDelta)"
            )
            await router.noteWholeHomeTimingInstability(reason: reason)
        }
        lastLocalBridgeResyncCounts = bridgeTiming.mapValues {
            $0.driftResyncCount
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
    func reconcileEngine() {
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
                    await reapplyWholeHomeDelayLine(
                        reason: "whole-home route started"
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
                if mode == .wholeHome {
                    await pushDeviceDelayTrims(reason: "engine started")
                }
            } catch {
                SyncCastLog.log("reconcile: router.start FAILED: \(error)")
                lastError = "engine: \(error.localizedDescription)"
                streamingState = .error
            }
        case (.running, false):
            SyncCastLog.log("reconcile: stopping (no enabled outputs)")
            await router.setActiveAirplayDevices([])
            await router.stop()
            streamingState = .idle
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
                // The covered set may have changed (toggle / hot-plug /
                // discovery republishing a UID under a new device id)
                // without a streamingState transition, so the didSet hook
                // doesn't fire — refresh capabilities + hardware volumes
                // for the new set here. GATED on the (id, uid) set
                // actually changing: volume/mute writes also land in this
                // arm via reconcileEngine, and snapshotting on those reads
                // racy hardware state (queued DDC / async router-actor
                // writes) and would shove stale values back into
                // routing. Enter-running and wake snapshots are handled
                // by updateVolumeKeyEligibility / handleWake.
                let coveredFingerprint =
                    DirectStereoVolumeLogic.coveredSetFingerprint(
                        idUIDPairs: enabledDirectStereoVolumeTargets().map {
                            (id: $0.device.id, uid: $0.uid)
                        }
                    )
                if coveredFingerprint != lastDirectStereoSnapshotFingerprint {
                    refreshDirectStereoVolumeState(
                        reason: "reconcile covered set changed"
                    )
                }
            case .wholeHome:
                await router.startWholeHome(devices: devices)
                await reapplyWholeHomeDelayLine(
                    reason: "whole-home route reconciled"
                )
            }
            await pushAirplayState()
            if mode == .wholeHome {
                await pushDeviceDelayTrims(reason: "enabled outputs changed")
            }
        default:
            SyncCastLog.log("reconcile: no-op (state=\(streamingState.rawValue) shouldRun=\(shouldRun))")
            break
        }
    }

    func shutdownForTermination() async -> Bool {
        SyncCastLog.log("AppModel: termination cleanup requested")
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

    private func pushAirplayState() async {
        let enabledAirplay = devices.filter {
            $0.transport == .airplay2
                && (routing[$0.id]?.enabled ?? false)
                // Direction B backstop — independent of `isSelectableInMode`.
                // This is the ACTUAL choke point that registers an AirPlay
                // receiver with OwnTone (below), which is what starts AirPlay
                // pair-setup. Registering this Mac's own Receiver would make
                // macOS throw a full-screen PIN over SyncCast: the v3 self-pair
                // deadlock. Refusing it here means the UI selectability gate and
                // this registration gate are two separate enforcement points, so
                // one regressing does not resurrect self-targeting. (Both still
                // rest on `isLocalMachineReceiver`; if that flag itself were ever
                // wrong, neither gate catches it — see AirPlayDiscovery for how
                // the loopback-interface signal is derived.)
                && !$0.isLocalMachineReceiver
        }
        SyncCastLog.log("pushAirplayState: enabledAirplay=\(enabledAirplay.map { $0.name })")
        for dev in enabledAirplay {
            SyncCastLog.log("  registerAirplayDevice: \(dev.name) host=\(dev.host ?? "?") port=\(dev.port ?? 7000)")
            await router.registerAirplayDevice(
                id: dev.id,
                name: dev.name,
                host: dev.host ?? "",
                port: dev.port ?? 7000,
                airplayDeviceID: dev.airplayDeviceID
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
        let oldMode = mode
        mode = newMode
        if newMode != .wholeHome {
            // Leaving whole-home tears the bridges down, so their resync
            // counters restart from zero next time. Keeping the old values
            // would make the first sample after re-entry look like a huge
            // resync burst.
            lastLocalBridgeResyncCounts.removeAll()
        }
        refreshScreenRecordingStatusForRuntimePath(reason: "mode changed")
        // Remember what was on in the mode we are LEAVING, then disable
        // anything the new mode cannot drive, then restore whatever was on
        // last time we were in the new mode.
        //
        // "Disable what the new mode can't drive" on its own used to destroy
        // the user's selection: switch to stereo and back and every AirPlay
        // receiver was off again. Remembering by stable key rather than by
        // the per-launch device id is what makes it survive.
        rememberedEnabledKeysByMode[oldMode] = enabledStableKeys()
        for dev in devices {
            if !isSelectableInMode(dev, mode: newMode),
               var r = routing[dev.id], r.enabled {
                r.enabled = false
                routing[dev.id] = r
            }
        }
        restoreRememberedSelection(for: newMode)
        // Direction B: the per-mode key map above is in-memory only and empty
        // on a fresh launch, so it cannot restore the local-output choice the
        // user made in a previous session. Apply the UID-keyed persisted set
        // here so entering whole-home honours it whatever is connected now.
        if newMode == .wholeHome {
            applyRememberedWholeHomeLocalOutputs()
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
                }
            }
        } else {
            // No engine to stop — the new mode just needs reconciliation.
            // No async work, so no need to flip the transition flag here.
            reconcileEngine()
        }
    }

    func toggleDevice(_ id: String) {
        let r = routing[id] ?? DeviceRouting(deviceID: id)
        setDeviceEnabled(!r.enabled, for: id)
    }

    func setDeviceEnabled(_ enabled: Bool, for id: String) {
        // Never let a device be switched on in a mode that cannot drive it.
        // For this Mac's own AirPlay Receiver that is not a tidiness rule:
        // it is never a legal whole-home target under direction B, so enabling
        // it is refused here as well as being unlisted in the UI.
        if enabled,
           let device = devices.first(where: { $0.id == id }),
           !isSelectableInMode(device, mode: mode) {
            SyncCastLog.log(
                "setDeviceEnabled: refusing to enable \(device.name) — not selectable in \(mode.rawValue)"
            )
            return
        }
        var r = routing[id] ?? DeviceRouting(deviceID: id)
        let oldEnabled = r.enabled
        if oldEnabled == enabled {
            let name = devices.first(where: { $0.id == id })?.name ?? id
            SyncCastLog.log("setDeviceEnabled: \(name) [id=\(id.prefix(8))] already \(enabled ? "ON" : "off"). routing: { \(routingSummary()) }")
            return
        }
        r.enabled = enabled
        routing[id] = r
        let name = devices.first(where: { $0.id == id })?.name ?? id
        // Emit BOTH the toggled id and the post-toggle full routing so
        // we can prove or disprove the user-reported "click X but Y
        // toggled" symptom from the log alone (no Console.app needed).
        SyncCastLog.log("toggleDevice: \(name) [id=\(id.prefix(8))] \(oldEnabled ? "ON" : "off") → \(r.enabled ? "ON" : "off"). routing: { \(routingSummary()) }")
        // Direction B: in whole-home the enabled local CoreAudio outputs ARE
        // the remembered selection. Persist it by UID whenever it changes so a
        // relaunch (or a change of location) restores exactly what was on.
        if mode == .wholeHome,
           let device = devices.first(where: { $0.id == id }),
           device.transport == .coreAudio {
            persistWholeHomeLocalOutputSelection()
        }
        reconcileEngine()
    }

    private struct DirectVolumeTarget {
        let device: Device
        let route: DeviceRouting
        let uid: String
    }

    private var directStereoVolumeKeyEligible: Bool {
        mode == .stereo
            && Self.selectedStereoOutputPath == .direct
            && streamingState == .running
    }

    private func enabledDirectStereoVolumeTargets() -> [DirectVolumeTarget] {
        devices.compactMap { device in
            guard device.transport == .coreAudio,
                  let route = routing[device.id],
                  route.enabled,
                  let uid = device.coreAudioUID
            else {
                return nil
            }
            return DirectVolumeTarget(device: device, route: route, uid: uid)
        }
    }

    private func handleSystemVolumeKey(_ action: SystemVolumeKeyAction) {
        guard directStereoVolumeKeyEligible else { return }
        // Snapshot gate (Codex P2): until the enter-running hardware
        // snapshot lands, `routing` still holds last session's persisted
        // slider values — stepping from them would write stale levels to
        // hardware. Drop the action (the tap already consumed the event,
        // so macOS shows no "forbidden" OSD); the fallback timer bounds
        // the window to a few seconds at worst.
        guard volumeKeySnapshotGate.allowsKeys else {
            if volumeKeyGateDropLoggedEpisode != volumeKeySnapshotGate.episode {
                volumeKeyGateDropLoggedEpisode = volumeKeySnapshotGate.episode
                SyncCastLog.log(
                    "systemVolumeKey: \(action) dropped — enter-running hardware snapshot still in flight (episode \(volumeKeySnapshotGate.episode))"
                )
            }
            return
        }
        let targets = enabledDirectStereoVolumeTargets()
        guard !targets.isEmpty else { return }
        switch action {
        case .volumeUp:
            applyDirectStereoVolumeKeyChange(
                targets: targets, reason: "volumeUp"
            ) { route in
                var next = route
                next.volume = DirectStereoVolumeLogic.steppedVolume(
                    from: route.volume, direction: .up
                )
                if DirectStereoVolumeLogic.unmutesOnStep(.up) {
                    next.muted = false
                }
                return next
            }
        case .volumeDown:
            applyDirectStereoVolumeKeyChange(
                targets: targets, reason: "volumeDown"
            ) { route in
                var next = route
                next.volume = DirectStereoVolumeLogic.steppedVolume(
                    from: route.volume, direction: .down
                )
                return next
            }
        case .mute:
            let muteAll = DirectStereoVolumeLogic.groupMuteTarget(
                currentlyMuted: targets.map(\.route.muted)
            )
            applyDirectStereoVolumeKeyChange(
                targets: targets, reason: muteAll ? "mute" : "unmute"
            ) { route in
                var next = route
                next.muted = muteAll
                return next
            }
        }
    }

    /// Apply one media-key action across the covered set.
    ///
    /// Each device is transformed RELATIVE to its own current route (its
    /// own volume ± 1/16) — never set to a shared absolute value — so the
    /// per-device balance the user dialed in survives. The old behavior
    /// (read one device's hardware volume as a "reference", write that
    /// absolute value everywhere) collapsed the MBP-speakers-vs-monitor
    /// balance on the first key press, and synchronously read CoreAudio
    /// on the main thread per press.
    ///
    /// Deliberately does NOT call reconcileEngine():
    ///   - a volume key cannot change the covered device set (enabled
    ///     flags are untouched), so reconcile's syncLocalOutputs pass is
    ///     a guaranteed no-op for the direct path;
    ///   - a held key repeats every ~33 ms and each reconcile pass logs
    ///     multiple lines, which flooded launch.log without changing any
    ///     engine state.
    /// The Router's routing copy is kept in sync with a targeted
    /// setRouting push instead.
    private func applyDirectStereoVolumeKeyChange(
        targets: [DirectVolumeTarget],
        reason: String,
        transform: (DeviceRouting) -> DeviceRouting
    ) {
        var changedSummaries: [String] = []
        for target in targets {
            let next = transform(target.route)
            guard next != target.route else { continue }
            routing[target.device.id] = next
            changedSummaries.append(
                "\(target.device.id.prefix(8))=\(String(format: "%.2f", next.volume))\(next.muted ? "(muted)" : "")"
            )
            applyDirectStereoHardwareVolume(
                device: target.device,
                route: next,
                uid: target.uid
            )
            Task { [router] in
                await router.setRouting(next)
            }
        }
        guard !changedSummaries.isEmpty else { return }
        SyncCastLog.log(
            "systemVolumeKey: direct stereo \(reason) → \(changedSummaries.joined(separator: ", "))"
        )
    }

    private func applyDirectStereoHardwareVolumeIfNeeded(for id: String) {
        guard directStereoVolumeKeyEligible,
              let device = devices.first(where: { $0.id == id }),
              device.transport == .coreAudio,
              let uid = device.coreAudioUID,
              let route = routing[id],
              route.enabled
        else {
            return
        }
        applyDirectStereoHardwareVolume(device: device, route: route, uid: uid)
    }

    private func applyDirectStereoHardwareVolume(
        device: Device,
        route: DeviceRouting,
        uid: String
    ) {
        // Announce our write BEFORE it lands so the hardware observer's
        // suppression window is already open when CoreAudio fires the
        // property listener (prevents our own echo re-entering routing).
        hardwareVolumeObserver?.noteAppInitiatedWrite(uid: uid)
        Task { [router] in
            await router.applyDirectStereoHardwareVolume(
                deviceID: device.id,
                uid: uid,
                volume: route.volume,
                muted: route.muted
            )
        }
    }

    // MARK: - Direct Stereo volume-key plumbing

    /// Push the "direct stereo running" gate into the volume-key
    /// controller (read synchronously by the event-tap thread), trigger
    /// the one-shot Accessibility prompt on first eligible transition,
    /// and (re)sync routes from hardware. Called from `mode` /
    /// `streamingState` didSet plus init, so every state transition is
    /// covered without sprinkling calls over the reconcile paths.
    private func updateVolumeKeyEligibility(reason: String) {
        let eligible = directStereoVolumeKeyEligible
        systemVolumeKeyController?.setEligible(eligible)
        if eligible {
            // Snapshot gate (Codex P2): keys stay held (tap consumes,
            // AppModel drops) until the snapshot below lands or the
            // fallback fires. Only a closed→waiting transition arms the
            // timer; eligible→eligible re-entries leave an open gate open.
            let decision = DirectStereoVolumeLogic.SnapshotGate
                .becameEligible(volumeKeySnapshotGate)
            volumeKeySnapshotGate = decision.state
            if decision.shouldArmFallback {
                armVolumeKeySnapshotGateFallback(
                    episode: decision.state.episode
                )
            }
            maybePromptForAccessibility()
            refreshDirectStereoVolumeState(reason: reason)
        } else {
            volumeKeySnapshotGate = DirectStereoVolumeLogic.SnapshotGate
                .becameIneligible(volumeKeySnapshotGate)
            volumeKeySnapshotGateFallbackTask?.cancel()
            volumeKeySnapshotGateFallbackTask = nil
            directStereoVolumeSyncTask?.cancel()
            directStereoVolumeSyncTask = nil
            hardwareVolumeObserver?.setWatchedDevices([])
            // Next eligible entry must always take a fresh snapshot —
            // hardware may have moved while we weren't watching.
            lastDirectStereoSnapshotFingerprint = nil
        }
    }

    /// Bounded release for the snapshot gate: if the enter-running
    /// snapshot stalls (wedged I2C probe, HAL hang) or fails without
    /// reaching `applyDirectStereoVolumeSnapshot`, the keys must degrade
    /// to the old behavior — live, stepping from possibly-stale routing —
    /// rather than stay dead. The episode pairing makes a timer that
    /// outlives a quick leave/re-enter of running inert.
    private func armVolumeKeySnapshotGateFallback(episode: UInt64) {
        volumeKeySnapshotGateFallbackTask?.cancel()
        volumeKeySnapshotGateFallbackTask = Task { [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(
                    Self.volumeKeySnapshotGateFallbackSeconds
                        * 1_000_000_000
                )
            )
            if Task.isCancelled { return }
            guard let self else { return }
            let next = DirectStereoVolumeLogic.SnapshotGate.fallbackFired(
                self.volumeKeySnapshotGate, episode: episode
            )
            if next != self.volumeKeySnapshotGate {
                SyncCastLog.log(
                    "systemVolumeKey: snapshot gate opened by fallback timeout (episode \(episode)) — snapshot never settled, volume keys released"
                )
            }
            self.volumeKeySnapshotGate = next
        }
    }

    /// Show the system Accessibility prompt at most once, and only when
    /// direct stereo is actually running without the permission —
    /// prompting at launch (before the user ever plays audio) would be
    /// noise.
    private func maybePromptForAccessibility() {
        guard volumeKeyCaptureState == .needsPermission else { return }
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.accessibilityPromptShownKey) else {
            return
        }
        defaults.set(true, forKey: Self.accessibilityPromptShownKey)
        systemVolumeKeyController?.promptForAccessibilityPermission()
    }

    /// One-shot sync of route volumes/mutes to REAL hardware state when
    /// direct stereo enters running (or the covered set changes), plus
    /// backend capability capture and hardware-observer wiring.
    ///
    /// Why: the popover slider persists across sessions while hardware
    /// volume does not (or was changed externally). Without this sync the
    /// first media-key press "jumps" every device to stale slider values
    /// — one source of the user-reported "volume control feels off".
    private func refreshDirectStereoVolumeState(reason: String) {
        directStereoVolumeSyncTask?.cancel()
        guard directStereoVolumeKeyEligible else { return }
        let targets = enabledDirectStereoVolumeTargets()
        // Record the fingerprint so the reconcile path skips redundant
        // snapshots until the covered (id, uid) set changes again.
        lastDirectStereoSnapshotFingerprint =
            DirectStereoVolumeLogic.coveredSetFingerprint(
                idUIDPairs: targets.map { (id: $0.device.id, uid: $0.uid) }
            )
        guard !targets.isEmpty else {
            directStereoVolumeBackends = [:]
            hardwareVolumeObserver?.setWatchedDevices([])
            // Nothing to snapshot — the gate must not hold keys hostage
            // for a covered set that doesn't exist (keys would no-op on
            // zero targets anyway, but the episode should settle).
            volumeKeySnapshotGate = DirectStereoVolumeLogic.SnapshotGate
                .snapshotSettled(volumeKeySnapshotGate)
            return
        }
        directStereoVolumeSyncTask = Task { [weak self] in
            guard let self else { return }
            let capabilities = await self.router.directStereoVolumeCapabilities()
            var volumes: [String: Float] = [:]
            for target in targets {
                if Task.isCancelled { return }
                if let v = await self.router.readDirectStereoVolume(uid: target.uid) {
                    volumes[target.uid] = v
                }
            }
            let hardwareUIDs = targets.map(\.uid)
                .filter { capabilities[$0] == .coreAudioHardware }
            let mutes = await Self.readHardwareMutes(uids: hardwareUIDs)
            if Task.isCancelled { return }
            self.applyDirectStereoVolumeSnapshot(
                capabilities: capabilities,
                volumes: volumes,
                mutes: mutes,
                reason: reason
            )
        }
    }

    /// HAL mute reads off the main actor — `refreshDirectStereoVolumeState`
    /// must not block key handling or the UI on CoreAudio IPC.
    private nonisolated static func readHardwareMutes(
        uids: [String]
    ) async -> [String: Bool] {
        await Task.detached(priority: .utility) {
            var result: [String: Bool] = [:]
            for uid in uids {
                if let muted = AggregateDevice.readHardwareMute(uid: uid) {
                    result[uid] = muted
                }
            }
            return result
        }.value
    }

    private func applyDirectStereoVolumeSnapshot(
        capabilities: [String: DirectStereoVolumeBackend],
        volumes: [String: Float],
        mutes: [String: Bool],
        reason: String
    ) {
        guard directStereoVolumeKeyEligible else { return }
        let targets = enabledDirectStereoVolumeTargets()
        var backends: [String: DirectStereoVolumeBackend] = [:]
        var synced: [String] = []
        for target in targets {
            let backend = capabilities[target.uid]
                ?? DirectStereoVolumeBackend.none
            backends[target.device.id] = backend
            var route = target.route
            // Same pure mirror decision as the hardware-observer path: a
            // muted route with a hardware scalar parked at ≈0 (emulated
            // mute, or a driver zeroing the scalar while muted) must keep
            // its saved volume, or a mid-mute refresh destroys the level
            // unmute would restore.
            let decision = DirectStereoVolumeLogic.externalHardwareChange(
                routeVolume: route.volume,
                routeMuted: route.muted,
                observedVolume: volumes[target.uid],
                observedMuted: mutes[target.uid]
            )
            if let volume = decision.volume {
                route.volume = volume
            }
            if let muted = decision.muted {
                route.muted = muted
            }
            if decision.changesAnything {
                routing[target.device.id] = route
                synced.append(
                    "\(target.device.id.prefix(8))=\(String(format: "%.2f", route.volume))\(route.muted ? "(muted)" : "")"
                )
                Task { [router, route] in
                    await router.setRouting(route)
                }
            }
        }
        directStereoVolumeBackends = backends
        let watched = targets
            .filter { backends[$0.device.id] == .coreAudioHardware }
            .map {
                HardwareVolumeObserver.WatchedDevice(
                    deviceID: $0.device.id, uid: $0.uid
                )
            }
        ensureHardwareVolumeObserver().setWatchedDevices(watched)
        // Routing now mirrors real hardware — release the media keys
        // (no-op unless this is the enter-running snapshot the gate was
        // armed for; see SnapshotGate).
        volumeKeySnapshotGate = DirectStereoVolumeLogic.SnapshotGate
            .snapshotSettled(volumeKeySnapshotGate)
        let backendSummary = backends
            .map { "\($0.key.prefix(8))=\($0.value.rawValue)" }
            .sorted()
            .joined(separator: ",")
        SyncCastLog.log(
            "systemVolumeKey: hardware snapshot (\(reason)) backends=[\(backendSummary)] synced=\(synced.isEmpty ? "none" : synced.joined(separator: ","))"
        )
    }

    private func ensureHardwareVolumeObserver() -> HardwareVolumeObserver {
        if let hardwareVolumeObserver {
            return hardwareVolumeObserver
        }
        let observer = HardwareVolumeObserver { [weak self] change in
            // Observer callback arrives on its private queue.
            Task { @MainActor [weak self] in
                self?.handleExternalHardwareVolumeChange(change)
            }
        }
        hardwareVolumeObserver = observer
        return observer
    }

    /// External (non-SyncCast) hardware volume/mute change — mirror it
    /// into routing so the popover slider matches reality. No hardware
    /// write-back here: hardware is already at this value, and writing
    /// would risk a feedback loop.
    ///
    /// The mirror decision is the pure
    /// `DirectStereoVolumeLogic.externalHardwareChange`: it drops the
    /// mute-echo case (route muted, report still muted, observed volume
    /// ≈ 0) so our own mute write — deferred past the observer's
    /// suppression window and republished here — can never overwrite the
    /// saved `route.volume` with 0 (Codex P1).
    private func handleExternalHardwareVolumeChange(
        _ change: HardwareVolumeObserver.ExternalChange
    ) {
        guard directStereoVolumeKeyEligible,
              var route = routing[change.deviceID],
              route.enabled
        else { return }
        let decision = DirectStereoVolumeLogic.externalHardwareChange(
            routeVolume: route.volume,
            routeMuted: route.muted,
            observedVolume: change.volume,
            observedMuted: change.muted
        )
        if let volume = decision.volume {
            route.volume = volume
        }
        if let muted = decision.muted {
            route.muted = muted
        }
        guard decision.changesAnything else { return }
        routing[change.deviceID] = route
        Task { [router, route] in
            await router.setRouting(route)
        }
        SyncCastLog.log(
            "systemVolumeKey: external hardware change \(change.deviceID.prefix(8)) → volume=\(String(format: "%.2f", route.volume)) muted=\(route.muted)"
        )
    }

    // MARK: - Volume-key UI surface

    /// Popover hint visibility: direct stereo is running but the event
    /// tap can't exist without Accessibility.
    var volumeKeyNeedsAccessibilityHint: Bool {
        directStereoVolumeKeyEligible
            && volumeKeyCaptureState == .needsPermission
    }

    /// Re-check Accessibility trust (popover open). Installs the tap
    /// immediately if the user granted permission since the last check.
    func recheckVolumeKeyPermission() {
        systemVolumeKeyController?.recheckPermission(reason: "popover opened")
    }

    func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
        SyncCastLog.log("systemVolumeKey: opened Accessibility settings pane")
    }

    /// Per-device-row hint for devices whose hardware volume cannot be
    /// controlled at all (backend == .none, e.g. DisplayPort audio with
    /// no DDC path). `.ddc` and `.coreAudioHardware` return nil — their
    /// sliders work normally.
    func volumeControlHint(for deviceID: String) -> String? {
        guard directStereoVolumeKeyEligible,
              routing[deviceID]?.enabled == true,
              directStereoVolumeBackends[deviceID]
                == DirectStereoVolumeBackend.none
        else { return nil }
        return "音量不可控 — 请用显示器按键/OSD 调节"
    }

    func setVolume(_ value: Float, for id: String) {
        var r = routing[id] ?? DeviceRouting(deviceID: id)
        r.volume = max(0, min(1, value))
        routing[id] = r
        applyDirectStereoHardwareVolumeIfNeeded(for: id)
        reconcileEngine()
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
        applyDirectStereoHardwareVolumeIfNeeded(for: id)
        reconcileEngine()
        let name = devices.first(where: { $0.id == id })?.name ?? id
        SyncCastLog.log("setMute: \(name) [id=\(id.prefix(8))] \(oldMuted ? "muted" : "unmuted") → \(muted ? "muted" : "unmuted")")
    }

    // MARK: - Per-device delay trim
    //
    // One millisecond bias per enabled output, compensating how far each
    // speaker sits from where the user actually listens (1 ms ≈ 34 cm) plus
    // whatever residual systematic skew Layers 1-3 leave behind. This model
    // owns the RAW SIGNED intent; `Router` normalises it to the non-negative
    // values the two legs can actually apply.

    /// Persistence key. Stores `[persistenceKey: rawTrimMs]` — RAW intent,
    /// never the normalised output. Normalised values depend on which devices
    /// happen to be present, so persisting them would make the stored numbers
    /// drift a little further every session.
    static let deviceTrimDefaultsKey = "syncast.deviceDelayTrimMs"

    /// Debounce before a trim change reaches either leg. Mirrors
    /// `setAirplayDelay`'s 200 ms, and earns it twice over here: each AirPlay
    /// commit costs that receiver a ~0.4 s relatch dropout (OwnTone latches
    /// `offset_ms` at session construction) and each local commit costs a
    /// ~10 ms cross-fade.
    static let deviceTrimCommitDebounceNanos: UInt64 = 200_000_000

    /// Backoff before re-driving a trim commit whose AirPlay half failed
    /// (sidecar restarting OwnTone, IPC not answering). Deliberately longer
    /// than the debounce: the failure mode it covers is a busy sidecar, and
    /// hammering it makes that worse.
    static let deviceTrimRetryDelayNanos: UInt64 = 2_000_000_000

    /// How many times a failed trim commit is re-driven before it is left to
    /// the next natural trigger (a reconcile, or the user touching a
    /// stepper). Bounded so a sidecar that is down for good does not leave a
    /// task looping for the life of the process.
    static let deviceTrimMaxRetries: Int = 3

    /// Raw user intent keyed by `Device.persistenceKey` (`ca:<UID>` /
    /// `ap:<hex>`), NOT by `Device.id` — `Device.id` is regenerated per
    /// process, so keying off it would lose every trim on relaunch. Devices
    /// with no stable key are held in `routing` only and never written.
    ///
    /// A remembered device that is absent right now keeps its entry, exactly
    /// as `WholeHomeMemberStore` keeps an absent UID: the office display
    /// comes back when the user does.
    private var persistedDeviceTrims: [String: Int] = AppModel.loadPersistedDeviceTrims()
    private var deviceTrimCommitTask: Task<Void, Never>?
    /// Internal rather than private so the unit tests can observe that a
    /// re-seed or a failed commit actually left work queued.
    private(set) var pendingTrimDeviceIDs: Set<String> = []
    /// Consecutive failed commits, reset on the first success. Bounds the
    /// retry loop against `deviceTrimMaxRetries`.
    private var deviceTrimRetryCount: Int = 0

    /// True while a debounced trim commit is in flight. The UI uses it to say
    /// "applying…" on AirPlay rows — a 0.4 s silence with no explanation
    /// reads as a bug rather than as the relatch it is.
    private(set) var deviceTrimCommitInFlight: Bool = false

    private static func loadPersistedDeviceTrims() -> [String: Int] {
        guard let raw = UserDefaults.standard.dictionary(forKey: deviceTrimDefaultsKey)
        else { return [:] }
        var out: [String: Int] = [:]
        for (key, value) in raw {
            guard let ms = value as? Int else { continue }
            out[key] = DeviceDelayTrim.clamp(ms)
        }
        return out
    }

    private func persistDeviceTrims() {
        UserDefaults.standard.set(
            persistedDeviceTrims, forKey: AppModel.deviceTrimDefaultsKey
        )
    }

    private func persistenceKey(for deviceID: String) -> String? {
        devices.first { $0.id == deviceID }?.persistenceKey
    }

    /// Re-seed `routing[*].manualDelayMs` from the persisted store.
    ///
    /// Called after every discovery event, because `Device.id` is minted per
    /// process and per appearance: the stable identity lives in
    /// `persistenceKey`, and this is the one place that maps it back onto the
    /// transient id `routing` is keyed by.
    /// Internal rather than private so the unit tests can drive the
    /// stable-key → transient-id re-seeding directly; it is not part of the
    /// UI surface.
    ///
    /// A re-seed is a real trim change and is QUEUED like one. Without that,
    /// a receiver that flapped on Bonjour and came back under a fresh
    /// `Device.id` gets its value restored into `routing` — where it joins
    /// the local leg's normalisation minimum — while the sidecar's own map is
    /// still keyed by the old id and resolves to nothing. The local speakers
    /// then shift for a trim the AirPlay receiver never receives.
    ///
    /// - Returns: whether anything changed, so the caller can decide whether
    ///   to spend a debounced commit. Callers that only want the in-memory
    ///   state (the tests) can ignore it.
    @discardableResult
    func applyPersistedDeviceTrims() -> Bool {
        var changed = false
        for dev in devices {
            guard let key = dev.persistenceKey else { continue }
            let stored = persistedDeviceTrims[key] ?? 0
            // A device with no routing entry yet has nothing to re-seed INTO:
            // writing through the optional chain would silently no-op while
            // still reporting a change, which would queue a commit on every
            // single discovery event forever.
            guard var r = routing[dev.id], r.manualDelayMs != stored else {
                continue
            }
            r.manualDelayMs = stored
            routing[dev.id] = r
            pendingTrimDeviceIDs.insert(dev.id)
            changed = true
        }
        return changed
    }

    /// True when at least one output carries a non-zero trim. Gates the
    /// "Reset trims" affordance so it only exists when it would do something.
    var hasAnyDeviceTrim: Bool {
        routing.values.contains { $0.manualDelayMs != 0 }
    }

    /// The trim currently dialled in for a device, in milliseconds. Signed:
    /// positive means "hold this speaker back".
    func deviceTrimMs(for deviceID: String) -> Int {
        routing[deviceID]?.manualDelayMs ?? 0
    }

    /// Human-readable hint beside the stepper. Sound covers ~34 cm per
    /// millisecond, which is the whole reason this feature has a physical
    /// interpretation at all.
    ///
    /// Phrased as the CORRECTION the value applies, never as the speaker's
    /// distance. The two read opposite: on an AV receiver you type how far
    /// away a speaker is, and the box works out that a distant speaker must
    /// fire EARLIER. Here positive means "hold this one back"
    /// (`DeviceDelayTrim`'s stated convention), so a speaker that is further
    /// away wants a NEGATIVE trim. Labelling `+3 ms` as "further" taught the
    /// user to press the wrong button and doubled the skew they were trying
    /// to remove.
    func deviceTrimDistanceHint(for deviceID: String) -> String {
        let ms = deviceTrimMs(for: deviceID)
        if ms == 0 { return "0 ms" }
        let metres = DeviceDelayTrim.distanceMeters(forMs: ms)
        let sign = ms > 0 ? "+" : "−"
        let sense = ms > 0 ? "held back" : "brought forward"
        return String(
            format: "%@%d ms, %@ ≈ %.1f m", sign, abs(ms), sense, metres
        )
    }

    /// Set one output's trim. In-memory + persisted immediately (so the value
    /// survives a crash mid-tuning); the push to the audio legs is debounced.
    func setDeviceTrim(_ ms: Int, for deviceID: String) {
        let clamped = DeviceDelayTrim.clamp(ms)
        var r = routing[deviceID] ?? DeviceRouting(deviceID: deviceID)
        guard r.manualDelayMs != clamped else { return }
        r.manualDelayMs = clamped
        routing[deviceID] = r
        if let key = persistenceKey(for: deviceID) {
            // Zero is the default, so drop the key rather than storing it —
            // an untouched speaker leaves no trace in the defaults plist.
            if clamped == 0 {
                persistedDeviceTrims.removeValue(forKey: key)
            } else {
                persistedDeviceTrims[key] = clamped
            }
            persistDeviceTrims()
        }
        scheduleDeviceTrimCommit(for: deviceID)
    }

    /// Nudge one output's trim by a signed delta (the stepper's `-` / `+`).
    func nudgeDeviceTrim(_ deltaMs: Int, for deviceID: String) {
        setDeviceTrim(deviceTrimMs(for: deviceID) + deltaMs, for: deviceID)
    }

    func resetDeviceTrim(for deviceID: String) {
        setDeviceTrim(0, for: deviceID)
    }

    /// Clear every trim in one commit.
    ///
    /// Deliberately routed through the same debounced path as a single edit,
    /// so a system that was already at zero produces no IPC at all and
    /// therefore relatches no AirPlay receiver.
    func resetAllDeviceTrims() {
        var changed = false
        for (id, r) in routing where r.manualDelayMs != 0 {
            routing[id]?.manualDelayMs = 0
            pendingTrimDeviceIDs.insert(id)
            changed = true
        }
        if !persistedDeviceTrims.isEmpty {
            persistedDeviceTrims.removeAll()
            persistDeviceTrims()
            changed = true
        }
        guard changed else { return }
        scheduleDeviceTrimCommitTask()
        SyncCastLog.log("deviceTrim: reset all")
    }

    private func scheduleDeviceTrimCommit(for deviceID: String) {
        pendingTrimDeviceIDs.insert(deviceID)
        scheduleDeviceTrimCommitTask()
    }

    /// `after` nil means the normal debounce. Spelled as an optional rather
    /// than a default of `AppModel.deviceTrimCommitDebounceNanos` because a
    /// MainActor-isolated static cannot be evaluated in a default-argument
    /// (nonisolated) context under Swift 6.
    private func scheduleDeviceTrimCommitTask(after delayNanos: UInt64? = nil) {
        let delay = delayNanos ?? AppModel.deviceTrimCommitDebounceNanos
        deviceTrimCommitInFlight = true
        deviceTrimCommitTask?.cancel()
        deviceTrimCommitTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            if Task.isCancelled { return }
            await self?.commitDeviceTrims()
        }
    }

    /// Push the accumulated trim edits.
    ///
    /// Routing goes first so the Router's own copy carries the new
    /// `manualDelayMs` before it normalises; `applyDeviceDelayTrims` then
    /// drives BOTH legs from one snapshot. Outside whole-home this is a
    /// no-op inside the Router (stereo runs a different output path whose
    /// timing is deliberately untouched), but the routing push still happens
    /// so a later switch into whole-home starts from the right values.
    private func commitDeviceTrims() async {
        let ids = pendingTrimDeviceIDs
        pendingTrimDeviceIDs.removeAll()
        for id in ids {
            guard let r = routing[id] else { continue }
            await router.setRouting(r)
        }
        let result = await router.applyDeviceDelayTrims()
        guard result == .applied else {
            // The local leg already moved (applyDeviceDelayTrims applies it
            // before the IPC), so dropping the AirPlay half here would leave
            // the two legs disagreeing by exactly what the user just dialled
            // in — while the UI reports the edit as landed. Re-queue and stay
            // "in flight" so the row keeps saying "applying…".
            deviceTrimRetryCount += 1
            guard deviceTrimRetryCount <= AppModel.deviceTrimMaxRetries else {
                deviceTrimCommitInFlight = false
                deviceTrimRetryCount = 0
                lastError = "Speaker delay trim could not be applied."
                SyncCastLog.log("deviceTrim: giving up after "
                                + "\(AppModel.deviceTrimMaxRetries) retries")
                return
            }
            pendingTrimDeviceIDs.formUnion(ids)
            SyncCastLog.log(
                "deviceTrim: push failed, retry "
                + "\(deviceTrimRetryCount)/\(AppModel.deviceTrimMaxRetries)"
            )
            scheduleDeviceTrimCommitTask(
                after: AppModel.deviceTrimRetryDelayNanos
            )
            return
        }
        deviceTrimRetryCount = 0
        deviceTrimCommitInFlight = false
        if !ids.isEmpty {
            let summary = ids
                .map { "\($0.prefix(8))=\(routing[$0]?.manualDelayMs ?? 0)ms" }
                .sorted()
                .joined(separator: ", ")
            SyncCastLog.log("deviceTrim applied: \(summary)")
        }
    }

    /// Drive both trim legs from a reconcile point rather than from a user
    /// edit, and re-queue on failure through the same path as an edit.
    ///
    /// Needed because enabling or disabling ANY output changes the set the
    /// normalisation minimum is taken over, so every enabled speaker's
    /// effective delay moves. `startWholeHome` / `replan` re-apply the LOCAL
    /// leg on their own; only this drives the AirPlay one.
    private func pushDeviceDelayTrims(reason: String) async {
        let result = await router.applyDeviceDelayTrims()
        guard result == .applied else {
            SyncCastLog.log("deviceTrim: push failed (\(reason)), queued for retry")
            scheduleDeviceTrimCommitTask(
                after: AppModel.deviceTrimRetryDelayNanos
            )
            return
        }
        deviceTrimRetryCount = 0
    }

    /// Live-tune the whole-home FIFO delay. In-memory update is immediate
    /// (snappy UI); IPC + UserDefaults write is debounced 200 ms so a
    /// continuous drag doesn't spam either subsystem.
    func setAirplayDelay(_ ms: Int) {
        let clamped = min(max(ms, AppModel.airplayDelayMsRange.lowerBound),
                          AppModel.airplayDelayMsRange.upperBound)
        if clamped != airplayDelayMs {
            userDelayRevision &+= 1
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

    @discardableResult
    private func reapplyWholeHomeDelayLine(reason: String) async -> Bool {
        guard mode == .wholeHome else { return false }
        let requested = airplayDelayMs
        let applied = await commitAirplayDelay(requested)
        if applied {
            SyncCastLog.log(
                "airplayDelay re-applied to whole-home FIFO: \(airplayDelayMs)ms reason=\(reason)"
            )
        }
        return applied
    }

    /// Reset the slider to the canonical default — same path as a drag.
    func resetAirplayDelayToDefault() {
        setAirplayDelay(AppModel.defaultAirplayDelayMs)
    }

    // MARK: - Manual delay lock

    /// Pin the broadcast-side AirPlay delay to the current `airplayDelayMs`.
    /// The locked value is persisted in UserDefaults so it survives a
    /// relaunch (see `loadPersistedDelayMs` + `loadPersistedLockedAt`).
    public func lockAirplayDelay() {
        let value = airplayDelayMs
        UserDefaults.standard.set(value, forKey: AppModel.airplayDelayLockedAtKey)
        delayLockState = .locked(at: value)
        userDelayRevision &+= 1
        SyncCastLog.log("delayLock: locked at \(value)ms")
    }

    /// Release the lock so the slider is free-running again. Stores
    /// 0 as the persisted lock target so a future launch sees "no lock".
    public func unlockAirplayDelay() {
        UserDefaults.standard.set(0, forKey: AppModel.airplayDelayLockedAtKey)
        delayLockState = .unlocked
        userDelayRevision &+= 1
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
            // Direction B: this Mac's own AirPlay Receiver is NEVER a target.
            // The local speakers participate as an OwnTone fifo output, on
            // OwnTone's player clock — no self-target, no full-screen PIN.
            // Making the Receiver a target would render into the system
            // default output the capture tap covers, closing a feedback loop,
            // and reintroduce the self-pair deadlock direction B removes. This
            // is the UI selectability gate; `pushAirplayState` independently
            // refuses to register a local-machine receiver with OwnTone, so
            // there are two separate enforcement points, not one.
            if d.isLocalMachineReceiver { return false }
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

    /// Genuinely remote AirPlay receivers (Mac mini, Xiaomi, …) — the only
    /// legal AirPlay targets. `airPlayDevices` already drops the local-machine
    /// receiver via `isSelectableInMode`; the repeated `isLocalMachineReceiver`
    /// filter here is defensive but NOT independent (it reads the same flag).
    /// The genuinely independent backstop lives in `pushAirplayState`, which is
    /// the choke point that hands a device to OwnTone.
    var remoteAirPlayDevices: [Device] {
        airPlayDevices.filter { !$0.isLocalMachineReceiver }
    }
    var enabledDeviceCount: Int { routing.values.filter(\.enabled).count }

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
    // recovery path: bump the Router AirPlay timing epoch and reconcile
    // bridges / receiver selection / socket.

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
        // Direction B parks nothing on the system default output, so there is
        // no willSleep cleanup to do — only wake recovery for transiently
        // dropped local outputs.
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
    ///   reconciles route state.
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
                        if snapshot.isRunning && snapshot.hasEnabledRouting {
                            self.reconcileEngine()
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
                    // Explicit post-wake hardware snapshot (gate (c) of
                    // the snapshot policy — see
                    // lastDirectStereoSnapshotFingerprint). DPMS wake reissues
                    // AudioDeviceIDs for the same UIDs: the refresh both
                    // re-reads real hardware volume/mute into routing
                    // and re-wires HardwareVolumeObserver's listeners
                    // onto the fresh ids via setWatchedDevices.
                    await MainActor.run {
                        self.refreshDirectStereoVolumeState(
                            reason: "post-wake rebuild"
                        )
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
    // the observers naturally die with the process. Adding a deinit would
    // require unsafe-isolation gymnastics around `@MainActor` for zero
    // real benefit (NSWorkspace's notification center cleans up
    // observers on process exit anyway).
}
