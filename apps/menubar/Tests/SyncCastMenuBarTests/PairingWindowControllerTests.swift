import AppKit
import XCTest
@testable import SyncCastMenuBar

/// Unit tests for the parts of the pairing-window fix that can be exercised
/// without a window server.
///
/// What is deliberately NOT covered here: whether the window actually becomes
/// key, whether `NSApp.activate` is honoured for an `LSUIElement` app, and
/// whether the PIN field takes keyboard focus. Those are window-server
/// behaviours — they need a real login session, a real menu-bar click, and a
/// real receiver showing a real PIN, so they belong in the human verification
/// steps, not in `swift test`.
///
/// What IS covered is the piece that was easy to get wrong and impossible to
/// see: the two-way teardown between the window and the model. The model
/// clearing `pairingSheet` closes the window, and closing the window cancels
/// pairing — so the guard that stops those two from calling each other, and
/// the rule that a user-initiated close must still tell the sidecar to stop,
/// are worth pinning down.
@MainActor
final class PairingWindowControllerTests: XCTestCase {

    private func sheet(stage: PairingSheetState.Stage, pin: String = "") -> PairingSheetState {
        PairingSheetState(
            deviceKey: "airplay:test-receiver",
            deviceName: "Test Receiver",
            stage: stage,
            pin: pin
        )
    }

    /// The red close button (or Cmd-W) has to cancel. If it only hid the
    /// window, the sidecar would keep the pairing session open and the
    /// receiver would keep its full-screen PIN up with nothing driving it.
    func testUserInitiatedCloseCancelsPairing() {
        let model = AppModel()
        model.pairingSheet = sheet(stage: .enterPIN, pin: "1234")
        let controller = PairingWindowController(model: model)

        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))

        XCTAssertNil(
            model.pairingSheet,
            "closing the pairing window must end the attempt, not just hide it"
        )
    }

    /// `dismiss()` is the model-driven direction: the flow already ended, so
    /// there is nothing left to cancel. With no window on screen it must be a
    /// no-op rather than tearing down a flow that is still running.
    func testDismissWithoutAWindowLeavesTheFlowAlone() {
        let model = AppModel()
        model.pairingSheet = sheet(stage: .enterPIN, pin: "1234")
        let controller = PairingWindowController(model: model)

        controller.dismiss()

        XCTAssertNotNil(model.pairingSheet)
    }

    /// A second close notification must not fail or re-cancel; the window is
    /// reused across attempts, so this path is hit more than once per launch.
    func testRepeatedCloseNotificationsAreHarmless() {
        let model = AppModel()
        model.pairingSheet = sheet(stage: .enterPIN, pin: "1234")
        let controller = PairingWindowController(model: model)
        let close = Notification(name: NSWindow.willCloseNotification)

        controller.windowWillClose(close)
        controller.windowWillClose(close)

        XCTAssertNil(model.pairingSheet)
    }

    /// PIN hygiene: "Try again" reuses the same window, so the previous
    /// attempt's digits must not still be sitting in the field.
    func testRestartClearsThePINAndReturnsToTheExplainStage() {
        let model = AppModel()
        model.pairingSheet = sheet(stage: .failed("nope"), pin: "1234")

        model.restartPairing()

        XCTAssertEqual(model.pairingSheet?.pin, "")
        XCTAssertEqual(model.pairingSheet?.stage, .explainFullScreenPIN)
    }

    // MARK: - Stale terminal state must not leak into a new attempt

    /// The bug that made a once-failed receiver practically unpairable.
    ///
    /// The Router caches pairing state per DEVICE KEY, and the UI polls that
    /// cache once a second. A terminal outcome is per ATTEMPT, so re-applying
    /// it unconditionally slammed the sheet back to the failure screen about
    /// a second after every "Try again" — leaving a ~1 s race window as the
    /// only way to reach the Continue button.
    func testAStaleTimeoutDoesNotOverwriteAFreshAttempt() {
        let model = AppModel()
        let key = "airplay:test-receiver"
        model.pairingSheet = sheet(stage: .failed("timed out"))

        model.restartPairing()
        XCTAssertEqual(model.pairingSheet?.stage, .explainFullScreenPIN)

        // The Router's cache still holds the PREVIOUS attempt's outcome.
        model.applyPairingSnapshotToSheet([key: .timedOut])

        XCTAssertEqual(
            model.pairingSheet?.stage, .explainFullScreenPIN,
            "a new attempt must not inherit the previous attempt's outcome"
        )
    }

    func testAStaleFailureDoesNotOverwriteAFreshAttempt() {
        let model = AppModel()
        let key = "airplay:test-receiver"
        model.pairingSheet = sheet(stage: .failed("nope"))
        model.restartPairing()

        model.applyPairingSnapshotToSheet([key: .failed])

        XCTAssertEqual(model.pairingSheet?.stage, .explainFullScreenPIN)
    }

    /// The flip side: while the sheet IS waiting for the user to type the
    /// code, a terminal outcome is current and must still land.
    func testATimeoutStillLandsWhileWaitingForTheCode() {
        let model = AppModel()
        let key = "airplay:test-receiver"
        model.pairingSheet = sheet(stage: .enterPIN)

        model.applyPairingSnapshotToSheet([key: .timedOut])

        guard case .failed = model.pairingSheet?.stage else {
            return XCTFail("expected the sheet to fail, got \(String(describing: model.pairingSheet?.stage))")
        }
    }

    /// Success closes the sheet from any stage — including the explain stage,
    /// which is where a receiver that paired out of band lands.
    func testPairedClosesTheSheetFromAnyStage() {
        let model = AppModel()
        let key = "airplay:test-receiver"
        model.pairingSheet = sheet(stage: .explainFullScreenPIN)

        model.applyPairingSnapshotToSheet([key: .paired])

        XCTAssertNil(model.pairingSheet)
    }

    // MARK: - Countdown

    /// The countdown is wall-clock, because the sidecar's window is. Counting
    /// poll ticks drifted long — each tick sleeps a second and then awaits
    /// three RPCs — so the label showed time the user did not have.
    func testTheCountdownIsDerivedFromTheDeadlineNotTheTickCount() {
        let model = AppModel()
        var state = sheet(stage: .enterPIN)
        state.deadline = Date().addingTimeInterval(90)
        model.pairingSheet = state

        model.tickPairingSheetCountdown()

        let remaining = model.pairingSheet?.secondsRemaining ?? -1
        XCTAssertTrue(
            (88...91).contains(remaining),
            "expected ~90s from the deadline, got \(remaining)"
        )
    }

    /// A deadline already in the past ends the attempt locally, so a lost
    /// timeout notification from the sidecar cannot strand the sheet.
    func testAnExpiredDeadlineFailsTheSheet() {
        let model = AppModel()
        var state = sheet(stage: .enterPIN)
        state.deadline = Date().addingTimeInterval(-1)
        model.pairingSheet = state

        model.tickPairingSheetCountdown()

        XCTAssertEqual(model.pairingSheet?.secondsRemaining, 0)
        guard case .failed = model.pairingSheet?.stage else {
            return XCTFail("an expired window must fail the sheet")
        }
    }
}
