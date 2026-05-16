import SwiftUI
import AppKit
import CoreGraphics
import Foundation
import SyncCastDiscovery
import SyncCastRouter

/// File-based logger reachable from `open`-launched apps where stderr is
/// detached and NSLog is silently dropped by the system log subsystem.
/// Always writes to ~/Library/Logs/SyncCast/launch.log.
public enum SyncCastLog {
    private static let path: URL = {
        let dir = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs/SyncCast", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("launch.log")
    }()
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
        NSApp?.setActivationPolicy(.accessory)

        // Only ScreenCaptureKit needs Screen Recording. Tap mode and Direct
        // Stereo mode must not trip this TCC class, otherwise DRM validation
        // is meaningless.
        let captureBackend = ProcessInfo.processInfo
            .environment["SYNCAST_CAPTURE_BACKEND"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let selectedStereoPath = StereoOutputPathPolicy.selectedPath()
        let initialMode = ProcessInfo.processInfo
            .environment["SYNCAST_INITIAL_MODE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let startsWholeHome = initialMode == "wholehome" || initialMode == "whole_home"
        let skipScreenRecordingPreflight =
            captureBackend == "tap" || (selectedStereoPath == .direct && !startsWholeHome)
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
