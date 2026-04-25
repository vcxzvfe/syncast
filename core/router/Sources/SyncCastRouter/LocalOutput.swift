import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation
import os.lock

/// One AUHAL bound to a single CoreAudio output device. Reads from a shared
/// `RingBuffer` at a per-device frame offset (= delay compensation), applies a
/// per-device gain, and writes into the AUHAL output buffer.
///
/// Thread-safety: all property mutations from the app thread go through the
/// `OSAllocatedUnfairLock` and are read once per render callback. The render
/// callback itself runs on a real-time thread; no allocations.
public final class LocalOutput {
    public enum LocalOutputError: Error {
        case audioComponentNotFound
        case audioUnitInstantiationFailed(OSStatus)
        case configurationFailed(OSStatus)
        case startFailed(OSStatus)
    }

    public let deviceID: AudioObjectID
    public let deviceUID: String
    public let sampleRate: Double
    public let channelCount: Int

    private let ring: RingBuffer
    private var unit: AudioUnit?
    private let stateLock = OSAllocatedUnfairLock()
    private var _readBackoffFrames: Int = 0
    private var _gain: Float = 1.0
    private var _muted: Bool = false
    private var _readCursor: Int64 = 0
    private var initialized = false
    /// Pre-allocated channel pointer slot for the render callback so we
    /// don't allocate a Swift Array on every render tick.
    private let outPtrs: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    private let outPtrsCount: Int
    /// Diagnostic — incremented on every AUHAL render callback.
    public private(set) var renderTickCount: UInt64 = 0
    /// Peak abs sample of the most recent rendered frame block.
    public private(set) var lastRenderPeak: Float = 0
    /// Phase counter for SYNCAST_TONE diagnostic mode.
    private var toneSampleIndex: UInt64 = 0

    /// Per-process registry of each open LocalOutput's hardware output
    /// latency in frames (deviceLatency + safetyOffset + streamLatency).
    /// Used by every render() to determine the worst-case latency across
    /// all currently active local outputs and compensate so they all emit
    /// the same captured frame at the same wall-clock instant.
    private static let latencyLock = OSAllocatedUnfairLock()
    nonisolated(unsafe) private static var deviceLatencyFramesByDevID: [String: Int64] = [:]
    /// This output's measured hardware latency in frames.
    private var deviceLatencyFrames: Int64 = 0

    public init(
        deviceID: AudioObjectID,
        deviceUID: String,
        ring: RingBuffer,
        sampleRate: Double = 48_000,
        channelCount: Int = 2
    ) {
        self.deviceID = deviceID
        self.deviceUID = deviceUID
        self.ring = ring
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        // Allocate a single buffer for the render-callback channel pointers.
        let ptrs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: channelCount)
        // Initialize to a placeholder; will be overwritten on every render.
        let placeholder = UnsafeMutablePointer<Float>.allocate(capacity: 1)
        placeholder.initialize(to: 0)
        ptrs.initialize(repeating: placeholder, count: channelCount)
        self.outPtrs = ptrs
        self.outPtrsCount = channelCount
        // We deliberately leak the placeholder; deinit deallocates outPtrs.
        // The actual pointers used are owned by CoreAudio.
    }

    deinit {
        stop()
        outPtrs.deallocate()
    }

    // MARK: - Hardware latency probing

    /// Total output latency in frames for a CoreAudio device:
    ///   device-level latency + safety offset + max stream latency.
    /// Called once per LocalOutput at start time; values are stable for
    /// the lifetime of an AUHAL binding.
    private static func queryOutputLatencyFrames(deviceID: AudioObjectID) -> Int64 {
        let dev = readUInt32Property(deviceID, kAudioDevicePropertyLatency, kAudioDevicePropertyScopeOutput)
        let safety = readUInt32Property(deviceID, kAudioDevicePropertySafetyOffset, kAudioDevicePropertyScopeOutput)
        // Per-stream latency (output-stream side). We sum the largest one.
        var streamAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &streamAddr, 0, nil, &size) == noErr else {
            return Int64(dev + safety)
        }
        let count = Int(size) / MemoryLayout<AudioStreamID>.size
        var streams = Array(repeating: AudioStreamID(0), count: count)
        if AudioObjectGetPropertyData(deviceID, &streamAddr, 0, nil, &size, &streams) != noErr {
            return Int64(dev + safety)
        }
        var maxStreamLat: UInt32 = 0
        for s in streams {
            let l = readUInt32Property(s, kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal)
            if l > maxStreamLat { maxStreamLat = l }
        }
        return Int64(dev + safety + maxStreamLat)
    }

    private static func readUInt32Property(
        _ id: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope
    ) -> UInt32 {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) != noErr {
            return 0
        }
        return value
    }

    public func setRouting(readBackoffFrames: Int, gain: Float, muted: Bool) {
        stateLock.withLock {
            _readBackoffFrames = max(0, readBackoffFrames)
            _gain = max(0, min(1, gain))
            _muted = muted
        }
    }

    public func start() throws {
        guard !initialized else { return }
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw LocalOutputError.audioComponentNotFound
        }
        var unitOut: AudioUnit?
        var status = AudioComponentInstanceNew(component, &unitOut)
        guard status == noErr, let unit = unitOut else {
            throw LocalOutputError.audioUnitInstantiationFailed(status)
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
        guard status == noErr else { throw LocalOutputError.configurationFailed(status) }

        // Set output stream format (Float32 non-interleaved).
        var format = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
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
        guard status == noErr else { throw LocalOutputError.configurationFailed(status) }

        // Render callback.
        var callback = AURenderCallbackStruct(
            inputProc: { (inRefCon, _, _, _, inNumberFrames, ioData) -> OSStatus in
                let owner = Unmanaged<LocalOutput>.fromOpaque(inRefCon).takeUnretainedValue()
                return owner.render(frames: Int(inNumberFrames), ioData: ioData)
            },
            inputProcRefCon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )
        status = AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input,
            0,
            &callback,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        guard status == noErr else { throw LocalOutputError.configurationFailed(status) }

        status = AudioUnitInitialize(unit)
        guard status == noErr else { throw LocalOutputError.configurationFailed(status) }
        status = AudioOutputUnitStart(unit)
        guard status == noErr else { throw LocalOutputError.startFailed(status) }

        self.unit = unit
        self.initialized = true
        // Measure this device's hardware output latency NOW that it's
        // initialized — kAudioDevicePropertyLatency is only stable after
        // the AUHAL has bound. Store globally so peer LocalOutputs can
        // compensate against the worst-case latency in the group.
        let latencyFrames = Self.queryOutputLatencyFrames(deviceID: deviceID)
        deviceLatencyFrames = latencyFrames
        Self.latencyLock.withLock {
            Self.deviceLatencyFramesByDevID[deviceUID] = latencyFrames
        }
        // Initialize read cursor to lag the writer by a sane default (will be
        // re-set on first scheduler plan).
        stateLock.withLock { self._readCursor = max(0, ring.writePosition - 4_800) }
    }

    public func stop() {
        guard let unit = unit else { return }
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        self.unit = nil
        initialized = false
        Self.latencyLock.withLock {
            Self.deviceLatencyFramesByDevID.removeValue(forKey: deviceUID)
        }
    }

    private func render(frames: Int, ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        guard let ioData = ioData else { return noErr }
        let bufList = UnsafeMutableAudioBufferListPointer(ioData)
        guard bufList.count >= channelCount else { return noErr }

        // Read state once.
        let snapshot = stateLock.withLock {
            (gain: _gain, muted: _muted, backoff: _readBackoffFrames, cursor: _readCursor)
        }

        let writePos = ring.writePosition
        // Multi-device sync: every active output reads at the same
        // absolute frame instant by padding the FAST outputs with extra
        // wait so all of them play the SAME captured frame at the same
        // physical time. compensation = (slowest_device_latency - my_latency).
        // Floor base 50ms (2400 frames) so we never underrun.
        let maxLatencyFrames: Int64 = Self.latencyLock.withLock {
            Self.deviceLatencyFramesByDevID.values.max() ?? deviceLatencyFrames
        }
        let baselineFrames: Int64 = 2400  // 50ms floor at 48 kHz
        let compensation = max(0, maxLatencyFrames - deviceLatencyFrames)
        let startFrame: Int64 = max(0, writePos - baselineFrames - compensation - Int64(frames))

        // Use the pre-allocated outPtrs slot — no Swift runtime allocation.
        var allOk = true
        for ch in 0..<channelCount {
            if let raw = bufList[ch].mData {
                outPtrs[ch] = raw.assumingMemoryBound(to: Float.self)
            } else {
                allOk = false
                break
            }
        }
        if !allOk { return noErr }

        // Restored production path — read from ring. Tone diagnostic
        // confirmed AUHAL→device path works (user heard the 440Hz).
        ring.read(at: startFrame, frames: frames, into: outPtrs)

        // Per-render diagnostics: bump tick count + sample peak so the
        // engine can tell whether AUHAL is firing AND emitting non-zero
        // audio. Done before gain is applied (so we measure actual
        // captured audio, not gain-attenuated).
        renderTickCount &+= 1
        var pk: Float = 0
        let n = min(frames, 128)
        let p0 = outPtrs[0]
        for i in 0..<n { pk = max(pk, abs(p0[i])) }
        lastRenderPeak = pk

        // Apply gain / mute. Also zero on negative backoff condition.
        let effectiveGain = snapshot.muted ? Float(0) : snapshot.gain
        if effectiveGain != 1.0 {
            for ch in 0..<channelCount {
                let p = outPtrs[ch]
                var i = 0
                while i < frames {
                    p[i] *= effectiveGain
                    i += 1
                }
            }
        }

        stateLock.withLock { _readCursor = startFrame &+ Int64(frames) }
        return noErr
    }
}
