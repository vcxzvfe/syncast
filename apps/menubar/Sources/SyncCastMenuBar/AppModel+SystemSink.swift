import Foundation
import SyncCastRouter

/// Menubar side of every path whose default output is a sink device with a
/// real volume control: the Stereo sink path, and whole-home when SyncCast's
/// own driver is installed.
///
/// The point of those paths is that SyncCast stops intercepting volume keys:
/// macOS renders into a virtual device that HAS a volume control, so the
/// menu-bar slider, F11/F12, the HUD and LinearMouse's scroll wheel all work
/// natively. This coordinator is the one piece that has to exist on the app
/// side: it WATCHES that device's volume/mute and forwards every change to the
/// Router, which turns it into a real level — per-output hardware levels in
/// stereo, the master gain on the samples entering OwnTone in whole-home.
///
/// One coordinator for both modes rather than one per mode: it is one listener
/// on one device, and the two modes differ only in what the Router does with
/// the number. `Router.SystemSinkStatus.drivesSystemVolume` is the flag that
/// says whether a watchable device is in force at all — whole-home's
/// wrapped-aggregate fallback holds the default output but has no volume
/// control, and reports `uid: nil`.
///
/// Deliberately not an event tap, not a key handler, and not a poller: a
/// CoreAudio property listener on one device, reusing the debounced
/// `HardwareVolumeObserver` that Direct Stereo already relies on.
///
/// Feedback safety: the ONE thing that writes this device's volume from inside
/// SyncCast is the popover's master slider (`writeSystemVolume`), which exists
/// so the panel and macOS's own UI cannot disagree. It announces itself
/// through `HardwareVolumeObserver.noteAppInitiatedWrite` first, and the
/// Router re-reads the device rather than trusting the payload, so the echo
/// resolves to the value we just wrote and changes nothing. What we never
/// watch is the *downstream* devices (built-in speakers' hardware scalar, the
/// display's DDC level); the system volume is the single source of truth for
/// level, and an external change to a downstream device is overwritten on the
/// next replan rather than fed back.
@MainActor
@Observable
final class SystemSinkCoordinator {

    /// Sentinel device id for the observer's `WatchedDevice`. The observer's
    /// API is keyed by SyncCast device id because Direct Stereo mirrors
    /// changes into `routing`; the sink is not a routed device at all, so it
    /// carries a reserved id that can never collide with a discovery id.
    static let sinkPseudoDeviceID = "__syncast.systemSink__"

    /// Short debounce: this observer is the system volume itself, and a held
    /// volume key repeats every ~33 ms.
    private static let readDebounce: DispatchTimeInterval = .milliseconds(20)

    enum DriverInstallState: Equatable {
        case idle
        case running
        case succeeded(String)
        case failed(String)
    }

    /// Live sink state, mirrored from the Router for the popover.
    private(set) var status = Router.SystemSinkStatus(
        active: false,
        uid: nil,
        displayName: nil,
        isSystemDefaultOutput: false,
        masterVolume: 1,
        masterMuted: false
    )
    /// Per-output volume backend, keyed by SyncCast device id, so a row can
    /// say how its level is being carried (hardware / display OSD / software).
    private(set) var backendsByDeviceID: [String: SystemSinkVolumeLaw.Backend] = [:]
    private(set) var driverInstallState: DriverInstallState = .idle

    /// Whether the STEREO configuration uses the sink path at all. Whole-home
    /// has no such switch — which owner it gets is decided by what is
    /// installed, and the Router answers that through `status`.
    var pathIsSink: Bool { AppModel.selectedStereoOutputPath == .sink }

    /// True when a watched device's own volume scalar is the level in force.
    /// The single fact the panel and the media-key gate key on.
    var drivesSystemVolume: Bool { status.active && status.drivesSystemVolume }

    /// Which sink this launch would use, independent of whether it is running.
    var installedSinkName: String? { SystemSinkDevice.resolved?.displayName }

    /// True when SyncCast's own driver is NOT the sink in use — i.e. the
    /// popover should still offer to install it.
    var shouldOfferDriverInstall: Bool {
        SystemSinkDevice.resolved?.uid != SystemSinkDevice.syncCastDriverUID
    }

    private var observer: HardwareVolumeObserver?
    private var watchedUID: String?
    private var capabilityTask: Task<Void, Never>?

    // MARK: - Lifecycle

    /// Called from `AppModel.updateVolumeKeyEligibility` (the one place that
    /// already fires on every mode / streaming-state transition) and from the
    /// once-a-second health poll.
    func refresh(router: Router, eligible: Bool, reason: String) {
        // Every refresh opens a new episode. The status read below is a
        // suspension point, and `refresh` fires on EVERY mode / streaming
        // transition, so a `refresh(eligible: true)` can suspend, a
        // `refresh(eligible: false)` can tear down, and the first task can
        // then resume and re-attach a HAL listener to a path that is no longer
        // running — which also poisons `watchedUID`, so the next legitimate
        // start short-circuits and the system volume silently stops working
        // until the app is restarted. The episode counter plus the post-await
        // re-check close that; the task is also cancelled on teardown.
        refreshEpisode &+= 1
        let episode = refreshEpisode
        refreshTask?.cancel()
        guard eligible else {
            teardown()
            return
        }
        refreshTask = Task { [weak self] in
            let snapshot = await router.systemSinkStatus()
            guard let self, !Task.isCancelled, episode == self.refreshEpisode else {
                return
            }
            self.status = snapshot
            // A sink that holds the default output but exposes no volume
            // control (whole-home's wrapped aggregate) keeps its STATUS — the
            // panel still has to say which device the Sound menu shows, and
            // the displacement poll still has to work — but there is nothing
            // to listen to.
            guard snapshot.active, snapshot.drivesSystemVolume,
                  let uid = snapshot.uid
            else {
                self.stopWatching()
                return
            }
            self.startWatching(uid: uid, router: router, reason: reason)
            self.refreshCapabilities(router: router)
        }
    }

    /// Monotonic episode counter pairing each in-flight `refresh` with the
    /// state that started it.
    private var refreshEpisode: UInt64 = 0
    private var refreshTask: Task<Void, Never>?

    /// Once-a-second displacement check. `false` for `isSystemDefaultOutput`
    /// while active means the user picked another output in the Sound menu.
    ///
    /// Runs in whole-home too: there the same property is what tells the user
    /// their Mac is playing every track twice.
    func pollStatus(router: Router, modeIsWholeHome: Bool) async {
        guard pathIsSink || modeIsWholeHome else { return }
        let snapshot = await router.systemSinkStatus()
        guard snapshot != status else { return }
        status = snapshot
    }

    private func startWatching(uid: String, router: Router, reason: String) {
        if watchedUID == uid, observer != nil { return }
        let observer = self.observer ?? HardwareVolumeObserver(
            readDebounce: Self.readDebounce
        ) { [weak self] change in
            Task { @MainActor [weak self] in
                self?.applySystemVolume(change)
            }
        }
        self.observer = observer
        self.router = router
        watchedUID = uid
        observer.setWatchedDevices([
            HardwareVolumeObserver.WatchedDevice(
                deviceID: Self.sinkPseudoDeviceID, uid: uid
            )
        ])
        SyncCastLog.log(
            "systemSink: watching \(uid) as the system volume (\(reason))"
        )
    }

    private func teardown() {
        refreshTask?.cancel()
        refreshTask = nil
        stopWatching()
        // Otherwise the popover keeps showing a live "系统音量 NN%" line for a
        // path that is no longer running.
        status = Router.SystemSinkStatus(
            active: false,
            uid: status.uid,
            displayName: status.displayName,
            isSystemDefaultOutput: false,
            masterVolume: status.masterVolume,
            masterMuted: status.masterMuted
        )
    }

    /// Detach the HAL listener without touching `status`. Split out from
    /// `teardown` because a sink can legitimately hold the default output with
    /// no volume control to listen to (whole-home's wrapped aggregate), and
    /// blanking the status there would take the panel's device name and the
    /// displacement banner down with it.
    private func stopWatching() {
        capabilityTask?.cancel()
        capabilityTask = nil
        guard observer != nil || watchedUID != nil else { return }
        observer?.setWatchedDevices([])
        watchedUID = nil
        backendsByDeviceID = [:]
        backendsByUID = [:]
        uidByDeviceID = [:]
        SyncCastLog.log("systemSink: stopped watching the system volume")
    }

    // MARK: - Writing the system volume (the panel's master slider)

    /// Move the system volume from inside SyncCast.
    ///
    /// Only the popover's master slider calls this, and only while the sink
    /// drives the master. It writes macOS's OWN volume control rather than a
    /// private copy, so there is exactly one number: drag the panel slider and
    /// the menu-bar slider moves with it, and vice versa. A private mirror
    /// would be a second authority over the same level, which is the drift
    /// this whole path exists to remove.
    ///
    /// The write is announced to the observer first so the listener callback
    /// it provokes is not mistaken for a user action mid-drag; the Router
    /// re-reads the device anyway, so the worst case is a redundant apply.
    @discardableResult
    func writeSystemVolume(scalar: Float, router: Router) -> Bool {
        guard drivesSystemVolume, let uid = status.uid else { return false }
        let clamped = max(0, min(1, scalar))
        observer?.noteAppInitiatedWrite(uid: uid)
        guard AggregateDevice.applyHardwareVolume(uid: uid, volume: clamped) else {
            SyncCastLog.log(
                "systemSink: device \(uid) refused a volume write of \(clamped)"
            )
            return false
        }
        // Optimistic, so the slider tracks the drag instead of waiting a
        // debounce for the listener to confirm what we just wrote.
        status = Self.status(status, masterVolume: clamped)
        Task { [router] in
            await router.setSystemSinkMaster(volume: clamped, muted: nil)
        }
        return true
    }

    /// Mute counterpart of `writeSystemVolume`. Writes the device's own Mute
    /// property, so the menu bar shows the same muted state.
    @discardableResult
    func writeSystemMute(_ muted: Bool, router: Router) -> Bool {
        guard drivesSystemVolume, let uid = status.uid else { return false }
        observer?.noteAppInitiatedWrite(uid: uid)
        guard AggregateDevice.applyHardwareMute(uid: uid, muted: muted) else {
            SyncCastLog.log("systemSink: device \(uid) refused a mute write")
            return false
        }
        status = Self.status(status, masterMuted: muted)
        Task { [router] in
            await router.setSystemSinkMaster(volume: nil, muted: muted)
        }
        return true
    }

    /// Copy one field of a status snapshot. The struct has no `with`-style
    /// API and open-coding the six-field initialiser at every call site is how
    /// a field silently stops being carried.
    private static func status(
        _ base: Router.SystemSinkStatus,
        masterVolume: Float? = nil,
        masterMuted: Bool? = nil
    ) -> Router.SystemSinkStatus {
        Router.SystemSinkStatus(
            active: base.active,
            uid: base.uid,
            displayName: base.displayName,
            isSystemDefaultOutput: base.isSystemDefaultOutput,
            masterVolume: masterVolume ?? base.masterVolume,
            masterMuted: masterMuted ?? base.masterMuted,
            drivesSystemVolume: base.drivesSystemVolume
        )
    }

    /// Held so the observer callback (which arrives without context) can push
    /// into the actor. Cleared implicitly with the app.
    private var router: Router?

    private func applySystemVolume(_ change: HardwareVolumeObserver.ExternalChange) {
        guard change.deviceID == Self.sinkPseudoDeviceID, let router else { return }
        status = Self.status(
            status,
            masterVolume: change.volume,
            masterMuted: change.muted
        )
        Task { [router, change] in
            await router.setSystemSinkMaster(
                volume: change.volume, muted: change.muted
            )
        }
    }

    /// Refresh which mechanism carries each output's level. Keyed by SyncCast
    /// device id for the UI; the Router answers by CoreAudio UID.
    ///
    /// The mapping is REMEMBERED rather than passed through to the task. Two
    /// callers exist — the status refresh (which has no mapping) and
    /// `AppModel.refreshSystemSinkPath` (which does) — and they share one
    /// cancellable task; a later mapping-less call used to cancel the mapped
    /// one mid-DDC-probe and leave every per-row hint blank.
    func refreshCapabilities(router: Router, uidByDeviceID: [String: String] = [:]) {
        if !uidByDeviceID.isEmpty {
            self.uidByDeviceID = uidByDeviceID
        }
        capabilityTask?.cancel()
        let mapping = self.uidByDeviceID
        capabilityTask = Task { [weak self] in
            let byUID = await router.systemSinkVolumeCapabilities()
            guard let self, !Task.isCancelled else { return }
            self.backendsByUID = byUID
            guard !mapping.isEmpty else { return }
            self.backendsByDeviceID = mapping.compactMapValues { byUID[$0] }
        }
    }

    /// Seam for the panel-authority tests: the real `status` arrives from the
    /// Router across an actor hop, which a unit test cannot stage without a
    /// running engine and an installed driver. Nothing in the app calls this —
    /// the property stays `private(set)` for production code.
    func applyStatusForTesting(_ status: Router.SystemSinkStatus) {
        self.status = status
    }

    private(set) var backendsByUID: [String: SystemSinkVolumeLaw.Backend] = [:]
    /// Last known device id -> CoreAudio UID mapping for the enabled outputs.
    private var uidByDeviceID: [String: String] = [:]

    /// Human-readable note for one output row, or nil when there is nothing
    /// worth saying (the level is carried by real hardware).
    func volumeBackendHint(forUID uid: String) -> String? {
        switch backendsByUID[uid] {
        case .coreAudioHardware, .none:
            return nil
        case .ddc:
            return "音量经显示器 DDC/CI 控制 · level via display DDC/CI"
        case .softwareGain:
            return "音量为软件增益（无硬件音量） · software gain"
        }
    }

    // MARK: - Driver install

    /// Install `SyncCastAudio.driver` into `/Library/Audio/Plug-Ins/HAL` and
    /// restart coreaudiod. Requires an admin password, which macOS collects in
    /// its own dialog — SyncCast never sees it.
    ///
    /// The install script is the same one a developer runs by hand
    /// (`scripts/install-driver.sh`), so there is exactly one install path to
    /// keep working.
    func installDriver(scriptURL: URL?, engineIsRunning: Bool) {
        guard driverInstallState != .running else { return }
        // Installing restarts coreaudiod (`killall coreaudiod`; launchd
        // respawns it — `launchctl kickstart` is refused while SIP is
        // engaged), which destroys the process tap, the tap aggregate and our
        // own aggregate device out from under a running engine. TapCapture's
        // onUnexpectedStop only records the event, so the app would look
        // healthy and play nothing. Refuse rather than silently break.
        guard !engineIsRunning else {
            driverInstallState = .failed(
                "安装会重启 coreaudiod：请先取消勾选输出设备（停止播放）再安装 · stop playback first"
            )
            return
        }
        guard let scriptURL, FileManager.default.fileExists(atPath: scriptURL.path) else {
            driverInstallState = .failed(
                "找不到安装脚本 install-driver.sh · installer script not found"
            )
            return
        }
        driverInstallState = .running
        Task { [weak self] in
            let result = await Self.runPrivilegedInstall(scriptURL: scriptURL)
            guard let self else { return }
            self.driverInstallState = result
            // Installing restarts coreaudiod, after which a UID can be served
            // by a different AudioObjectID — drop the memoised transport-type
            // verdicts rather than classify the new device from the old one.
            VirtualOutputPolicy.resetCache()
            SyncCastLog.log("systemSink: driver install → \(result)")
        }
    }

    private nonisolated static func runPrivilegedInstall(
        scriptURL: URL
    ) async -> DriverInstallState {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // Two layers of quoting, and BOTH matter because this string
                // ends up running as root.
                //
                //  1. AppleScript string literal: escape backslashes, then
                //     double quotes.
                //  2. Shell: `quoted form of` wraps the path in single quotes
                //     the way AppleScript itself knows to. Escaping only the
                //     double quotes (as a first cut did) leaves `$(...)`,
                //     backticks and `;` live inside the command — a bundle
                //     sitting in a path with shell metacharacters would then
                //     execute them with administrator privileges.
                let literal = scriptURL.path
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                let source = """
                do shell script "/bin/bash " & quoted form of "\(literal)" with administrator privileges
                """
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", source]
                let out = Pipe()
                let err = Pipe()
                process.standardOutput = out
                process.standardError = err
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: .failed("无法启动安装程序: \(error.localizedDescription)"))
                    return
                }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                let errData = err.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let stdout = String(decoding: outData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let stderr = String(decoding: errData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if process.terminationStatus == 0 {
                    continuation.resume(returning: .succeeded(
                        stdout.isEmpty
                            ? "已安装，请重启 SyncCast · installed, restart SyncCast"
                            : stdout
                    ))
                } else {
                    // osascript reports a user-cancelled auth dialog as -128.
                    let message = stderr.contains("-128")
                        ? "已取消 · cancelled"
                        : (stderr.isEmpty ? "退出码 \(process.terminationStatus)" : stderr)
                    continuation.resume(returning: .failed(message))
                }
            }
        }
    }
}

// MARK: - AppModel integration

extension AppModel {

    /// One-line status for the popover.
    ///
    /// Three states worth distinguishing:
    ///   * running and holding the default output — say WHICH device the Sound
    ///     menu now shows, because that is the surprising part;
    ///   * running but displaced — the user picked another output, so SyncCast
    ///     is not receiving audio at all;
    ///   * not on the sink path — say what is carrying volume instead.
    var systemSinkStatusLine: String? {
        if mode == .wholeHome { return wholeHomeSinkStatusLine }
        guard mode == .stereo else { return nil }
        guard AppModel.selectedStereoOutputPath == .sink else {
            guard AppModel.selectedStereoOutputPath == .direct else { return nil }
            return systemSink.installedSinkName == nil
                ? "系统音量不可用：未安装虚拟声卡 · system volume needs a virtual sink"
                : nil
        }
        let name = systemSink.status.displayName
            ?? systemSink.installedSinkName
            ?? SystemSinkDevice.syncCastDriverName
        if systemSinkPausedByDisplacement {
            return "已暂停：输出被切到别处，选回「\(name)」后点继续 · paused, output moved away"
        }
        guard systemSink.status.active else {
            return "系统音量将由「\(name)」承载 · system volume via \(name)"
        }
        if !systemSink.status.isSystemDefaultOutput {
            return "输出已被切走：请在「声音」里选回「\(name)」 · output moved away, pick \(name) again"
        }
        let percent = Int((systemSink.status.masterVolume * 100).rounded())
        return systemSink.status.masterMuted
            ? "系统音量：静音（输出「\(name)」） · system volume muted"
            : "系统音量 \(percent)%（输出「\(name)」） · system volume \(percent)%"
    }

    /// Whole-home's counterpart. Three things worth saying, in the order they
    /// matter:
    ///
    ///   * paused because the user moved the output away — the one state where
    ///     nothing is playing and there is an action to take;
    ///   * the system volume IS the master — say the level, because "the
    ///     panel's 总音量 slider now follows the menu bar" is the surprising
    ///     part of this mode;
    ///   * the wrapped fallback — say which device the Sound menu shows and
    ///     that volume lives in the panel, since the system slider is greyed.
    var wholeHomeSinkStatusLine: String? {
        let name = systemSink.status.displayName ?? WholeHomeSinkOutput.displayName
        if systemSinkPausedByDisplacement {
            return "已暂停：输出被切到别处，选回「\(name)」后点继续 · paused, output moved away"
        }
        guard systemSink.status.active else { return nil }
        guard systemSink.drivesSystemVolume else {
            return "输出「\(name)」（系统滑杆置灰，音量用下面的总音量） · volume via the panel"
        }
        if !systemSink.status.isSystemDefaultOutput {
            return "输出已被切走：请在「声音」里选回「\(name)」 · output moved away, pick \(name) again"
        }
        let percent = VolumeCurve.percent(
            forFraction: Double(systemSink.status.masterVolume)
        )
        return systemSink.status.masterMuted
            ? "系统音量：静音（输出「\(name)」） · system volume muted"
            : "系统音量 \(percent)%（输出「\(name)」） · system volume \(percent)%"
    }

    /// Whether the popover should offer the driver-install button: only on the
    /// sink path (or when no sink exists at all) and only while SyncCast's own
    /// driver is not the one in use.
    var showsDriverInstallAction: Bool {
        systemSink.shouldOfferDriverInstall
    }

    func installSystemSinkDriver() {
        systemSink.installDriver(
            scriptURL: AppModel.driverInstallScriptURL,
            engineIsRunning: streamingState == .running
        )
    }

    /// The install script.
    ///
    /// The bundled copy wins: `package-app.sh` puts it in `Contents/Resources`
    /// NEXT TO a prebuilt `SyncCastAudio.driver`, and the script installs that
    /// sibling rather than building from source — which is the only thing that
    /// can work in a distributed .app, where no checkout exists. The source
    /// path is the developer fallback.
    static var driverInstallScriptURL: URL? {
        if let bundled = Bundle.main.url(
            forResource: "install-driver", withExtension: "sh"
        ), FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SyncCastMenuBar
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // menubar
            .deletingLastPathComponent()   // apps
            .appendingPathComponent("scripts/install-driver.sh")
        return FileManager.default.fileExists(atPath: repo.path) ? repo : nil
    }

    /// Per-row note about HOW this output's level is being carried on the sink
    /// path. Nil for the ordinary case (the device has a real hardware volume)
    /// and outside the sink path, so no row grows a line it does not need.
    func systemSinkVolumeHint(for deviceID: String) -> String? {
        guard mode == .stereo,
              AppModel.selectedStereoOutputPath == .sink,
              streamingState == .running
        else {
            return nil
        }
        switch systemSink.backendsByDeviceID[deviceID] {
        case .ddc:
            return "跟随系统音量（DDC/CI） · follows system volume via DDC/CI"
        case .softwareGain:
            return "跟随系统音量（软件增益） · follows system volume, software gain"
        case .coreAudioHardware, nil:
            return nil
        }
    }

    /// Sink-path counterpart of `updateVolumeKeyEligibility`'s Direct Stereo
    /// half. Called from the same place, so every transition is covered.
    func refreshSystemSinkPath(reason: String) {
        let stereoSink = mode == .stereo
            && AppModel.selectedStereoOutputPath == .sink
            && streamingState == .running
        // Whole-home always has a default-output owner while it runs; whether
        // that owner has a volume control is the Router's answer, not ours.
        let eligible = stereoSink
            || (mode == .wholeHome && streamingState == .running)
        // Switching modes is an explicit user action that re-establishes the
        // default output, so it retires a displacement pause taken in the
        // other mode. Without this the engine would refuse to start in the
        // mode the user just picked, with a banner about the one they left.
        if let pausedIn = systemSinkPauseMode, pausedIn != mode {
            systemSinkPausedByDisplacement = false
            systemSinkPauseMode = nil
        }
        systemSink.refresh(router: router, eligible: eligible, reason: reason)
        if stereoSink {
            systemSink.refreshCapabilities(
                router: router,
                uidByDeviceID: enabledCoreAudioUIDsByDeviceID()
            )
        }
        // The media-key gate depends on whether the sink drives the system
        // volume, which the refresh above resolves asynchronously — push it
        // again once we know.
        pushVolumeKeyEligibility()
    }

    /// Enabled local outputs as `device id → CoreAudio UID`, for mapping the
    /// Router's UID-keyed capability answer back onto popover rows.
    func enabledCoreAudioUIDsByDeviceID() -> [String: String] {
        var result: [String: String] = [:]
        for device in devices where device.transport == .coreAudio {
            guard routing[device.id]?.enabled ?? false,
                  let uid = device.coreAudioUID
            else {
                continue
            }
            result[device.id] = uid
        }
        return result
    }

    /// Once-a-second poll: keeps the "output moved away" banner honest, and
    /// acts on it.
    ///
    /// Picking another output in the Sound menu while SyncCast owns the
    /// default output is treated as INTENT, not as a fault to heal: macOS is
    /// now rendering to the device the user chose, and SyncCast is either
    /// receiving nothing (stereo sink path) or playing everything twice at two
    /// latencies (whole-home). So we stop the engine, restore nothing (they
    /// already moved it), and say so in the popover.
    /// `systemSinkPausedByDisplacement` keeps the reconciler from immediately
    /// restarting and grabbing the output back.
    ///
    /// ONE policy for every path that takes the default output over.
    /// Whole-home used to have its own banner with a 「切回」 button that put
    /// the sink back — i.e. the same condition, judged the opposite way. Two
    /// answers to one question is how a user ends up clicking 「切回」 against
    /// the headphones they just plugged in.
    func pollSystemSinkStatus() async {
        await systemSink.pollStatus(router: router, modeIsWholeHome: mode == .wholeHome)
        // The gate reads a status the poll above may have just changed.
        pushVolumeKeyEligibility()
        guard streamingState == .running, !systemSinkPausedByDisplacement,
              await router.systemSinkDisplaced
        else {
            return
        }
        systemSinkPausedByDisplacement = true
        systemSinkPauseMode = mode
        SyncCastLog.log(
            "systemSink: default output moved away by the user — stopping routing (no restore, no re-assert)"
        )
        await router.stop()
        streamingState = .idle
        lastError = nil
    }

    /// User-driven resume after a displacement stop. Deliberately manual, for
    /// the same reason the stop is: SyncCast must not fight the Sound menu.
    func resumeAfterSystemSinkDisplacement() {
        guard systemSinkPausedByDisplacement else { return }
        systemSinkPausedByDisplacement = false
        systemSinkPauseMode = nil
        SyncCastLog.log("systemSink: user asked to resume the sink path")
        reconcileEngine()
    }
}
