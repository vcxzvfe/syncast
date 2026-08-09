import XCTest
import Darwin
@testable import SyncCastRouter

/// `IpcClient.call` suspends on a continuation that only a matching response
/// resumes. Callers bound it by racing it against a sleeping task inside a
/// task group — and a task group must await EVERY child before it can return.
/// So a continuation that ignores cancellation does not merely make the
/// timeout late, it makes it unreachable: the group blocks forever on the
/// child it just told to stop.
///
/// These tests drive the real client against a real Unix socket, because the
/// bug lives in the interaction between structured concurrency and the
/// continuation, not in any logic that can be stubbed.
final class IpcClientCancellationTests: XCTestCase {

    func testCallHonoursCancellationWhenTheHelperNeverAnswers() async throws {
        let server = try SilentUnixSocketServer()
        defer { server.stop() }

        let client = IpcClient(socketPath: server.url)
        try await client.connect(notificationHandler: { _, _ in })
        defer { Task { await client.close() } }

        let started = Date()
        do {
            _ = try await withThrowingTaskGroup(of: Any.self) { group in
                group.addTask { try await client.call("never.answers") }
                group.addTask {
                    try await Task.sleep(nanoseconds: 300_000_000)
                    throw TimedOut()
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else { throw TimedOut() }
                return first
            }
            XCTFail("expected the timeout to win")
        } catch {
            // Any error is fine; what matters is that we got one at all.
        }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(
            elapsed, 5,
            "the task group could not return, so the timeout never took effect"
        )
    }

    /// The reader thread exiting on EOF means no response can ever arrive.
    /// Anything still in flight has to be failed, or its caller stays
    /// suspended for the life of the process.
    func testPendingCallsFailWhenTheConnectionDrops() async throws {
        let server = try SilentUnixSocketServer()
        let client = IpcClient(socketPath: server.url)
        try await client.connect(notificationHandler: { _, _ in })
        defer { Task { await client.close() } }

        let call = Task { try await client.call("dropped.midflight") }
        // Give the write time to land before pulling the socket out.
        try await Task.sleep(nanoseconds: 200_000_000)
        server.stop()

        let outcome = await call.result
        switch outcome {
        case .success:
            XCTFail("a dropped connection must not look like a successful call")
        case .failure:
            break
        }
    }

    private struct TimedOut: Error {}
}

/// Accepts one connection, reads whatever arrives, and deliberately never
/// replies — the shape of a wedged or dead sidecar.
private final class SilentUnixSocketServer: @unchecked Sendable {
    let url: URL
    private let listenFD: Int32
    private var acceptedFD: Int32 = -1
    private let thread: Thread

    init() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("syncast-ipc-test-\(UUID().uuidString.prefix(8)).sock")
        self.url = path
        unlink(path.path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: "sock", code: Int(errno)) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        path.path.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                let raw = UnsafeMutableRawPointer(dst).assumingMemoryBound(to: CChar.self)
                let count = min(strlen(src), capacity - 1)
                memcpy(raw, src, count)
                raw[count] = 0
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard bound == 0, listen(fd, 1) == 0 else {
            Darwin.close(fd)
            throw NSError(domain: "bind", code: Int(errno))
        }
        self.listenFD = fd

        let box = Box()
        self.thread = Thread {
            let accepted = accept(fd, nil, nil)
            box.fd = accepted
            guard accepted >= 0 else { return }
            var scratch = [UInt8](repeating: 0, count: 1024)
            while true {
                let n = scratch.withUnsafeMutableBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return -1 }
                    return read(accepted, base, 1024)
                }
                if n <= 0 { break }
                // Read and discard. Never answer.
            }
        }
        self.box = box
        thread.start()
    }

    private let box: Box
    private final class Box: @unchecked Sendable { var fd: Int32 = -1 }

    func stop() {
        if box.fd >= 0 { Darwin.close(box.fd); box.fd = -1 }
        if listenFD >= 0 { Darwin.close(listenFD) }
        unlink(url.path)
    }
}
