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
    /// Rate of the stream on this socket. A static as well as an instance
    /// property so the equalizer bank — which fixes its coefficients at
    /// construction — can be built in `init` from the one source of truth.
    public static let wireSampleRate: Double = 48_000

    public let socketPath: URL
    public let frameCount = 480
    public let channelCount = 2
    public let sampleRate: Double = AudioSocketWriter.wireSampleRate

    private let ring: RingBuffer
    private var fd: Int32 = -1
    private var task: Task<Void, Never>?
    private let lock = NSLock()
    /// Diagnostic — packets actually sent through the socket (full-frame
    /// only). A short send (sent < bytesPerPacket) is counted in
    /// `partialSends` and NOT in `packetsSent`, so this counter accurately
    /// reflects the rate of well-formed s16le packets the receiver sees.
    public private(set) var packetsSent: UInt64 = 0
    public private(set) var bytesSent: UInt64 = 0
    public private(set) var lastSendError: String = ""
    /// Diagnostic — packets that found the ring under-filled and emitted
    /// silence to keep wall-clock pacing. Indicator of capture stalls.
    public private(set) var underrunPackets: UInt64 = 0
    /// Diagnostic — Darwin.send() returned 0 < n < bytesPerPacket. With
    /// SOCK_STREAM that mis-frames the s16le wire format, so we treat it
    /// as an error rather than as a successful packet.
    public private(set) var partialSends: UInt64 = 0
    /// Sentinel for true idempotent start. Just checking
    /// `task != nil && !task.isCancelled` is racy: stop() cancels the
    /// task but the detached body keeps executing until it observes
    /// cancellation, and a stop+start cycle in that window used to spawn
    /// a SECOND writer that paced its own 100 pkts/s. Two writers ⇒ the
    /// observed 2.2× over-rate that overflowed the kernel pipe buffer.
    /// We set this flag true on entry to runLoop and clear on exit;
    /// start() refuses to spawn while it's true.
    private var writerActive: Bool = false

    /// Monotonically increasing generation counter. Bumped by `start()`
    /// each time a new Task is spawned, AND by `stop()` to invalidate
    /// any in-flight Task cleanup. The Task captures its generation at
    /// spawn time and only clears `writerActive` if the generation still
    /// matches — preventing a stale cancelled-Task cleanup from wiping
    /// the flag of a NEWER Task that was legitimately started after a
    /// stop(). Without this, stop()+start() in rapid succession would
    /// allow the old cancelled Task's exit handler to clear the flag
    /// owned by the new generation, letting a third start() spawn a
    /// second concurrent writer — the same 2.2× over-rate bug feb56ca
    /// originally fixed.
    private var writerGeneration: UInt64 = 0

    // MARK: - Master volume
    //
    // The master fader is applied HERE, on the samples going into OwnTone's
    // input fifo, and nowhere else. That placement is load-bearing:
    //
    //  * Both output legs descend from this one stream — the AirPlay leg from
    //    OwnTone's AirPlay outputs, the local leg from OwnTone's fifo output
    //    fanned back to `LocalAirPlayBridge`. One multiply here is therefore
    //    bit-identically applied to both, with no curve reconciliation needed.
    //  * OwnTone's per-output volume floors at -30 dB (see `VolumeCurve`), so a
    //    master implemented as per-output volume could not mute, and — worse —
    //    any combination summing below -30 dB would clamp on the AirPlay leg
    //    while the local leg took the full attenuation, pulling the two legs
    //    apart by up to 15 dB. Upstream has no floor.
    //  * This loop is a plain async Task paced on the wall clock, not a
    //    real-time thread. A multiply per sample does not move the packet
    //    cadence, so the Layer-2 PLL sees nothing at all.
    //
    // The cost is that attenuation happens before the s16 quantisation below,
    // so the master spends headroom: one bit per 6.02 dB. The master follows
    // `VolumeCurve`, NOT a linear fader, so read the budget off
    // `VolumeCurve.decibels(forPercent:)` rather than off slider travel —
    // 50 % is -15 dB (~2.5 bits, ~13.5 left of 16), 25 % is -22.5 dB
    // (~3.7 bits, ~12.3 left). Both are fine; users who want to run very low
    // should pull the per-speaker faders instead, which act after OwnTone.
    // `VolumeCurveTests` derives these numbers rather than trusting the prose.

    /// Ramp time for a master change, matching
    /// `LocalAirPlayBridge.volumeRampMs` for the same reason: an instantaneous
    /// gain step on a non-zero signal is an audible click. One packet is
    /// `frameCount / sampleRate` = 10 ms, so a ramp completes inside a single
    /// packet and never straddles a socket write.
    public static let masterRampMs: Double = 10.0

    /// No attenuation.
    public static let masterGainDefault: Float = 1.0

    /// Guards the two gain fields only. Deliberately NOT `lock` — that one
    /// guards `fd` and is taken inside the send loop, and a fader drag must
    /// never contend with an in-flight write.
    private let masterGainLock = NSLock()
    private var _masterGainTarget: Float = AudioSocketWriter.masterGainDefault
    private var _masterGainCurrent: Float = AudioSocketWriter.masterGainDefault

    /// Set the master linear amplitude. Takes effect on the next packet and
    /// ramps in over `masterRampMs`.
    public func setMasterGain(_ gain: Float) {
        let clamped = Self.clampGain(gain)
        masterGainLock.withLock { _masterGainTarget = clamped }
    }

    /// Set the master amplitude with NO ramp, for a writer that has not
    /// emitted a packet yet.
    ///
    /// `Router.attachIpc` builds a brand-new writer on every sidecar
    /// (re)connection and re-seeds it from the user's current setting. Doing
    /// that through `setMasterGain` only moved the TARGET, leaving `current`
    /// at `masterGainDefault` — so a sidecar restart with the fader at 10 %
    /// (or muted) began its very first packet at full scale and ramped down
    /// over 480 frames, putting ~10 ms of full-volume audio onto every AirPlay
    /// receiver and local bridge at exactly the moment the user had the system
    /// turned down. There is nothing to ramp away from before the first
    /// packet, so seeding both fields is both safe and correct.
    ///
    /// Only valid before `start()`; afterwards use `setMasterGain` so live
    /// changes keep their click-free ramp.
    public func seedMasterGain(_ gain: Float) {
        let clamped = Self.clampGain(gain)
        masterGainLock.withLock {
            _masterGainTarget = clamped
            _masterGainCurrent = clamped
        }
    }

    private static func clampGain(_ gain: Float) -> Float {
        guard gain.isFinite else { return masterGainDefault }
        return max(0, min(1, gain))
    }

    /// The last value passed to `setMasterGain`, not the in-flight ramp
    /// position — set/get symmetry for the Router's re-seed on reconnect.
    public var masterGain: Float {
        masterGainLock.withLock { _masterGainTarget }
    }

    /// Where the ramp currently sits, i.e. the gain the NEXT packet starts at.
    /// Internal: the only consumer is the test that pins `seedMasterGain`
    /// moving this and `setMasterGain` deliberately not.
    var masterGainRampPosition: Float {
        masterGainLock.withLock { _masterGainCurrent }
    }

    // MARK: - AirPlay group equalizer
    //
    // OwnTone sends ONE stream to every receiver: the sidecar hands it this
    // socket and OwnTone fans the result out. There is no point downstream of
    // that where a receiver's samples can be shaped on their own, so a
    // PER-RECEIVER curve is not a feature this architecture can express — the
    // honest offer is one curve for the whole AirPlay group, applied here.
    //
    // Order of the output stages, and why:
    //
    //     EQ (bank limiter, ±1) → master gain ramp → clamp → s16
    //
    //  * EQ FIRST, so it sits in the same place on the signal as on the local
    //    legs (`LocalOutput.render` / `LocalAirPlayBridge.render` both put the
    //    bank ahead of their gain stage). The master fader stays the last
    //    attenuator, so turning the system down still turns a boosted curve
    //    down rather than merely quieting a clipped one.
    //  * The bank's own limiter clamps at full scale and COUNTS what it
    //    clamped (`equalizerClipCount`). That count is the diagnostic that
    //    tells the user to pull the trim down; leaving the boost unclamped
    //    until after the master fader would hide it whenever the fader
    //    happened to be low, which is exactly when a user stops noticing
    //    distortion and starts blaming the speaker.
    //  * The clamp before the s16 conversion stays where it was. It is now a
    //    backstop rather than the primary limiter (the signal reaching it is
    //    already inside ±1, and the master gain only attenuates), which is
    //    what makes it safe for the s16 cast never to wrap.
    //
    // This runs on the writer's plain async Task, not a real-time thread, so
    // the bank's RT contract is met with room to spare. The local bridges get
    // their own PER-DEVICE curve from the same store; only receivers share.

    /// One pair, matching the socket's stereo format.
    private let equalizer: EqualizerBank

    /// Install the AirPlay group curve. Idempotent — re-publishing an
    /// unchanged curve is a no-op — so the Router can re-apply it on every
    /// replan and on every sidecar reconnect.
    ///
    /// - Returns: whether anything was actually published.
    @discardableResult
    public func setEqualizer(_ settings: EqualizerSettings) -> Bool {
        equalizer.setSettings(settings, pair: 0)
    }

    /// Samples the group equalizer's limiter had to clamp this session.
    public var equalizerClipCount: Int64 { equalizer.clipCount }

    /// True when the group curve changes the signal.
    public var equalizerIsEngaged: Bool { equalizer.isEngaged }

    public init(ring: RingBuffer, socketPath: URL) {
        self.ring = ring
        self.socketPath = socketPath
        self.equalizer = EqualizerBank(
            pairCount: 1,
            channelsPerPair: 2,
            sampleRate: AudioSocketWriter.wireSampleRate
        )
    }

    public func start() throws {
        // Idempotent: refuse to spawn a second writer while the previous
        // one is still alive. The `writerActive` flag is the source of
        // truth — `task != nil && !task.isCancelled` is racy because the
        // detached body continues running between cancel() and the next
        // await checkpoint. Two concurrent writers each pacing at 100/s
        // showed up downstream as 200+/s on the wire, overflowing the
        // 8 KB kernel pipe and corrupting s16le framing.
        //
        // Reservation is a single compare-and-set under `lock` so the
        // check-and-claim is atomic. On connect() failure we clear the
        // flag before re-throwing.
        let myGeneration: UInt64? = lock.withLock { () -> UInt64? in
            guard !writerActive else { return nil }
            writerActive = true
            writerGeneration &+= 1
            return writerGeneration
        }
        guard let myGeneration else { return }
        do {
            try connect()
        } catch {
            lock.withLock { writerActive = false }
            throw error
        }
        task = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.runLoop()
            guard let self else { return }
            // Only clear the flag if our generation still matches.
            // If stop() ran after we started (or another start() bumped
            // the generation), this stale cleanup would otherwise wipe
            // the NEW writer's flag and allow a double-spawn next time.
            self.lock.withLock {
                if self.writerGeneration == myGeneration {
                    self.writerActive = false
                }
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        lock.lock(); defer { lock.unlock() }
        if fd >= 0 { Darwin.close(fd); fd = -1 }
        writerActive = false
        // Invalidate any in-flight Task cleanup from a previous
        // generation so a stop()+start() cycle's stale Task exit
        // cannot clobber the new generation's `writerActive`.
        writerGeneration &+= 1
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
        // Planar staging, heap-allocated once for the life of the loop rather
        // than as a `[[Float]]`. Both consumers below (`RingBuffer.read` and
        // `EqualizerBank.process`) want a channel-pointer TABLE, and taking
        // one out of a Swift array means letting `baseAddress` escape its
        // `withUnsafeMutableBufferPointer` closure — which this loop used to
        // do. Allocating the slabs outright makes the pointers legitimately
        // stable instead of relying on the array's storage not moving.
        let planar: [UnsafeMutablePointer<Float>] = (0..<channelCount).map { _ in
            let slab = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
            slab.initialize(repeating: 0, count: frameCount)
            return slab
        }
        let planarTable = UnsafeMutablePointer<UnsafeMutablePointer<Float>>
            .allocate(capacity: channelCount)
        for ch in 0..<channelCount { planarTable[ch] = planar[ch] }
        defer {
            planarTable.deallocate()
            for slab in planar {
                slab.deinitialize(count: frameCount)
                slab.deallocate()
            }
        }

        // CRITICAL: pace at exactly real-time rate. Without this, the
        // previous version drained the ring at whatever rate the loop
        // could iterate (observed: 218 pkts/sec vs the 100 pkts/sec
        // playback rate — exactly 2x). OwnTone happily accepted the
        // over-rate stream into its FIFO, and the AirPlay receiver
        // (Xiaomi Sound) then accumulated 5+ seconds of lag because
        // playback drains at 100 pkts/sec while the pipe fills at 218.
        // Pacing on wall-clock guarantees the average rate matches the
        // capture rate regardless of how SCK chunks its callbacks.
        let packetIntervalNs: UInt64 = UInt64(
            (Double(frameCount) / sampleRate) * 1_000_000_000
        )

        var nextRead: Int64 = -1
        var startNs = Clock.nowNs()
        var packetsConsumed: UInt64 = 0

        // Longest ramp segment, in frames. Computed once: `sampleRate` and
        // `masterRampMs` are both constant for the life of the writer, and the
        // per-packet path must stay allocation-free.
        let masterRampFrames = max(
            1, Int(Self.masterRampMs / 1000.0 * sampleRate)
        )

        while !Task.isCancelled {
            // 1. Wall-clock pacing. Sleep until our scheduled wake-up for
            //    THIS packet. If we're already late by ≤ 2 packets, we
            //    proceed without sleeping — the next iteration's sleep
            //    catches back up. If we're late by MORE than 2 packets
            //    (likely woke up after a system sleep, debugger pause, or
            //    long GC stall) we re-anchor `startNs` so we don't try to
            //    "catch up" by emitting a 100-packet burst that would
            //    instantly overflow the 8 KB kernel pipe and corrupt
            //    s16le framing. The invariant we restore is:
            //        packetsConsumed * packetIntervalNs ≈ now - startNs
            let targetNs = startNs &+ packetsConsumed &* packetIntervalNs
            var packetStartNs = targetNs
            let nowNs = Clock.nowNs()
            if nowNs < packetStartNs {
                try? await Task.sleep(nanoseconds: packetStartNs &- nowNs)
                if Task.isCancelled { return }
            } else if nowNs > packetStartNs &+ (packetIntervalNs &* 2) {
                startNs = nowNs &- packetsConsumed &* packetIntervalNs
                packetStartNs = nowNs
            }

            // 2. Pull one packet's worth of frames from the ring. If the
            //    ring is starved (less than `frameCount` fresh frames),
            //    emit silence rather than block — keeps the AirPlay
            //    receiver's playout clock in lockstep with our wall clock.
            //    Skipping packets instead would let the receiver drain
            //    its jitter buffer to zero and audibly stutter.
            let writePos = ring.writePosition
            if nextRead < 0 { nextRead = max(0, writePos - Int64(frameCount)) }

            if writePos - nextRead < Int64(frameCount) {
                // Underrun: ring doesn't have a full packet's worth of
                // unread frames yet. Emit silence so the AirPlay receiver
                // keeps its playout clock locked, but do NOT advance
                // `nextRead` — the frames were never consumed and are
                // still going to land in the ring shortly. Advancing here
                // strands `nextRead` permanently AHEAD of `writePos`:
                // SCK delivers in jittery ~10ms callbacks of variable
                // size (sometimes 480 frames, sometimes 1024), and any
                // single underrun would shift `nextRead` past the next
                // SCK arrival, turning ONE missed callback into perpetual
                // silence for the rest of the session. Symptom in the
                // wild: airplayWriter=pkts:142 underrun:141 (99% silence
                // on the wire) and AirPlay receivers playing one initial
                // burst then going silent forever.
                for ch in 0..<channelCount {
                    planar[ch].update(repeating: 0, count: frameCount)
                }
                underrunPackets &+= 1
            } else {
                ring.read(at: nextRead, frames: frameCount, into: planarTable)
                nextRead &+= Int64(frameCount)
            }

            packet.withUnsafeMutableBufferPointer { out in
                renderPacket(
                    planar: planarTable,
                    packet: out.baseAddress!,
                    masterRampFrames: masterRampFrames
                )
            }

            // 3. Send one well-framed packet down the Unix stream socket.
            // Darwin.send() may legally write only part of the buffer. For
            // raw s16le over SOCK_STREAM, continuing with the next packet
            // after a short write permanently shifts the receiver's frame
            // boundaries, so loop until this packet is complete or stop the
            // writer on a hard error.
            let sendResult = packet.withUnsafeBytes { raw -> (
                bytes: Int, error: Int32, partials: UInt64
            ) in
                guard let base = raw.baseAddress else {
                    return (0, EINVAL, 0)
                }
                var offset = 0
                var partials: UInt64 = 0
                while offset < bytesPerPacket {
                    let remaining = bytesPerPacket - offset
                    let s = lock.withLock { fd }
                    guard s >= 0 else { return (offset, EBADF, partials) }
                    let n = Darwin.send(
                        s, base.advanced(by: offset), remaining, 0
                    )
                    if n < 0 {
                        let e = errno
                        if e == EINTR { continue }
                        return (offset, e, partials)
                    }
                    if n == 0 {
                        return (offset, EPIPE, partials)
                    }
                    if n < remaining {
                        partials &+= 1
                    }
                    offset += n
                }
                return (offset, 0, partials)
            }
            if sendResult.partials > 0 {
                partialSends &+= sendResult.partials
                lastSendError =
                    "short send recovered n=\(sendResult.bytes)"
            }
            if sendResult.error != 0 {
                lastSendError =
                    "send errno=\(sendResult.error) after \(sendResult.bytes) bytes"
                break
            }
            packetsSent &+= 1
            bytesSent &+= UInt64(sendResult.bytes)
            packetsConsumed &+= 1
        }
    }

    /// Turn one packet's worth of planar Float32 into the interleaved s16le
    /// the socket carries: group EQ, then the master fader's ramp, then the
    /// clamp, then the cast. See the AirPlay-group-equalizer note above for
    /// why that is the order.
    ///
    /// One lock acquisition per packet (not per sample); the ramp itself runs
    /// off loop-local values so the fader can be dragged concurrently without
    /// ever contending here.
    ///
    /// Internal rather than inlined in `runLoop` so the stage ORDER — the part
    /// a test can actually pin — is exercisable without a socket, a sidecar,
    /// or wall-clock pacing.
    ///
    /// - Parameters:
    ///   - planar: `channelCount` channel pointers, `frameCount` frames each.
    ///     Equalised IN PLACE.
    ///   - packet: `frameCount * channelCount` interleaved s16 slots.
    ///   - masterRampFrames: longest ramp segment, in frames.
    func renderPacket(
        planar: UnsafeMutablePointer<UnsafeMutablePointer<Float>>,
        packet: UnsafeMutablePointer<Int16>,
        masterRampFrames: Int
    ) {
        // AirPlay group tone control, ahead of the master fader. A flat curve
        // takes the bank's fast exit and leaves the samples byte-identical, so
        // a user who never opens the group EQ gets the pre-feature wire format
        // exactly. Silence from an underrun is fed through too, deliberately:
        // the filter state has to keep decaying, or the next real packet would
        // splice onto a stale tail.
        equalizer.process(
            pair: 0,
            channels: planar,
            channelOffset: 0,
            channelCount: channelCount,
            frames: frameCount
        )

        let masterSnapshot = masterGainLock.withLock {
            (current: _masterGainCurrent, target: _masterGainTarget)
        }
        var gain = masterSnapshot.current
        let ramping = masterSnapshot.current != masterSnapshot.target
        let rampFrames = min(frameCount, max(1, masterRampFrames))
        let gainStep = ramping
            ? (masterSnapshot.target - masterSnapshot.current) / Float(rampFrames)
            : 0
        for f in 0..<frameCount {
            if ramping {
                gain = f < rampFrames ? gain + gainStep : masterSnapshot.target
            }
            for ch in 0..<channelCount {
                let v = planar[ch][f] * gain
                // Backstop, not the primary limiter: the equalizer bank has
                // already brought the signal inside ±1 and the master fader
                // only attenuates. It is what guarantees the cast below can
                // never wrap a full-scale sample round to the opposite sign.
                let clamped = max(-1.0, min(1.0, v))
                packet[f * channelCount + ch] = Int16(clamped * 32_767.0)
            }
        }
        if ramping {
            // `rampFrames <= frameCount` by construction, so a ramp always
            // completes within the packet that started it. Persisting the
            // reached value (rather than the target) keeps this honest if that
            // ever stops being true.
            let reached = frameCount >= rampFrames ? masterSnapshot.target : gain
            masterGainLock.withLock { _masterGainCurrent = reached }
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        self.lock(); defer { self.unlock() }
        return body()
    }
}
