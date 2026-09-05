import Foundation

/// Am I running inside an XCTest bundle?
///
/// `swift test` loads the app target into a test host, so anything the app does
/// at construction — writing the real log, installing a system-wide CGEventTap
/// — happens once per test that touches it. That is not a hypothetical: a
/// single `swift test` run put dozens of "CGEventTap installed" lines into the
/// user's real `~/Library/Logs/SyncCast/launch.log`, mixed in with the lines
/// from the app they were actually running.
///
/// Two signals, because neither is sufficient on its own:
///
///   * `XCTestConfigurationFilePath` — set by Xcode's test runner. MEASURED
///     2026-09-05: SwiftPM's own `swift test` on this machine does NOT set it
///     (the only test-ish variable in the child environment is
///     `SWIFT_TESTING_ENABLED=0`), so relying on it alone silently does
///     nothing under the command we actually run.
///   * `NSClassFromString("XCTestCase")` — the XCTest framework is loaded into
///     the process that runs the bundle, under both runners. This is the one
///     that fires for `swift test`.
///
/// Anything a test must be able to force explicitly gets its own env var
/// instead (see `SyncCastLog.pathOverrideEnvVar`); this flag only answers
/// "am I allowed to touch the user's machine", and the answer under test is no.
enum TestEnvironment {
    static let xctestEnvVar = "XCTestConfigurationFilePath"

    static var isRunningUnderXCTest: Bool {
        isRunningUnderXCTest(environment: ProcessInfo.processInfo.environment)
            || isXCTestFrameworkLoaded
    }

    /// Environment-only form, so the rule is testable against a dictionary.
    static func isRunningUnderXCTest(environment: [String: String]) -> Bool {
        guard let value = environment[xctestEnvVar] else { return false }
        return !value.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Runtime form: is XCTest linked into this process at all?
    static var isXCTestFrameworkLoaded: Bool {
        NSClassFromString("XCTestCase") != nil
    }
}
