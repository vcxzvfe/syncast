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
        /// Every audio packet, with the monotonic time it landed. The arrival
        /// stamp is what lets a test measure the LEAD — `play_at_ns` minus
        /// arrival — which is the sender-side proxy for the receiver's jitter
        /// buffer level: a link that puts more audio on the wire than the ring
        /// produces shows up here as a lead that grows without bound.
        var packets: [(header: LanAudioPacketHeader, payload: Data, arrivalNs: UInt64)] = []
        var rejectedPackets: Int = 0
    }

    /// How the fake behaves once a sender connects.
    enum Behaviour {
        /// Speak the protocol: check the token, answer `hello_ack` and `ping`.
        case normal
        /// Accept the TCP connection and then say nothing at all.
        ///
        /// This is the shape of the real-hardware failure this fake exists to
        /// reproduce: the second Mac's Application Firewall let the kernel
        /// finish the handshake and then dropped the connection before the
        /// daemon ever saw it, so the sender's connect "succeeded" and the
        /// link sat waiting for a `hello_ack` that could not come.
        case silent
    }

    /// The token this receiver will accept. Anything else gets an `error` and
    /// a closed connection, like the real daemon.
    let expectedToken: String
    let behaviour: Behaviour
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

    init(expectedToken: String = "cafef00d", behaviour: Behaviour = .normal) {
        self.expectedToken = expectedToken
        self.behaviour = behaviour
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
        // A silent receiver still RECORDS what it was sent — the tests assert
        // the sender got as far as `hello` — but answers nothing.
        if behaviour == .silent {
            if type == "hello" {
                mutate {
                    $0.helloToken = json["token"] as? String
                    $0.helloStreamID = (json["stream_id"] as? NSNumber)?.uint32Value
                }
            }
            return
        }
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
                    let arrival = Clock.nowNs()
                    self.mutate {
                        $0.packets.append((parsed.header, parsed.payload, arrival))
                    }
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
/// # Two delivery shapes
///
/// `.smooth` writes whatever has become due on every tick, which is a
/// convenient fiction: no capture backend delivers a handful of frames every
/// two milliseconds.
///
/// `.bursty` writes whole 512-frame blocks — 10.67 ms of audio, what a
/// CoreAudio IOProc actually hands over — and holds each one for a random 0…4
/// ms before releasing it, so the write cursor stands still for milliseconds
/// at a time and then jumps. That is the shape that made the old sender
/// synthesise silence packets: a 5 ms producer tick against a 10.67 ms block
/// finds nothing new roughly every second wake.
///
/// # Frames, time, and the two clocks
///
/// The frame count is computed from ELAPSED TIME rather than accumulated per
/// tick, so timer jitter moves the size or the moment of a write but never
/// the ring's average rate.
///
/// The capture ANCHOR is separate from all of that: a block's anchor carries
/// the host time of its first frame taken from the (here, perfect) device
/// clock, not the moment the writer happened to be scheduled. That
/// distinction is the point of the whole timeline — the release jitter above
/// must never reach `play_at_ns`.
///
/// `pause()` freezes the ring where it is, exactly as a capture backend that
/// stops delivering does; `resume()` starts a new epoch, so the frames after
/// the gap carry the host times they are really captured at rather than
/// pretending the missing seconds were recorded.
final class SyntheticRingProducer: @unchecked Sendable {

    enum Mode {
        /// Write everything due on every tick.
        case smooth
        /// Write whole 512-frame blocks, each held for a random 0…4 ms.
        case bursty
    }

    /// What a CoreAudio IOProc hands over in one go at 48 kHz: 10.67 ms.
    static let blockFrames: Int = 512
    /// Ceiling on the random hold applied to a block in `.bursty`, in
    /// nanoseconds. Re-drawn per block, so it jitters the arrival of each
    /// block by ±2 ms about its 2 ms mean without accumulating.
    static let burstJitterSpanNs: Double = 4_000_000

    let ring: RingBuffer
    let anchors: CaptureAnchorPublisher
    private let mode: Mode
    private let sampleRate: Double
    private let queue = DispatchQueue(label: "test.synthetic.ring", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    /// Start of the current epoch, and the ring frame it began at. A pause
    /// ends one epoch; a resume opens the next.
    private var epochNs: UInt64 = 0
    private var epochFrame: Int64 = 0
    private var written: Int64 = 0
    private var phase: Double = 0
    private var holdNs: Double = 0
    private var random = SystemRandomNumberGenerator()

    init(mode: Mode = .smooth, sampleRate: Double = 48_000, capacityFrames: Int = 1 << 18) {
        self.mode = mode
        self.sampleRate = sampleRate
        self.ring = RingBuffer(channelCount: 2, capacityFrames: capacityFrames)
        self.anchors = CaptureAnchorPublisher(sampleRate: sampleRate)
    }

    func start() {
        queue.sync {
            epochNs = Clock.nowNs()
            epochFrame = written
            holdNs = 0
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let period: DispatchTimeInterval = mode == .bursty
            ? .milliseconds(1) : .milliseconds(2)
        timer.schedule(deadline: .now(), repeating: period, leeway: .microseconds(200))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Freeze the ring where it is. The write cursor stops moving and no
    /// further anchors are published — what a capture backend that stops
    /// delivering looks like from the ring's side.
    func pause() { stop() }

    /// Start writing again, in a new epoch. Frames after the gap carry the
    /// host times they are captured at; the silence in between was never
    /// recorded and is never written.
    func resume() { start() }

    /// Host time this producer's clock assigns to a ring frame. The test uses
    /// it to say what `play_at_ns` should have been.
    func hostNs(forFrame frame: Int64) -> UInt64 {
        queue.sync {
            epochNs &+ UInt64((Double(frame - epochFrame) / sampleRate * 1_000_000_000).rounded())
        }
    }

    private func tick() {
        let now = Clock.nowNs()
        let elapsed = Double(now &- epochNs)
        switch mode {
        case .smooth:
            let target = epochFrame + Int64((elapsed / 1_000_000_000 * sampleRate).rounded())
            let toWrite = min(Int(target - written), 4_096)
            guard toWrite > 0 else { return }
            writeBlock(frames: toWrite)
        case .bursty:
            // A block is released once its whole 10.67 ms has elapsed AND the
            // random hold drawn for it has passed.
            while true {
                let releasable = epochFrame
                    + Int64(max(0, elapsed - holdNs) / 1_000_000_000 * sampleRate)
                guard written + Int64(Self.blockFrames) <= releasable else { return }
                writeBlock(frames: Self.blockFrames)
                holdNs = Double.random(in: 0...Self.burstJitterSpanNs, using: &random)
            }
        }
    }

    /// Write `frames` of a 440 Hz tone and publish the block's anchor.
    private func writeBlock(frames: Int) {
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        let step = 2 * Double.pi * 440 / sampleRate
        for index in 0..<frames {
            // Never exactly zero: a test that asserts the link sent no silent
            // packets needs the ring itself to be unambiguously non-silent.
            left[index] = Float(sin(phase) * 0.25 + 0.05)
            right[index] = Float(sin(phase) * -0.25 - 0.05)
            phase += step
            if phase > 2 * Double.pi { phase -= 2 * Double.pi }
        }
        let startFrame = written
        left.withUnsafeBufferPointer { l in
            right.withUnsafeBufferPointer { r in
                let table = UnsafeMutablePointer<UnsafePointer<Float>>.allocate(capacity: 2)
                defer { table.deallocate() }
                table[0] = l.baseAddress!
                table[1] = r.baseAddress!
                ring.write(channels: table, frames: frames)
            }
        }
        written = startFrame + Int64(frames)
        // The block began at the device's own time for its first frame, not
        // at the moment this writer was scheduled.
        anchors.publish(
            frame: startFrame,
            hostNs: epochNs &+ UInt64(
                (Double(startFrame - epochFrame) / sampleRate * 1_000_000_000).rounded()
            )
        )
    }
}
