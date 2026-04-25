import Foundation
import CoreGraphics

/// Screen Recording TCC permission helper.
///
/// SyncCast's audio capture (`SCKCapture`) relies on the Screen Recording
/// permission category — NOT microphone. The SCK research brief
/// (`docs/research/screencapturekit-brief.md`) documents the exact prompt
/// flow Tahoe expects:
///
///   1. `CGPreflightScreenCaptureAccess()` — non-blocking, no prompt.
///   2. If not granted, `CGRequestScreenCaptureAccess()` — shows the OS
///      prompt that points the user to System Settings.
///   3. Restart the app after the user grants — Tahoe does not pick up
///      a fresh grant in the running process.
public enum ScreenRecordingTCC {
    public enum Status: String, Sendable {
        case granted
        case denied        // user has explicitly denied
        case notDetermined // never asked yet
    }

    public static var current: Status {
        // CGPreflightScreenCaptureAccess returns true only if granted.
        // It cannot distinguish "denied" from "not yet asked"; we treat
        // anything-not-granted as "notDetermined" until we explicitly
        // request and observe the user's choice.
        return CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
    }

    /// Show the system Screen Recording prompt. Returns immediately —
    /// the user's actual choice doesn't materialize until they restart
    /// the process. Caller should display a "click Allow then quit and
    /// reopen SyncCast" hint and then `NSApp.terminate(nil)`.
    @discardableResult
    public static func request() -> Bool {
        return CGRequestScreenCaptureAccess()
    }

    /// Open System Settings → Privacy & Security → Screen Recording.
    public static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

#if canImport(AppKit)
import AppKit
#endif
