import Foundation
import CoreAudio
import Darwin

/// System-audio capture using Core Audio Process Tap (macOS 14.2+).
///
/// This backend is intentionally wired behind `SYNCAST_CAPTURE_BACKEND=tap`
/// until it has passed local Stereo, DRM, and sleep/wake validation. It
/// presents the same 48 kHz stereo Float32 planar `RingBuffer` contract as
/// `SCKCapture` so Router and downstream outputs do not need to know which
/// capture source is active.
@available(macOS 14.2, *)
public final class TapCapture: @unchecked Sendable {
    public enum CaptureError: Error, CustomStringConvertible {
        case alreadyRunning
        case processObjectLookupFailed(OSStatus)
        case createTapFailed(OSStatus)
        case tapUIDReadFailed(OSStatus)
        case tapFormatReadFailed(OSStatus)
        case unsupportedFormat(String)
        case createAggregateFailed(OSStatus)
        case ioProcCreationFailed(OSStatus)
        case startFailed(OSStatus)

        public var description: String {
            switch self {
            case .alreadyRunning: return "capture already running"
            case .processObjectLookupFailed(let s): return "process object lookup failed: OSStatus=\(s)"
            case .createTapFailed(let s): return "AudioHardwareCreateProcessTap failed: OSStatus=\(s)"
            case .tapUIDReadFailed(let s): return "could not read tap UID: OSStatus=\(s)"
            case .tapFormatReadFailed(let s): return "could not read tap format: OSStatus=\(s)"
            case .unsupportedFormat(let s): return "unsupported tap format: \(s)"
            case .createAggregateFailed(let s): return "AudioHardwareCreateAggregateDevice failed: OSStatus=\(s)"
            case .ioProcCreationFailed(let s): return "AudioDeviceCreateIOProcIDWithBlock failed: OSStatus=\(s)"
            case .startFailed(let s): return "AudioDeviceStart failed: OSStatus=\(s)"
            }
        }
    }

    public let ringBuffer: RingBuffer
    public let sampleRate: Double
    public let channelCount: Int
    public var onUnexpectedStop: (@Sendable () -> Void)?
    public private(set) var tickCount: UInt64 = 0

    public private(set) var debugBuffersSeen: UInt64 = 0
    public private(set) var debugBuffersWritten: UInt64 = 0
    public private(set) var debugLastReason: String = "not_started"
    public private(set) var debugLastASBD: String = ""
    public private(set) var debugLastPeak: Float = 0
    public private(set) var debugMaxPeak: Float = 0

    private static let aggregateUIDPrefix = "io.syncast.tapaggregate.v1."

    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private var running = false
    private var isNonInterleaved = false
    private var sourceChannelCount = 0

    private let channelPtrs: UnsafeMutablePointer<UnsafePointer<Float>?>
    private let channelPtrsCount: Int
    private static let scratchFrameCapacity = 8192
    private let scratchChannels: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    private let scratchSlabs: [UnsafeMutablePointer<Float>]

    public init(
        sampleRate: Double = 48_000,
        channelCount: Int = 2,
        ringCapacityFrames: Int = 1 << 18
    ) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.ringBuffer = RingBuffer(
            channelCount: channelCount,
            capacityFrames: ringCapacityFrames
        )
        let ptrs = UnsafeMutablePointer<UnsafePointer<Float>?>.allocate(capacity: channelCount)
        ptrs.initialize(repeating: nil, count: channelCount)
        self.channelPtrs = ptrs
        self.channelPtrsCount = channelCount

        var slabs: [UnsafeMutablePointer<Float>] = []
        slabs.reserveCapacity(channelCount)
        for _ in 0..<channelCount {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: Self.scratchFrameCapacity)
            p.initialize(repeating: 0, count: Self.scratchFrameCapacity)
            slabs.append(p)
        }
        self.scratchSlabs = slabs
        let scratchPtrs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: channelCount)
        for i in 0..<channelCount { scratchPtrs[i] = slabs[i] }
        self.scratchChannels = scratchPtrs
    }

    deinit {
        stop()
        channelPtrs.deinitialize(count: channelPtrsCount)
        channelPtrs.deallocate()
        scratchChannels.deallocate()
        for slab in scratchSlabs {
            slab.deinitialize(count: Self.scratchFrameCapacity)
            slab.deallocate()
        }
    }

    public func start() async throws {
        guard !running, tapID == 0, aggregateID == 0, ioProcID == nil else {
            throw CaptureError.alreadyRunning
        }

        let ownProcess = try Self.currentProcessObjectID()
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [ownProcess])
        description.name = "SyncCast System Audio Tap"
        description.isPrivate = true
        description.muteBehavior = CATapMuteBehavior(rawValue: 0) ?? description.muteBehavior

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &newTapID)
        guard status == noErr, newTapID != kAudioObjectUnknown else {
            throw CaptureError.createTapFailed(status)
        }
        tapID = newTapID

        do {
            let tapUID = try Self.readCFStringProperty(tapID, kAudioTapPropertyUID)
            let asbd = try Self.readTapFormat(tapID)
            try configure(format: asbd)
            let aggregate = try Self.createAggregateDevice(tapUID: tapUID)
            aggregateID = aggregate
            Self.setNominalSampleRate(aggregate, rate: sampleRate)
            try startIOProc(on: aggregate)
            running = true
            debugLastReason = "started"
        } catch {
            stop()
            throw error
        }
    }

    public func stop() {
        if let procID = ioProcID, aggregateID != 0 {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        ioProcID = nil
        running = false

        if aggregateID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = 0
        }
        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
        }
        debugLastReason = "stopped"
    }

    @discardableResult
    public static func sweepOrphans() -> Int {
        let myPID = ProcessInfo.processInfo.processIdentifier
        var destroyed = 0
        for id in enumerateAllDevices() {
            guard let uid = readDeviceUID(id),
                  uid.hasPrefix(aggregateUIDPrefix) else {
                continue
            }
            guard let pid = processID(from: uid) else {
                continue
            }
            if pid == myPID || processIsAlive(pid) {
                continue
            }
            if AudioHardwareDestroyAggregateDevice(id) == noErr {
                destroyed += 1
            }
        }
        return destroyed
    }

    private func configure(format asbd: AudioStreamBasicDescription) throws {
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let nonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let channels = Int(asbd.mChannelsPerFrame)
        let formatDescription = Self.describe(asbd)
        debugLastASBD = formatDescription

        guard isFloat, asbd.mBitsPerChannel == 32 else {
            throw CaptureError.unsupportedFormat(formatDescription)
        }
        guard abs(asbd.mSampleRate - sampleRate) < 0.5 else {
            throw CaptureError.unsupportedFormat(formatDescription)
        }
        guard channels >= channelCount else {
            throw CaptureError.unsupportedFormat(formatDescription)
        }

        isNonInterleaved = nonInterleaved
        sourceChannelCount = channels
    }

    private func startIOProc(on deviceID: AudioObjectID) throws {
        let ringRef = ringBuffer
        let chanCount = channelCount
        let chPtrs = channelPtrs
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(
            &procID,
            deviceID,
            DispatchQueue.global(qos: .userInteractive),
            { [weak self] _, inInputData, _, _, _ in
                guard let self else { return }
                self.debugBuffersSeen &+= 1
                let inputList = UnsafeMutableAudioBufferListPointer(
                    UnsafeMutablePointer(mutating: inInputData)
                )
                let frames = Self.frameCount(from: inputList)
                guard frames > 0 else {
                    self.debugLastReason = "zero_frames"
                    return
                }
                guard frames <= Self.scratchFrameCapacity else {
                    self.debugLastReason = "frame_block_too_large"
                    return
                }

                if self.isNonInterleaved {
                    guard inputList.count >= chanCount else {
                        self.debugLastReason = "not_enough_buffers"
                        return
                    }
                    var ok = true
                    for ch in 0..<chanCount {
                        guard let raw = inputList[ch].mData else {
                            ok = false
                            break
                        }
                        chPtrs[ch] = UnsafePointer(raw.assumingMemoryBound(to: Float.self))
                    }
                    guard ok else {
                        self.debugLastReason = "nil_channel_data"
                        return
                    }
                } else {
                    guard inputList.count >= 1, let raw = inputList[0].mData else {
                        self.debugLastReason = "no_interleaved_data"
                        return
                    }
                    let interleaved = raw.assumingMemoryBound(to: Float.self)
                    self.deinterleave(
                        interleaved,
                        frames: frames,
                        sourceChannels: max(self.sourceChannelCount, chanCount)
                    )
                    for ch in 0..<chanCount {
                        chPtrs[ch] = UnsafePointer(self.scratchSlabs[ch])
                    }
                }

                chPtrs.withMemoryRebound(to: UnsafePointer<Float>.self, capacity: chanCount) { rebound in
                    ringRef.write(channels: rebound, frames: frames)
                }
                self.debugLastPeak = Self.peak(chPtrs[0], frames: frames)
                self.debugMaxPeak = max(self.debugMaxPeak, self.debugLastPeak)
                self.debugBuffersWritten &+= 1
                self.tickCount &+= 1
                self.debugLastReason = "ok"
            }
        )
        guard status == noErr, let created = procID else {
            throw CaptureError.ioProcCreationFailed(status)
        }
        ioProcID = created

        let startStatus = AudioDeviceStart(deviceID, created)
        guard startStatus == noErr else {
            throw CaptureError.startFailed(startStatus)
        }
    }

    private func deinterleave(
        _ interleaved: UnsafePointer<Float>,
        frames: Int,
        sourceChannels: Int
    ) {
        for frame in 0..<frames {
            let base = frame * sourceChannels
            for ch in 0..<channelCount {
                scratchSlabs[ch][frame] = interleaved[base + ch]
            }
        }
    }

    public func diagnosticReport() -> String {
        "backend=\(backendName) seen=\(debugBuffersSeen) written=\(debugBuffersWritten) ticks=\(tickCount) peak=\(String(format: "%.4f", debugLastPeak))/\(String(format: "%.4f", debugMaxPeak)) asbd={\(debugLastASBD)} last=\(debugLastReason)"
    }

    private static func currentProcessObjectID() throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid = getpid()
        var processObject = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let qSize = UInt32(MemoryLayout<pid_t>.size)
        let status = withUnsafePointer(to: &pid) { pidPtr -> OSStatus in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                qSize,
                pidPtr,
                &size,
                &processObject
            )
        }
        guard status == noErr, processObject != kAudioObjectUnknown else {
            throw CaptureError.processObjectLookupFailed(status)
        }
        return processObject
    }

    private static func readCFStringProperty(
        _ objectID: AudioObjectID,
        _ selector: AudioObjectPropertySelector
    ) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let result = value as String? else {
            throw CaptureError.tapUIDReadFailed(status)
        }
        return result
    }

    private static func readTapFormat(_ tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr else {
            throw CaptureError.tapFormatReadFailed(status)
        }
        return asbd
    }

    private static func createAggregateDevice(tapUID: String) throws -> AudioObjectID {
        let pid = ProcessInfo.processInfo.processIdentifier
        let uid = "\(aggregateUIDPrefix)\(pid).\(UUID().uuidString)"
        let tapConfig: [String: Any] = [
            kAudioSubTapUIDKey as String: tapUID,
            kAudioSubTapDriftCompensationKey as String: UInt32(0),
        ]
        let composition: [String: Any] = [
            kAudioAggregateDeviceUIDKey as String: uid,
            kAudioAggregateDeviceNameKey as String: "SyncCast Process Tap Input",
            kAudioAggregateDeviceIsPrivateKey as String: 1,
            kAudioAggregateDeviceTapAutoStartKey as String: 1,
            kAudioAggregateDeviceTapListKey as String: [tapConfig],
        ]

        var newID: AudioObjectID = 0
        let status = AudioHardwareCreateAggregateDevice(
            composition as CFDictionary,
            &newID
        )
        guard status == noErr, newID != 0 else {
            throw CaptureError.createAggregateFailed(status)
        }
        return newID
    }

    private static func setNominalSampleRate(_ id: AudioObjectID, rate: Double) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = Float64(rate)
        let size = UInt32(MemoryLayout<Float64>.size)
        _ = AudioObjectSetPropertyData(id, &address, 0, nil, size, &value)
    }

    private static func processID(from uid: String) -> pid_t? {
        guard uid.hasPrefix(aggregateUIDPrefix) else { return nil }
        let suffix = uid.dropFirst(aggregateUIDPrefix.count)
        guard let pidPart = suffix.split(separator: ".", maxSplits: 1).first,
              let pid = Int32(pidPart),
              pid > 0 else {
            return nil
        }
        return pid_t(pid)
    }

    private static func processIsAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    private static func readDeviceUID(_ id: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfUID: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { ptr in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let uid = cfUID as String? else { return nil }
        return uid
    }

    private static func enumerateAllDevices() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        ) == noErr else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var ids = Array(repeating: AudioObjectID(0), count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &ids
        ) == noErr else {
            return []
        }
        return ids
    }

    private static func frameCount(from inputList: UnsafeMutableAudioBufferListPointer) -> Int {
        guard inputList.count > 0 else { return 0 }
        let bytes = Int(inputList[0].mDataByteSize)
        let channels = max(1, Int(inputList[0].mNumberChannels))
        return bytes / (MemoryLayout<Float>.size * channels)
    }

    private static func peak(_ pointer: UnsafePointer<Float>?, frames: Int) -> Float {
        guard let pointer, frames > 0 else { return 0 }
        var result: Float = 0
        for i in 0..<frames {
            result = max(result, abs(pointer[i]))
        }
        return result
    }

    private static func describe(_ asbd: AudioStreamBasicDescription) -> String {
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let nonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        return "rate=\(asbd.mSampleRate) ch=\(asbd.mChannelsPerFrame) bits=\(asbd.mBitsPerChannel) bpf=\(asbd.mBytesPerFrame) float=\(isFloat) nonInterleaved=\(nonInterleaved) flags=0x\(String(asbd.mFormatFlags, radix: 16))"
    }
}

@available(macOS 14.2, *)
extension TapCapture: SystemAudioCapture {
    public var backendName: String { "tap" }
}
