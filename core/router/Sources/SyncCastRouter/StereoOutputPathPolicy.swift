import Foundation

public enum StereoOutputPathPolicy {
    public enum Path: String, Sendable {
        case direct
        case capture
    }

    public static let environmentFlag = "SYNCAST_STEREO_PATH"

    /// Local Stereo defaults to Direct Stereo so normal local playback does
    /// not require ScreenCaptureKit / Screen Recording. Use
    /// `SYNCAST_STEREO_PATH=capture` or `sck` as an explicit fallback.
    public static func selectedPath(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Path {
        let raw = environment[environmentFlag]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch raw {
        case nil, "", "direct":
            return .direct
        case "capture", "sck":
            return .capture
        default:
            return .direct
        }
    }

    public static func warningForUnknownValue(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard let rawValue = environment[environmentFlag] else { return nil }
        let raw = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !raw.isEmpty,
              raw != "direct",
              raw != "capture",
              raw != "sck"
        else {
            return nil
        }
        return "unknown SYNCAST_STEREO_PATH=\(raw); using direct stereo path"
    }
}
