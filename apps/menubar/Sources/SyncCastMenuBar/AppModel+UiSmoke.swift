import Foundation

/// Dev-only UI smoke hooks.
///
/// Windows are the one part of this app `swift test` cannot honestly cover:
/// the failure mode being guarded against (an AppKit exception raised from a
/// display-cycle layout observer) only happens with a real window server, a
/// real menu-bar panel and a real event loop. So the app itself can be asked
/// to open a window shortly after launch, and the operator watches whether it
/// comes up or the process dies.
///
/// Strictly dev-only, and off unless the environment variable is set — the
/// same rule `SYNCAST_AUTO_TEST` follows.
@MainActor
extension AppModel {

    /// `SYNCAST_UI_SMOKE=<window>`; currently the only window is `token`.
    static let uiSmokeEnvVar = "SYNCAST_UI_SMOKE"

    /// Long enough for the menu-bar item, discovery and the sidecar attach to
    /// settle, so the window opens into a running app rather than a
    /// half-bootstrapped one.
    static let uiSmokeDelaySeconds: Double = 3

    /// The device id the token smoke hook targets when no real receiver has
    /// been discovered. Not a real device, so nothing can be saved against it
    /// — `setLanToken` refuses ids it cannot key.
    static let uiSmokePlaceholderDeviceID = "synccast-ui-smoke"

    /// Which window a given environment asks for, or nil for none. Pure, so
    /// the parsing rule is testable without launching anything.
    static func uiSmokeTarget(environment: [String: String]) -> String? {
        guard let raw = environment[uiSmokeEnvVar] else { return nil }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    /// Schedule whatever `SYNCAST_UI_SMOKE` asked for. Called once, from
    /// bootstrap.
    func scheduleUiSmokeIfRequested() {
        guard let target = Self.uiSmokeTarget(
            environment: ProcessInfo.processInfo.environment
        ) else { return }
        guard !TestEnvironment.isRunningUnderXCTest else { return }
        guard target == "token" else {
            SyncCastLog.log("UI_SMOKE: unknown target '\(target)' (known: token)")
            return
        }
        SyncCastLog.log(
            "UI_SMOKE: will open the LAN token window in \(Self.uiSmokeDelaySeconds)s"
        )
        Task { [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(Self.uiSmokeDelaySeconds * 1_000_000_000)
            )
            guard let self else { return }
            await MainActor.run {
                // A real receiver if discovery found one, so the smoke run
                // exercises the same code path the user hits; the placeholder
                // otherwise, so the hook works on a machine with no receiver.
                let deviceID = self.lanReceiverDevices.first?.id
                    ?? Self.uiSmokePlaceholderDeviceID
                SyncCastLog.log("UI_SMOKE: opening the LAN token window for \(deviceID.prefix(8))")
                self.presentLanTokenWindow(for: deviceID)
            }
        }
    }
}
