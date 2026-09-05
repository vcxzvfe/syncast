import AppKit
import SwiftUI

/// Geometry and timing constants for the token window. Named rather than
/// inlined because the height floor is load-bearing (see
/// `LanTokenWindowRootView`) and would otherwise read as an arbitrary number.
private enum LanTokenWindowMetrics {
    /// The window's content width IS the form's width — the form pins itself
    /// with `.frame(width:)`, so anything else would letterbox it.
    static let contentWidth: CGFloat = LanTokenEntryView.contentWidth

    /// Floor for the window's content height, in points.
    ///
    /// This is not a layout preference, it is a crash guard. The window used
    /// to open at 1 pt tall (a `Color.clear` placeholder) and then jump to the
    /// form's real height one SwiftUI update later. That jump is a window
    /// resize driven from inside a SwiftUI update, i.e. exactly the
    /// "constraints changed during the display cycle" traffic that
    /// `present()` goes to such lengths to stay out of. Measured against the
    /// form with every optional line hidden (~190 pt); rounded down so a
    /// slightly shorter form never gets padded.
    static let minimumContentHeight: CGFloat = 180

    /// Long enough for AppKit's activation handshake, short enough that the
    /// user cannot have started typing.
    static let activationVerificationDelay: Duration = .milliseconds(250)
}

/// Hosts the LAN pairing-token entry form in a real, key-capable AppKit
/// window.
///
/// The same constraint that produced `PairingWindowController` applies here
/// and is worth restating, because it is the kind of thing that gets
/// "simplified" back into the popover: `MenuBarExtra(.window)` is a
/// non-activating status-bar panel. An `NSTextField`'s field editor only
/// receives key events when its window is key AND its app is active, so a text
/// field inside that panel can never be typed into — and the click that tries
/// to focus it makes the panel resign key, which tears the panel down.
///
/// This controller is deliberately simpler than the pairing one: there is no
/// remote flow to cancel, no countdown, and closing the window means nothing
/// beyond "the user changed their mind".
///
/// # Why presentation is deferred (the 2026-09-05 SIGABRT)
///
/// Enabling a LAN receiver row and opening this window crashed the app with an
/// uncaught AppKit exception raised from
/// `-[NSWindow(NSDisplayCycle) _postWindowNeedsUpdateConstraints]`, reached
/// through `NSHostingView.invalidateSafeAreaCornerInsets()` →
/// `requestUpdate(after:)` → `setNeedsUpdateConstraints:` while the crashing
/// thread was inside `NSDisplayCycleFlush` →
/// `__NSWindowGetDisplayCycleObserverForLayout_block_invoke`. In plain terms:
/// a hosting view asked for a constraints update *during* the layout pass of a
/// display cycle, which AppKit refuses.
///
/// Two things in the old code fed that:
///
///   1. `present()` created the `NSWindow` and ordered it front synchronously,
///      on the stack of the SwiftUI action that had just mutated observable
///      model state. A brand-new window with a hosting view joins the display
///      cycle the moment it has a content view, so it could be picked up by a
///      flush that was already running.
///   2. The window was built as `NSWindow(contentViewController:)` — whose
///      default style mask is `[.titled, .closable, .miniaturizable,
///      .resizable]` — and the style mask was then *mutated* to
///      `[.titled, .closable]` with the hosting view already installed.
///      Dropping `.resizable` rebuilds the window's theme frame, which is
///      precisely what makes AppKit recompute corner/safe-area insets and
///      makes the hosting view invalidate its constraints.
///
/// So: hop to the next main-queue turn before touching AppKit at all, and
/// build the window with its final style in one shot, installing the hosting
/// view only after every window property is settled. No exception is caught
/// anywhere — an ObjC exception through Swift frames is unrecoverable, and the
/// only real fix is not to raise it.
@MainActor
final class LanTokenWindowController: NSObject, NSWindowDelegate {

    private static let windowTitle = "LAN Receiver Token"
    /// SyncCast's normal policy: menu-bar only, no Dock icon (`LSUIElement`).
    private static let menuBarActivationPolicy: NSApplication.ActivationPolicy = .accessory
    /// Fallback if `.accessory` activation is refused and the window therefore
    /// cannot take keyboard focus. Costs a Dock icon for the duration, which
    /// is far cheaper than a field nobody can type into.
    private static let foregroundActivationPolicy: NSApplication.ActivationPolicy = .regular

    private unowned let model: AppModel
    private var window: NSWindow?
    private var didEscalateActivationPolicy = false
    private var didBecomeKeySincePresent = false
    private var activationCheck: Task<Void, Never>?

    /// True between `present()` and the deferred presentation actually
    /// running. A second `present()` in that gap is dropped rather than
    /// queueing a second hop: the row's button can be clicked twice, and two
    /// hops would `NSApp.activate` twice for one window.
    private var presentationIsPending = false

    /// The same guard for the closing direction.
    private var dismissalIsPending = false

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    // MARK: - Testing seams

    /// The window, once the deferred presentation has built it. Exists so a
    /// test can assert that `present()` builds nothing synchronously.
    var presentedWindowForTesting: NSWindow? { window }

    /// Whether a deferred presentation is in flight.
    var hasPendingPresentationForTesting: Bool { presentationIsPending }

    // MARK: - Presentation

    /// Show the window for whichever receiver `model.lanTokenEditorDeviceID`
    /// names. A second call for another receiver reuses the same window rather
    /// than stacking one per row.
    ///
    /// Nothing here touches AppKit: the actual window work runs on the next
    /// main-queue turn, outside whatever display cycle the calling SwiftUI
    /// update belongs to. See the type comment for what happens when it does
    /// not.
    func present() {
        guard model.lanTokenEditorDeviceID != nil else { return }
        guard !presentationIsPending else { return }
        presentationIsPending = true
        // A close that was scheduled a moment ago must not land on the window
        // we are about to show.
        dismissalIsPending = false
        afterCurrentDisplayCycle { [weak self] in
            guard let self else { return }
            self.presentationIsPending = false
            self.presentNow()
        }
    }

    private func presentNow() {
        // The user can cancel between the hop being scheduled and it running
        // (the row's button is one click, the popover's dismissal another).
        guard model.lanTokenEditorDeviceID != nil else { return }
        let window = self.window ?? makeWindow()
        self.window = window
        if !window.isVisible { window.center() }
        activateAndFocus(window)
    }

    /// Close the window because the flow ended. The model state is cleared
    /// immediately — that is an ordinary SwiftUI mutation and is safe from
    /// anywhere — but the `close()` is deferred for the same reason the open
    /// is: closing a window runs a layout pass on whatever inherits key
    /// status.
    func dismiss() {
        model.lanTokenEditorDeviceID = nil
        model.lanTokenSaveError = nil
        guard let window, window.isVisible, !dismissalIsPending else { return }
        dismissalIsPending = true
        afterCurrentDisplayCycle { [weak self] in
            guard let self else { return }
            self.dismissalIsPending = false
            // A `present()` that arrived while this hop was in flight re-armed
            // the editor; closing now would yank the window out from under it.
            guard self.model.lanTokenEditorDeviceID == nil else { return }
            guard let window = self.window, window.isVisible else { return }
            window.close()
        }
    }

    /// Run `work` on the next main-queue turn, i.e. after the current AppKit
    /// display cycle (and the SwiftUI transaction that provoked it) has fully
    /// unwound.
    ///
    /// `DispatchQueue.main.async` rather than `Task { @MainActor }` because
    /// the ordering guarantee we need is a run-loop one — "after the current
    /// callout returns" — and the main queue states it directly instead of
    /// leaving it to the cooperative executor's scheduling.
    private func afterCurrentDisplayCycle(_ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { work() }
        }
    }

    /// Build the window in its final shape, in one pass.
    ///
    /// Order is deliberate and is half of the crash fix: every window property
    /// — style mask, level, collection behaviour, title — is settled BEFORE
    /// the hosting view is installed, so the hosting view never observes a
    /// window whose theme frame is being rebuilt underneath it.
    private func makeWindow() -> NSWindow {
        let root = LanTokenWindowRootView(onFinished: { [weak self] in self?.dismiss() })
            .environment(model)
        let hosting = NSHostingView(rootView: root)
        // `.standardBounds` (min ∪ intrinsic ∪ max) rather than
        // `.preferredContentSize`: the latter forwards the SwiftUI ideal size
        // to the hosting view's ENCLOSING VIEW CONTROLLER, and this window has
        // none — the hosting view is the content view directly, precisely so
        // that no `NSHostingController` re-styles the window after the fact.
        // `.standardBounds` is what makes the window adopt (and keep) the
        // form's own size, so the fixed-width form is never clipped and never
        // has to be resized by hand.
        hosting.sizingOptions = [.standardBounds]
        let fitting = hosting.fittingSize
        let contentSize = CGSize(
            width: max(fitting.width, LanTokenWindowMetrics.contentWidth),
            height: max(fitting.height, LanTokenWindowMetrics.minimumContentHeight)
        )
        // An explicit initial frame, so the first layout pass has a real size
        // to work with instead of resizing from zero.
        hosting.frame = CGRect(origin: .zero, size: contentSize)

        // `.titled` is what makes a window able to become key at all; a
        // borderless panel reproduces the bug this class exists to avoid.
        // Passed at init rather than assigned afterwards — see the type
        // comment for what the assignment cost us.
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = Self.windowTitle
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        // AppKit state restoration would archive the field editor's contents —
        // i.e. the token — into ~/Library/Saved Application State.
        window.isRestorable = false
        window.delegate = self
        window.contentView = hosting
        return window
    }

    private func activateAndFocus(_ window: NSWindow) {
        // Order matters: activate the app first, then make the window key.
        // Reversed, AppKit hands key status to a window in an inactive app and
        // the field editor still never sees a keystroke.
        didBecomeKeySincePresent = false
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        didBecomeKeySincePresent = didBecomeKeySincePresent || window.isKeyWindow
        activationCheck?.cancel()
        activationCheck = Task { @MainActor [weak self] in
            try? await Task.sleep(for: LanTokenWindowMetrics.activationVerificationDelay)
            guard !Task.isCancelled else { return }
            self?.escalateActivationIfStillUnfocused()
        }
    }

    /// macOS may refuse an activation request from a background accessory app.
    /// If it did, the window is on screen but inert, so promote the app and
    /// try once more — but only if the window has NEVER been key, because a
    /// window that took focus and then lost it means the user deliberately
    /// moved to the receiving Mac's screen to read the token.
    private func escalateActivationIfStillUnfocused() {
        guard let window, window.isVisible, !window.isKeyWindow else { return }
        guard !didBecomeKeySincePresent, !didEscalateActivationPolicy else { return }
        SyncCastLog.log(
            "LanTokenWindowController: accessory activation refused — promoting to .regular"
        )
        NSApp.setActivationPolicy(Self.foregroundActivationPolicy)
        didEscalateActivationPolicy = true
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func restoreActivationPolicy() {
        guard didEscalateActivationPolicy else { return }
        didEscalateActivationPolicy = false
        NSApp.setActivationPolicy(Self.menuBarActivationPolicy)
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        didBecomeKeySincePresent = true
        activationCheck?.cancel()
        activationCheck = nil
    }

    func windowWillClose(_ notification: Notification) {
        activationCheck?.cancel()
        activationCheck = nil
        restoreActivationPolicy()
        model.lanTokenEditorDeviceID = nil
        model.lanTokenSaveError = nil
    }
}

/// Root view inside the token window.
///
/// Reads `model.lanTokenEditorDeviceID` live rather than capturing it, so
/// opening the window for a second receiver re-targets the form instead of
/// editing the first one's token.
///
/// There is deliberately no `if let` around the form: an empty
/// `lanTokenEditorDeviceID` renders the SAME form, disabled, rather than a
/// 1-pt placeholder. A placeholder that size makes the window open tiny and
/// resize itself one update later, and a window resize driven from a SwiftUI
/// update is the constraint traffic that crashed this window in the first
/// place.
struct LanTokenWindowRootView: View {
    @Environment(AppModel.self) private var model

    let onFinished: () -> Void

    var body: some View {
        LanTokenEntryView(deviceID: model.lanTokenEditorDeviceID, onFinished: onFinished)
            // A fresh view per receiver, so the field starts empty rather than
            // holding what was typed for another one.
            .id(model.lanTokenEditorDeviceID ?? "")
    }
}
