import XCTest
@testable import SyncCastRouter

/// The predicate that decides whether the system-sink path has anywhere to
/// send audio.
///
/// The bug being pinned down: the check used to be `!localOutputs.isEmpty`, so
/// enabling ONLY a LAN receiver made `Router.start` fail with
/// `SyncCastRouter` code 112 — "no local output could be opened" — while the
/// receiver leg was open, connected and waiting for packets. A receiver leg is
/// an output; that is the whole point of the feature.
final class SystemSinkOutputPolicyTests: XCTestCase {

    func testACoreAudioOutputAloneIsEnough() {
        XCTAssertTrue(
            SystemSinkOutputPolicy.hasRenderableOutput(
                localOutputCount: 1, lanReceiverLegCount: 0
            )
        )
    }

    /// The regression. One LAN leg, no AUHAL at all, is a complete output set.
    func testALanLegAloneIsEnough() {
        XCTAssertTrue(
            SystemSinkOutputPolicy.hasRenderableOutput(
                localOutputCount: 0, lanReceiverLegCount: 1
            ),
            "a LAN receiver leg is an output; the sink path must not demand a CoreAudio one"
        )
    }

    func testBothTogetherAreEnough() {
        XCTAssertTrue(
            SystemSinkOutputPolicy.hasRenderableOutput(
                localOutputCount: 2, lanReceiverLegCount: 3
            )
        )
    }

    /// The case the check exists for: the sink is already the system default,
    /// and nothing is rendering it. That must still fail loudly so the start
    /// unwinds and macOS gets its output back.
    func testNeitherIsAFailure() {
        XCTAssertFalse(
            SystemSinkOutputPolicy.hasRenderableOutput(
                localOutputCount: 0, lanReceiverLegCount: 0
            )
        )
    }

    /// A receiver that is enabled but has no token yet opens no leg, so the
    /// count it contributes is zero and the path correctly refuses to run.
    /// (Encoded here as the call the Router makes: it passes
    /// `lanReceiverOutputs.count`, which only counts OPEN legs.)
    func testAnEnabledButUntokenedReceiverContributesNoLeg() {
        let openLegs = 0  // reconcileLanReceivers skips receivers with no token
        XCTAssertFalse(
            SystemSinkOutputPolicy.hasRenderableOutput(
                localOutputCount: 0, lanReceiverLegCount: openLegs
            )
        )
    }

    func testTheFailureMessageNamesBothKindsOfOutput() {
        let message = SystemSinkOutputPolicy.noOutputMessage(lastError: nil)
        XCTAssertTrue(message.contains("CoreAudio"), message)
        XCTAssertTrue(message.contains("LAN"), message)
    }

    func testTheFailureMessageCarriesTheLastDriverError() {
        let message = SystemSinkOutputPolicy.noOutputMessage(
            lastError: "open Display failed: -10851"
        )
        XCTAssertTrue(message.hasSuffix("open Display failed: -10851"), message)
    }

    func testAnEmptyLastErrorIsNotAppendedAsAStrayColon() {
        XCTAssertEqual(
            SystemSinkOutputPolicy.noOutputMessage(lastError: ""),
            SystemSinkOutputPolicy.noOutputMessage(lastError: nil)
        )
    }
}
