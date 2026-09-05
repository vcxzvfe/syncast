import XCTest
@testable import SyncCastMenuBar

/// `swift test` loads the app target, so anything the app writes at
/// construction it writes on the developer's own machine. These pin the
/// routing rule that keeps the real log out of test runs.
final class LogDestinationTests: XCTestCase {
    private let library = URL(fileURLWithPath: "/Users/someone/Library")
    private let temp = URL(fileURLWithPath: "/var/folders/tmp")

    private func resolve(
        _ environment: [String: String], underXCTest: Bool = false
    ) -> URL {
        SyncCastLog.resolvePath(
            environment: environment,
            libraryDirectory: library,
            temporaryDirectory: temp,
            processIdentifier: 4321,
            underXCTest: underXCTest
        )
    }

    func testProductionEnvironmentUsesTheRealLaunchLog() {
        let path = resolve([:]).path
        XCTAssertEqual(path, "/Users/someone/Library/Logs/SyncCast/launch.log")
    }

    func testXCTestEnvironmentRedirectsToTemp() {
        let path = resolve([TestEnvironment.xctestEnvVar: "/some/Test.xctestconfiguration"]).path
        XCTAssertEqual(path, "/var/folders/tmp/SyncCast-tests-4321.log")
        XCTAssertFalse(path.contains("Library/Logs"), "a test run must not touch the real log")
    }

    /// `swift test` sets no XCTest environment variable at all (measured
    /// 2026-09-05: the child environment carries only SWIFT_TESTING_ENABLED),
    /// so the runtime signal has to be able to redirect on its own.
    func testRuntimeSignalAloneRedirectsToTemp() {
        let path = resolve([:], underXCTest: true).path
        XCTAssertEqual(path, "/var/folders/tmp/SyncCast-tests-4321.log")
    }

    func testExplicitOverrideWinsOverBoth() {
        let path = resolve([
            SyncCastLog.pathOverrideEnvVar: "/tmp/explicit.log",
            TestEnvironment.xctestEnvVar: "/some/Test.xctestconfiguration",
        ]).path
        XCTAssertEqual(path, "/tmp/explicit.log")
    }

    func testEmptyOverrideIsIgnoredRatherThanWritingToTheCurrentDirectory() {
        let path = resolve([SyncCastLog.pathOverrideEnvVar: "   "]).path
        XCTAssertEqual(path, "/Users/someone/Library/Logs/SyncCast/launch.log")
    }

    func testEmptyXCTestVariableIsNotTreatedAsATestRun() {
        XCTAssertFalse(TestEnvironment.isRunningUnderXCTest(environment: [:]))
        XCTAssertFalse(TestEnvironment.isRunningUnderXCTest(
            environment: [TestEnvironment.xctestEnvVar: ""]
        ))
        XCTAssertTrue(TestEnvironment.isRunningUnderXCTest(
            environment: [TestEnvironment.xctestEnvVar: "/x.xctestconfiguration"]
        ))
    }

    /// The rule as it applies to THIS process: while these tests run, the
    /// logger must not be pointed at the user's launch.log.
    func testThisTestProcessIsNotWritingToTheRealLog() {
        XCTAssertTrue(TestEnvironment.isRunningUnderXCTest)
        XCTAssertTrue(TestEnvironment.isXCTestFrameworkLoaded)
        XCTAssertFalse(
            SyncCastLog.currentPath.hasSuffix("Library/Logs/SyncCast/launch.log"),
            "this test run is logging to \(SyncCastLog.currentPath)"
        )
    }

    /// A controller constructed in a test must not install a system-wide event
    /// tap or NSEvent monitors. Both `start()` and the independent
    /// `recheckPermission` path are exercised, then the main run loop is spun:
    /// without the gate the tap thread publishes `.eventTap` within a few
    /// milliseconds, so an empty state list is real evidence, not a race that
    /// happened to be won.
    func testVolumeKeyControllerDoesNotInstallATapUnderXCTest() {
        final class Box: @unchecked Sendable {
            var actions = 0
            var states: [SystemVolumeKeyCaptureState] = []
        }
        let box = Box()
        let controller = SystemVolumeKeyController(
            onAction: { _ in box.actions += 1 },
            onStateChange: { box.states.append($0) }
        )
        controller.start()
        controller.recheckPermission(reason: "unit test")
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(controller.captureState, .needsPermission)
        XCTAssertEqual(box.actions, 0)
        XCTAssertTrue(
            box.states.isEmpty,
            "no capture state should have been published, got \(box.states)"
        )
        controller.stop()
    }
}
