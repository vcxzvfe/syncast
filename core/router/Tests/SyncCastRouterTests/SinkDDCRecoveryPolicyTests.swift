import XCTest
@testable import SyncCastRouter

/// The sink path's DDC re-probe schedule.
///
/// # Why these exist
///
/// A display whose DDC/CI link failed used to stay on software gain for the
/// rest of the session. Software gain cannot raise a panel above its own
/// level, so turning the system volume down worked and turning it back up
/// stopped at whatever the panel had when DDC was lost. The re-probe loop is
/// what lets the panel come back; these pin its pacing.
final class SinkDDCRecoveryPolicyTests: XCTestCase {

    func testEarlyRetriesAreFastForAPanelThatWasNotReadyYet() {
        XCTAssertEqual(SinkDDCRecoveryPolicy.delaySeconds(attempt: 0), 1)
        XCTAssertEqual(SinkDDCRecoveryPolicy.delaySeconds(attempt: 1), 2)
        // The whole fast phase fits in about a minute.
        let fastPhase = SinkDDCRecoveryPolicy.backoffSeconds.reduce(0, +)
        XCTAssertLessThanOrEqual(fastPhase, 60)
    }

    func testBackoffNeverShrinks() {
        let delays = (0..<20).map { SinkDDCRecoveryPolicy.delaySeconds(attempt: $0) }
        XCTAssertEqual(delays, delays.sorted())
    }

    func testSteadyStateAfterTheBackoffAndForNonsenseAttempts() {
        let past = SinkDDCRecoveryPolicy.backoffSeconds.count
        XCTAssertEqual(
            SinkDDCRecoveryPolicy.delaySeconds(attempt: past),
            SinkDDCRecoveryPolicy.steadySeconds
        )
        XCTAssertEqual(
            SinkDDCRecoveryPolicy.delaySeconds(attempt: 10_000),
            SinkDDCRecoveryPolicy.steadySeconds
        )
        XCTAssertEqual(
            SinkDDCRecoveryPolicy.delaySeconds(attempt: -1),
            SinkDDCRecoveryPolicy.steadySeconds
        )
    }

    /// The held attenuation of a hand-back must not outlive one slow I2C
    /// transaction by much, but must comfortably cover a normal one
    /// (tens of milliseconds with retries).
    func testHandBackTimeoutIsShortButCoversASlowWrite() {
        XCTAssertGreaterThanOrEqual(SinkDDCRecoveryPolicy.firstWriteTimeoutSeconds, 1)
        XCTAssertLessThanOrEqual(SinkDDCRecoveryPolicy.firstWriteTimeoutSeconds, 5)
    }
}
