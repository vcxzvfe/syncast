import XCTest
@testable import SyncCastRouter

/// Which local Stereo path runs is the difference between "the system volume
/// slider works" and "SyncCast needs Accessibility to fake volume keys", so
/// the selection rules are pinned here.
final class StereoOutputPathPolicyTests: XCTestCase {

    private let flag = StereoOutputPathPolicy.environmentFlag

    // MARK: - Defaults

    func testDefaultsToSinkWhenASinkIsInstalled() {
        XCTAssertEqual(
            StereoOutputPathPolicy.selectedPath(environment: [:], sinkAvailable: true),
            .sink
        )
    }

    /// No sink driver installed → the legacy Direct Stereo path, unchanged.
    /// This is the promise that this feature cannot break existing users.
    func testDefaultsToDirectWithoutASink() {
        XCTAssertEqual(
            StereoOutputPathPolicy.selectedPath(environment: [:], sinkAvailable: false),
            .direct
        )
    }

    func testEmptyValueBehavesLikeUnset() {
        XCTAssertEqual(
            StereoOutputPathPolicy.selectedPath(
                environment: [flag: "   "], sinkAvailable: true
            ),
            .sink
        )
    }

    // MARK: - Explicit overrides

    func testDirectIsForcedEvenWhenASinkExists() {
        XCTAssertEqual(
            StereoOutputPathPolicy.selectedPath(
                environment: [flag: "direct"], sinkAvailable: true
            ),
            .direct
        )
    }

    func testCaptureAliasesAreHonoured() {
        for value in ["capture", "sck", "SCK", " Capture "] {
            XCTAssertEqual(
                StereoOutputPathPolicy.selectedPath(
                    environment: [flag: value], sinkAvailable: true
                ),
                .capture,
                "value=\(value)"
            )
        }
    }

    func testSinkCanBeRequestedExplicitly() {
        XCTAssertEqual(
            StereoOutputPathPolicy.selectedPath(
                environment: [flag: "sink"], sinkAvailable: true
            ),
            .sink
        )
    }

    /// Asking for the sink path with no sink installed must not silently
    /// become "capture" or a crash: Direct Stereo is the only path that can
    /// still play audio, and the demotion is reported.
    func testSinkRequestWithoutASinkFallsBackToDirectAndWarns() {
        XCTAssertEqual(
            StereoOutputPathPolicy.selectedPath(
                environment: [flag: "sink"], sinkAvailable: false
            ),
            .direct
        )
        XCTAssertNotNil(StereoOutputPathPolicy.sinkFallbackWarning(
            environment: [flag: "sink"], sinkAvailable: false
        ))
    }

    func testNoFallbackWarningWhenTheSinkIsThere() {
        XCTAssertNil(StereoOutputPathPolicy.sinkFallbackWarning(
            environment: [flag: "sink"], sinkAvailable: true
        ))
        XCTAssertNil(StereoOutputPathPolicy.sinkFallbackWarning(
            environment: [:], sinkAvailable: false
        ))
    }

    // MARK: - Unknown values

    func testUnknownValueFallsBackToTheDefaultPathAndWarns() {
        XCTAssertEqual(
            StereoOutputPathPolicy.selectedPath(
                environment: [flag: "banana"], sinkAvailable: true
            ),
            .sink
        )
        XCTAssertEqual(
            StereoOutputPathPolicy.selectedPath(
                environment: [flag: "banana"], sinkAvailable: false
            ),
            .direct
        )
        XCTAssertNotNil(StereoOutputPathPolicy.warningForUnknownValue(
            environment: [flag: "banana"]
        ))
    }

    func testKnownValuesDoNotWarn() {
        for value in ["direct", "sink", "capture", "sck", ""] {
            XCTAssertNil(
                StereoOutputPathPolicy.warningForUnknownValue(environment: [flag: value]),
                "value=\(value)"
            )
        }
    }
}
