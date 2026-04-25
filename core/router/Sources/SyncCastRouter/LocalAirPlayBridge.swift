import Foundation
import CoreAudio
import AudioToolbox
import Darwin
import os.lock

/// Bridges OwnTone's player-clock-driven PCM output to a single local
/// CoreAudio device, so the device stays in lockstep with AirPlay 2
/// receivers in *whole-home AirPlay mode* (Strategy 1).
///
/// Data flow:
///
///   ```
///   OwnTone player thread
///       │
///       ▼  (44.1 kHz s16le 2ch, 1408-byte packets)
///   output.fifo  (named pipe)
///       │
///       ▼  (read by LocalFifoBroadcaster in the Python sidecar)
///   /tmp/syncast-$UID.localfifo.sock  (SOCK_STREAM, multi-listen)
///       │
///       ▼  (THIS class — one TCP-shaped read per bridge instance)
///   internal Float32 non-interleaved ring buffer (~200 ms)
///       │
///       ▼  (AUHAL render callback, real-time CoreAudio thread)
///   physical CoreAudio device (built-in speakers, USB DAC, HDMI/DP, ...)
///   ```
///
/// Why a *separate* ring buffer (independent from SCKCapture's):
/// SCKCapture's ring is fed by the system audio capture — which we do
/// NOT want to play back when whole-home AirPlay mode is active. In
/// whole-home mode, every output (local CoreAudio + AirPlay receivers)
/// is driven by OwnTone's player. Reusing SCKCapture's ring would mix
/// the two clocks and re-introduce drift.
///
/// Threading model:
///  * `start()` / `stop()` are called from `Router` (an `actor`); they
///    are NOT real-time.
///  * The reader runs in a detached `Task` and does blocking `read(2)`
///    on the Unix socket. It's a non-RT thread; it allocates a small
///    interleaved-Int16 staging buffer once and reuses it.
///  * The render callback runs on a CoreAudio real-time thread; it does
///    NO allocations and only takes the unfair lock to read state once.
///
/// Latency budget: the internal ring is sized for ~200 ms (8192 frames at
/// 44.1 kHz, rounded up to a power of two for cheap modulo). The
/// broadcaster's per-client SO_SNDBUF is ~50 ms, so the end-to-end
/// queue depth for an idle, well-paced bridge sits well under 100 ms —
/// matched against AirPlay's ~1.8 s buffer by OwnTone's per-output
/// `delay_ms`. Drift correction is OwnTone's job (it owns the player
/// clock); we just consume.
public final class LocalAirPlayBridge: @unchecked Sendable {
    public enum BridgeError: Error {
        case audioComponentNotFound
        case audioUnitInstantiationFailed(OSStatus)
        case configurationFailed(OSStatus)
        case startFailed(OSStatus)
        case socketCreationFailed(Int32)
        case socketConnectFailed(Int32)
    }

    public let deviceID: AudioObjectID
    public let deviceUID: String
    public let socketPath: URL
    /// Bridge feed format. After the sidecar tee refactor (~b0543d5
    /// follow-up), we no longer use OwnTone's fifo OUTPUT module —
    /// instead the sidecar tees Swift's native PCM (matching
    /// `AudioSocketWriter`'s wire format at SCKCapture's sample rate)
    /// directly to bridge clients. So sample rate is now 48 kHz with
    /// 480-frame packets (= 1920 bytes s16le 2ch). Opening AUHAL at
    /// 48 kHz also skips CoreAudio's resampler.
    public let inboundSampleRate: Double = 48_000
    public let channelCount: Int = 2
    /// 480 frames * 2 channels * 2 bytes = 1920 bytes per packet.
    /// Same as Swift's `AudioSocketWriter.frameCount` (480) at
    /// 48 kHz — matches the wire format the sidecar tees.
    public let packetBytes: Int = 1920

    /// Internal ring buffer: ~200 ms of 44.1 kHz stereo, rounded up to
    /// the next power of two for cheap modulo arithmetic in
    /// `RingBuffer`. 8820 frames = 200 ms at 44.1 kHz → next pow2 is
    /// 16384. We deliberately use the same `RingBuffer` type as the
    /// capture path so the producer/consumer atomic-ordering audit is
    /// shared.
    public let ringCapacityFrames: Int = 16_384
    private let ring: RingBuffer

    // AUHAL state
    private var unit: AudioUnit?
    private let stateLock = OSAllocatedUnfairLock()
    private var initialized = false
    private var refConOpaque: UnsafeMutableRawPointer?
    /// Pre-allocated channel pointer slot for the render callback.
    private let outPtrs: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    /// Pre-allocated planar Float32 staging buffer used by the SOCKET
    /// reader to convert s16le interleaved → Float32 non-interleaved
    /// once per packet, then `RingBuffer.write` straight into the ring.
    /// Sized to one packet's worth of frames (352).
    private let scratchFloat: [UnsafeMutablePointer<Float>]
    private let scratchFramesPerPacket: Int
    /// Pre-allocated 2-slot channel-pointer buffer for the ring-write
    /// call. RingBuffer.write expects a `UnsafePointer<UnsafePointer<Float>>`
    /// pointing at exactly `channelCount` channel pointers. Allocating
    /// it per-iteration was burning ~31 alloc/dealloc cycles per second
    /// per bridge — not real-time-thread, but still wasteful and the
    /// header above the call site claimed "no heap allocation". Now that
    /// claim is correct.
    private let chansPtr: UnsafeMutablePointer<UnsafePointer<Float>>

    /// Diagnostic — every successful socket read of one full packet
    /// bumps this. Should advance at ~31 Hz (44.1 kHz / 1408 B per
    /// packet ÷ 4 B per frame ÷ 352 frames). Zero after a few seconds
    /// of "running" → broadcaster is starved or not connected.
    public private(set) var packetsReceived: UInt64 = 0
    /// Diagnostic — render callback ticks. Same role as
    /// `LocalOutput.renderTickCount`.
    public private(set) var renderTickCount: UInt64 = 0
    /// Diagnostic — peak abs sample of the most recent rendered block.
    public private(set) var lastRenderPeak: Float = 0
    /// Diagnostic — most recent error string (empty if everything's OK).
    public private(set) var lastError: String = ""

    // Reader-task state
    private var fd: Int32 = -1
    private var readerTask: Task<Void, Never>?
    /// Monotonic counter the render callback reads from. Producer is
    /// the reader Task; consumer is the AUHAL render callback. Updated
    /// via `RingBuffer.write` (which has its own atomic publish) so
    /// nothing else needs to be atomic here.
    private var readCursor: Int64 = 0

    public init(
        deviceID: AudioObjectID,
        deviceUID: String,
        socketPath: URL
    ) {
        self.deviceID = deviceID
        self.deviceUID = deviceUID
        self.socketPath = socketPath
        self.ring = RingBuffer(channelCount: 2, capacityFrames: 16_384)
        let ptrs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 2)
        let placeholder = UnsafeMutablePointer<Float>.allocate(capacity: 1)
        placeholder.initialize(to: 0)
        ptrs.initialize(repeating: placeholder, count: 2)
        self.outPtrs = ptrs
        // 480 frames per Swift packet (1920 B / 4 B-per-frame for s16 stereo).
        // Matches the sidecar tee's per-packet framing at 48 kHz, which in
        // turn matches Swift's AudioSocketWriter.frameCount.
        let framesPerPacket = 1920 / (2 * MemoryLayout<Int16>.size)
        self.scratchFramesPerPacket = framesPerPacket
        let scratch: [UnsafeMutablePointer<Float>] = (0..<2).map { _ in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: framesPerPacket)
            p.initialize(repeating: 0, count: framesPerPacket)
            return p
        }
        self.scratchFloat = scratch
        // chansPtr holds two `UnsafePointer<Float>` slots that the reader
        // populates with addresses of `scratchFloat[0]` / `scratchFloat[1]`
        // each iteration. The pointed-to pointers don't change since
        // `scratchFloat` is `let` — we could in principle initialize once
        // here, but populating each iteration keeps the read loop's
        // intent obvious and the cost is two stores per packet.
        let chans = UnsafeMutablePointer<UnsafePointer<Float>>.allocate(capacity: 2)
        chans[0] = UnsafePointer(scratch[0])
        chans[1] = UnsafePointer(scratch[1])
        self.chansPtr = chans
    }

    deinit {
        stop()
        outPtrs.deallocate()
        chansPtr.deallocate()
        for p in scratchFloat {
            p.deinitialize(count: scratchFramesPerPacket)
            p.deallocate()
        }
    }

    // MARK: - Lifecycle

    /// Open AUHAL on the target device, connect to the broadcast socket,
    /// and start the reader task. Idempotent — calling start() on an
    /// already-running bridge is a no-op.
    public func start() throws {
        if initialized { return }
        try openSocket()
        do {
            try openAudioUnit()
        } catch {
            // AUHAL setup failed — close the socket we just opened so
            // we don't leak the fd.
            closeSocket()
            throw error
        }
        // Reader runs at userInitiated priority. It does blocking
        // syscalls (read on the Unix socket); a Task.detached gives it
        // its own thread without contending on the cooperative pool.
        readerTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.runReader()
        }
        initialized = true
    }

    /// Cancel the reader, close the socket, stop and dispose the AUHAL.
    /// Safe to call multiple times. Same retain-rollback pattern as
    /// LocalOutput.stop() — we only release the +1 retain on `self`
    /// (handed to the AUHAL via inputProcRefCon) AFTER Dispose so the
    /// last in-flight render callback can't fire on a freed object.
    ///
    /// Ordering rationale (mirrors LocalOutput.stop):
    ///   1. Cancel the reader task FIRST so it stops writing into the
    ///      ring while we're tearing the AUHAL down.
    ///   2. Close the socket — this unblocks the reader's `recv` if it
    ///      was sleeping inside the kernel; recv returns -1 / EBADF and
    ///      the loop exits via the cancellation check.
    ///   3. AudioOutputUnitStop drains the in-flight render block
    ///      synchronously. Apple's docs guarantee this; on Tahoe it's
    ///      observably weaker, which is why the +1 retain on self
    ///      handed to the render callback's refCon must outlive the
    ///      Stop call. We release it AFTER Dispose, below.
    ///   4. Uninitialize → Dispose. Reversing has been observed to
    ///      deadlock coreaudiod (see BlackHole issue tracker).
    ///   5. ONLY AFTER Dispose, release the refCon retain so a final
    ///      stragler render callback can still safely call
    ///      `takeUnretainedValue` against a live LocalAirPlayBridge.
    public func stop() {
        // 1. Cancel reader. It may still be blocked in recv until we
        //    close the socket below, but observing this flag once recv
        //    returns is the fast-exit signal.
        readerTask?.cancel()
        readerTask = nil
        // 2. Close the socket. This unblocks any in-flight recv() with
        //    EBADF, letting the reader loop exit.
        closeSocket()
        // 3-4. AUHAL teardown. Skip cleanly if start() failed before
        //      assigning self.unit.
        if let unit = unit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            self.unit = nil
        }
        // 5. Release the +1 retain we placed on self when handing the
        //    opaque pointer to the AUHAL. Done AFTER Dispose so any
        //    in-flight render callback can complete safely. Mark
        //    consumed BEFORE releasing so a defensive re-entry sees
        //    nil and skips the release (impossible in practice, but
        //    cheap insurance against future refactors).
        if let opaque = refConOpaque {
            refConOpaque = nil
            Unmanaged<LocalAirPlayBridge>.fromOpaque(opaque).release()
        }
        initialized = false
    }

    // MARK: - Socket

    private func openSocket() throws {
        let s = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        if s < 0 { throw BridgeError.socketCreationFailed(errno) }
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
            throw BridgeError.socketConnectFailed(e)
        }
        fd = s
    }

    private func closeSocket() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    // MARK: - Reader task

    /// Pulls 1408-byte packets off the broadcast socket, converts s16le
    /// interleaved → Float32 non-interleaved, writes into the ring.
    /// Runs forever until cancelled or the socket EOFs (sidecar
    /// shutdown / mode switch back to stereo).
    private func runReader() async {
        // One-time scaling constant for s16 → float.
        let invInt16Max: Float = 1.0 / 32_767.0
        var buffer = [UInt8](repeating: 0, count: packetBytes)
        while !Task.isCancelled {
            // Read EXACTLY one OwnTone packet per iteration. The
            // sidecar's broadcaster sends one full packet per send(),
            // but TCP-shaped Unix sockets coalesce, so we MUST loop on
            // recv until we have packetBytes bytes — otherwise we'd
            // mis-frame the s16le stream and play noise.
            let ok = await readExactly(into: &buffer, count: packetBytes)
            if !ok { return }
            // De-interleave + convert in-place. The packet contains
            // `framesPerPacket` frames of stereo s16le — read from
            // buffer in 2-byte LE pairs, write into scratchFloat[ch].
            // Avoid Swift Array-of-Int16 allocation by reading directly
            // through the UInt8 array.
            let n = scratchFramesPerPacket
            buffer.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let s16 = raw.bindMemory(to: Int16.self)
                let l = scratchFloat[0]
                let r = scratchFloat[1]
                var src = 0
                for i in 0..<n {
                    // Int16 is host-endian on Apple Silicon (LE) so we
                    // can read directly. If we ever ship to BE we'd
                    // need an explicit byteswap.
                    let lv = s16[src]; src += 1
                    let rv = s16[src]; src += 1
                    l[i] = Float(lv) * invInt16Max
                    r[i] = Float(rv) * invInt16Max
                }
            }
            // Publish to the ring buffer. RingBuffer.write does its own
            // release-store on the cursor so the render callback sees
            // both the new cursor and the new audio data.
            //
            // chansPtr is pre-allocated in init (capacity 2) and freed in
            // deinit, so the read loop runs with zero heap traffic — see
            // the field declaration for rationale.
            chansPtr[0] = UnsafePointer(scratchFloat[0])
            chansPtr[1] = UnsafePointer(scratchFloat[1])
            ring.write(channels: chansPtr, frames: n)
            packetsReceived &+= 1
        }
    }

    /// Blocking ``recv`` loop until exactly `count` bytes are read.
    /// Returns false on EOF / error / cancellation; the caller should
    /// then drop out of the read loop.
    private func readExactly(into buffer: inout [UInt8], count: Int) async -> Bool {
        var got = 0
        while got < count {
            if Task.isCancelled { return false }
            let s = fd
            if s < 0 { return false }
            let n: Int = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.recv(
                    s,
                    base.advanced(by: got),
                    count - got,
                    0
                )
            }
            if n > 0 {
                got += n
                continue
            }
            if n == 0 {
                // EOF — sidecar closed our socket (mode switch back to
                // stereo / shutdown).
                lastError = "socket EOF"
                return false
            }
            // n < 0
            let e = errno
            if e == EINTR { continue }
            // Yield once on EAGAIN to avoid busy-loop. SOCK_STREAM
            // shouldn't normally hit EAGAIN since fd is blocking, but
            // be defensive.
            if e == EAGAIN || e == EWOULDBLOCK {
                try? await Task.sleep(nanoseconds: 1_000_000)  // 1 ms
                continue
            }
            lastError = "recv errno=\(e)"
            return false
        }
        return true
    }

    // MARK: - AUHAL

    /// Set up an AUHAL on `deviceID` and wire its render callback to
    /// our ring buffer. Mirrors LocalOutput.start() with one critical
    /// difference: the AUHAL stream format is set to 44.1 kHz (matches
    /// our incoming feed). CoreAudio resamples to the device's nominal
    /// rate transparently for us — by far the simpler choice over
    /// pre-resampling on the reader thread.
    private func openAudioUnit() throws {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw BridgeError.audioComponentNotFound
        }
        var unitOut: AudioUnit?
        var status = AudioComponentInstanceNew(component, &unitOut)
        guard status == noErr, let unit = unitOut else {
            throw BridgeError.audioUnitInstantiationFailed(status)
        }
        // From here on, EVERY error path must dispose `unit` —
        // AudioComponentInstanceNew has already allocated kernel state.
        // We track success with a sentinel; defer disposes the local
        // unit when the function exits via an error path.
        var unitInitialized = false
        var unitStarted = false
        var unitInstalled = false
        defer {
            if !unitInstalled {
                if unitStarted { AudioOutputUnitStop(unit) }
                if unitInitialized { AudioUnitUninitialize(unit) }
                AudioComponentInstanceDispose(unit)
            }
        }

        // Bind to specific output device.
        var devID = deviceID
        status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &devID,
            UInt32(MemoryLayout<AudioObjectID>.size)
        )
        guard status == noErr else { throw BridgeError.configurationFailed(status) }

        // Stream format: Float32 non-interleaved at OwnTone's fifo rate.
        var format = AudioStreamBasicDescription(
            mSampleRate: inboundSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat
                | kAudioFormatFlagIsPacked
                | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        status = AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            0,
            &format,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        guard status == noErr else { throw BridgeError.configurationFailed(status) }

        // Render callback. Same retain-with-rollback pattern as
        // LocalOutput.start — see that file for the rationale.
        let opaque = Unmanaged.passRetained(self).toOpaque()
        self.refConOpaque = opaque
        var refConInstalled = false
        defer {
            if !refConInstalled {
                self.refConOpaque = nil
                Unmanaged<LocalAirPlayBridge>.fromOpaque(opaque).release()
            }
        }
        var callback = AURenderCallbackStruct(
            inputProc: { (inRefCon, _, _, _, inNumberFrames, ioData) -> OSStatus in
                let owner = Unmanaged<LocalAirPlayBridge>.fromOpaque(inRefCon).takeUnretainedValue()
                return owner.render(frames: Int(inNumberFrames), ioData: ioData)
            },
            inputProcRefCon: opaque
        )
        status = AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input,
            0,
            &callback,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        guard status == noErr else { throw BridgeError.configurationFailed(status) }

        status = AudioUnitInitialize(unit)
        guard status == noErr else { throw BridgeError.configurationFailed(status) }
        unitInitialized = true
        status = AudioOutputUnitStart(unit)
        guard status == noErr else { throw BridgeError.startFailed(status) }
        unitStarted = true

        self.unit = unit
        unitInstalled = true   // Suppresses the AudioUnit-rollback defer.
        refConInstalled = true // Suppresses the refCon-rollback defer.
        // Read cursor lags the writer by ~100 ms so the very first
        // renders see real data even before the broadcaster's first
        // packet has gone through SCK conversion. 4800 frames @ 48 kHz
        // matches LocalOutput.openAudioUnit's identical safety margin.
        stateLock.withLock {
            self.readCursor = max(0, ring.writePosition - Self.baselineBackoffFrames)
        }
    }

    /// 100 ms safety margin between the writer's `writePosition` and the
    /// render callback's `readCursor`. Without this, the bridge ran with
    /// only `frames` (≈ 10 ms) of slack — fine while the AUHAL output
    /// was being CoreAudio-resampled at 44.1 kHz (the resampler dampens
    /// rate skew), but at 48 kHz native the AUHAL's device clock and
    /// AudioSocketWriter's wall-clock pacer drift independently. With a
    /// near-zero margin, cursor periodically lands at exactly `writePos`
    /// and `RingBuffer.read` returns 0 valid frames (zero-fills the
    /// whole AUHAL buffer) — observable as `peak: 0.0000` while pkts
    /// and ticks both advance. 100 ms is the same baseline LocalOutput
    /// uses; the ring is sized 16384 frames ≈ 341 ms so this still
    /// leaves >2x headroom against further drift.
    private static let baselineBackoffFrames: Int64 = 4_800

    /// AUHAL render callback. Real-time thread: NO allocations, NO
    /// async, NO Swift runtime calls beyond the unfair-lock acquire.
    private func render(frames: Int, ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        guard let ioData = ioData else { return noErr }
        let bufList = UnsafeMutableAudioBufferListPointer(ioData)
        if bufList.count < channelCount { return noErr }
        if frames <= 0 { return noErr }

        // Snapshot the cursor under the lock; advance it after we've
        // copied frames out (so a concurrent stop() observing the
        // cursor sees a consistent value).
        let cursor = stateLock.withLock { self.readCursor }
        let writePos = ring.writePosition
        // Default target: trail the writer by `baselineBackoffFrames`
        // (~100 ms) PLUS one render block. That gives every read full
        // coverage even when the device clock and the writer's wall-
        // clock pacer drift; without the baseline margin, cursor would
        // tend to settle exactly at `writePos` and every read would
        // return 0 valid frames (silent peak).
        let target: Int64 = max(
            0, writePos - Self.baselineBackoffFrames - Int64(frames)
        )
        // Resync conditions:
        //   * first call (cursor=0)
        //   * cursor fell so far behind the writer that it's outside
        //     the ring (lost data — sustained stall)
        //   * cursor leapt ahead of the writer (shouldn't happen, but
        //     defend against it)
        //   * cursor drifted more than 250 ms from `target` in either
        //     direction — safety net for clock divergence over time.
        let lowerValid = max(0, writePos - Int64(ring.capacityFrames) + Int64(frames))
        let driftLimitFrames: Int64 = Int64(inboundSampleRate) / 4   // 250 ms
        let needsResync =
            cursor == 0 ||
            cursor < lowerValid ||
            cursor > writePos ||
            abs(cursor - target) > driftLimitFrames
        let startFrame: Int64 = needsResync ? target : cursor

        // Channel-pointer wiring with the pre-allocated outPtrs slot.
        for ch in 0..<channelCount {
            if let raw = bufList[ch].mData {
                outPtrs[ch] = raw.assumingMemoryBound(to: Float.self)
            } else {
                return noErr
            }
        }
        ring.read(at: startFrame, frames: frames, into: outPtrs)

        // Diagnostics + tail accounting. Done on the RT thread but
        // they're just simple writes, no allocation.
        renderTickCount &+= 1
        var pk: Float = 0
        let n = min(frames, 128)
        let p0 = outPtrs[0]
        for i in 0..<n { pk = max(pk, abs(p0[i])) }
        lastRenderPeak = pk

        stateLock.withLock { self.readCursor = startFrame &+ Int64(frames) }
        return noErr
    }
}
