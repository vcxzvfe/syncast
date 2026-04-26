import Foundation
import Darwin
import CoreAudio
import SyncCastDiscovery

/// Unix-domain JSON-RPC listener that lets `scripts/calibration_test.sh`
/// drive `Router.runCalibration` from the CLI without touching the menubar.
/// Whole-home only — Router binds it on entering whole-home+running and
/// tears it down on every other state. NDJSON over SOCK_STREAM, mode 0600.
/// Single-flight: a second concurrent connection gets -32002 and closes.
public final class CalibrationDiagnosticServer: @unchecked Sendable {
    public struct Snapshot: Sendable {
        public let devices: [Device]
        public let microphoneDeviceID: AudioDeviceID?
        public init(devices: [Device], microphoneDeviceID: AudioDeviceID?) {
            self.devices = devices
            self.microphoneDeviceID = microphoneDeviceID
        }
    }
    public typealias Provider = @Sendable () async -> Snapshot?
    public typealias Runner = @Sendable (Snapshot) async throws
        -> (deltaMs: Int, confidence: Double, perDeviceOffsetMs: [String: Int])

    public let socketPath: URL
    private let provider: Provider
    private let runner: Runner
    private var listenFd: Int32 = -1
    private var acceptThread: Thread?
    private let lock = NSLock()
    private var inProgress: Bool = false

    public init(socketPath: URL, provider: @escaping Provider, runner: @escaping Runner) {
        self.socketPath = socketPath; self.provider = provider; self.runner = runner
    }

    public func start() throws {
        if lock.calibLock({ listenFd >= 0 }) { return }
        try? FileManager.default.removeItem(at: socketPath)
        let s = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        if s < 0 { throw IpcClient.IpcError.socketCreationFailed(errno) }
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        socketPath.path.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                let p = UnsafeMutableRawPointer(dst).assumingMemoryBound(to: CChar.self)
                let n = min(strlen(src), cap - 1); memcpy(p, src, n); p[n] = 0
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(s, $0, len) }
        }
        if rc != 0 { let e = errno; Darwin.close(s); throw IpcClient.IpcError.socketCreationFailed(e) }
        chmod(socketPath.path, 0o600)
        if Darwin.listen(s, 4) != 0 {
            let e = errno; Darwin.close(s); throw IpcClient.IpcError.socketCreationFailed(e)
        }
        lock.calibLock { listenFd = s }
        let captured = s
        let t = Thread { [weak self] in self?.acceptLoop(fd: captured) }
        t.name = "syncast.calibration.diag.accept"; t.qualityOfService = .utility; t.start()
        acceptThread = t
    }

    public func stop() {
        let s: Int32 = lock.calibLock { let f = listenFd; listenFd = -1; return f }
        // Closing the listener fd unblocks the accept thread (returns -1).
        if s >= 0 { Darwin.close(s) }
        acceptThread = nil
        try? FileManager.default.removeItem(at: socketPath)
    }

    // MARK: - Internals

    private func acceptLoop(fd: Int32) {
        while true {
            var ca = sockaddr_un()
            var cl = socklen_t(MemoryLayout<sockaddr_un>.size)
            let client: Int32 = withUnsafeMutablePointer(to: &ca) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.accept(fd, $0, &cl) }
            }
            if client < 0 {
                if errno == EBADF || errno == EINVAL { return }
                if errno == EINTR { continue }
                return
            }
            handleClient(client: client)
        }
    }

    private func handleClient(client: Int32) {
        defer { Darwin.close(client) }
        // 4 KiB cap is plenty for `calibrate` (no payload). EOF-terminated
        // requests (no trailing \n) are also accepted.
        var buf = Data()
        var tmp = [UInt8](repeating: 0, count: 1024)
        while buf.count < 4096 {
            let n = tmp.withUnsafeMutableBytes { raw -> Int in
                guard let p = raw.baseAddress else { return -1 }
                return Darwin.read(client, p, raw.count)
            }
            if n <= 0 { break }
            buf.append(tmp, count: n)
            if buf.contains(0x0a) { break }
        }
        let line: Data
        if let nl = buf.firstIndex(of: 0x0a) { line = buf.subdata(in: 0..<nl) }
        else if buf.isEmpty { return }
        else { line = buf }
        var rid: Any = NSNull()
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            sendError(client: client, id: rid, code: -32700, message: "parse error"); return
        }
        if let id = obj["id"] { rid = id }
        guard let method = obj["method"] as? String else {
            sendError(client: client, id: rid, code: -32600, message: "missing method"); return
        }
        switch method {
        case "calibrate": handleCalibrate(client: client, id: rid)
        case "ping":      sendResult(client: client, id: rid, result: ["ok": true])
        default:          sendError(client: client, id: rid, code: -32601,
                                    message: "method not found: \(method)")
        }
    }

    private func handleCalibrate(client: Int32, id: Any) {
        // Single-flight: reject concurrent runs (-32002) instead of letting
        // two click-injection loops race the live ring + mic AUHAL.
        let claimed: Bool = lock.calibLock {
            if inProgress { return false }
            inProgress = true; return true
        }
        if !claimed {
            sendError(client: client, id: id, code: -32002,
                      message: "calibration already in progress"); return
        }
        // Box result so the @Sendable Task closure can mutate by reference.
        final class Box: @unchecked Sendable {
            var success: [String: Any]?
            var error: (Int, String)?
        }
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        Task.detached { [provider, runner] in
            defer { sem.signal() }
            guard let snap = await provider() else {
                box.error = (-32001, "router not in whole-home + running state"); return
            }
            do {
                let r = try await runner(snap)
                box.success = [
                    "deltaMs": r.deltaMs,
                    "confidence": r.confidence,
                    "perDeviceOffsetMs": r.perDeviceOffsetMs,
                ]
            } catch { box.error = (-32000, "\(error)") }
        }
        // Block this connection thread (NOT the listener) until done.
        // Calibration takes ~5-30s; netcat client uses -w 60 to match.
        sem.wait()
        lock.calibLock { inProgress = false }
        if let err = box.error {
            sendError(client: client, id: id, code: err.0, message: err.1)
        } else if let ok = box.success {
            sendResult(client: client, id: id, result: ok)
        } else {
            sendError(client: client, id: id, code: -32000, message: "no result")
        }
    }

    private func sendResult(client: Int32, id: Any, result: [String: Any]) {
        var p: [String: Any] = ["jsonrpc": "2.0", "result": result]
        p["id"] = id is NSNull ? NSNull() : id
        writeFrame(client: client, payload: p)
    }
    private func sendError(client: Int32, id: Any, code: Int, message: String) {
        var p: [String: Any] = ["jsonrpc": "2.0",
                                "error": ["code": code, "message": message]]
        p["id"] = id is NSNull ? NSNull() : id
        writeFrame(client: client, payload: p)
    }
    private func writeFrame(client: Int32, payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []) else { return }
        var f = Data(); f.append(data); f.append(0x0a)
        f.withUnsafeBytes { raw in
            var ptr = raw.baseAddress!; var rem = raw.count
            while rem > 0 {
                let n = Darwin.write(client, ptr, rem)
                if n < 0 { if errno == EINTR { continue }; return }
                ptr = ptr.advanced(by: n); rem -= n
            }
        }
    }
}

private extension NSLock {
    // Distinct name from AudioSocketWriter's withLock — both are file-private.
    func calibLock<T>(_ body: () -> T) -> T {
        self.lock(); defer { self.unlock() }
        return body()
    }
}
