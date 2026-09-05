import AppKit
import SwiftUI

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
@MainActor
final class LanTokenWindowController: NSObject, NSWindowDelegate {

    private static let windowTitle = "LAN Receiver Token"
    /// SyncCast's normal policy: menu-bar only, no Dock icon (`LSUIElement`).
    private static let menuBarActivationPolicy: NSApplication.ActivationPolicy = .accessory
    /// Fallback if `.accessory` activation is refused and the window therefore
    /// cannot take keyboard focus. Costs a Dock icon for the duration, which
    /// is far cheaper than a field nobody can type into.
    private static let foregroundActivationPolicy: NSApplication.ActivationPolicy = .regular
    /// Long enough for AppKit's activation handshake, short enough that the
    /// user cannot have started typing.
    private static let activationVerificationDelay: Duration = .milliseconds(250)

    private unowned let model: AppModel
    private var window: NSWindow?
    private var didEscalateActivationPolicy = false
    private var didBecomeKeySincePresent = false
    private var activationCheck: Task<Void, Never>?

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    /// Show the window for whichever receiver `model.lanTokenEditorDeviceID`
    /// names. A second call for another receiver reuses the same window rather
    /// than stacking one per row.
    func present() {
        guard model.lanTokenEditorDeviceID != nil else { return }
        let window = self.window ?? makeWindow()
        self.window = window
        if !window.isVisible { window.center() }
        activateAndFocus(window)
    }

    func dismiss() {
        model.lanTokenEditorDeviceID = nil
        model.lanTokenSaveError = nil
        guard let window, window.isVisible else { return }
        window.close()
    }

    private func makeWindow() -> NSWindow {
        let root = LanTokenWindowRootView(onFinished: { [weak self] in self?.dismiss() })
            .environment(model)
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        // `.titled` is what makes a window able to become key at all; a
        // borderless panel reproduces the bug this class exists to avoid.
        window.styleMask = [.titled, .closable]
        window.title = Self.windowTitle
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        // AppKit state restoration would archive the field editor's contents —
        // i.e. the token — into ~/Library/Saved Application State.
        window.isRestorable = false
        window.delegate = self
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
            try? await Task.sleep(for: Self.activationVerificationDelay)
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
struct LanTokenWindowRootView: View {
    @Environment(AppModel.self) private var model

    let onFinished: () -> Void

    var body: some View {
        Group {
            if let deviceID = model.lanTokenEditorDeviceID {
                LanTokenEntryView(deviceID: deviceID, onFinished: onFinished)
                    // A fresh view per receiver, so the field starts empty
                    // rather than holding what was typed for another one.
                    .id(deviceID)
            } else {
                Color.clear.frame(width: LanTokenEntryView.contentWidth, height: 1)
            }
        }
    }
}
