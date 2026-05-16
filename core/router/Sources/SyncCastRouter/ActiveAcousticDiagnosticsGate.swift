import Darwin
import Foundation

/// Single source of truth for the lab-only active acoustic probe gate.
///
/// Active probes can be audible on real speakers, so requiring three explicit
/// environment flags prevents stale lab flags from enabling test tones.
public enum ActiveAcousticDiagnosticsGate {
    public static let enableFlag = "SYNCAST_ENABLE_ACTIVE_CALIBRATION"
    public static let audibleProbeFlag = "SYNCAST_ALLOW_AUDIBLE_PROBES"
    public static let confirmationFlag = "SYNCAST_CONFIRM_AUDIBLE_PROBE_TEST"
    public static let labSessionFlag = "SYNCAST_ACTIVE_PROBE_LAB_SESSION"
    public static let labSessionFileFlag = "SYNCAST_ACTIVE_PROBE_LAB_SESSION_FILE"
    public static let labSessionMaxAgeSeconds: TimeInterval = 15 * 60

    public static let disabledMessage =
        "active acoustic calibration is disabled by default; use passive no-probe diagnostics or relaunch with SYNCAST_ENABLE_ACTIVE_CALIBRATION=1, SYNCAST_ALLOW_AUDIBLE_PROBES=1, SYNCAST_CONFIRM_AUDIBLE_PROBE_TEST=1, and a fresh SYNCAST_ACTIVE_PROBE_LAB_SESSION token file for lab test tones"

    public struct LabSessionEvidence: Sendable {
        public let token: String?
        public let modifiedAt: Date?

        public init(token: String?, modifiedAt: Date?) {
            self.token = token
            self.modifiedAt = modifiedAt
        }
    }

    public static func isEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date(),
        labSessionEvidence: LabSessionEvidence? = nil
    ) -> Bool {
        guard truthy(environment[enableFlag]),
              truthy(environment[audibleProbeFlag]),
              truthy(environment[confirmationFlag])
        else { return false }
        guard let sessionToken = normalizedToken(environment[labSessionFlag])
        else { return false }
        let evidence = labSessionEvidence
            ?? readLabSessionEvidence(
                path: labSessionFilePath(environment: environment)
            )
        guard normalizedToken(evidence.token) == sessionToken else {
            return false
        }
        guard let modifiedAt = evidence.modifiedAt else { return false }
        let age = now.timeIntervalSince(modifiedAt)
        return age >= -5 && age <= labSessionMaxAgeSeconds
    }

    public static func startupLogState(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date(),
        labSessionEvidence: LabSessionEvidence? = nil
    ) -> String {
        isEnabled(
            environment: environment,
            now: now,
            labSessionEvidence: labSessionEvidence
        )
            ? "enabled by explicit lab tone flags"
            : "disabled; passive no-probe diagnostics only"
    }

    private static func truthy(_ raw: String?) -> Bool {
        let value = raw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return value == "1" || value == "true" || value == "yes"
    }

    public static func labSessionFilePath(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        normalizedToken(environment[labSessionFileFlag])
            ?? "/private/tmp/syncast-active-probe-\(getuid()).allow"
    }

    private static func readLabSessionEvidence(path: String) -> LabSessionEvidence {
        let url = URL(fileURLWithPath: path)
        let token = try? String(contentsOf: url, encoding: .utf8)
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return LabSessionEvidence(
            token: token,
            modifiedAt: attrs?[.modificationDate] as? Date
        )
    }

    private static func normalizedToken(_ raw: String?) -> String? {
        let value = raw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
