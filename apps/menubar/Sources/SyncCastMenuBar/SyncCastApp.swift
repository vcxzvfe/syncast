import SwiftUI
import AppKit
import CoreGraphics
import Foundation
import SyncCastDiscovery
import SyncCastRouter

/// File-based logger reachable from `open`-launched apps where stderr is
/// detached and NSLog is silently dropped by the system log subsystem.
///
/// Destination, in order:
///   1. `SYNCAST_LOG_PATH`, if set to a non-empty path — an explicit override
///      for scripted runs and for tests that want to READ back what was logged.
///   2. A per-process file under the temp directory when running inside
///      XCTest. `swift test` loads the app target, so without this every test
///      run appended to the user's real log — which it did, dozens of lines
///      per run, until 2026-09-05.
///   3. `~/Library/Logs/SyncCast/launch.log` — the real app's log.
public enum SyncCastLog {
    /// Explicit destination override. Takes precedence over the XCTest
    /// redirect, so a test can point the log at a file it then reads.
    public static let pathOverrideEnvVar = "SYNCAST_LOG_PATH"

    /// Where a given environment sends the log. Pure, so the routing rule is
    /// testable without touching the filesystem.
    static func resolvePath(
        environment: [String: String],
        libraryDirectory: URL,
        temporaryDirectory: URL,
        processIdentifier: Int32,
        underXCTest: Bool
    ) -> URL {
        if let override = environment[pathOverrideEnvVar],
           !override.trimmingCharacters(in: .whitespaces).isEmpty {
            return URL(fileURLWithPath: override)
        }
        if underXCTest || TestEnvironment.isRunningUnderXCTest(environment: environment) {
            return temporaryDirectory
                .appendingPathComponent("SyncCast-tests-\(processIdentifier).log")
        }
        return libraryDirectory
            .appendingPathComponent("Logs/SyncCast", isDirectory: true)
            .appendingPathComponent("launch.log")
    }

    private static let path: URL = {
        let resolved = resolvePath(
            environment: ProcessInfo.processInfo.environment,
            libraryDirectory: FileManager.default
                .urls(for: .libraryDirectory, in: .userDomainMask).first!,
            temporaryDirectory: FileManager.default.temporaryDirectory,
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            underXCTest: TestEnvironment.isXCTestFrameworkLoaded
        )
        try? FileManager.default.createDirectory(
            at: resolved.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        return resolved
    }()
    /// Where this process is actually logging. Exposed so a test (or a support
    /// request) can say which file to look in rather than guessing.
    public static var currentPath: String { path.path }
    private static let lock = NSLock()

    public static func log(_ msg: String) {
        let line = "\(Date()) \(msg)\n"
        fputs(line, stderr)
        lock.lock(); defer { lock.unlock() }
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: path.path),
           let h = try? FileHandle(forWritingTo: path) {
            try? h.seekToEnd()
            try? h.write(contentsOf: data)
            try? h.close()
        } else {
            try? data.write(to: path)
        }
    }
}

/// Resolve a status icon name (either `sf:<symbol>` for SF Symbols, or
/// the basename of a flat PNG in the SwiftPM resource bundle) to a
/// SwiftUI `Image`. Used by both `MenuBarExtra` and `MainPopover` header
/// so a future status-icon-name change can't desync them.
@inline(__always)
func statusIcon(name: String) -> Image {
    if name.hasPrefix("sf:") {
        return Image(systemName: String(name.dropFirst(3)))
    }
    if let ns = Bundle.module.image(forResource: NSImage.Name(name)) {
        ns.isTemplate = true
        return Image(nsImage: ns)
    }
    SyncCastLog.log("statusIcon('\(name)'): Bundle.module.image nil; falling back to SF speaker.wave.2")
    let fallback = NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: nil) ?? NSImage()
    fallback.isTemplate = true
    return Image(nsImage: fallback)
}

@MainActor
final class AppTerminationCoordinator {
    static let shared = AppTerminationCoordinator()
    var model: AppModel?
}

final class SyncCastAppDelegate: NSObject, NSApplicationDelegate {
    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            let canTerminate =
                await AppTerminationCoordinator.shared.model?
                    .shutdownForTermination() ?? true
            sender.reply(toApplicationShouldTerminate: canTerminate)
        }
        return .terminateLater
    }
}

@main
struct SyncCastApp: App {
    @NSApplicationDelegateAdaptor(SyncCastAppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    init() {
        SyncCastLog.log("=== SyncCast process starting (pid \(getpid())) ===")
        // The router package writes its diagnostics to stderr by default, and
        // an `open`-launched .app has no stderr — which is why a 108 s stall
        // inside `Router.start` on 2026-09-05 left nothing at all in
        // launch.log. Point them at the same file the app logs to, tagged so
        // the source is unambiguous.
        RouterLog.sink = { line in SyncCastLog.log("[router] \(line)") }
        NSApp?.setActivationPolicy(.accessory)

        // Only ScreenCaptureKit needs Screen Recording. Tap mode, Direct
        // Stereo and the system-sink path (whose tap is System Audio
        // Recording, a different TCC class) must not trip it, otherwise DRM
        // validation is meaningless.
        let captureBackend = ProcessInfo.processInfo
            .environment["SYNCAST_CAPTURE_BACKEND"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let selectedStereoPath = StereoOutputPathPolicy.resolvedPath()
        let initialMode = ProcessInfo.processInfo
            .environment["SYNCAST_INITIAL_MODE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let startsWholeHome = initialMode == "wholehome" || initialMode == "whole_home"
        let skipScreenRecordingPreflight =
            captureBackend == "tap"
            || (selectedStereoPath != .capture && !startsWholeHome)
        if skipScreenRecordingPreflight {
            SyncCastLog.log("screen-recording preflight skipped: capture=\(captureBackend ?? "sck") stereoPath=\(selectedStereoPath.rawValue)")
        } else {
            let pre = CGPreflightScreenCaptureAccess()
            SyncCastLog.log("screen-recording preflight: \(pre)")
            if !pre {
                SyncCastLog.log("requesting screen-recording access — expect a system prompt")
                let granted = CGRequestScreenCaptureAccess()
                SyncCastLog.log("screen-recording request immediate=\(granted) (Tahoe: real grant requires app restart)")
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MainPopover()
                .environment(model)
                .frame(width: 340)
        } label: {
            Label {
                Text("SyncCast")
            } icon: {
                statusIcon(name: model.statusIconName)
            }
        }
        .menuBarExtraStyle(.window)
    }
}
