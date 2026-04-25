import Foundation
import Darwin

/// Writes PCM packets from the ring buffer to the sidecar audio socket
/// (SOCK_SEQPACKET, see `proto/ipc-schema.md`).
///
/// Pulls 480-frame packets at 48 kHz stereo (≈10 ms each), converts the ring
/// buffer's planar Float32 to interleaved 16-bit little-endian, and writes
/// each packet as one SEQPACKET datagram.
///
/// Runs on a dedicated background task; never on a real-time thread.
public final class AudioSocketWriter: @unchecked Sendable {
    public let socketPath: URL
    public let frameCount = 480
    public let channelCount = 2

    private let ring: RingBuffer
    private var fd: Int32 = -1
    private var task: Task<Void, Never>?
    private let lock = NSLock()
    /// Diagnostic — packets actually sent through the socket.
    public private(set) var packetsSent: UInt64 = 0
    public private(set) var bytesSent: UInt64 = 0
    public private(set) var lastSendError: String = ""

    public init(ring: RingBuffer, socketPath: URL) {
        self.ring = ring
        self.socketPath = socketPath
    }

    public func start() throws {
        // Idempotent: if we already have a running writer task with an
        // open fd, do nothing. Calling start() twice (from successive
        // pushAirplayState invocations) used to stomp the previous fd
        // and kill the original task — which manifested as "AudioSocket
        // sent 68 packets then stopped forever".
        let existingFd = lock.withLock { fd }
        if existingFd >= 0, let t = task, !t.isCancelled {
            return
        }
        try connect()
        task = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.runLoop()
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        lock.lock(); defer { lock.unlock() }
        if fd >= 0 { Darwin.close(fd); fd = -1 }
    }

    private func connect() throws {
        // macOS Unix sockets don't support SOCK_SEQPACKET (returns
        // EPROTONOSUPPORT). Use SOCK_STREAM. The wire format is naturally
        // framed because both sender and receiver always operate on
        // exactly one packet per send/recv (bytesPerPacket = 1920 bytes
        // = 480 frames × 2 channels × 2 bytes).
        let s = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        if s < 0 { throw IpcClient.IpcError.socketCreationFailed(errno) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        socketPath.path.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                let dstPtr = UnsafeMutableRawPointer(dst).assumingMemoryBound(to: CChar.self)
                let n = min(strlen(src), cap - 1)
                memcpy(dstPtr, src, n)
                dstPtr[n] = 0
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(s, $0, len)
            }
        }
        if rc != 0 {
            let e = errno
            Darwin.close(s)
            throw IpcClient.IpcError.socketConnectFailed(e)
        }
        lock.lock(); defer { lock.unlock() }
        fd = s
    }

    private func runLoop() async {
        let bytesPerPacket = frameCount * channelCount * MemoryLayout<Int16>.size
        var packet = [Int16](repeating: 0, count: frameCount * channelCount)
        var planar = [[Float]](
            repeating: [Float](repeating: 0, count: frameCount),
            count: channelCount
        )
        var nextRead: Int64 = -1
        while !Task.isCancelled {
            let writePos = ring.writePosition
            if nextRead < 0 { nextRead = max(0, writePos - Int64(frameCount)) }
            if writePos - nextRead < Int64(frameCount) {
                try? await Task.sleep(nanoseconds: 5_000_000)  // 5 ms
                continue
            }
            // Read from ring into planar Float32, convert to interleaved Int16.
            let outPtrs = planar.indices.map { i in
                planar[i].withUnsafeMutableBufferPointer { $0.baseAddress! }
            }
            ring.read(at: nextRead, frames: frameCount, into: outPtrs)
            for f in 0..<frameCount {
                for ch in 0..<channelCount {
                    let v = planar[ch][f]
                    let clamped = max(-1.0, min(1.0, v))
                    packet[f * channelCount + ch] = Int16(clamped * 32_767.0)
                }
            }
            nextRead &+= Int64(frameCount)
            // Send one SEQPACKET datagram.
            let sent = packet.withUnsafeBytes { raw -> Int in
                let s = lock.withLock { fd }
                guard s >= 0 else { return -1 }
                return Darwin.send(s, raw.baseAddress, bytesPerPacket, 0)
            }
            if sent < 0 {
                let e = errno
                lastSendError = "send errno=\(e)"
                if e == EINTR { continue }
                break
            }
            packetsSent &+= 1
            bytesSent &+= UInt64(sent)
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        self.lock(); defer { self.unlock() }
        return body()
    }
}
