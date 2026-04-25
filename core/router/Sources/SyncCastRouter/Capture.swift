import Foundation
import CoreAudio
import AudioToolbox
import SyncCastDiscovery

/// Captures audio from a CoreAudio input device (typically BlackHole 2ch) and
/// feeds it into a `RingBuffer`.
///
/// The IOProc runs on a real-time CoreAudio thread. Do NOT allocate, take
/// locks, or call into Swift runtime code that may allocate. The ring buffer
/// uses an unfair lock, which is bounded-wait and acceptable here.
public final class Capture {
    public enum CaptureError: Error {
        case deviceNotFound(uid: String)
        case ioProcCreationFailed(OSStatus)
        case startFailed(OSStatus)
        case unsupportedFormat(String)
    }

    public let ringBuffer: RingBuffer
    public let sampleRate: Double
    public let channelCount: Int

    private var deviceID: AudioObjectID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private var running = false

    public init(
        sampleRate: Double = 48_000,
        channelCount: Int = 2,
        ringCapacityFrames: Int = 1 << 18  // 262144 frames @ 48 kHz ≈ 5.46 s
    ) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.ringBuffer = RingBuffer(
            channelCount: channelCount,
            capacityFrames: ringCapacityFrames
        )
    }

    public func start(uid: String) throws {
        let id = try Self.deviceID(forUID: uid)
        try Self.assertNominalSampleRate(id, expected: sampleRate)
        deviceID = id
        var procID: AudioDeviceIOProcID?
        let ringRef = ringBuffer
        let chanCount = channelCount
        let status = AudioDeviceCreateIOProcIDWithBlock(
            &procID,
            id,
            DispatchQueue.global(qos: .userInteractive),
            { _, inInputData, _, _, _ in
                // inInputData is non-nil for input-direction IOProcs. We must
                // copy frames out before this callback returns.
                let inputList = UnsafeMutableAudioBufferListPointer(
                    UnsafeMutablePointer(mutating: inInputData)
                )
                guard inputList.count >= chanCount else { return }
                let frames = Int(inputList[0].mDataByteSize) / MemoryLayout<Float>.size
                if frames == 0 { return }
                var planar: [UnsafePointer<Float>] = []
                planar.reserveCapacity(chanCount)
                for ch in 0..<chanCount {
                    let buf = inputList[ch]
                    if let raw = buf.mData {
                        planar.append(raw.assumingMemoryBound(to: Float.self))
                    }
                }
                if planar.count == chanCount {
                    ringRef.write(channels: planar, frames: frames)
                }
            }
        )
        if status != noErr || procID == nil {
            throw CaptureError.ioProcCreationFailed(status)
        }
        self.ioProcID = procID
        let startStatus = AudioDeviceStart(id, procID)
        if startStatus != noErr {
            throw CaptureError.startFailed(startStatus)
        }
        running = true
    }

    public func stop() {
        guard running, let procID = ioProcID else { return }
        AudioDeviceStop(deviceID, procID)
        AudioDeviceDestroyIOProcID(deviceID, procID)
        ioProcID = nil
        running = false
    }

    deinit {
        stop()
    }

    // MARK: - Helpers

    static func deviceID(forUID uid: String) throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfUid: CFString = uid as CFString
        var resolved: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &cfUid) { uidPtr -> OSStatus in
            var pSize = UInt32(MemoryLayout<CFString>.size)
            return AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                pSize, uidPtr,
                &size, &resolved
            )
        }
        guard status == noErr, resolved != kAudioObjectUnknown else {
            throw CaptureError.deviceNotFound(uid: uid)
        }
        return resolved
    }

    static func assertNominalSampleRate(_ id: AudioObjectID, expected: Double) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate)
        guard status == noErr else {
            throw CaptureError.unsupportedFormat("cannot read sample rate")
        }
        if abs(Double(rate) - expected) > 0.5 {
            throw CaptureError.unsupportedFormat(
                "device sample rate is \(rate) Hz, expected \(expected) Hz"
            )
        }
    }
}
