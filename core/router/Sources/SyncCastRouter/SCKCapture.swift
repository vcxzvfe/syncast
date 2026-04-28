import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia

/// System-audio capture using ScreenCaptureKit (macOS 13+).
///
/// Replaces the previous BlackHole + CoreAudio HAL IOProc path. SCK uses
/// the Screen Recording TCC class (not Microphone), works under ad-hoc
/// code signing, and doesn't require the user to install BlackHole or
/// change their default audio output.
///
/// See `docs/research/screencapturekit-brief.md` and ADR-007 for the
/// full rationale.
@available(macOS 13.0, *)
public final class SCKCapture: NSObject, @unchecked Sendable {
    public enum CaptureError: Error, CustomStringConvertible {
        case noDisplay
        case permissionDenied
        case alreadyRunning
        case formatMismatch(String)
        case streamError(String)

        public var description: String {
            switch self {
            case .noDisplay: return "no display available"
            case .permissionDenied: return "screen recording permission denied"
            case .alreadyRunning: return "capture already running"
            case .formatMismatch(let s): return "format mismatch: \(s)"
            case .streamError(let s): return "stream error: \(s)"
            }
        }
    }

    public let ringBuffer: RingBuffer
    public let sampleRate: Double
    public let channelCount: Int

    /// Fired from `stream(_:didStopWithError:)` whenever SCK terminates the
    /// capture stream on its own — most commonly `connectionInvalid (-3805)`
    /// after display sleep breaks system-audio capture. The Router wires
    /// this in `init` so it can restart SCK as part of the wake-recovery
    /// `forceLocalDriverRebuild` path; without the notification the Router
    /// has no way to know capture is dead, the new aggregate device has no
    /// source, and the user hears silence until they manually deselect /
    /// reselect each device. Marked @Sendable + invoked from a detached
    /// Task so we never block the SCK delegate queue.
    public var onUnexpectedStop: (@Sendable () -> Void)?

    /// Diagnostic — incremented on every audio sample buffer received.
    /// If this stays at zero after start, capture isn't actually flowing.
    public private(set) var tickCount: UInt64 = 0

    private let ownBundleID: String
    private let audioQueue = DispatchQueue(label: "io.syncast.sck.audio", qos: .userInteractive)
    private var stream: SCStream?
    private var output: AudioStreamOutput?
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private let targetFormat: AVAudioFormat

    public init(
        sampleRate: Double = 48_000,
        channelCount: Int = 2,
        ringCapacityFrames: Int = 1 << 18,
        ownBundleID: String = "io.syncast.menubar"
    ) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.ringBuffer = RingBuffer(
            channelCount: channelCount,
            capacityFrames: ringCapacityFrames
        )
        self.ownBundleID = ownBundleID
        self.targetFormat = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: AVAudioChannelCount(channelCount)
        )!
        super.init()
    }

    /// Start capturing system audio. Throws `permissionDenied` if Screen
    /// Recording is not granted (UI should redirect the user to System
    /// Settings and terminate so they can quit-and-reopen).
    public func start() async throws {
        guard stream == nil else { throw CaptureError.alreadyRunning }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
        } catch {
            throw CaptureError.permissionDenied
        }
        guard let display = content.displays.first else {
            throw CaptureError.noDisplay
        }

        // Defense in depth (per the brief): exclude SyncCast at the
        // *content filter* layer AND set excludesCurrentProcessAudio.
        // The two together close the AUHAL feedback path.
        let ownApps = content.applications.filter {
            $0.bundleIdentifier == ownBundleID
        }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: ownApps,
            exceptingWindows: []
        )

        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = Int(sampleRate)
        cfg.channelCount = channelCount
        // SCK requires a non-zero video size even for audio-only — we just
        // never add a .screen output, so no frames are produced.
        cfg.width = 2
        cfg.height = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        cfg.queueDepth = 6

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        let out = AudioStreamOutput(owner: self)
        try s.addStreamOutput(out, type: .audio, sampleHandlerQueue: audioQueue)
        // Codex must-fix #2: assign BEFORE startCapture so a racing
        // didStopWithError fired during the start() await window finds
        // self.stream === s (instead of nil), correctly nils it, and
        // we observe the failure here. Without this, start() could
        // return success while self.stream points at a dead stream.
        self.stream = s
        self.output = out
        do {
            try await s.startCapture()
        } catch {
            // Clean up the assignments on throw — avoid a "registered
            // but never started" stream lingering in self.stream.
            if self.stream === s {
                self.stream = nil
                self.output = nil
            }
            throw error
        }
    }

    public func stop() {
        guard let s = stream else { return }
        Task {
            do { try await s.stopCapture() } catch {}
        }
        stream = nil
        output = nil
        converter = nil
        sourceFormat = nil
    }

    deinit { stop() }

    // MARK: - Frame conversion

    /// Diagnostic-only counter that tracks how many sample buffers we
    /// inspected vs. how many we successfully wrote to the ring.
    public private(set) var debugBuffersSeen: UInt64 = 0
    public private(set) var debugBuffersWritten: UInt64 = 0
    public private(set) var debugLastReason: String = ""
    public private(set) var debugLastASBD: String = ""
    /// Peak absolute amplitude of the most recent buffer's first channel.
    /// 0.0 = silence (SCK delivering empty data). > 0.001 = real audio.
    public private(set) var debugLastPeak: Float = 0
    public private(set) var debugMaxPeak: Float = 0
    /// Write→Read self-test: peak of data read back from ring immediately
    /// after writing. If this stays 0 while debugMaxPeak > 0, ring.read
    /// is broken.
    public private(set) var debugReadbackPeak: Float = 0
    public private(set) var debugReadbackPos: Int64 = -1
    private var debugLoggedFirstFormat = false

    fileprivate func handle(sampleBuffer sb: CMSampleBuffer) {
        debugBuffersSeen &+= 1
        guard sb.isValid, sb.dataReadiness == .ready else {
            debugLastReason = "invalid_or_not_ready"
            return
        }
        guard let fd = CMSampleBufferGetFormatDescription(sb),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fd) else {
            debugLastReason = "no_asbd"
            return
        }
        let asbd = asbdPtr.pointee

        // Log the first format we see — critical to know what SCK delivers.
        if !debugLoggedFirstFormat {
            debugLoggedFirstFormat = true
            let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
            let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
            let bytesPerFrame = asbd.mBytesPerFrame
            let bitsPerChannel = asbd.mBitsPerChannel
            debugLastASBD = "rate=\(asbd.mSampleRate) ch=\(asbd.mChannelsPerFrame) bits=\(bitsPerChannel) bpf=\(bytesPerFrame) float=\(isFloat) nonInterleaved=\(isNonInterleaved) flags=0x\(String(asbd.mFormatFlags, radix: 16))"
        }

        // FAST PATH: if SCK already gives us 48 kHz Float32 stereo
        // (interleaved or non-interleaved), skip AVAudioConverter and
        // memcpy straight into the ring.
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let frameCount = Int(CMSampleBufferGetNumSamples(sb))

        if isFloat
            && Int(asbd.mSampleRate) == Int(sampleRate)
            && Int(asbd.mChannelsPerFrame) == channelCount
            && asbd.mBitsPerChannel == 32
            && frameCount > 0 {
            if writeFastPath(sb: sb, frames: frameCount, nonInterleaved: isNonInterleaved) {
                debugBuffersWritten &+= 1
                tickCount &+= 1
                return
            }
            // Fall through to converter path on fast-path failure.
        }

        // SLOW PATH: AVAudioConverter for any format SCK throws at us.
        if sourceFormat == nil
            || sourceFormat!.streamDescription.pointee.mSampleRate != asbd.mSampleRate
            || sourceFormat!.streamDescription.pointee.mChannelsPerFrame != asbd.mChannelsPerFrame
            || sourceFormat!.streamDescription.pointee.mFormatFlags != asbd.mFormatFlags {
            var mutable = asbd
            guard let newFmt = AVAudioFormat(streamDescription: &mutable) else {
                debugLastReason = "AVAudioFormat_init_failed"
                return
            }
            sourceFormat = newFmt
            converter = AVAudioConverter(from: newFmt, to: targetFormat)
            converter?.primeMethod = .none
        }
        guard let srcFmt = sourceFormat, let conv = converter else {
            debugLastReason = "no_converter"
            return
        }

        // Use the same two-step ABL extraction helper as the fast path —
        // mandatory with the Assure16ByteAlignment flag.
        guard let (raw, listPtr, blockBuffer) = extractABL(from: sb) else { return }
        defer {
            raw.deallocate()
            _ = blockBuffer
        }

        let frames = AVAudioFrameCount(frameCount)
        guard let inPCM = AVAudioPCMBuffer(pcmFormat: srcFmt, frameCapacity: frames) else {
            debugLastReason = "inPCM_alloc_failed"
            return
        }
        inPCM.frameLength = frames
        let srcBuffers = UnsafeMutableAudioBufferListPointer(listPtr)
        let dstBuffers = UnsafeMutableAudioBufferListPointer(inPCM.mutableAudioBufferList)
        let nb = min(srcBuffers.count, dstBuffers.count)
        for i in 0..<nb {
            let srcBuf = srcBuffers[i]
            var dstBuf = dstBuffers[i]
            let copyBytes = Int(min(srcBuf.mDataByteSize, dstBuf.mDataByteSize))
            if let dst = dstBuf.mData, let src = srcBuf.mData {
                memcpy(dst, src, copyBytes)
            }
            dstBuf.mDataByteSize = UInt32(copyBytes)
            dstBuffers[i] = dstBuf
        }

        let outCapacity = AVAudioFrameCount(
            Double(frameCount) * sampleRate / max(srcFmt.sampleRate, 1)
        ) + 64
        guard let outPCM = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else {
            debugLastReason = "outPCM_alloc_failed"
            return
        }

        var consumed = false
        var convError: NSError?
        let result = conv.convert(to: outPCM, error: &convError) { _, statusPtr in
            if consumed { statusPtr.pointee = .endOfStream; return nil }
            consumed = true
            statusPtr.pointee = .haveData
            return inPCM
        }
        if result == .error {
            debugLastReason = "convert_error=\(convError?.localizedDescription ?? "unknown")"
            return
        }
        guard let chData = outPCM.floatChannelData else {
            debugLastReason = "no_floatChannelData"
            return
        }
        let outFrames = Int(outPCM.frameLength)
        guard outFrames > 0 else {
            debugLastReason = "outFrames=0 (result=\(result.rawValue))"
            return
        }
        let chs = Int(outPCM.format.channelCount)
        let ptrs = UnsafeMutablePointer<UnsafePointer<Float>>.allocate(capacity: chs)
        defer { ptrs.deallocate() }
        for c in 0..<chs {
            ptrs[c] = UnsafePointer(chData[c])
        }
        ringBuffer.write(channels: ptrs, frames: outFrames)
        debugBuffersWritten &+= 1
        debugLastReason = "ok_via_converter"
        tickCount &+= 1
    }

    /// Two-step ABL extraction. The `Assure16ByteAlignment` flag forces a
    /// padded layout whose actual size cannot be predicted from
    /// `MemoryLayout<AudioBufferList>.size + (n-1)*MemoryLayout<AudioBuffer>.size`
    /// alone — Apple's docs require a probe pass to learn the real size.
    /// Skipping the probe is what produced the
    /// `kCMSampleBufferError_ArrayTooSmall` (-12737) bug.
    private func extractABL(
        from sb: CMSampleBuffer
    ) -> (raw: UnsafeMutableRawPointer, listPtr: UnsafeMutablePointer<AudioBufferList>, blockBuffer: CMBlockBuffer)? {
        var needed: Int = 0
        let probe = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb,
            bufferListSizeNeededOut: &needed,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: nil
        )
        guard probe == noErr || probe == kCMSampleBufferError_ArrayTooSmall,
              needed > 0 else {
            debugLastReason = "abl_probe_failed=\(probe)"
            return nil
        }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: needed,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        let listPtr = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb,
            bufferListSizeNeededOut: nil,
            bufferListOut: listPtr,
            bufferListSize: needed,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let bb = blockBuffer else {
            raw.deallocate()
            debugLastReason = "abl_fetch_status=\(status)"
            return nil
        }
        return (raw, listPtr, bb)
    }

    /// Direct memcpy path for SCK buffers that already match our target
    /// format. Returns true on success.
    private func writeFastPath(sb: CMSampleBuffer, frames: Int, nonInterleaved: Bool) -> Bool {
        guard let (raw, listPtr, blockBuffer) = extractABL(from: sb) else { return false }
        defer {
            raw.deallocate()
            // CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer returns
            // a +1 retained CMBlockBuffer — must release per call or we leak.
            _ = blockBuffer  // explicit retention for the lifetime of the access
        }
        let buffers = UnsafeMutableAudioBufferListPointer(listPtr)

        let chPtrs = UnsafeMutablePointer<UnsafePointer<Float>>.allocate(capacity: channelCount)
        defer { chPtrs.deallocate() }

        if nonInterleaved {
            guard buffers.count >= channelCount else {
                debugLastReason = "fast_ni_too_few_buffers=\(buffers.count)"
                return false
            }
            for c in 0..<channelCount {
                guard let m = buffers[c].mData else {
                    debugLastReason = "fast_ni_nil_data ch=\(c)"
                    return false
                }
                chPtrs[c] = UnsafePointer(m.assumingMemoryBound(to: Float.self))
            }
            // Sample peak from channel 0 BEFORE writing to ring.
            let sampleN = min(frames, 256)
            var pk: Float = 0
            let p = chPtrs[0]
            for i in 0..<sampleN { pk = max(pk, abs(p[i])) }
            debugLastPeak = pk
            if pk > debugMaxPeak { debugMaxPeak = pk }
            // Capture writePos BEFORE write
            let posBefore = ringBuffer.writePosition
            ringBuffer.write(channels: chPtrs, frames: frames)
            // Read-back self-test: read what we just wrote and verify peak
            // matches. Catches "write doesn't actually copy" bugs vs
            // "read can't find data" bugs.
            if pk > 0.01 && debugReadbackPeak == 0 {
                let scratch = UnsafeMutablePointer<Float>.allocate(capacity: sampleN)
                let scratchB = UnsafeMutablePointer<Float>.allocate(capacity: sampleN)
                defer { scratch.deallocate(); scratchB.deallocate() }
                let rbPtrs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 2)
                rbPtrs[0] = scratch
                rbPtrs[1] = scratchB
                defer { rbPtrs.deallocate() }
                _ = ringBuffer.read(at: posBefore, frames: sampleN, into: rbPtrs)
                var rbPk: Float = 0
                for i in 0..<sampleN { rbPk = max(rbPk, abs(scratch[i])) }
                debugReadbackPeak = rbPk
                debugReadbackPos = posBefore
            }
        } else {
            guard let m = buffers[0].mData else {
                debugLastReason = "fast_il_nil_data"
                return false
            }
            let interleaved = m.assumingMemoryBound(to: Float.self)
            let scratch = UnsafeMutablePointer<Float>.allocate(capacity: frames * channelCount)
            defer { scratch.deallocate() }
            for c in 0..<channelCount {
                let dst = scratch.advanced(by: c * frames)
                for f in 0..<frames { dst[f] = interleaved[f * channelCount + c] }
                chPtrs[c] = UnsafePointer(dst)
            }
            ringBuffer.write(channels: chPtrs, frames: frames)
        }
        debugLastReason = "ok_fast_path"
        return true
    }
}

@available(macOS 13.0, *)
extension SCKCapture: SCStreamDelegate {
    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Codex must-fix #1: guard same-stream identity. An old stream's
        // deferred didStopWithError callback can land AFTER stop()+start()
        // has assigned a new stream; without this guard we'd null out
        // the new stream and silently lose capture.
        guard stream === self.stream else {
            let stale = "[SCKCapture] stale didStopWithError ignored (old stream after restart): \(error.localizedDescription)\n"
            FileHandle.standardError.write(Data(stale.utf8))
            return
        }
        let msg = "[SCKCapture] stream stopped with error: \(error.localizedDescription) — notifying router\n"
        FileHandle.standardError.write(Data(msg.utf8))
        self.stream = nil
        self.output = nil
        // Snapshot the closure before dispatch — protects against a racing
        // unset (e.g. caller resetting the callback while SCK is tearing
        // down). Detached so we never re-enter SCK's delegate queue.
        let cb = onUnexpectedStop
        Task.detached {
            cb?()
        }
    }
}

/// SCStreamOutput conformance lives in a separate object because the
/// stream retains its outputs and we want SCKCapture to be able to be
/// deallocated normally.
@available(macOS 13.0, *)
private final class AudioStreamOutput: NSObject, SCStreamOutput {
    weak var owner: SCKCapture?
    init(owner: SCKCapture) {
        self.owner = owner
        super.init()
    }
    func stream(_ stream: SCStream,
                didOutputSampleBuffer sb: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio else { return }
        owner?.handle(sampleBuffer: sb)
    }
}
