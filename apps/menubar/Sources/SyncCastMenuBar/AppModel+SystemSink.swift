import Foundation
import SyncCastRouter

/// Menubar side of the system-sink Stereo path.
///
/// The path's whole point is that SyncCast stops intercepting volume keys:
/// macOS renders into a virtual sink device that HAS a volume control, so the
/// menu-bar slider, F11/F12, the HUD and LinearMouse's scroll wheel all work
/// natively. This coordinator is the one piece that has to exist on the app
/// side: it WATCHES that device's volume/mute and forwards every change to the
/// Router, which turns it into a real level on the physical speakers.
///
/// Deliberately not an event tap, not a key handler, and not a poller: a
/// CoreAudio property listener on one device, reusing the debounced
/// `HardwareVolumeObserver` that Direct Stereo already relies on.
///
/// Feedback safety: SyncCast never writes the SINK's volume — only macOS does
/// — so there is no self-write echo to suppress here. What we write is the
/// *downstream* devices (built-in speakers' hardware scalar, the display's
/// DDC level), and those are not watched. The system slider is the single
/// source of truth for level; an external change to a downstream device is
/// overwritten on the next replan rather than fed back.
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

    /// Whether the running configuration uses the sink path at all.
    var pathIsSink: Bool { AppModel.selectedStereoOutputPath == .sink }

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
        guard eligible else {
            teardown()
            return
        }
        Task { [weak self] in
            let snapshot = await router.systemSinkStatus()
            guard let self else { return }
            self.status = snapshot
            guard snapshot.active, let uid = snapshot.uid else {
                self.teardown()
                return
            }
            self.startWatching(uid: uid, router: router, reason: reason)
            self.refreshCapabilities(router: router)
        }
    }

    /// Once-a-second displacement check. `false` for `isSystemDefaultOutput`
    /// while active means the user picked another output in the Sound menu.
    func pollStatus(router: Router) async {
        guard pathIsSink else { return }
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
        capabilityTask?.cancel()
        capabilityTask = nil
        guard observer != nil || watchedUID != nil else { return }
        observer?.setWatchedDevices([])
        watchedUID = nil
        backendsByDeviceID = [:]
        SyncCastLog.log("systemSink: stopped watching the system volume")
    }

    /// Held so the observer callback (which arrives without context) can push
    /// into the actor. Cleared implicitly with the app.
    private var router: Router?

    private func applySystemVolume(_ change: HardwareVolumeObserver.ExternalChange) {
        guard change.deviceID == Self.sinkPseudoDeviceID, let router else { return }
        status = Router.SystemSinkStatus(
            active: status.active,
            uid: status.uid,
            displayName: status.displayName,
            isSystemDefaultOutput: status.isSystemDefaultOutput,
            masterVolume: change.volume ?? status.masterVolume,
            masterMuted: change.muted ?? status.masterMuted
        )
        Task { [router, change] in
            await router.setSystemSinkMaster(
                volume: change.volume, muted: change.muted
            )
        }
    }

    /// Refresh which mechanism carries each output's level. Keyed by SyncCast
    /// device id for the UI; the Router answers by CoreAudio UID.
    func refreshCapabilities(router: Router, uidByDeviceID: [String: String] = [:]) {
        capabilityTask?.cancel()
        capabilityTask = Task { [weak self] in
            let byUID = await router.systemSinkVolumeCapabilities()
            guard let self, !Task.isCancelled else { return }
            guard !uidByDeviceID.isEmpty else {
                // No mapping supplied (the common refresh): keep the previous
                // per-device map rather than blanking the UI, and stash the
                // UID-keyed answer for the next mapped call.
                self.backendsByUID = byUID
                return
            }
            self.backendsByUID = byUID
            self.backendsByDeviceID = uidByDeviceID.compactMapValues { byUID[$0] }
        }
    }

    private(set) var backendsByUID: [String: SystemSinkVolumeLaw.Backend] = [:]

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
    func installDriver(scriptURL: URL?) {
        guard driverInstallState != .running else { return }
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
            SyncCastLog.log("systemSink: driver install → \(result)")
        }
    }

    private nonisolated static func runPrivilegedInstall(
        scriptURL: URL
    ) async -> DriverInstallState {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let quoted = scriptURL.path.replacingOccurrences(of: "\"", with: "\\\"")
                let source = """
                do shell script "/bin/bash \\"\(quoted)\\"" with administrator privileges
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

    /// Whether the popover should offer the driver-install button: only on the
    /// sink path (or when no sink exists at all) and only while SyncCast's own
    /// driver is not the one in use.
    var showsDriverInstallAction: Bool {
        systemSink.shouldOfferDriverInstall
    }

    func installSystemSinkDriver() {
        systemSink.installDriver(scriptURL: AppModel.driverInstallScriptURL)
    }

    /// The install script, looked up in the app bundle first (shipped under
    /// `Contents/Resources/scripts`) and then in the source tree, so a
    /// developer running from a checkout gets the same path.
    static var driverInstallScriptURL: URL? {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/scripts/install-driver.sh")
        if FileManager.default.fileExists(atPath: bundled.path) { return bundled }
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
        let eligible = mode == .stereo
            && AppModel.selectedStereoOutputPath == .sink
            && streamingState == .running
        // Leaving stereo mode entirely retires the displacement pause: it is a
        // statement about the sink path's default output, and whole-home owns
        // that property itself.
        if mode != .stereo, systemSinkPausedByDisplacement {
            systemSinkPausedByDisplacement = false
        }
        systemSink.refresh(router: router, eligible: eligible, reason: reason)
        if eligible {
            systemSink.refreshCapabilities(
                router: router,
                uidByDeviceID: enabledCoreAudioUIDsByDeviceID()
            )
        }
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
    /// Picking another output in the Sound menu while the sink path runs is
    /// treated as INTENT, not as a fault to heal: macOS is now rendering to
    /// the device the user chose, our tap receives nothing, and re-asserting
    /// the sink would yank the default back out from under a deliberate
    /// choice. So we stop the engine, restore nothing (they already moved it),
    /// and say so in the popover. `systemSinkPausedByDisplacement` keeps the
    /// reconciler from immediately restarting and grabbing the output again.
    func pollSystemSinkStatus() async {
        await systemSink.pollStatus(router: router)
        guard mode == .stereo,
              AppModel.selectedStereoOutputPath == .sink,
              streamingState == .running,
              systemSink.status.active,
              !systemSink.status.isSystemDefaultOutput,
              !systemSinkPausedByDisplacement
        else {
            return
        }
        systemSinkPausedByDisplacement = true
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
        SyncCastLog.log("systemSink: user asked to resume the sink path")
        reconcileEngine()
    }
}
