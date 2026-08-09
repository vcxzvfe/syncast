import AppKit
import SwiftUI

/// Geometry and timing constants for the pairing window. Named rather than
/// inlined because two of them (the width, the activation grace period) are
/// the kind of number a future reader would otherwise have to guess at.
private enum PairingWindowMetrics {
    /// Matches the popover width the pairing view was laid out against, so
    /// moving the view out of the popover does not reflow its text.
    static let contentWidth: CGFloat = 340

    /// Height of the empty placeholder shown only in the brief window between
    /// the model clearing `pairingSheet` and the window actually closing.
    static let placeholderHeight: CGFloat = 1

    /// How long to wait before checking whether the activation request was
    /// honoured. Long enough for AppKit to finish its activation handshake,
    /// short enough that the user cannot have started typing yet.
    static let activationVerificationDelay: Duration = .milliseconds(250)
}

/// Hosts the AirPlay pairing flow in a real, key-capable AppKit window.
///
/// Why this exists at all: the pairing UI used to be a SwiftUI `.sheet`
/// attached to the `MenuBarExtra(.window)` popover. That popover is a
/// non-activating status-bar panel — clicking it never makes SyncCast the
/// active application, and an NSTextField's field editor only receives key
/// events when its window is key AND its app is active. So the PIN field
/// could never be typed into; worse, the click that tried to focus it made the
/// panel resign key, which tore the panel down and took the sheet with it.
/// That is the "I click the box and everything disappears" report.
///
/// The fix is a window we own outright, with every auto-dismiss behaviour
/// switched off, plus an explicit `NSApp.activate` — SyncCast is an
/// `LSUIElement` accessory app, so nothing else will ever activate it for us.
@MainActor
final class PairingWindowController: NSObject, NSWindowDelegate {

    /// SyncCast's normal policy: menu-bar only, no Dock icon (`LSUIElement`).
    private static let menuBarActivationPolicy: NSApplication.ActivationPolicy = .accessory

    /// Fallback policy, used only if `.accessory` activation is refused and
    /// the window therefore cannot take keyboard focus. The cost is a Dock
    /// icon appearing for the duration of the pairing attempt, which is far
    /// cheaper than a PIN field nobody can type into.
    private static let foregroundActivationPolicy: NSApplication.ActivationPolicy = .regular

    private static let windowTitle = "AirPlay Pairing"

    private unowned let model: AppModel

    /// One window, reused across attempts and devices. Recreating it per
    /// attempt would drop keyboard focus on every "Try again".
    private var window: NSWindow?

    /// Guards the two-way teardown path: the model clearing `pairingSheet`
    /// closes the window, and closing the window cancels pairing. Without this
    /// flag the two call each other forever.
    private var isTearingDown = false

    /// True while the app has been temporarily promoted out of `.accessory`.
    private var didEscalateActivationPolicy = false

    /// Whether the window has become key at any point since `present()`.
    ///
    /// This is what separates "macOS refused our activation" from "the user
    /// walked away on purpose". Both look identical at the moment of the
    /// check — not key, app not active — but only the first is ours to fix.
    private var didBecomeKeySincePresent = false

    private var activationCheck: Task<Void, Never>?

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    // MARK: - Presentation

    /// Show the pairing window, or bring it back to the front and re-focus it
    /// if it is already open (a second `startPairing` for another device
    /// reuses the same window).
    func present() {
        let window = self.window ?? makeWindow()
        self.window = window
        isTearingDown = false
        let isFirstAppearance = !window.isVisible
        if isFirstAppearance {
            window.center()
        }
        activateAndFocus(window)
        SyncCastLog.log(
            "PairingWindowController: presented (first=\(isFirstAppearance))"
        )
    }

    /// Close the window because the flow already ended elsewhere. Deliberately
    /// does NOT cancel pairing — the model is the one that ended it.
    func dismiss() {
        guard !isTearingDown, let window, window.isVisible else { return }
        isTearingDown = true
        window.close()
        isTearingDown = false
    }

    private func makeWindow() -> NSWindow {
        let root = PairingWindowRootView(
            onFlowEnded: { [weak self] in self?.dismiss() }
        )
        .environment(model)

        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        // `.titled` is what makes the window able to become key at all; a
        // borderless or non-activating panel reproduces the original bug.
        window.styleMask = [.titled, .closable]
        window.title = Self.windowTitle
        // The controller reuses one window for every attempt, so AppKit must
        // not deallocate it on close — that would leave a dangling pointer to
        // use on the second pairing.
        window.isReleasedWhenClosed = false
        // The receiver covers its own display with the PIN, and the user may
        // be on any Space by then. Float above, and follow them.
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        // AppKit state restoration would archive the field editor's contents —
        // i.e. the PIN — into ~/Library/Saved Application State. The PIN is
        // never persisted anywhere.
        window.isRestorable = false
        window.delegate = self
        return window
    }

    // MARK: - Activation

    private func activateAndFocus(_ window: NSWindow) {
        // Order matters: activate the app first, then make the window key.
        // Reversed, AppKit hands key status to a window in an inactive app and
        // the field editor still never sees a keystroke.
        didBecomeKeySincePresent = false
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // `makeKeyAndOrderFront` can make the window key synchronously, which
        // fires `windowDidBecomeKey` before this returns — so re-read rather
        // than trusting the reset above.
        didBecomeKeySincePresent = didBecomeKeySincePresent || window.isKeyWindow

        activationCheck?.cancel()
        activationCheck = Task { @MainActor [weak self] in
            try? await Task.sleep(for: PairingWindowMetrics.activationVerificationDelay)
            guard !Task.isCancelled else { return }
            self?.escalateActivationIfStillUnfocused()
        }
    }

    /// macOS may refuse an activation request from a background accessory app.
    /// If it did, the window is on screen but inert — exactly the symptom we
    /// are fixing — so promote the app to a regular one and try once more.
    ///
    /// Escalating is not free: it adds a Dock icon and yanks focus with
    /// `ignoringOtherApps`. So it only fires when the window has NEVER been
    /// key since `present()`. A window that took focus and then lost it means
    /// the user deliberately moved to another app — very likely the receiving
    /// Mac's screen, which is where the PIN is — and stealing focus back would
    /// eat the keys they are typing there.
    private func escalateActivationIfStillUnfocused() {
        guard let window, window.isVisible, !window.isKeyWindow else { return }
        guard !didBecomeKeySincePresent else {
            SyncCastLog.log(
                "PairingWindowController: window lost key to another app — "
                + "not escalating"
            )
            return
        }
        guard !didEscalateActivationPolicy else {
            SyncCastLog.log(
                "PairingWindowController: still not key after policy escalation"
            )
            return
        }
        SyncCastLog.log(
            "PairingWindowController: accessory activation refused — promoting to .regular"
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
        SyncCastLog.log("PairingWindowController: restored .accessory activation policy")
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        didBecomeKeySincePresent = true
        // The activation policy is deliberately NOT restored here even though
        // the escalation has served its purpose: going back to `.accessory`
        // while this window holds key can deactivate the app and drop the
        // field editor's focus, which is the very failure being fixed. It is
        // restored on close instead, so the Dock icon lasts at most as long as
        // the pairing attempt.
        activationCheck?.cancel()
        activationCheck = nil
    }

    func windowWillClose(_ notification: Notification) {
        activationCheck?.cancel()
        activationCheck = nil
        restoreActivationPolicy()

        // `dismiss()` sets the flag before closing, so a close we initiated
        // stops here: the model already ended the flow.
        guard !isTearingDown else { return }

        // A close the user initiated (red button, Cmd-W) must cancel, or the
        // sidecar keeps the pairing session open and the receiver keeps its
        // full-screen PIN up indefinitely.
        isTearingDown = true
        model.cancelPairing()
        isTearingDown = false
    }
}

/// Root view inside the pairing window.
///
/// It reads `model.pairingSheet` directly instead of taking a snapshot: the
/// countdown ticks once a second on a poll that is completely independent of
/// the UI, and a snapshot captured at window-creation time would freeze the
/// "Ns left" label and the Pair button's enablement.
///
/// It is also the right place to observe the end of the flow. The popover's
/// view tree is destroyed whenever the menu-bar panel closes, so an observer
/// there would silently stop working; this view lives in the pairing window
/// and is alive for exactly as long as the flow is.
struct PairingWindowRootView: View {
    @Environment(AppModel.self) private var model

    let onFlowEnded: () -> Void

    var body: some View {
        Group {
            if let state = model.pairingSheet {
                PairingSheet(state: state)
            } else {
                Color.clear
                    .frame(
                        width: PairingWindowMetrics.contentWidth,
                        height: PairingWindowMetrics.placeholderHeight
                    )
            }
        }
        .onChange(of: model.pairingSheet == nil) { _, flowEnded in
            if flowEnded { onFlowEnded() }
        }
    }
}
