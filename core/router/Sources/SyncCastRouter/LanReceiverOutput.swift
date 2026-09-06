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

    /// Frames the producer holds behind the ring's write head before it will
    /// read a packet: the capture floor plus one packet of tick slack. This is
    /// also how far in the PAST every packet already is when it leaves the
    /// machine, so `play_at_ns` adds it back on top of the target — otherwise
    /// the receiver's whole budget minus this lag is what is actually left for
    /// the network, which on Wi-Fi was the difference between 55 ms and 90 ms.
    public static func scheduleLagFrames(ringFloorFrames: Int) -> Int {
        max(0, ringFloorFrames) + extraLagFrames
    }
    /// How stale the newest hardware anchor may be before the packet timeline
    /// falls back to the estimator.
    ///
    /// Anchors arrive every few milliseconds while capture is alive, so a
    /// whole second without one means the capture backend has stopped
    /// delivering. Extrapolating a timeline from a stamp that old would put
    /// `play_at_ns` progressively further from the truth; the estimator, fed
    /// from the write cursor, at least degrades honestly.
    public static let anchorStaleLimitNs: UInt64 = 1_000_000_000
    /// How long the ring's write cursor may stand still before the producer
    /// is treated as idle. See `ProducerIdleDetector`.
    public static let idleThresholdMs: Int = ProducerIdleDetector.defaultIdleThresholdMs

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
    /// Idleness is read off the ring, never off a single tick. See
    /// `ProducerIdleDetector` for why that distinction is the whole fix.
    private var idleDetector = ProducerIdleDetector(thresholdMs: idleThresholdMs)

    private let counterLock = NSLock()
    private var _packetsSent: UInt64 = 0
    private var _silencePackets: UInt64 = 0
    private var _idleTicks: UInt64 = 0
    /// Producer-thread health: the longest gap between two ticks and the
    /// number of ticks that ran more than 3x late since the last snapshot,
    /// plus the largest packet burst one tick emitted. A bursty producer is
    /// indistinguishable from a jittery network at the receiver, so this is
    /// how the two are told apart.
    private var _lastTickNs: UInt64 = 0
    private var _tickMaxIntervalNs: UInt64 = 0
    private var _tickLateTicks: UInt64 = 0
    private var _burstMaxPackets: Int = 0
    /// Probe for the "half the packets are zero" field symptom: packets whose
    /// ring read returned fewer valid frames than a packet (the rest was
    /// zero-filled because the requested span lay outside the ring's window),
    /// plus the geometry of the most recent one. Logged rate-limited.
    private var _shortReads: UInt64 = 0
    private var _lastShortReadLogNs: UInt64 = 0
    private var _gapSkips: Int = 0
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
        self.lagFrames = Int64(Self.scheduleLagFrames(ringFloorFrames: ringFloorFrames))
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
            idleDetector.reset()
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
        /// Packets whose payload came out of the chain digitally silent.
        ///
        /// These are REAL packets read from real ring frames — the sender no
        /// longer synthesises anything — so a non-zero count means the ring
        /// itself was carrying silence, which is a fact about the program
        /// rather than about the link. During continuous playback it must be
        /// zero; if it is not, the capture backend is the place to look.
        public let silencePackets: UInt64
        /// Ticks that ran while the producer was judged idle (the ring's
        /// write cursor had stood still for `idleThresholdMs`). Nothing is
        /// sent on those ticks.
        public let idleTicks: UInt64
        /// Times the cursor skipped a gap on the tick where the producer
        /// resumed, rather than replaying stale frames.
        public let gapSkips: Int
        public let reanchorCount: Int
        public let encoderClipCount: Int64
        public let ringClockPpm: Double
        public let ringClockReanchors: Int
        /// Which timeline `play_at_ns` is currently derived from: "hal" when
        /// the capture backend stamps its blocks, "est" when it does not.
        public let clockSource: String
        /// Longest tick-to-tick gap since the previous snapshot, ms.
        public let tickMaxIntervalMs: Double
        /// Ticks that ran more than 3x late since the previous snapshot.
        public let tickLateTicks: UInt64
        /// Largest number of packets one tick emitted since the previous snapshot.
        public let burstMaxPackets: Int
        /// Packets whose ring read came back partly zero-filled (see `_shortReads`).
        public let shortReads: UInt64
    }

    public var counters: Counters {
        counterLock.lock()
        let sent = _packetsSent
        let silence = _silencePackets
        let idle = _idleTicks
        let skips = _gapSkips
        let reanchors = _reanchorCount
        let clips = _encoderClipCount
        let tickMax = _tickMaxIntervalNs
        let tickLate = _tickLateTicks
        let burst = _burstMaxPackets
        let shortReads = _shortReads
        _tickMaxIntervalNs = 0
        _tickLateTicks = 0
        _burstMaxPackets = 0
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
            idleTicks: idle,
            gapSkips: skips,
            reanchorCount: reanchors,
            encoderClipCount: clips,
            ringClockPpm: ppm,
            ringClockReanchors: clockReanchors,
            clockSource: source,
            tickMaxIntervalMs: Double(tickMax) / 1_000_000,
            tickLateTicks: tickLate,
            burstMaxPackets: burst,
            shortReads: shortReads
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
        let idleInfo = counters.idleTicks > 0 ? " idle:\(counters.idleTicks)" : ""
        let tickInfo = String(
            format: " tickMax:%.1fms tickLate:%d burst:%d",
            counters.tickMaxIntervalMs, Int(counters.tickLateTicks), counters.burstMaxPackets
        ) + " short:\(counters.shortReads)"
        // Refusals are OUR fault, not the link's: the receiver only ever
        // reports them when this side stamps more than one timeline.
        let refused = (stats?.overlap ?? 0) + (stats?.farFuture ?? 0)
        let refusedInfo = refused > 0
            ? " refused:\(stats?.overlap ?? 0)/\(stats?.farFuture ?? 0)" : ""
        let skipInfo = counters.gapSkips > 0 ? " gapSkips:\(counters.gapSkips)" : ""
        return "rtt:\(rtt) off:\(offset) buf:\(buffer)"
            + " late:\(stats?.late ?? 0) lost:\(stats?.lost ?? 0)"
            + " underrun:\(stats?.underrun ?? 0)"
            + " pkts:\(counters.packetsSent) resync:\(counters.reanchorCount)"
            + idleInfo + skipInfo + refusedInfo + tickInfo
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
        counterLock.lock()
        if _lastTickNs != 0 {
            let interval = now &- _lastTickNs
            if interval > _tickMaxIntervalNs { _tickMaxIntervalNs = interval }
            if interval > UInt64(Self.tickIntervalMs) * 3_000_000 { _tickLateTicks &+= 1 }
        }
        _lastTickNs = now
        counterLock.unlock()
        // Idleness is a property of the ring over TIME, never of one tick.
        // The capture backend writes a 512-frame block every ~10.7 ms while
        // this timer runs every 5 ms, so about half of all ticks find the
        // write cursor exactly where they left it and the audio for that slot
        // is a millisecond away. It is decided first because it also decides
        // whether this tick's observations carry any information.
        let producer = idleDetector.observe(writePosition: writePosition, nowNs: now)
        if producer != ProducerIdleDetector.State.idle {
            // The fallback estimator is fed whether or not it is the one in
            // use: a backend whose stamps stop has to have something warm to
            // fall back TO. But a frozen write cursor paired with an
            // advancing `now` says nothing about the ring's rate — it is pure
            // phase error — and feeding it would re-anchor the estimator
            // every 100 ms for the whole of a silent stretch.
            ringClock.observe(writePosition: writePosition, nowNs: now)
        }
        observeAnchor(nowNs: now)

        guard link.isAudioReady else {
            // Nothing to send into. Drop the cursor so the link re-anchors on
            // live audio when it comes up, rather than resuming from a
            // position the ring has long overwritten.
            cursor = nil
            lastPlayAtNs = nil
            idleDetector.reset()
            return
        }

        switch producer {
        case .running:
            break
        case .idle:
            // The producer has genuinely stopped. Send NOTHING: the receiver
            // zero-fills what it does not have, which is the correct
            // rendering of silence and costs no packet to say. Anything
            // synthesised here would have to invent a timestamp, and a second
            // timeline interleaved with the ring's is what garbled the audio
            // before this fix.
            counterLock.lock(); _idleTicks &+= 1; counterLock.unlock()
        case .resumed:
            // First frames after an idle stretch. Everything between the old
            // cursor and the new write head is the silence that was not
            // written; replaying it would put a burst of stale timestamps on
            // the wire ahead of the audio that is about to arrive.
            if let skipped = LanSendPlanner.resumeCursor(
                writePosition: writePosition, cursor: cursor, lagFrames: lagFrames
            ) {
                cursor = skipped
                counterLock.lock(); _gapSkips += 1; counterLock.unlock()
                RouterLog.write(
                    "[LAN] \(displayName) producer resumed; skipped the idle gap\n"
                )
            }
        }

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

        // Zero packets is the normal outcome of roughly every second tick and
        // is not a fault: the timer runs faster than the capture block rate,
        // and `play_at_ns` comes from the FRAME number, so a tick that sends
        // nothing costs the receiver's timeline nothing either.
        guard plan.packets > 0 else { return }

        counterLock.lock()
        if plan.packets > _burstMaxPackets { _burstMaxPackets = plan.packets }
        counterLock.unlock()
        for index in 0..<plan.packets {
            let frame = plan.startFrame + Int64(index) * Int64(LanPcmWire.framesPerPacket)
            sendPacket(readingFrame: frame)
        }
        cursor = plan.nextCursor
    }

    /// Read one packet's worth of ring, run the chain, packetise, send.
    ///
    /// This is the ONLY thing that puts a packet on the wire, which is the
    /// point: every `play_at_ns` on this link is derived from a ring frame
    /// index through `timeOf(frame)`, and the cursor advances by whole
    /// packets for every one of them. There is no second timeline to
    /// interleave with this one.
    private func sendPacket(readingFrame frame: Int64) {
        let valid = ring.read(at: frame, frames: LanPcmWire.framesPerPacket, into: stagingChannels)
        if valid < LanPcmWire.framesPerPacket {
            let writePosition = ring.writePosition
            let now = Clock.nowNs()
            counterLock.lock()
            _shortReads &+= 1
            let shouldLog = now &- _lastShortReadLogNs > 1_000_000_000
            if shouldLog { _lastShortReadLogNs = now }
            let total = _shortReads
            counterLock.unlock()
            if shouldLog {
                RouterLog.write(
                    "[LAN] \(displayName) short read #\(total): frame=\(frame) valid=\(valid)/\(LanPcmWire.framesPerPacket) writePos=\(writePosition) lowerValid=\(writePosition - Int64(ring.capacityFrames)) cursorLag=\(writePosition - frame) lag=\(lagFrames) cap=\(ring.capacityFrames)\n"
                )
            }
        }
        applyChain()
        let playAt = playAtNs(forFrame: frame)
        emit(playAtNs: playAt, silence: stagingIsSilent())
    }

    /// Whether the packet about to be sent is digitally silent.
    ///
    /// Cheap (480 float compares on a non-real-time thread, 200 times a
    /// second) and worth having: it separates "the link sent nothing" from
    /// "the link sent zeros", which are different faults with the same
    /// symptom at the speaker.
    private func stagingIsSilent() -> Bool {
        for channel in 0..<channelCount {
            let samples = stagingSlabs[channel]
            for index in 0..<LanPcmWire.framesPerPacket where samples[index] != 0 {
                return false
            }
        }
        return true
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

    /// The read lag expressed in nanoseconds of ring time.
    private var lagNs: UInt64 {
        UInt64((Double(lagFrames) / sampleRate * 1_000_000_000).rounded())
    }

    /// `play_at_ns` for a ring frame: when the ring says it was captured, plus
    /// the playout target.
    ///
    /// Monotonicity is enforced rather than assumed. In steady state the ring
    /// clock advances exactly one packet per packet and the guard never
    /// fires; it exists for the two seams where it could: the timeline handing
    /// over between the hardware anchors and the fallback estimator, and a
    /// cursor re-anchor that lands on an earlier ring time than the packet
    /// before it. A receiver that saw time run backwards would drop
    /// everything until it caught up.
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
            : ringClock.timeNs(forFrame: frame)) &+ lagNs &+ targetNs
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
