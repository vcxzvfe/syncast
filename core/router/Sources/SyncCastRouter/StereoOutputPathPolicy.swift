import Foundation

public enum StereoOutputPathPolicy {
    public enum Path: String, Sendable {
        /// Public aggregate of the real speakers becomes the default output.
        /// No capture, but no system volume either — needs the media-key
        /// event tap (`SystemVolumeKeyController`).
        case direct
        /// A virtual HAL sink becomes the default output and owns the system
        /// volume; a Process Tap pinned to it feeds the real speakers. No
        /// event tap. Requires `SyncCastAudio.driver` or BlackHole 2ch.
        case sink
        /// ScreenCaptureKit capture into the normal fan-out. Explicit fallback.
        case capture
    }

    public static let environmentFlag = "SYNCAST_STEREO_PATH"

    /// Local Stereo prefers the **sink** path whenever a virtual sink device
    /// is installed: it is the only local path where the macOS volume UI
    /// (menu-bar slider, F11/F12, HUD, LinearMouse scroll) drives SyncCast's
    /// outputs natively. Without a sink device it falls back to Direct Stereo,
    /// which is unchanged — media keys there still go through the event tap.
    ///
    /// `SYNCAST_STEREO_PATH=direct` forces the legacy path even when a sink is
    /// installed; `capture`/`sck` forces the ScreenCaptureKit path.
    ///
    /// `sinkAvailable` is injected rather than probed here so the decision is
    /// unit-testable; production callers pass
    /// `SystemSinkDevice.detect() != nil`.
    public static func selectedPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        sinkAvailable: Bool
    ) -> Path {
        let raw = environment[environmentFlag]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch raw {
        case "direct":
            return .direct
        case "capture", "sck":
            return .capture
        case "sink":
            // An explicit request for the sink path with no sink installed
            // must NOT silently become something else: the caller asked for
            // native system volume. Direct Stereo is the only path that can
            // still play audio, so we take it and the Router logs the demotion
            // (`sinkFallbackWarning`).
            return sinkAvailable ? .sink : .direct
        case nil, "":
            return sinkAvailable ? .sink : .direct
        default:
            return sinkAvailable ? .sink : .direct
        }
    }

    /// The path this process will actually run, resolved against the sink
    /// devices installed on this machine.
    ///
    /// Every call site (Router, AppModel, the app's launch log) must use this
    /// rather than probing separately: they have to agree, or the UI would
    /// advertise a path the Router is not running. `SystemSinkDevice.resolved`
    /// is itself resolved once per process, so installing a driver mid-session
    /// takes effect at the next launch — which is what the install action
    /// tells the user, since installing also restarts coreaudiod.
    public static func resolvedPath(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Path {
        selectedPath(
            environment: environment,
            sinkAvailable: SystemSinkDevice.resolved != nil
        )
    }

    /// Non-nil when `SYNCAST_STEREO_PATH=sink` was requested but no sink
    /// device is installed, so the Router can say why the event tap is still
    /// in play.
    public static func sinkFallbackWarning(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        sinkAvailable: Bool
    ) -> String? {
        let raw = environment[environmentFlag]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard raw == "sink", !sinkAvailable else { return nil }
        return "SYNCAST_STEREO_PATH=sink requested but no virtual sink device is installed; using direct stereo"
    }

    public static func warningForUnknownValue(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard let rawValue = environment[environmentFlag] else { return nil }
        let raw = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !raw.isEmpty,
              raw != "direct",
              raw != "sink",
              raw != "capture",
              raw != "sck"
        else {
            return nil
        }
        return "unknown SYNCAST_STEREO_PATH=\(raw); using the default stereo path"
    }
}
