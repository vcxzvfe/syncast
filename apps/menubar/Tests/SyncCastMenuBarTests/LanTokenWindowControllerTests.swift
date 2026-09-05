import AppKit
import SwiftUI
import XCTest
@testable import SyncCastMenuBar

/// Regression tests for the LAN token window's presentation.
///
/// The crash these guard against (2026-09-05, macOS 26.6.2) was an uncaught
/// AppKit exception raised from `_postWindowNeedsUpdateConstraints` while the
/// main thread was inside `NSDisplayCycleFlush` — a SwiftUI hosting view in a
/// freshly-created window asking for a constraints update in the middle of a
/// layout pass. Two properties of the fix are checkable without a window
/// server, and they are the two that matter:
///
///   1. `present()` touches no AppKit at all on the caller's stack. Whatever
///      display cycle the SwiftUI action belongs to has fully unwound before a
///      window exists.
///   2. The presentation is idempotent while it is pending, so a double click
///      on the row's button does not activate the app twice.
///
/// What is deliberately NOT covered: whether the window becomes key, whether
/// `NSApp.activate` is honoured for an `LSUIElement` app, and whether the
/// field takes keyboard focus. Those need a real login session and a real
/// menu-bar click. `SYNCAST_UI_SMOKE=token` (see `AppModel+UiSmoke.swift`)
/// exists for that half.
@MainActor
final class LanTokenWindowControllerTests: XCTestCase {

    private static let deviceID = "lan:test-receiver"

    /// Drain the main queue so a `DispatchQueue.main.async` hop lands.
    private func settleMainQueue(_ seconds: TimeInterval = 0.2) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: - Deferral

    /// The core of the crash fix. A window built synchronously inside the
    /// SwiftUI action joins the display cycle that is already running, and its
    /// hosting view's first constraint invalidation lands mid-layout.
    func testPresentBuildsNoWindowOnTheCallersStack() {
        let model = AppModel()
        model.lanTokenEditorDeviceID = Self.deviceID
        let controller = LanTokenWindowController(model: model)

        controller.present()

        XCTAssertNil(
            controller.presentedWindowForTesting,
            "present() must not create an NSWindow inside the caller's display cycle"
        )
        XCTAssertTrue(controller.hasPendingPresentationForTesting)
    }

    /// The row's button can be clicked twice before the hop runs. One window,
    /// one activation.
    func testRepeatedPresentCallsCoalesceIntoOnePendingPresentation() {
        let model = AppModel()
        model.lanTokenEditorDeviceID = Self.deviceID
        let controller = LanTokenWindowController(model: model)

        controller.present()
        controller.present()
        controller.present()

        XCTAssertTrue(controller.hasPendingPresentationForTesting)
        XCTAssertNil(controller.presentedWindowForTesting)
    }

    /// Cancelling between the click and the hop must leave nothing behind.
    func testAPresentationCancelledBeforeItRunsOpensNothing() {
        let model = AppModel()
        model.lanTokenEditorDeviceID = Self.deviceID
        let controller = LanTokenWindowController(model: model)

        controller.present()
        model.lanTokenEditorDeviceID = nil
        settleMainQueue()

        XCTAssertNil(controller.presentedWindowForTesting)
        XCTAssertFalse(controller.hasPendingPresentationForTesting)
    }

    /// With no receiver selected there is nothing to present, and no hop
    /// should be scheduled at all.
    func testPresentWithNoEditorTargetIsANoOp() {
        let model = AppModel()
        let controller = LanTokenWindowController(model: model)

        controller.present()

        XCTAssertFalse(controller.hasPendingPresentationForTesting)
        XCTAssertNil(controller.presentedWindowForTesting)
    }

    // MARK: - Dismissal

    /// `dismiss()` clears the model immediately (an ordinary SwiftUI mutation)
    /// even though the window close is deferred, so the row's state is correct
    /// the moment the user hits Cancel.
    func testDismissClearsTheEditorStateImmediately() {
        let model = AppModel()
        model.lanTokenEditorDeviceID = Self.deviceID
        model.lanTokenSaveError = "boom"
        let controller = LanTokenWindowController(model: model)

        controller.dismiss()

        XCTAssertNil(model.lanTokenEditorDeviceID)
        XCTAssertNil(model.lanTokenSaveError)
    }

    /// A close the user initiated goes through the delegate callback, which is
    /// already outside the display cycle and must clear the same state.
    func testWindowWillCloseClearsTheEditorState() {
        let model = AppModel()
        model.lanTokenEditorDeviceID = Self.deviceID
        model.lanTokenSaveError = "boom"
        let controller = LanTokenWindowController(model: model)

        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))

        XCTAssertNil(model.lanTokenEditorDeviceID)
        XCTAssertNil(model.lanTokenSaveError)
    }

    // MARK: - The window itself

    /// Builds the same window shape the controller builds — final style mask
    /// at init, hosting view installed last — and forces a full layout pass.
    ///
    /// This is the shape assertion, not the timing one: if the root view's
    /// constraints were self-contradictory, or the hosting view could not size
    /// itself, this is where it would show up. An ObjC exception here takes
    /// the whole test process down, which is exactly the signal wanted.
    func testTheWindowShapeLaysOutWithoutRaising() {
        let model = AppModel()
        model.lanTokenEditorDeviceID = Self.deviceID
        let root = LanTokenWindowRootView(onFinished: {}).environment(model)
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = [.standardBounds]
        let size = hosting.fittingSize
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting

        window.layoutIfNeeded()
        window.displayIfNeeded()

        XCTAssertGreaterThan(
            window.contentView?.frame.width ?? 0, 0,
            "the hosting view must size itself from the SwiftUI form"
        )
        window.close()
    }

    /// The empty-editor state must render the same-sized form rather than a
    /// 1-pt placeholder: a window that opens tiny and resizes one SwiftUI
    /// update later is doing exactly the mid-update constraint work the crash
    /// came from.
    func testTheEmptyEditorRendersAFullSizePlaceholder() {
        let model = AppModel()
        model.lanTokenEditorDeviceID = nil
        let hosting = NSHostingView(
            rootView: LanTokenWindowRootView(onFinished: {}).environment(model)
        )
        hosting.sizingOptions = [.standardBounds]

        let size = hosting.fittingSize

        XCTAssertEqual(size.width, LanTokenEntryView.contentWidth, accuracy: 1)
        XCTAssertGreaterThan(
            size.height, 100,
            "an empty editor must still be a full-height form, not a 1-pt placeholder"
        )
    }

    /// Opt-in end-to-end: actually order the window on screen and spin the run
    /// loop, which is the only way to exercise the real display cycle from a
    /// test. Off by default because it puts a window on the operator's screen
    /// during an ordinary `swift test`.
    ///
    ///     SYNCAST_UI_SMOKE=token swift test --filter LanTokenWindowController
    func testOrderingTheWindowOnScreenSurvivesADisplayCycle() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["SYNCAST_UI_SMOKE"] == "token",
            "set SYNCAST_UI_SMOKE=token to run the on-screen smoke test"
        )
        let model = AppModel()
        model.lanTokenEditorDeviceID = Self.deviceID
        let hosting = NSHostingView(
            rootView: LanTokenWindowRootView(onFinished: {}).environment(model)
        )
        hosting.sizingOptions = [.standardBounds]
        let size = hosting.fittingSize
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting

        // `orderFrontRegardless` rather than `makeKeyAndOrderFront`: the point
        // is to make the window server lay the window out, not to steal the
        // operator's keyboard mid-test-run.
        window.orderFrontRegardless()
        settleMainQueue(0.4)
        // Provoke a second display cycle the way the popover did: change
        // something the hosting view has to re-lay-out for.
        model.lanTokenSaveError = "smoke test"
        settleMainQueue(0.4)

        XCTAssertTrue(window.isVisible)
        window.close()
        settleMainQueue(0.1)
    }
}

/// The `SYNCAST_UI_SMOKE` parsing rule, which is the half of the dev hook that
/// can be tested without launching the app.
@MainActor
final class UiSmokeHookTests: XCTestCase {

    func testAnAbsentVariableAsksForNothing() {
        XCTAssertNil(AppModel.uiSmokeTarget(environment: [:]))
    }

    func testAnEmptyVariableAsksForNothing() {
        XCTAssertNil(
            AppModel.uiSmokeTarget(environment: [AppModel.uiSmokeEnvVar: "   "])
        )
    }

    func testTheTargetIsNormalized() {
        XCTAssertEqual(
            AppModel.uiSmokeTarget(environment: [AppModel.uiSmokeEnvVar: " Token "]),
            "token"
        )
    }
}
