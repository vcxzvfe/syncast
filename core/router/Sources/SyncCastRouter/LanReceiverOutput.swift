import Foundation

/// One LAN receiver leg of the local Stereo path.
///
/// Structurally the sibling of `LocalOutput`: it reads the same capture ring
/// at its own cursor, runs the same per-device chain (equalizer → stereo image
/// → channel matrix → balance), and hands the result to an output. The output
/// happens to be a socket rather than an AUHAL, which changes two things and
/// nothing else:
///
///   * **There is no hardware clock to be driven by.** A `DispatchSourceTimer`
///     wakes every 5 ms and asks `LanSendPlanner` how many whole packets have
///     become available; the timer sets the *pacing*, the ring sets the
///     *rate*. See `RingWriteClock` for why that distinction is the whole
///     design.
///   * **It is not a real-time thread.** Allocation is allowed here (each
///     packet becomes a `Data` for the socket), so the code is written for
///     clarity rather than for the render-thread contract — with the exception
///     of the three DSP banks, which are shared with the RT paths and keep
///     their own no-allocation guarantees.
///
/// A dead or missing receiver costs the local outputs nothing: this class owns
/// its own timer and its own socket, and never touches theirs.
public final class LanReceiverOutput: @unchecked Sendable {

    /// Producer wake interval. One packet's worth, so the steady state is one
    /// packet per tick.
    public static let tickIntervalMs: Int = 5
    /// Timer leeway. Generous on purpose: the planner copes with a tick that
    /// lands early or late by emitting zero or two packets, and a tight leeway
    /// would only cost wakeups.
    public static let tickLeewayMs: Int = 1
    /// Extra ring lag on top of the capture floor, so a tick that runs 1–2 ms
    /// late still finds a whole packet written. One packet.
    public static let extraLagFrames: Int = LanPcmWire.framesPerPacket
    /// How stale the newest hardware anchor may be before the packet timeline
    /// falls back to the estimator.
    ///
    /// Anchors arrive every few milliseconds while capture is alive, so a
    /// whole second without one means the capture backend has stopped
    /// delivering. Extrapolating a timeline from a stamp that old would put
    /// `play_at_ns` progressively further from the truth; the estimator, fed
    /// from the write cursor, at least degrades honestly.
    public static let anchorStaleLimitNs: UInt64 = 1_000_000_000

    public let receiverUID: String
    /// Friendly name, for logs and the diagnostics line.
    public let displayName: String
    public let link: LanReceiverLink

    private let ring: RingBuffer
    private let sampleRate: Double
    private let channelCount: Int
    private let lagFrames: Int64
    private let queue: DispatchQueue

    private let equalizer: EqualizerBank
    private let stereoImage: StereoImageProcessor
    private let channelMatrix: ChannelMatrixBank

    /// Per-device balance, as linear amplitude. The MASTER level is not
    /// applied here — it travels to the receiver as a `gain` control message
    /// so the receiver can use its own hardware volume. This is only the
    /// per-device fader and the per-device mute.
    private var balanceAmplitude: Float = 1

    // Staging: two planar Float32 slabs of one packet each, allocated once.
    private let stagingSlabs: [UnsafeMutablePointer<Float>]
    private let stagingChannels: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    /// Packet scratch, reused across ticks. Copied into a `Data` at the socket
    /// boundary because `NWConnection.send` takes ownership of its buffer.
    private var packetScratch: [UInt8]

    private var timer: DispatchSourceTimer?
    private var running = false
    /// Hardware capture stamps, when the backend produces them. This is the
    /// timeline the receiver is rate-locked to; `ringClock` is the fallback.
    private let anchors: CaptureAnchorPublisher?
    private var hostClock: HostAnchoredRingClock
    private var lastAnchorFrame: Int64 = .min
    private var lastAnchorSeenNs: UInt64 = 0
    private var loggedClockSource: String?
    private var ringClock: RingWriteClock
    private var cursor: Int64?
    private var sequence: UInt32 = 0
    private var lastPlayAtNs: UInt64?
    private var lastWritePosition: Int64 = -1

    private let counterLock = NSLock()
    private var _packetsSent: UInt64 = 0
    private var _silencePackets: UInt64 = 0
    private var _reanchorCount: Int = 0
    private var _encoderClipCount: Int64 = 0

    public init(
        receiverUID: String,
        displayName: String,
        ring: RingBuffer,
        sampleRate: Double,
        channelCount: Int,
        ringFloorFrames: Int,
        link: LanReceiverLink,
        captureAnchors: CaptureAnchorPublisher? = nil
    ) {
        self.receiverUID = receiverUID
        self.displayName = displayName
        self.ring = ring
        self.sampleRate = sampleRate > 0 ? sampleRate : LanPcmWire.sampleRate
        self.channelCount = max(1, channelCount)
        self.link = link
        self.lagFrames = Int64(max(0, ringFloorFrames) + Self.extraLagFrames)
        self.queue = DispatchQueue(label: "io.syncast.lan.producer", qos: .userInitiated)
        self.ringClock = RingWriteClock(sampleRate: self.sampleRate)
        self.anchors = captureAnchors
        self.hostClock = HostAnchoredRingClock(sampleRate: self.sampleRate)
        self.equalizer = EqualizerBank(
            pairCount: 1, channelsPerPair: self.channelCount, sampleRate: self.sampleRate
        )
        self.stereoImage = StereoImageProcessor(
            pairCount: 1, channelsPerPair: self.channelCount, sampleRate: self.sampleRate
        )
        self.channelMatrix = ChannelMatrixBank(
            pairCount: 1, channelsPerPair: self.channelCount, sampleRate: self.sampleRate
        )
        var slabs: [UnsafeMutablePointer<Float>] = []
        slabs.reserveCapacity(self.channelCount)
        for _ in 0..<self.channelCount {
            let slab = UnsafeMutablePointer<Float>.allocate(
                capacity: LanPcmWire.framesPerPacket
            )
            slab.initialize(repeating: 0, count: LanPcmWire.framesPerPacket)
            slabs.append(slab)
        }
        self.stagingSlabs = slabs
        let table = UnsafeMutablePointer<UnsafeMutablePointer<Float>>
            .allocate(capacity: self.channelCount)
        for index in 0..<self.channelCount { table[index] = slabs[index] }
        self.stagingChannels = table
        self.packetScratch = [UInt8](repeating: 0, count: LanPcmWire.packetBytes)
    }

    deinit {
        // Same rule as `LanReceiverLink.deinit`: cancel directly rather than
        // going through `stop()`, which would dispatch onto `queue` with
        // `self` captured.
        timer?.cancel()
        timer = nil
        running = false
        link.stop()
        stagingChannels.deallocate()
        for slab in stagingSlabs {
            slab.deinitialize(count: LanPcmWire.framesPerPacket)
            slab.deallocate()
        }
    }

    // MARK: - Lifecycle

    public func start() {
        queue.sync {
            guard !running else { return }
            running = true
            cursor = nil
            sequence = 0
            lastPlayAtNs = nil
            lastWritePosition = -1
            ringClock = RingWriteClock(sampleRate: sampleRate)
            hostClock = HostAnchoredRingClock(sampleRate: sampleRate)
            lastAnchorFrame = .min
            lastAnchorSeenNs = 0
            loggedClockSource = nil
        }
        link.start()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now(),
            repeating: .milliseconds(Self.tickIntervalMs),
            leeway: .milliseconds(Self.tickLeewayMs)
        )
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        queue.sync { running = false }
        link.stop()
    }

    // MARK: - Per-device settings

    @discardableResult
    public func setEqualizer(_ settings: EqualizerSettings) -> Bool {
        equalizer.setSettings(settings, pair: 0)
    }

    @discardableResult
    public func setStereoImage(_ settings: StereoImageSettings) -> Bool {
        stereoImage.setSettings(settings, pair: 0)
    }

    @discardableResult
    public func setChannelMatrix(_ settings: ChannelMatrixSettings) -> Bool {
        channelMatrix.setSettings(settings, pair: 0)
    }

    /// Per-device balance and mute, as a linear amplitude.
    public func setBalance(amplitude: Float) {
        let clamped = amplitude.isFinite ? min(1, max(0, amplitude)) : 0
        queue.async { [self] in balanceAmplitude = clamped }
    }

    public var equalizerClipCount: Int64 { equalizer.clipCount }
    public var stereoImageClipCount: Int64 { stereoImage.clipCount }
    public var channelMatrixClipCount: Int64 { channelMatrix.clipCount }

    // MARK: - Diagnostics

    public struct Counters: Sendable, Equatable {
        public let packetsSent: UInt64
        public let silencePackets: UInt64
        public let reanchorCount: Int
        public let encoderClipCount: Int64
        public let ringClockPpm: Double
        public let ringClockReanchors: Int
        /// Which timeline `play_at_ns` is currently derived from: "hal" when
        /// the capture backend stamps its blocks, "est" when it does not.
        public let clockSource: String
    }

    public var counters: Counters {
        counterLock.lock()
        let sent = _packetsSent
        let silence = _silencePackets
        let reanchors = _reanchorCount
        let clips = _encoderClipCount
        counterLock.unlock()
        // The clocks are queue-confined; a torn read of two Doubles is not
        // possible in practice here, but the diagnostic is read once a second
        // and a queue hop costs nothing.
        let (ppm, clockReanchors, source) = queue.sync { () -> (Double, Int, String) in
            if isHostAnchored(nowNs: Clock.nowNs()) {
                return (hostClock.rateDeviationPpm, hostClock.reanchorCount, "hal")
            }
            return (ringClock.rateDeviationPpm, ringClock.reanchorCount, "est")
        }
        return Counters(
            packetsSent: sent,
            silencePackets: silence,
            reanchorCount: reanchors,
            encoderClipCount: clips,
            ringClockPpm: ppm,
            ringClockReanchors: clockReanchors,
            clockSource: source
        )
    }

    /// One-line summary for `Router.diagnosticCaptureReport()`.
    public func diagnosticSummary() -> String {
        let snapshot = link.snapshot
        let counters = self.counters
        let rtt = snapshot.roundTripMs.map { String(format: "%.1fms", $0) } ?? "-"
        let offset = snapshot.offsetMs.map { String(format: "%.1fms", $0) } ?? "-"
        let stats = snapshot.stats
        let buffer = stats.map { String(format: "%.0fms", $0.bufferMs) }
            ?? snapshot.receiverBufferMs.map { "\($0)ms" }
            ?? "-"
        let clip = counters.encoderClipCount
        let clipInfo = clip > 0 ? " clip:\(clip)" : ""
        let silence = counters.silencePackets
        let silenceInfo = silence > 0 ? " silence:\(silence)" : ""
        return "rtt:\(rtt) off:\(offset) buf:\(buffer)"
            + " late:\(stats?.late ?? 0) lost:\(stats?.lost ?? 0)"
            + " underrun:\(stats?.underrun ?? 0)"
            + " pkts:\(counters.packetsSent) resync:\(counters.reanchorCount)"
            + " clk:\(counters.clockSource)"
            + " ppm:\(String(format: "%.1f", counters.ringClockPpm))"
            + "\(clipInfo)\(silenceInfo)"
            + " link:\(snapshot.isAudioReady ? "up" : (snapshot.lastError ?? "connecting"))"
    }

    // MARK: - Producer

    private func tick() {
        guard running else { return }
        let writePosition = ring.writePosition
        let now = Clock.nowNs()
        // The fallback estimator is fed on every tick whether or not it is
        // the one in use: a backend whose stamps stop has to have something
        // warm to fall back TO.
        ringClock.observe(writePosition: writePosition, nowNs: now)
        observeAnchor(nowNs: now)

        guard link.isAudioReady else {
            // Nothing to send into. Drop the cursor so the link re-anchors on
            // live audio when it comes up, rather than resuming from a
            // position the ring has long overwritten.
            cursor = nil
            lastPlayAtNs = nil
            lastWritePosition = writePosition
            return
        }

        let producerAdvanced = lastWritePosition < 0 || writePosition > lastWritePosition
        lastWritePosition = writePosition

        let plan = LanSendPlanner.plan(
            writePosition: writePosition,
            cursor: cursor,
            lagFrames: lagFrames,
            capacityFrames: ring.capacityFrames,
            driftLimitFrames: Int64(LanSendPlanner.driftResyncLimitMs)
                * Int64(sampleRate) / 1000
        )
        if plan.didReanchor, cursor != nil {
            counterLock.lock(); _reanchorCount += 1; counterLock.unlock()
        }

        guard plan.packets > 0 else {
            // The producer is not feeding us. Keep the receiver's jitter
            // buffer primed with silence rather than letting it drain: an
            // empty buffer is an underrun burst the moment audio resumes, and
            // the receiver's clock loop has nothing to lock to meanwhile.
            //
            // Only while the producer is genuinely idle. A tick that simply
            // arrived before the next packet was written must NOT inject
            // silence — the audio for that slot is a millisecond away.
            if !producerAdvanced, cursor != nil {
                sendSilencePacket()
            }
            return
        }

        for index in 0..<plan.packets {
            let frame = plan.startFrame + Int64(index) * Int64(LanPcmWire.framesPerPacket)
            sendPacket(readingFrame: frame)
        }
        cursor = plan.nextCursor
    }

    /// Read one packet's worth of ring, run the chain, packetise, send.
    private func sendPacket(readingFrame frame: Int64) {
        ring.read(at: frame, frames: LanPcmWire.framesPerPacket, into: stagingChannels)
        applyChain()
        let playAt = playAtNs(forFrame: frame)
        emit(playAtNs: playAt, silence: false)
    }

    /// Send a packet of digital silence, pacing `play_at_ns` off the previous
    /// packet so the receiver's timeline stays continuous.
    private func sendSilencePacket() {
        for channel in 0..<channelCount {
            stagingSlabs[channel].update(
                repeating: 0, count: LanPcmWire.framesPerPacket
            )
        }
        // The chain is deliberately NOT run on silence: a crosstalk recursion
        // fed zeros still decays its own state, which is what we want, but
        // running three banks 200 times a second for a buffer that is zero on
        // the way in and zero on the way out is pure waste.
        let playAt = (lastPlayAtNs ?? (Clock.nowNs() + targetNs)) + LanPcmWire.packetDurationNs
        emit(playAtNs: playAt, silence: true)
    }

    private func applyChain() {
        equalizer.process(
            pair: 0, channels: stagingChannels, channelOffset: 0,
            channelCount: channelCount, frames: LanPcmWire.framesPerPacket
        )
        stereoImage.process(
            pair: 0, channels: stagingChannels, channelOffset: 0,
            channelCount: channelCount, frames: LanPcmWire.framesPerPacket
        )
        channelMatrix.process(
            pair: 0, channels: stagingChannels, channelOffset: 0,
            channelCount: channelCount, frames: LanPcmWire.framesPerPacket
        )
        let gain = balanceAmplitude
        guard gain != 1 else { return }
        for channel in 0..<channelCount {
            let samples = stagingSlabs[channel]
            for index in 0..<LanPcmWire.framesPerPacket { samples[index] *= gain }
        }
    }

    private var targetNs: UInt64 {
        UInt64(LanPcmWire.clampTargetMs(link.targetMs)) * 1_000_000
    }

    /// `play_at_ns` for a ring frame: when the ring says it was captured, plus
    /// the playout target.
    ///
    /// Monotonicity is enforced rather than assumed. In steady state the ring
    /// clock advances exactly one packet per packet and the guard never fires;
    /// it exists for the seam where a stretch of silence packets (paced off
    /// wall clock) hands back to ring-derived timestamps, and for a cursor
    /// re-anchor that lands on an earlier ring time than the packet before it.
    /// A receiver that saw time run backwards would drop everything until it
    /// caught up.
    /// Take the newest hardware anchor, if the backend has published one we
    /// have not folded in yet.
    private func observeAnchor(nowNs: UInt64) {
        guard let anchors, let anchor = anchors.latest else { return }
        guard anchor.frame != lastAnchorFrame else { return }
        lastAnchorFrame = anchor.frame
        lastAnchorSeenNs = nowNs
        hostClock.observe(anchor)
    }

    /// Whether `play_at_ns` is currently coming off the capture hardware's
    /// own clock.
    private func isHostAnchored(nowNs: UInt64) -> Bool {
        guard anchors != nil, hostClock.isAnchored, lastAnchorSeenNs > 0 else { return false }
        return nowNs &- lastAnchorSeenNs <= Self.anchorStaleLimitNs
    }

    /// One line the first time the timeline comes from the hardware, and one
    /// each time it changes hands. Which clock is driving the wire is the
    /// first thing to know when a link sounds wrong.
    private func logClockSource(_ source: String) {
        guard loggedClockSource != source else { return }
        loggedClockSource = source
        let detail = source == "hal"
            ? "capture hardware timestamps"
            : "write-cursor estimate (backend publishes no timestamps)"
        RouterLog.write(
            "[LAN] \(displayName) packet timeline from \(detail)\n"
        )
    }

    private func playAtNs(forFrame frame: Int64) -> UInt64 {
        let now = Clock.nowNs()
        let hostAnchored = isHostAnchored(nowNs: now)
        logClockSource(hostAnchored ? "hal" : "est")
        let base = (hostAnchored
            ? hostClock.timeNs(forFrame: frame)
            : ringClock.timeNs(forFrame: frame)) &+ targetNs
        if let last = lastPlayAtNs, base <= last {
            return last &+ LanPcmWire.packetDurationNs
        }
        return base
    }

    private func emit(playAtNs: UInt64, silence: Bool) {
        let header = LanAudioPacketHeader(
            streamID: link.streamID,
            sequence: sequence,
            playAtNs: playAtNs,
            frames: UInt32(LanPcmWire.framesPerPacket)
        )
        var clipped = 0
        packetScratch.withUnsafeMutableBytes { raw in
            header.encode(into: raw)
            clipped = LanPcmEncoder.encode(
                channels: stagingChannels,
                channelCount: channelCount,
                frames: LanPcmWire.framesPerPacket,
                into: raw,
                offset: LanPcmWire.headerBytes
            )
        }
        link.sendAudio(Data(packetScratch))
        sequence &+= 1
        lastPlayAtNs = playAtNs
        counterLock.lock()
        _packetsSent &+= 1
        if silence { _silencePackets &+= 1 }
        _encoderClipCount &+= Int64(clipped)
        counterLock.unlock()
    }
}
