import Foundation

/// Router-side diagnostic log sink. Writes to BOTH stderr and
/// `~/Library/Logs/SyncCast/launch.log` (mirrors the menubar's
/// SyncCastLog — duplicated here because the router target sits below
/// the menubar package and cannot import it). The launch.log path is
/// what survives `open -a SyncCast.app`, where stderr is detached.
///
/// Its live consumer is `LocalAirPlayBridge`: device/rate/backoff setup
/// at `openAudioUnit`, and the batched Layer-2 drift-resync drain.
/// Gated globally by `DiagnosticLog.verbose`.
public enum DiagnosticLog {
    public static var verbose: Bool = true

    private static let path: URL = {
        let dir = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs/SyncCast", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        return dir.appendingPathComponent("launch.log")
    }()
    private static let lock = NSLock()

    public static func log(_ message: String) {
        guard verbose else { return }
        let line = "\(Date()) \(message)\n"
        fputs(line, stderr)
        lock.lock(); defer { lock.unlock() }
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: path.path),
           let h = try? FileHandle(forWritingTo: path) {
            do {
                try h.seekToEnd()
                try h.write(contentsOf: data)
                try h.close()
            } catch {
                // Best-effort — stderr write above already happened.
            }
        } else {
            try? data.write(to: path)
        }
    }
}
