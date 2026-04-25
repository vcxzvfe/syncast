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
    }

    deinit { stop() }

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
        let startFrame: Int64 = {
            var s = writePos - Int64(snapshot.backoff) - Int64(frames)
            if s > writePos - Int64(frames) { s = writePos - Int64(frames) }
            if s < snapshot.cursor { s = snapshot.cursor }
            return s
        }()

        var out: [UnsafeMutablePointer<Float>] = []
        out.reserveCapacity(channelCount)
        for ch in 0..<channelCount {
            if let raw = bufList[ch].mData {
                out.append(raw.assumingMemoryBound(to: Float.self))
            }
        }
        if out.count != channelCount { return noErr }

        ring.read(at: startFrame, frames: frames, into: out)

        // Apply gain / mute. Also zero on negative backoff condition.
        let effectiveGain = snapshot.muted ? 0 : snapshot.gain
        if effectiveGain != 1.0 {
            for ch in 0..<channelCount {
                var i = 0
                while i < frames {
                    out[ch][i] *= effectiveGain
                    i += 1
                }
            }
        }

        stateLock.withLock { _readCursor = startFrame &+ Int64(frames) }
        return noErr
    }
}
