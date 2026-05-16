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
    public let sampleRate: Double = 48_000

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
    private struct ScheduledOverlay {
        let startNs: UInt64
        let samples: [[Float]]
        let frames: Int
        var mixedFrames: Int = 0
    }
    private var scheduledOverlays: [ScheduledOverlay] = []
    public private(set) var overlaysScheduled: UInt64 = 0
    public private(set) var overlayFramesScheduled: UInt64 = 0
    public private(set) var overlayFramesMixed: UInt64 = 0
    public private(set) var overlaysDroppedLate: UInt64 = 0

    public init(ring: RingBuffer, socketPath: URL) {
        self.ring = ring
        self.socketPath = socketPath
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
        scheduledOverlays.removeAll()
        // Invalidate any in-flight Task cleanup from a previous
        // generation so a stop()+start() cycle's stale Task exit
        // cannot clobber the new generation's `writerActive`.
        writerGeneration &+= 1
    }

    /// Schedule a short stereo probe to be mixed into the outgoing
    /// AirPlay-bound PCM at a wall-clock time. This is used by
    /// `ActiveCalibrator` instead of writing probes into `RingBuffer`:
    /// writing into the ring advances its write cursor and permanently
    /// adds backlog, which made repeated 100 ms chirps appear about
    /// 100 ms later on every cycle. Overlay mixing preserves the capture
    /// queue's timeline while still sending the probe through OwnTone.
    @discardableResult
    public func scheduleStereoOverlay(samples: [[Float]], atNs: UInt64) -> Bool {
        guard samples.count >= channelCount,
              !samples[0].isEmpty,
              samples[0].count == samples[1].count
        else { return false }
        let frames = samples[0].count
        return lock.withLock {
            guard writerActive, fd >= 0 else { return false }
            scheduledOverlays.append(.init(
                startNs: atNs,
                samples: Array(samples.prefix(channelCount)),
                frames: frames
            ))
            overlaysScheduled &+= 1
            overlayFramesScheduled &+= UInt64(frames)
            return true
        }
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
                    for f in 0..<frameCount { planar[ch][f] = 0 }
                }
                underrunPackets &+= 1
            } else {
                let outPtrs = planar.indices.map { i in
                    planar[i].withUnsafeMutableBufferPointer { $0.baseAddress! }
                }
                ring.read(at: nextRead, frames: frameCount, into: outPtrs)
                nextRead &+= Int64(frameCount)
            }

            mixScheduledOverlays(
                into: &planar, packetStartNs: packetStartNs,
                packetIntervalNs: packetIntervalNs
            )
            for f in 0..<frameCount {
                for ch in 0..<channelCount {
                    let v = planar[ch][f]
                    let clamped = max(-1.0, min(1.0, v))
                    packet[f * channelCount + ch] = Int16(clamped * 32_767.0)
                }
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

    private func mixScheduledOverlays(
        into planar: inout [[Float]],
        packetStartNs: UInt64,
        packetIntervalNs: UInt64
    ) {
        let packetEndNs = packetStartNs &+ packetIntervalNs
        lock.withLock {
            var droppedLate = 0
            scheduledOverlays.removeAll { overlay in
                let durationNs = UInt64(
                    Double(overlay.frames) / sampleRate * 1_000_000_000.0
                )
                let expired = overlay.startNs &+ durationNs <= packetStartNs
                if expired, overlay.mixedFrames < overlay.frames {
                    droppedLate += 1
                }
                return expired
            }
            if droppedLate > 0 {
                overlaysDroppedLate &+= UInt64(droppedLate)
            }
            for index in scheduledOverlays.indices {
                let overlay = scheduledOverlays[index]
                let durationNs = UInt64(
                    Double(overlay.frames) / sampleRate * 1_000_000_000.0
                )
                let overlayEndNs = overlay.startNs &+ durationNs
                if overlay.startNs >= packetEndNs || overlayEndNs <= packetStartNs {
                    continue
                }

                let packetFrameStart: Int
                let overlayFrameStart: Int
                if overlay.startNs > packetStartNs {
                    packetFrameStart = min(
                        frameCount,
                        Int(ceil(
                            Double(overlay.startNs - packetStartNs)
                                / 1_000_000_000.0 * sampleRate
                        ))
                    )
                    overlayFrameStart = 0
                } else {
                    packetFrameStart = 0
                    overlayFrameStart = min(
                        overlay.frames,
                        Int(floor(
                            Double(packetStartNs - overlay.startNs)
                                / 1_000_000_000.0 * sampleRate
                        ))
                    )
                }

                var mixedFramesThisPacket = 0
                for f in packetFrameStart..<frameCount {
                    let overlayIndex = overlayFrameStart + f - packetFrameStart
                    if overlayIndex >= overlay.frames { break }
                    for ch in 0..<min(channelCount, overlay.samples.count) {
                        planar[ch][f] += overlay.samples[ch][overlayIndex]
                    }
                    mixedFramesThisPacket += 1
                }
                if mixedFramesThisPacket > 0 {
                    scheduledOverlays[index].mixedFrames = min(
                        overlay.frames,
                        scheduledOverlays[index].mixedFrames + mixedFramesThisPacket
                    )
                    overlayFramesMixed &+= UInt64(mixedFramesThisPacket)
                }
            }
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        self.lock(); defer { self.unlock() }
        return body()
    }
}
