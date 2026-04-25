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
    private var readerTask: Task<Void, Never>?

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
        self.readerTask = Task { [weak self] in await self?.readLoop() }
    }

    public func close() {
        readerTask?.cancel()
        readerTask = nil
        if fd >= 0 { Darwin.close(fd); fd = -1 }
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
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Any, Error>) in
            self.pending[id] = cont
            do {
                try writeAll(line)
            } catch {
                self.pending.removeValue(forKey: id)
                cont.resume(throwing: error)
            }
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

    private func readLoop() async {
        var buffer = Data()
        let chunkSize = 4096
        var tmp = [UInt8](repeating: 0, count: chunkSize)
        while !Task.isCancelled, fd >= 0 {
            let n = tmp.withUnsafeMutableBytes { rawPtr -> Int in
                let p = rawPtr.baseAddress!
                return Darwin.read(fd, p, chunkSize)
            }
            if n <= 0 { break }
            buffer.append(tmp, count: n)
            while let nlIdx = buffer.firstIndex(of: 0x0a) {
                let line = buffer.subdata(in: 0..<nlIdx)
                buffer.removeSubrange(0...nlIdx)
                handleLine(line)
            }
        }
    }

    private func handleLine(_ data: Data) {
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
