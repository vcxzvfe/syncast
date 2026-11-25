import XCTest
@testable import SyncCastMenuBar

final class PostWakeRecoveryPolicyTests: XCTestCase {

    private let homeDisplay = "test-display-left-before-sleep"
    private let speakers = "BuiltInSpeakerDevice"

    // MARK: - The 2026-11-25 wake at the office

    /// The home display was unplugged before the Mac slept; only the built-in
    /// speakers were enabled at the wake. The first rebuild captured and the
    /// speakers resolved: that is done, whatever the display is doing.
    func testAnOutputThatLeftBeforeTheWakeDoesNotKeepTheLoopRebuilding() {
        XCTAssertEqual(
            PostWakeRecoveryPolicy.verdict(
                captureOK: true, unresolvedEnabledUIDs: [], attempt: 0, maxAttempts: 4
            ),
            .recovered
        )
        XCTAssertEqual(
            PostWakeRecoveryPolicy.stillAbsent(
                remembered: [homeDisplay], presentNow: [speakers, "test-display-not-in-routing"]
            ),
            [homeDisplay]
        )
    }

    // MARK: - Retrying

    /// The tap lost the race to publish on the first rebuild (2026-11-23
    /// 08:23:13): rebuild again.
    func testCaptureFailureIsRetried() {
        XCTAssertEqual(
            PostWakeRecoveryPolicy.verdict(
                captureOK: false, unresolvedEnabledUIDs: [], attempt: 0, maxAttempts: 4
            ),
            .retry
        )
    }

    /// An enabled HDMI/DP output that has not been republished yet is what the
    /// retry exists for: the next rebuild picks up its new id.
    func testAnEnabledOutputThatDoesNotResolveIsRetried() {
        XCTAssertEqual(
            PostWakeRecoveryPolicy.verdict(
                captureOK: true, unresolvedEnabledUIDs: [homeDisplay], attempt: 2, maxAttempts: 4
            ),
            .retry
        )
    }

    // MARK: - Giving up

    func testOutOfAttemptsWithCaptureUpKeepsPlayingAndNamesTheOutput() {
        XCTAssertEqual(
            PostWakeRecoveryPolicy.verdict(
                captureOK: true, unresolvedEnabledUIDs: [speakers, homeDisplay],
                attempt: 3, maxAttempts: 4
            ),
            .gaveUpPlaying(unresolved: [homeDisplay, speakers].sorted())
        )
    }

    /// The 2026-11-25 end state: the last rebuild could not get a tap. There
    /// is no path, and the verdict has to say so rather than look like the
    /// incomplete-but-playing case.
    func testOutOfAttemptsWithCaptureDownIsSilent() {
        XCTAssertEqual(
            PostWakeRecoveryPolicy.verdict(
                captureOK: false, unresolvedEnabledUIDs: [], attempt: 3, maxAttempts: 4
            ),
            .gaveUpSilent
        )
        XCTAssertEqual(
            PostWakeRecoveryPolicy.verdict(
                captureOK: false, unresolvedEnabledUIDs: [speakers], attempt: 3, maxAttempts: 4
            ),
            .gaveUpSilent
        )
    }

    /// Success on the last attempt is still success.
    func testRecoveringOnTheLastAttemptIsRecovered() {
        XCTAssertEqual(
            PostWakeRecoveryPolicy.verdict(
                captureOK: true, unresolvedEnabledUIDs: [], attempt: 3, maxAttempts: 4
            ),
            .recovered
        )
    }

    // MARK: - Remembered outputs

    /// A remembered output that came back during the wake (the home display
    /// at an at-home wake, 2026-11-23 20:35:08) is not reported as absent.
    func testARememberedOutputThatIsBackIsNotAbsent() {
        XCTAssertEqual(
            PostWakeRecoveryPolicy.stillAbsent(
                remembered: [homeDisplay], presentNow: [speakers, homeDisplay]
            ),
            []
        )
    }
}
