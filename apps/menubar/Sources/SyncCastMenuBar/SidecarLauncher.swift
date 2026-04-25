import Foundation

/// Spawns the bundled `syncast-sidecar` (PyInstaller binary) and tells it
/// where to find the bundled `owntone` binary. Tracks the child process and
/// terminates it cleanly on app quit.
///
/// Bundle layout we expect:
///
///   SyncCast.app/Contents/Resources/sidecar/syncast-sidecar
///   SyncCast.app/Contents/Resources/owntone/owntone
///   SyncCast.app/Contents/Resources/owntone/owntone.conf.template
///
/// State (FIFO + db + config) goes to:
///   ~/Library/Application Support/SyncCast/owntone/
///
/// Sockets (control + audio) go to:
///   /tmp/syncast-$UID.sock  +  /tmp/syncast-$UID.audio.sock
public final class SidecarLauncher {
    public struct Paths {
        public let controlSocket: URL
        public let audioSocket: URL
        public let stateDir: URL
    }

    private var process: Process?
    private var stderrPipe: Pipe?
    private(set) public var paths: Paths

    public init() {
        let uid = getuid()
        let control = URL(fileURLWithPath: "/tmp/syncast-\(uid).sock")
        let audio   = URL(fileURLWithPath: "/tmp/syncast-\(uid).audio.sock")
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
        let stateDir = appSupport
            .appendingPathComponent("SyncCast", isDirectory: true)
            .appendingPathComponent("owntone", isDirectory: true)
        self.paths = Paths(controlSocket: control, audioSocket: audio, stateDir: stateDir)
    }

    /// Locate the bundled sidecar + owntone binaries, or fall back to a
    /// dev-mode source layout (for `swift run` outside a .app).
    public struct ResolvedBinaries {
        public let sidecar: URL
        public let owntone: URL?
        public let owntoneConfigTemplate: URL?
        public let usingBundle: Bool
    }

    public static func resolveBinaries() -> ResolvedBinaries? {
        let bundle = Bundle.main
        if let res = bundle.resourcePath {
            let resURL = URL(fileURLWithPath: res)
            let sidecar = resURL.appendingPathComponent("sidecar/syncast-sidecar")
            let owntone = resURL.appendingPathComponent("owntone/owntone")
            let conf = resURL.appendingPathComponent("owntone/owntone.conf.template")
            if FileManager.default.isExecutableFile(atPath: sidecar.path) {
                return ResolvedBinaries(
                    sidecar: sidecar,
                    owntone: FileManager.default.isExecutableFile(atPath: owntone.path) ? owntone : nil,
                    owntoneConfigTemplate: FileManager.default.fileExists(atPath: conf.path) ? conf : nil,
                    usingBundle: true
                )
            }
        }
        // Dev-mode fallback: look for the user-built artefacts at known
        // paths in the source tree. Only useful when running via `swift run`
        // during local development — production goes through the bundle path
        // above.
        let home = FileManager.default.homeDirectoryForCurrentUser
        let devSidecar = home.appendingPathComponent(
            "syncast/sidecar/dist-pyinstaller/syncast-sidecar")
        let devOwntone = home.appendingPathComponent(
            "owntone_data/usr/sbin/owntone")
        if FileManager.default.isExecutableFile(atPath: devSidecar.path) {
            return ResolvedBinaries(
                sidecar: devSidecar,
                owntone: FileManager.default.isExecutableFile(atPath: devOwntone.path) ? devOwntone : nil,
                owntoneConfigTemplate: nil,
                usingBundle: false
            )
        }
        return nil
    }

    @discardableResult
    public func start() throws -> Paths {
        guard let bins = Self.resolveBinaries() else {
            SyncCastLog.log("[SyncCast] no sidecar binary found".replacingOccurrences(of: "[SyncCast] ", with: ""))
            throw NSError(
                domain: "SidecarLauncher", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "syncast-sidecar binary not found in the .app bundle or the dev fallback path"]
            )
        }
        SyncCastLog.log("[SyncCast] sidecar binary: \(bins.sidecar.path), bundled=\(bins.usingBundle)".replacingOccurrences(of: "[SyncCast] ", with: ""))
        // Best-effort cleanup of stale sockets from a previous crash.
        for url in [paths.controlSocket, paths.audioSocket] {
            try? FileManager.default.removeItem(at: url)
        }
        try FileManager.default.createDirectory(
            at: paths.stateDir, withIntermediateDirectories: true
        )

        let proc = Process()
        proc.executableURL = bins.sidecar
        var args: [String] = [
            "--socket", paths.controlSocket.path,
            "--audio-socket", paths.audioSocket.path,
            "--state-dir", paths.stateDir.path,
            "--log-level", "info",
        ]
        if let owntone = bins.owntone {
            args.append("--owntone-binary"); args.append(owntone.path)
        }
        if let conf = bins.owntoneConfigTemplate {
            args.append("--owntone-config-template"); args.append(conf.path)
        }
        proc.arguments = args
        let errPipe = Pipe()
        proc.standardError = errPipe
        self.stderrPipe = errPipe
        try proc.run()
        self.process = proc
        SyncCastLog.log("[SyncCast] sidecar pid=\(proc.processIdentifier) launched, waiting for socket…".replacingOccurrences(of: "[SyncCast] ", with: ""))
        // Block briefly until the socket actually exists. PyInstaller's
        // onefile bootstrap can take 1-3s on first run while it extracts
        // bundled libs to /var/folders/...
        let deadline = Date().addingTimeInterval(8.0)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: paths.controlSocket.path) {
                SyncCastLog.log("[SyncCast] sidecar socket appeared after \(Date().timeIntervalSince(deadline.addingTimeInterval(-8))) s".replacingOccurrences(of: "[SyncCast] ", with: ""))
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        // Capture stderr (which is JSON log lines) into the unified system log
        // so the user can see sidecar messages in Console.app.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let h = self?.stderrPipe?.fileHandleForReading else { return }
            while true {
                let data = h.availableData
                if data.isEmpty { break }
                FileHandle.standardError.write(data)
            }
        }
        return paths
    }

    public func stop() {
        guard let proc = process, proc.isRunning else { return }
        proc.terminate()
        // Best-effort wait
        let deadline = Date().addingTimeInterval(2)
        while proc.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if proc.isRunning {
            kill(proc.processIdentifier, SIGKILL)
        }
        process = nil
    }

    deinit { stop() }
}
