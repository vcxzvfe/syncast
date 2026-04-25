import Foundation

/// Minimal JSON-RPC 2.0 client that talks to the Python sidecar over a Unix
/// domain socket. Newline-delimited frames; one in-flight request at a time
/// per id.
///
/// This client deliberately stays small. No reconnection logic, no audio
/// socket — both live in `SidecarManager` so the boundary is testable.
public actor IpcClient {
    public enum IpcError: Error {
        case socketCreationFailed(Int32)
        case socketConnectFailed(Int32)
        case writeFailed(Int32)
        case responseParseFailed
        case rpcError(code: Int, message: String)
    }

    private let socketPath: URL
    private var fd: Int32 = -1
    private var nextID: Int = 1
    private var pending: [Int: CheckedContinuation<Any, Error>] = [:]
    private var notificationHandler: (@Sendable (String, [String: Any]) -> Void)?
    /// Background thread doing blocking read(2). NOT an `actor`-bound Task —
    /// must run off-actor so it doesn't block IpcClient.call() from acquiring
    /// the actor.
    private var readerThread: Thread?

    public init(socketPath: URL) {
        self.socketPath = socketPath
    }

    public func connect(notificationHandler: @escaping @Sendable (String, [String: Any]) -> Void) async throws {
        self.notificationHandler = notificationHandler
        let s = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        if s < 0 { throw IpcError.socketCreationFailed(errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = socketPath.path
        let pathCapacity = MemoryLayout.size(ofValue: addr.sun_path)
        path.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                let dstPtr = UnsafeMutableRawPointer(dst).assumingMemoryBound(to: CChar.self)
                let count = min(strlen(src), pathCapacity - 1)
                memcpy(dstPtr, src, count)
                dstPtr[count] = 0
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connectRC = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(s, $0, len)
            }
        }
        if connectRC != 0 {
            let e = errno
            Darwin.close(s)
            throw IpcError.socketConnectFailed(e)
        }
        self.fd = s
        // Spawn a real POSIX thread (not a Swift Task) so the blocking
        // read(2) doesn't sit on the actor's serial executor and deadlock
        // .call() waiters. We capture the fd by value — close() invalidates
        // it via Darwin.close, after which read() returns EBADF/0 and the
        // loop terminates.
        let capturedFd = s
        let thread = Thread { [weak self] in
            IpcClient.readLoopOnThread(fd: capturedFd) { line in
                guard let self else { return }
                Task { await self.dispatchLine(line) }
            }
        }
        thread.name = "syncast.ipc.reader"
        thread.qualityOfService = .utility
        thread.start()
        self.readerThread = thread
    }

    public func close() {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
        readerThread = nil
    }

    @discardableResult
    public func call(_ method: String, params: [String: Any] = [:]) async throws -> Any {
        let id = nextID; nextID += 1
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        var line = Data(); line.append(data); line.append(0x0a)
        // Send the bytes BEFORE installing the continuation. If the write
        // fails we throw without leaving a dangling pending entry, and the
        // continuation only suspends on the response — it never owns the
        // blocking write.
        try writeAll(line)
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Any, Error>) in
            self.pending[id] = cont
        }
    }

    private func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var ptr = raw.baseAddress!
            var remaining = raw.count
            while remaining > 0 {
                let n = Darwin.write(fd, ptr, remaining)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw IpcError.writeFailed(errno)
                }
                ptr = ptr.advanced(by: n)
                remaining -= n
            }
        }
    }

    /// Runs on the dedicated `readerThread`. The fd is captured by value at
    /// thread spawn time; when the actor closes the socket, read returns 0
    /// or -1 EBADF and the loop exits cleanly.
    private static func readLoopOnThread(
        fd: Int32,
        onLine: @escaping (Data) -> Void
    ) {
        var buffer = Data()
        let chunkSize = 4096
        var tmp = [UInt8](repeating: 0, count: chunkSize)
        while true {
            let n = tmp.withUnsafeMutableBytes { rawPtr -> Int in
                guard let p = rawPtr.baseAddress else { return -1 }
                return Darwin.read(fd, p, chunkSize)
            }
            if n <= 0 { break }
            buffer.append(tmp, count: n)
            while let nlIdx = buffer.firstIndex(of: 0x0a) {
                let line = buffer.subdata(in: 0..<nlIdx)
                buffer.removeSubrange(0...nlIdx)
                onLine(line)
            }
        }
    }

    fileprivate func dispatchLine(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let method = obj["method"] as? String {
            let params = (obj["params"] as? [String: Any]) ?? [:]
            notificationHandler?(method, params)
            return
        }
        guard let id = obj["id"] as? Int, let cont = pending.removeValue(forKey: id) else { return }
        if let err = obj["error"] as? [String: Any] {
            let code = (err["code"] as? Int) ?? -1
            let msg = (err["message"] as? String) ?? "rpc error"
            cont.resume(throwing: IpcError.rpcError(code: code, message: msg))
        } else {
            cont.resume(returning: obj["result"] ?? NSNull())
        }
    }
}

