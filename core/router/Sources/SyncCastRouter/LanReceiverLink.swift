import Foundation
import Network

/// Where a receiver lives.
public enum LanReceiverEndpoint: Sendable, Equatable {
    /// Resolved by Bonjour at connect time. What discovery produces, and the
    /// only form used in production: a receiver's IP moves with DHCP, its
    /// instance name does not.
    case bonjour(name: String, domain: String?)
    /// A literal address. Used by the tests' in-process fake receiver, and
    /// available as an escape hatch if mDNS is blocked on a network.
    case hostPort(host: String, port: UInt16)
}

/// Everything the UI and the diagnostics line want to know about one link.
public struct LanLinkSnapshot: Sendable, Equatable {
    public var isConnected: Bool = false
    public var isAudioReady: Bool = false
    /// Last failure, cleared on a successful connect. Non-nil while the link
    /// is retrying, which is what lets the row say WHY rather than just
    /// spinning.
    public var lastError: String?
    /// Output device the receiver reports playing on.
    public var deviceName: String?
    /// Whether the receiver carries our master level in hardware.
    public var hasHardwareVolume: Bool?
    /// Receiver's own jitter-buffer depth from `hello_ack`.
    public var receiverBufferMs: Int?
    public var roundTripMs: Double?
    /// Receiver clock minus sender clock. Signed, and expected to be large —
    /// two machines' `mach_absolute_time` epochs are unrelated.
    public var offsetMs: Double?
    public var stats: LanReceiverStats?
    public var packetsSent: UInt64 = 0
    public var reconnectCount: Int = 0

    public init() {}
}

/// The TCP control channel and the UDP audio socket for one receiver.
///
/// Owns nothing about audio: `LanReceiverOutput` produces packets and hands
/// them here. Everything is confined to `queue` except `sendAudio`, which is
/// called from the producer timer and goes straight into `NWConnection.send`
/// (thread-safe by contract) with an idempotent completion so it never
/// allocates a continuation per packet.
///
/// # Failure policy
///
/// A dead receiver must never stall the local outputs. Nothing here blocks:
/// the connect is asynchronous, the sends are fire-and-forget, and a failure
/// schedules a retry on `queue` with exponential backoff rather than
/// propagating. The producer keeps running and keeps dropping its packets into
/// a socket that is not ready, which is exactly what a UDP leg should do.
public final class LanReceiverLink: @unchecked Sendable {

    /// Keep-alive / round-trip probe interval. The receiver stops and mutes
    /// after 5 s without one, so this has four chances to arrive.
    public static let pingIntervalSeconds: Double = 1.0
    /// Reconnect backoff, in seconds. Capped rather than unbounded: a receiver
    /// that has been off all evening should come back within seconds of being
    /// switched on, not after a five-minute wait.
    public static let reconnectBackoffSeconds: [Double] = [0.5, 1, 2, 4, 8]
    /// Ceiling on the control-channel read buffer. `LanControlCodec` enforces
    /// the same number per line; this is the accumulation guard for a peer
    /// that never sends a newline at all.
    public static let maximumControlBufferBytes = LanControlCodec.maximumLineBytes

    public let receiverUID: String
    private let endpoint: LanReceiverEndpoint
    private let token: String
    private let senderName: String
    let streamID: UInt32

    private let queue: DispatchQueue
    private let stateLock = NSLock()

    private var control: NWConnection?
    private var audio: NWConnection?
    private var pingTimer: DispatchSourceTimer?
    private var reconnectTimer: DispatchSourceTimer?
    private var controlBuffer = Data()
    private var running = false
    private var attempt = 0
    private var offsetEstimator = LanClockOffsetEstimator()
    private var resolvedHost: NWEndpoint.Host?

    // Published state, read from other threads under `stateLock`.
    private var _snapshot = LanLinkSnapshot()
    private var _targetMs: Int
    private var _gain: (linear: Double, muted: Bool) = (1, false)
    private var _sentGain: (linear: Double, muted: Bool)?
    private var _sentTargetMs: Int?

    public init(
        receiverUID: String,
        endpoint: LanReceiverEndpoint,
        token: String,
        senderName: String,
        streamID: UInt32,
        targetMs: Int
    ) {
        self.receiverUID = receiverUID
        self.endpoint = endpoint
        self.token = token
        self.senderName = senderName
        self.streamID = streamID
        self._targetMs = LanPcmWire.clampTargetMs(targetMs)
        // The label carries the UID rather than the friendly name so a crash
        // report identifies the link without printing a device name.
        self.queue = DispatchQueue(label: "io.syncast.lan.link")
    }

    deinit {
        // Direct, synchronous teardown rather than `stop()`. `stop()` hops
        // onto `queue`, and a closure capturing `self` from inside `deinit`
        // resurrects the object after its refcount reached zero — which the
        // runtime traps on ("deallocated with non-zero retain count"). Nothing
        // can be racing us here: a pending block on `queue` would itself hold
        // a reference, so `deinit` could not have been reached.
        running = false
        pingTimer?.cancel()
        reconnectTimer?.cancel()
        control?.cancel()
        audio?.cancel()
    }

    // MARK: - Published state

    public var snapshot: LanLinkSnapshot {
        stateLock.lock(); defer { stateLock.unlock() }
        return _snapshot
    }

    /// True once `hello_ack` has arrived and the UDP socket is ready. The
    /// producer checks this before packetising, so a link that is still
    /// connecting costs no DSP work.
    public var isAudioReady: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _snapshot.isAudioReady
    }

    public var targetMs: Int {
        stateLock.lock(); defer { stateLock.unlock() }
        return _targetMs
    }

    private func mutateSnapshot(_ body: (inout LanLinkSnapshot) -> Void) {
        stateLock.lock()
        body(&_snapshot)
        stateLock.unlock()
    }

    // MARK: - Lifecycle

    public func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            attempt = 0
            connect()
        }
    }

    public func stop() {
        queue.async { [self] in
            guard running else { return }
            running = false
            mutateSnapshot {
                $0.isConnected = false
                $0.isAudioReady = false
            }
            guard let control, control.state == .ready,
                  let bye = try? LanControlCodec.encode(.bye)
            else {
                teardown()
                return
            }
            // `bye` is the one message worth waiting for: it is what stops the
            // receiver playing immediately instead of after its 5 s keep-alive
            // timeout. Cancelling the connection right after an `.idempotent`
            // send would routinely discard it, so this send tears down from
            // its own completion.
            control.send(
                content: bye,
                completion: .contentProcessed { [weak self] _ in
                    self?.queue.async { self?.teardown() }
                }
            )
        }
    }

    private func teardown() {
        pingTimer?.cancel(); pingTimer = nil
        reconnectTimer?.cancel(); reconnectTimer = nil
        control?.cancel(); control = nil
        audio?.cancel(); audio = nil
        controlBuffer.removeAll(keepingCapacity: false)
        resolvedHost = nil
        stateLock.lock()
        _sentGain = nil
        _sentTargetMs = nil
        stateLock.unlock()
    }

    private func connect() {
        let nwEndpoint: NWEndpoint
        switch endpoint {
        case .bonjour(let name, let domain):
            nwEndpoint = .service(
                name: name,
                type: LanPcmWire.bonjourServiceType,
                domain: domain ?? "local.",
                interface: nil
            )
        case .hostPort(let host, let port):
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                fail("invalid port \(port)")
                return
            }
            nwEndpoint = .hostPort(host: NWEndpoint.Host(host), port: nwPort)
        }
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        let connection = NWConnection(to: nwEndpoint, using: parameters)
        control = connection
        connection.stateUpdateHandler = { [weak self] state in
            self?.handleControlState(state, connection: connection)
        }
        connection.start(queue: queue)
    }

    private func handleControlState(_ state: NWConnection.State, connection: NWConnection) {
        guard running, connection === control else { return }
        switch state {
        case .ready:
            guard let host = Self.resolvedHost(of: connection) else {
                fail("could not resolve the receiver's address")
                return
            }
            guard Self.isPrivatePeer(host) else {
                // LAN only, by design. A receiver that resolves to a routable
                // address is either a misconfiguration or someone else's
                // machine, and the link carries unencrypted PCM.
                fail("receiver is not on a private network; refusing to send")
                return
            }
            resolvedHost = host
            attempt = 0
            mutateSnapshot {
                $0.isConnected = true
                $0.lastError = nil
            }
            sendControl(.hello(token: token, senderName: senderName, streamID: streamID))
            receiveControl()
            startPingTimer()
        case .failed(let error):
            fail("control channel failed: \(error.localizedDescription)")
        case .cancelled:
            break
        case .waiting(let error):
            // `waiting` is Network framework retrying on its own (host down,
            // no route). Reported so the row can say why, but not treated as a
            // failure — cancelling here would fight its retry.
            mutateSnapshot { $0.lastError = "waiting: \(error.localizedDescription)" }
        default:
            break
        }
    }

    private func fail(_ message: String) {
        mutateSnapshot {
            $0.isConnected = false
            $0.isAudioReady = false
            $0.lastError = message
        }
        RouterLog.write("[LAN] \(receiverUID.prefix(24)): \(message)\n")
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard running else { return }
        teardownForRetry()
        let index = min(attempt, Self.reconnectBackoffSeconds.count - 1)
        let delay = Self.reconnectBackoffSeconds[index]
        attempt += 1
        mutateSnapshot { $0.reconnectCount += 1 }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            guard let self, self.running else { return }
            self.reconnectTimer = nil
            self.connect()
        }
        reconnectTimer?.cancel()
        reconnectTimer = timer
        timer.resume()
    }

    /// Drop the sockets but keep `running` and the retry timer alive.
    private func teardownForRetry() {
        pingTimer?.cancel(); pingTimer = nil
        control?.cancel(); control = nil
        audio?.cancel(); audio = nil
        controlBuffer.removeAll(keepingCapacity: false)
        resolvedHost = nil
        stateLock.lock()
        _sentGain = nil
        _sentTargetMs = nil
        _snapshot.isAudioReady = false
        stateLock.unlock()
    }

    // MARK: - Control channel

    private func sendControl(_ message: LanOutboundMessage) {
        guard let control, control.state == .ready else { return }
        guard let data = try? LanControlCodec.encode(message) else {
            RouterLog.write("[LAN] \(receiverUID.prefix(24)): could not encode \(message.typeName)\n")
            return
        }
        control.send(content: data, completion: .idempotent)
    }

    private func receiveControl() {
        guard let control else { return }
        control.receive(minimumIncompleteLength: 1, maximumLength: 8 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self, self.running else { return }
            if let data, !data.isEmpty {
                self.ingestControl(data)
            }
            if let error {
                self.fail("control read failed: \(error.localizedDescription)")
                return
            }
            if isComplete {
                self.fail("receiver closed the control channel")
                return
            }
            self.receiveControl()
        }
    }

    private func ingestControl(_ data: Data) {
        controlBuffer.append(data)
        guard controlBuffer.count <= Self.maximumControlBufferBytes else {
            fail("control channel sent \(controlBuffer.count) bytes with no newline")
            return
        }
        let split = LanControlCodec.split(buffer: controlBuffer)
        controlBuffer = split.remainder
        let t4 = Clock.nowNs()
        for line in split.lines where !line.isEmpty {
            do {
                handle(try LanControlCodec.decode(line: line), receivedAtNs: t4)
            } catch {
                // A single unparseable line is not a reason to drop a playing
                // link; a receiver from a future build may say things this one
                // does not know. Logged once per occurrence, never silently
                // swallowed.
                RouterLog.write(
                    "[LAN] \(receiverUID.prefix(24)): ignoring control line (\(error))\n"
                )
            }
        }
    }

    private func handle(_ message: LanInboundMessage, receivedAtNs t4: UInt64) {
        switch message {
        case .helloAck(let ack):
            mutateSnapshot {
                $0.deviceName = ack.deviceName.isEmpty ? nil : ack.deviceName
                $0.hasHardwareVolume = ack.hasHardwareVolume
                $0.receiverBufferMs = ack.bufferMs
            }
            openAudioSocket(port: ack.udpPort)
        case .pong(let t1, let t2, let t3):
            guard let sample = LanClockSample.fromTimestamps(t1: t1, t2: t2, t3: t3, t4: t4)
            else {
                // A quadruple that cannot be physical. Dropped rather than
                // averaged in — one bad sample would poison the minimum
                // filter for the rest of the window.
                return
            }
            offsetEstimator.add(sample)
            let offsetMs = offsetEstimator.smoothedOffsetNs / 1_000_000
            let rttMs = (offsetEstimator.latestRoundTripNs ?? 0) / 1_000_000
            mutateSnapshot {
                $0.offsetMs = offsetMs
                $0.roundTripMs = rttMs
            }
        case .stats(let stats):
            mutateSnapshot { $0.stats = stats }
        case .error(let message):
            // The receiver rejected us — a wrong token, almost always. Retry
            // anyway (the user may be typing the right one right now), but say
            // what happened.
            fail("receiver refused the session: \(message)")
        }
    }

    private func startPingTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + Self.pingIntervalSeconds,
            repeating: Self.pingIntervalSeconds,
            leeway: .milliseconds(50)
        )
        timer.setEventHandler { [weak self] in
            guard let self, self.running else { return }
            self.sendControl(.ping(t1: Clock.nowNs()))
        }
        pingTimer?.cancel()
        pingTimer = timer
        timer.resume()
    }

    // MARK: - Audio socket

    private func openAudioSocket(port: Int) {
        guard let host = resolvedHost else {
            fail("hello_ack arrived before the peer address was known")
            return
        }
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)), port > 0 else {
            fail("receiver advertised an unusable UDP port (\(port))")
            return
        }
        let parameters = NWParameters.udp
        parameters.includePeerToPeer = false
        let connection = NWConnection(host: host, port: nwPort, using: parameters)
        audio = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, connection === self.audio else { return }
            switch state {
            case .ready:
                self.mutateSnapshot { $0.isAudioReady = true }
                // Both settings are re-sent on every (re)connect: a receiver
                // that just restarted has neither, and a stale level is worse
                // than a redundant message.
                self.pushPendingSettings(force: true)
            case .failed(let error):
                self.fail("audio socket failed: \(error.localizedDescription)")
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    /// Hand one packet to the socket. Called from the producer timer.
    ///
    /// `.idempotent` means Network framework neither allocates a completion
    /// continuation nor tells us whether the datagram left — which is the
    /// right trade for UDP audio: there is nothing useful to do about a failed
    /// send 5 ms of audio ago, and the receiver's `lost` counter is the
    /// authoritative report anyway.
    public func sendAudio(_ packet: Data) {
        guard let audio, audio.state == .ready else { return }
        audio.send(content: packet, completion: .idempotent)
        mutateSnapshot { $0.packetsSent &+= 1 }
    }

    // MARK: - Settings

    /// Master level for this leg. Sent only when it actually changed, so a
    /// per-second reconcile does not put a message on the wire every second.
    public func setGain(linear: Double, muted: Bool) {
        let clamped = min(1, max(0, linear.isFinite ? linear : 0))
        stateLock.lock()
        _gain = (clamped, muted)
        stateLock.unlock()
        queue.async { [self] in pushPendingSettings(force: false) }
    }

    public func setTargetMs(_ ms: Int) {
        let clamped = LanPcmWire.clampTargetMs(ms)
        stateLock.lock()
        _targetMs = clamped
        stateLock.unlock()
        queue.async { [self] in pushPendingSettings(force: false) }
    }

    private func pushPendingSettings(force: Bool) {
        guard control?.state == .ready else { return }
        stateLock.lock()
        let gain = _gain
        let target = _targetMs
        let sentGain = _sentGain
        let sentTarget = _sentTargetMs
        stateLock.unlock()

        if force || sentGain == nil || sentGain! != gain {
            sendControl(.gain(linear: gain.linear, muted: gain.muted))
            stateLock.lock(); _sentGain = gain; stateLock.unlock()
        }
        if force || sentTarget != target {
            sendControl(.latency(targetMs: target))
            stateLock.lock(); _sentTargetMs = target; stateLock.unlock()
        }
    }

    // MARK: - Peer validation

    /// The remote address a ready connection actually landed on.
    static func resolvedHost(of connection: NWConnection) -> NWEndpoint.Host? {
        if case let .hostPort(host, _)? = connection.currentPath?.remoteEndpoint {
            return host
        }
        if case let .hostPort(host, _) = connection.endpoint {
            return host
        }
        return nil
    }

    /// LAN only: RFC1918, link-local, loopback, and their IPv6 equivalents.
    ///
    /// The link carries unencrypted PCM authenticated by a shared token, which
    /// is a reasonable trade inside a home network and is not a trade to make
    /// across the internet. Loopback is allowed deliberately — it is how the
    /// tests' in-process fake receiver is reached, and a receiver on this same
    /// machine is by definition not remote.
    public static func isPrivatePeer(_ host: NWEndpoint.Host) -> Bool {
        switch host {
        case .ipv4(let address):
            return isPrivateIPv4(Array(address.rawValue))
        case .ipv6(let address):
            return isPrivateIPv6(Array(address.rawValue))
        case .name(let name, _):
            // An unresolved name should not reach here (the check runs on a
            // READY connection), but if it does, only `.local.` — the mDNS
            // namespace — is trusted.
            let lower = name.lowercased()
            return lower == "localhost" || lower.hasSuffix(".local") || lower.hasSuffix(".local.")
        @unknown default:
            return false
        }
    }

    static func isPrivateIPv4(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        switch bytes[0] {
        case 10: return true
        case 127: return true
        case 169: return bytes[1] == 254
        case 172: return bytes[1] >= 16 && bytes[1] <= 31
        case 192: return bytes[1] == 168
        default: return false
        }
    }

    static func isPrivateIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        // ::1
        if bytes[0..<15].allSatisfy({ $0 == 0 }), bytes[15] == 1 { return true }
        // fc00::/7 unique local
        if bytes[0] & 0xFE == 0xFC { return true }
        // fe80::/10 link local
        if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0x80 { return true }
        // IPv4-mapped ::ffff:a.b.c.d — judge the embedded address.
        if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
            return isPrivateIPv4(Array(bytes[12..<16]))
        }
        return false
    }
}
