import Foundation
import Network
@testable import SyncCastRouter

/// A minimal in-process stand-in for the receiver daemon, on loopback.
///
/// It speaks exactly as much of the protocol as the SENDER needs to be
/// exercised end to end — accept the control connection, check the token,
/// answer `hello_ack`, answer `ping`, collect the UDP audio — and nothing
/// more. It is deliberately NOT a second implementation of the receiver: it
/// has no jitter buffer, no resampler and no DAC, because the thing under test
/// is what leaves this machine.
///
/// Everything is confined to `queue`; the accessors take `lock` so the test
/// body can read from the main thread while packets are arriving.
final class FakeLanReceiver: @unchecked Sendable {

    struct Observed {
        var helloToken: String?
        var helloStreamID: UInt32?
        var gains: [(linear: Double, muted: Bool)] = []
        var targets: [Int] = []
        var pings: Int = 0
        var sawBye = false
        var packets: [(header: LanAudioPacketHeader, payload: Data)] = []
        var rejectedPackets: Int = 0
    }

    /// The token this receiver will accept. Anything else gets an `error` and
    /// a closed connection, like the real daemon.
    let expectedToken: String
    private(set) var controlPort: UInt16 = 0
    private(set) var audioPort: UInt16 = 0

    private let queue = DispatchQueue(label: "test.fake.lan.receiver")
    private let lock = NSLock()
    private var observed = Observed()
    private var controlListener: NWListener?
    private var audioListener: NWListener?
    private var controlConnections: [NWConnection] = []
    private var audioConnections: [NWConnection] = []
    private var controlBuffer = Data()

    init(expectedToken: String = "cafef00d") {
        self.expectedToken = expectedToken
    }

    // MARK: - Lifecycle

    func start() throws {
        let audio = try NWListener(using: .udp, on: .any)
        audio.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.audioConnections.append(connection)
            connection.stateUpdateHandler = { _ in }
            connection.start(queue: self.queue)
            self.receiveAudio(on: connection)
        }
        audio.start(queue: queue)
        audioListener = audio

        let control = try NWListener(using: .tcp, on: .any)
        control.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.controlConnections.append(connection)
            connection.stateUpdateHandler = { _ in }
            connection.start(queue: self.queue)
            self.receiveControl(on: connection)
        }
        control.start(queue: queue)
        controlListener = control

        // Both listeners publish their port asynchronously; wait for them
        // rather than racing the sender's connect.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let controlPort = control.port?.rawValue,
               let audioPort = audio.port?.rawValue,
               controlPort != 0, audioPort != 0 {
                self.controlPort = controlPort
                self.audioPort = audioPort
                return
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw NSError(
            domain: "FakeLanReceiver", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "listeners never reported a port"]
        )
    }

    func stop() {
        controlListener?.cancel()
        audioListener?.cancel()
        for connection in controlConnections + audioConnections { connection.cancel() }
        controlListener = nil
        audioListener = nil
        controlConnections.removeAll()
        audioConnections.removeAll()
    }

    // MARK: - Observation

    var snapshot: Observed {
        lock.lock(); defer { lock.unlock() }
        return observed
    }

    private func mutate(_ body: (inout Observed) -> Void) {
        lock.lock()
        body(&observed)
        lock.unlock()
    }

    /// Block until `predicate` holds or the timeout expires.
    @discardableResult
    func wait(
        upTo seconds: TimeInterval,
        for predicate: @escaping (Observed) -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if predicate(snapshot) { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return predicate(snapshot)
    }

    // MARK: - Control channel

    private func receiveControl(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.controlBuffer.append(data)
                let split = LanControlCodec.split(buffer: self.controlBuffer)
                self.controlBuffer = split.remainder
                for line in split.lines where !line.isEmpty {
                    self.handleControl(line, on: connection)
                }
            }
            guard error == nil, !isComplete else { return }
            self.receiveControl(on: connection)
        }
    }

    private func handleControl(_ line: Data, on connection: NWConnection) {
        guard let object = try? JSONSerialization.jsonObject(with: line),
              let json = object as? [String: Any],
              let type = json["type"] as? String
        else { return }
        switch type {
        case "hello":
            let token = json["token"] as? String
            mutate {
                $0.helloToken = token
                $0.helloStreamID = (json["stream_id"] as? NSNumber)?.uint32Value
            }
            guard token == expectedToken else {
                send(
                    #"{"type":"error","message":"bad token"}"#,
                    on: connection
                )
                // Give the error line time to leave before closing, exactly as
                // the real daemon does: a close that races the write turns a
                // clear "bad token" into an opaque "connection closed".
                queue.asyncAfter(deadline: .now() + 0.2) { connection.cancel() }
                return
            }
            send(
                """
                {"type":"hello_ack","v":1,"udp_port":\(audioPort),\
                "device":"Test Output","device_uid":"test-uid",\
                "hw_volume":true,"buffer_ms":90}
                """,
                on: connection
            )
        case "gain":
            let linear = (json["linear"] as? NSNumber)?.doubleValue ?? -1
            let muted = json["muted"] as? Bool ?? false
            mutate { $0.gains.append((linear, muted)) }
        case "latency":
            let target = (json["target_ms"] as? NSNumber)?.intValue ?? -1
            mutate { $0.targets.append(target) }
        case "ping":
            let t1 = (json["t1"] as? NSNumber)?.uint64Value ?? 0
            let t2 = Clock.nowNs()
            mutate { $0.pings += 1 }
            send(
                #"{"type":"pong","t1":\#(t1),"t2":\#(t2),"t3":\#(Clock.nowNs())}"#,
                on: connection
            )
        case "bye":
            mutate { $0.sawBye = true }
        default:
            break
        }
    }

    private func send(_ line: String, on connection: NWConnection) {
        connection.send(content: Data((line + "\n").utf8), completion: .idempotent)
    }

    // MARK: - Audio

    private func receiveAudio(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data {
                if let parsed = LanAudioPacketHeader.decodePacket(data) {
                    self.mutate { $0.packets.append(parsed) }
                } else {
                    self.mutate { $0.rejectedPackets += 1 }
                }
            }
            guard error == nil else { return }
            self.receiveAudio(on: connection)
        }
    }
}

/// A capture ring driven at real-time 48 kHz by a timer, so a producer under
/// test sees the same frame-versus-wall-clock relationship a live tap gives.
///
/// The frame count is computed from ELAPSED TIME rather than accumulated per
/// tick, so timer jitter moves the size of a write but never the ring's
/// average rate — which is what lets the test assert exact packet spacing.
final class SyntheticRingProducer: @unchecked Sendable {
    let ring: RingBuffer
    private let sampleRate: Double
    private let queue = DispatchQueue(label: "test.synthetic.ring", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var startNs: UInt64 = 0
    private var written: Int64 = 0
    private var phase: Double = 0

    init(sampleRate: Double = 48_000, capacityFrames: Int = 1 << 18) {
        self.sampleRate = sampleRate
        self.ring = RingBuffer(channelCount: 2, capacityFrames: capacityFrames)
    }

    func start() {
        startNs = Clock.nowNs()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(2), leeway: .microseconds(200))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        let elapsed = Double(Clock.nowNs() - startNs) / 1_000_000_000
        let target = Int64((elapsed * sampleRate).rounded())
        var toWrite = Int(target - written)
        guard toWrite > 0 else { return }
        toWrite = min(toWrite, 4_096)
        var left = [Float](repeating: 0, count: toWrite)
        var right = [Float](repeating: 0, count: toWrite)
        // A 440 Hz tone, so a listener inspecting a capture hears something
        // recognisable and a decode check has non-trivial content.
        let step = 2 * Double.pi * 440 / sampleRate
        for index in 0..<toWrite {
            left[index] = Float(sin(phase) * 0.25)
            right[index] = Float(sin(phase) * -0.25)
            phase += step
            if phase > 2 * Double.pi { phase -= 2 * Double.pi }
        }
        left.withUnsafeBufferPointer { l in
            right.withUnsafeBufferPointer { r in
                let table = UnsafeMutablePointer<UnsafePointer<Float>>.allocate(capacity: 2)
                defer { table.deallocate() }
                table[0] = l.baseAddress!
                table[1] = r.baseAddress!
                ring.write(channels: table, frames: toWrite)
            }
        }
        written = target
    }
}
