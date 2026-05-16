import Foundation
import CoreAudio
import AudioToolbox
import os.lock
import SyncCastDiscovery

public struct PassiveCaptureResult: Codable, Sendable {
    public let referencePath: String
    public let microphonePath: String
    public let metadataPath: String
    public let outputDirectory: String
    public let sampleRate: Int
    public let channelCount: Int
    public let durationSec: Double
    public let maxDelayMs: Int
    public let referenceFrames: Int
    public let microphoneFrames: Int
    public let validReferenceFrames: Int
    public let backend: String
    public let microphoneDeviceID: AudioDeviceID?
    public let currentDelayMs: Int?
    public let contextSignature: String?
    public let delayLocked: Bool?
    public let enabledAirplayCount: Int?
    public let activeAirplayCount: Int?
    public let airplayTimingEpoch: UInt64?
    public let syncContextState: String?
    public let syncContextReason: String?
    public let syncContextRevision: UInt64?
    public let syncContextUpdatedUnix: Double?
    public let devices: [Device]?
    public let airplayConnectionStates: [String: String]?
    public let startedAtNs: UInt64
    public let endedAtNs: UInt64
    public let ringStartFrame: Int64
    public let ringEndFrame: Int64
    public let captureTickStart: UInt64
    public let captureTickEnd: UInt64
    public let microphoneArmedAtNs: UInt64
    public let microphoneFirstSampleAtNs: UInt64?
    public let microphoneStartPaddingFrames: Int
    public let microphoneWarmupFramesDropped: Int
}

public enum PassiveCaptureError: Error {
    case invalidDuration
    case referenceDurationExceedsRingCapacity(maxDurationSec: Double)
    case noInputDevice
    case audioUnitInstantiationFailed(OSStatus)
    case audioUnitConfigurationFailed(OSStatus)
    case audioUnitStartFailed(OSStatus)
    case permissionDenied
    case timedOutWaitingForReferenceFrames
    case timedOutWaitingForMicrophoneStart
}

extension PassiveCaptureError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .invalidDuration:
            return "passive capture duration must be >0s and <=60s, maxDelayMs must be 0...10000"
        case let .referenceDurationExceedsRingCapacity(maxDurationSec):
            return String(
                format: "passive capture duration exceeds capture ring capacity; max %.2fs for current backend",
                maxDurationSec
            )
        case .noInputDevice:
            return "no input device available for passive microphone capture"
        case let .audioUnitInstantiationFailed(status):
            return "passive microphone AudioUnit instantiation failed OSStatus=\(status)"
        case let .audioUnitConfigurationFailed(status):
            return "passive microphone AudioUnit configuration failed OSStatus=\(status)"
        case let .audioUnitStartFailed(status):
            return "passive microphone AudioUnit start failed OSStatus=\(status)"
        case .permissionDenied:
            return "microphone permission denied for passive capture"
        case .timedOutWaitingForReferenceFrames:
            return "timed out waiting for system-audio reference frames"
        case .timedOutWaitingForMicrophoneStart:
            return "timed out waiting for microphone callbacks before passive capture"
        }
    }
}

private struct PassiveMicrophoneCapture: Sendable {
    let samples: [Float]
    let armedAtNs: UInt64
    let firstSampleAtNs: UInt64?
    let startPaddingFrames: Int
    let warmupFramesDropped: Int
}

public struct PassiveMicFrameAlignment: Equatable, Sendable {
    public let copyStartFrame: Int
    public let copyFrameCount: Int
    public let firstSampleAtNs: UInt64?
    public let startPaddingFrames: Int
    public let warmupDropFrames: Int

    public var shouldCopy: Bool {
        copyStartFrame >= 0 && copyFrameCount > 0
    }

    public static func plan(
        callbackFrames: Int,
        sampleRate: Double,
        armedAtNs: UInt64?,
        callbackFirstHostNs: UInt64?,
        remainingCapacityFrames: Int,
        alreadyHasFirstSample: Bool
    ) -> PassiveMicFrameAlignment {
        guard callbackFrames > 0, remainingCapacityFrames > 0 else {
            return .drop(frames: 0)
        }
        guard let armedAtNs else {
            return .drop(frames: callbackFrames)
        }
        let sampleDurationNs = 1_000_000_000.0 / sampleRate
        var copyStartFrame = 0
        if let callbackFirstHostNs, callbackFirstHostNs < armedAtNs {
            let elapsedNs = Double(armedAtNs - callbackFirstHostNs)
            copyStartFrame = min(
                callbackFrames,
                Int(ceil(elapsedNs / sampleDurationNs))
            )
        }
        guard copyStartFrame < callbackFrames else {
            return .drop(frames: callbackFrames)
        }
        let firstSampleAtNs: UInt64?
        let startPaddingFrames: Int
        if alreadyHasFirstSample {
            firstSampleAtNs = nil
            startPaddingFrames = 0
        } else if let callbackFirstHostNs {
            let offsetNs = UInt64(
                (Double(copyStartFrame) * sampleDurationNs).rounded()
            )
            let firstNs = callbackFirstHostNs + offsetNs
            firstSampleAtNs = firstNs
            if firstNs > armedAtNs {
                let paddingNs = Double(firstNs - armedAtNs)
                startPaddingFrames = Int(
                    (paddingNs / sampleDurationNs).rounded()
                )
            } else {
                startPaddingFrames = 0
            }
        } else {
            firstSampleAtNs = nil
            startPaddingFrames = 0
        }
        return PassiveMicFrameAlignment(
            copyStartFrame: copyStartFrame,
            copyFrameCount: min(
                callbackFrames - copyStartFrame,
                remainingCapacityFrames
            ),
            firstSampleAtNs: firstSampleAtNs,
            startPaddingFrames: startPaddingFrames,
            warmupDropFrames: 0
        )
    }

    private static func drop(frames: Int) -> PassiveMicFrameAlignment {
        PassiveMicFrameAlignment(
            copyStartFrame: -1,
            copyFrameCount: 0,
            firstSampleAtNs: nil,
            startPaddingFrames: 0,
            warmupDropFrames: max(0, frames)
        )
    }
}

public enum PassiveCapture {
    public static func capture(
        captureBackend: any SystemAudioCapture,
        microphoneDeviceID: AudioDeviceID?,
        durationSec: Double,
        maxDelayMs: Int,
        outputDirectory: URL?,
        currentDelayMs: Int? = nil,
        contextSignature: String? = nil,
        delayLocked: Bool? = nil,
        enabledAirplayCount: Int? = nil,
        activeAirplayCount: Int? = nil,
        airplayTimingEpoch: UInt64? = nil,
        syncContextState: String? = nil,
        syncContextReason: String? = nil,
        syncContextRevision: UInt64? = nil,
        syncContextUpdatedUnix: Double? = nil,
        devices: [Device]? = nil,
        airplayConnectionStates: [String: String]? = nil
    ) async throws -> PassiveCaptureResult {
        guard durationSec > 0, durationSec <= 60, maxDelayMs >= 0,
              maxDelayMs <= 10_000
        else {
            throw PassiveCaptureError.invalidDuration
        }
        let sampleRate = Int(captureBackend.sampleRate.rounded())
        let referenceFrames = max(1, Int(durationSec * captureBackend.sampleRate))
        let maxReferenceFrames = max(1, captureBackend.ringBuffer.capacityFrames - 2048)
        guard referenceFrames <= maxReferenceFrames else {
            let maxDuration = Double(maxReferenceFrames) / captureBackend.sampleRate
            throw PassiveCaptureError.referenceDurationExceedsRingCapacity(
                maxDurationSec: maxDuration
            )
        }
        let maxDelayFrames = Int(
            Double(maxDelayMs) / 1000.0 * captureBackend.sampleRate
        )
        let microphoneFrames = referenceFrames + maxDelayFrames
        let dir = try prepareOutputDirectory(outputDirectory)
        let micRecorder = try PassiveMicRecorder(
            deviceID: microphoneDeviceID,
            frames: microphoneFrames,
            sampleRate: captureBackend.sampleRate
        )
        defer { micRecorder.stop() }
        try await micRecorder.waitUntilReady(timeoutSec: 2.0)
        let micArm = micRecorder.arm()
        let startedAtNs = micArm.armedAtNs
        let captureTickStart = captureBackend.tickCount
        let ringStartFrame = captureBackend.ringBuffer.writePosition

        async let micCapture: PassiveMicrophoneCapture = micRecorder.recordArmed(
            timeoutSec: Double(microphoneFrames) / captureBackend.sampleRate + 2.0
        )
        _ = try await waitForReferenceFrames(
            ring: captureBackend.ringBuffer,
            startFrame: ringStartFrame,
            frames: referenceFrames,
            timeoutSec: durationSec + 2.0
        )
        let (reference, validReferenceFrames) = readReference(
            ring: captureBackend.ringBuffer,
            channelCount: captureBackend.channelCount,
            startFrame: ringStartFrame,
            frames: referenceFrames
        )
        let microphone = try await micCapture
        let endedAtNs = Clock.nowNs()
        let captureTickEnd = captureBackend.tickCount
        let ringEndFrame = captureBackend.ringBuffer.writePosition

        let referenceURL = dir.appendingPathComponent("reference.wav")
        let microphoneURL = dir.appendingPathComponent("microphone.wav")
        let metadataURL = dir.appendingPathComponent("metadata.json")
        try WavWriter.writePCM16(
            channels: reference,
            sampleRate: sampleRate,
            to: referenceURL
        )
        try WavWriter.writePCM16(
            channels: [microphone.samples],
            sampleRate: sampleRate,
            to: microphoneURL
        )
        let result = PassiveCaptureResult(
            referencePath: referenceURL.path,
            microphonePath: microphoneURL.path,
            metadataPath: metadataURL.path,
            outputDirectory: dir.path,
            sampleRate: sampleRate,
            channelCount: captureBackend.channelCount,
            durationSec: durationSec,
            maxDelayMs: maxDelayMs,
            referenceFrames: referenceFrames,
            microphoneFrames: microphone.samples.count,
            validReferenceFrames: validReferenceFrames,
            backend: captureBackend.backendName,
            microphoneDeviceID: microphoneDeviceID,
            currentDelayMs: currentDelayMs,
            contextSignature: contextSignature,
            delayLocked: delayLocked,
            enabledAirplayCount: enabledAirplayCount,
            activeAirplayCount: activeAirplayCount,
            airplayTimingEpoch: airplayTimingEpoch,
            syncContextState: syncContextState,
            syncContextReason: syncContextReason,
            syncContextRevision: syncContextRevision,
            syncContextUpdatedUnix: syncContextUpdatedUnix,
            devices: devices,
            airplayConnectionStates: airplayConnectionStates,
            startedAtNs: startedAtNs,
            endedAtNs: endedAtNs,
            ringStartFrame: ringStartFrame,
            ringEndFrame: ringEndFrame,
            captureTickStart: captureTickStart,
            captureTickEnd: captureTickEnd,
            microphoneArmedAtNs: microphone.armedAtNs,
            microphoneFirstSampleAtNs: microphone.firstSampleAtNs,
            microphoneStartPaddingFrames: microphone.startPaddingFrames,
            microphoneWarmupFramesDropped: microphone.warmupFramesDropped
        )
        let metadata = try JSONEncoder.syncastPretty.encode(result)
        try metadata.write(to: metadataURL, options: .atomic)
        return result
    }

    private static func prepareOutputDirectory(_ requested: URL?) throws -> URL {
        let dir: URL
        if let requested {
            dir = requested
        } else {
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "")
            dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("syncast-passive-\(stamp)")
        }
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )
        return dir
    }

    private static func waitForReferenceFrames(
        ring: RingBuffer,
        startFrame: Int64,
        frames: Int,
        timeoutSec: Double
    ) async throws -> Int {
        let target = startFrame + Int64(frames)
        let deadline = Clock.nowNs()
            + UInt64(max(0.1, timeoutSec) * 1_000_000_000.0)
        while ring.writePosition < target {
            if Clock.nowNs() >= deadline {
                throw PassiveCaptureError.timedOutWaitingForReferenceFrames
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return max(0, Int(min(Int64(frames), ring.writePosition - startFrame)))
    }

    private static func readReference(
        ring: RingBuffer,
        channelCount: Int,
        startFrame: Int64,
        frames: Int
    ) -> (channels: [[Float]], validFrames: Int) {
        var pointers: [UnsafeMutablePointer<Float>] = []
        pointers.reserveCapacity(channelCount)
        for _ in 0..<channelCount {
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            pointer.initialize(repeating: 0, count: frames)
            pointers.append(pointer)
        }
        defer {
            for pointer in pointers {
                pointer.deinitialize(count: frames)
                pointer.deallocate()
            }
        }
        let validFrames = pointers.withUnsafeBufferPointer { ptrs in
            ring.read(at: startFrame, frames: frames, into: ptrs.baseAddress!)
        }
        let channels = pointers.map { pointer in
            Array(UnsafeBufferPointer(start: pointer, count: frames))
        }
        return (channels, validFrames)
    }
}

private final class PassiveMicRecorder: @unchecked Sendable {
    private static let kPermissionDenied = OSStatus(bitPattern: UInt32(0x6E6F7065))

    private let requestedFrames: Int
    private let sampleRate: Double
    private let buffer: UnsafeMutablePointer<Float>
    private let context: PassiveMicCaptureContext
    private var unit: AudioUnit?

    init(
        deviceID: AudioDeviceID?,
        frames: Int,
        sampleRate: Double
    ) throws {
        let resolvedDevice = try Self.resolveInputDeviceID(deviceID)
        self.requestedFrames = max(0, frames)
        self.sampleRate = sampleRate
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        buffer.initialize(repeating: 0, count: frames)
        self.buffer = buffer
        let context = PassiveMicCaptureContext(
            buffer: buffer,
            capacity: frames,
            sampleRate: sampleRate
        )
        self.context = context
        let opaque = Unmanaged.passUnretained(context).toOpaque()
        do {
            self.unit = try Self.openInputUnit(
                deviceID: resolvedDevice,
                sampleRate: sampleRate,
                context: context,
                inputCallbackContext: opaque
            )
        } catch {
            buffer.deinitialize(count: max(0, frames))
            buffer.deallocate()
            throw error
        }
    }

    deinit {
        stop()
        buffer.deinitialize(count: requestedFrames)
        buffer.deallocate()
    }

    func stop() {
        guard let unit else { return }
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        self.unit = nil
    }

    func waitUntilReady(timeoutSec: Double) async throws {
        let deadline = Clock.nowNs()
            + UInt64(max(0.1, timeoutSec) * 1_000_000_000.0)
        while !context.hasObservedCallback {
            if Task.isCancelled { throw CancellationError() }
            if Clock.nowNs() >= deadline {
                throw PassiveCaptureError.timedOutWaitingForMicrophoneStart
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func arm() -> (armedAtNs: UInt64, warmupFramesDropped: Int) {
        context.arm()
    }

    func recordArmed(timeoutSec: Double) async throws -> PassiveMicrophoneCapture {
        guard requestedFrames > 0 else {
            let timing = context.timingSnapshot()
            return PassiveMicrophoneCapture(
                samples: [],
                armedAtNs: timing.armedAtNs ?? Clock.nowNs(),
                firstSampleAtNs: timing.firstSampleAtNs,
                startPaddingFrames: timing.startPaddingFrames,
                warmupFramesDropped: timing.warmupFramesDropped
            )
        }
        let deadline = Clock.nowNs()
            + UInt64(max(0.1, timeoutSec) * 1_000_000_000.0)
        while !context.isFull {
            if Task.isCancelled { throw CancellationError() }
            if Clock.nowNs() >= deadline { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let written = context.writtenFrameCount()
        let timing = context.timingSnapshot()
        let padding = max(0, timing.startPaddingFrames)
        var samples = [Float](repeating: 0, count: padding)
        let captured = [Float](unsafeUninitializedCapacity: written) { ptr, count in
            ptr.baseAddress!.update(from: buffer, count: written)
            count = written
        }
        samples.append(contentsOf: captured)
        return PassiveMicrophoneCapture(
            samples: samples,
            armedAtNs: timing.armedAtNs ?? Clock.nowNs(),
            firstSampleAtNs: timing.firstSampleAtNs,
            startPaddingFrames: padding,
            warmupFramesDropped: timing.warmupFramesDropped
        )
    }

    private static func resolveInputDeviceID(
        _ requested: AudioDeviceID?
    ) throws -> AudioDeviceID {
        if let requested, requested != 0 { return requested }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dev: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr, 0, nil, &size, &dev
        )
        guard status == noErr, dev != 0 else {
            throw PassiveCaptureError.noInputDevice
        }
        return dev
    }

    private static func openInputUnit(
        deviceID: AudioDeviceID,
        sampleRate: Double,
        context: PassiveMicCaptureContext,
        inputCallbackContext: UnsafeMutableRawPointer
    ) throws -> AudioUnit {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw PassiveCaptureError.audioUnitInstantiationFailed(-1)
        }
        var unitOut: AudioUnit?
        var status = AudioComponentInstanceNew(component, &unitOut)
        guard status == noErr, let unit = unitOut else {
            throw PassiveCaptureError.audioUnitInstantiationFailed(status)
        }
        var ok = false
        defer {
            if !ok {
                AudioOutputUnitStop(unit)
                AudioUnitUninitialize(unit)
                AudioComponentInstanceDispose(unit)
            }
        }
        func setProp<T>(
            _ selector: AudioUnitPropertyID,
            _ scope: AudioUnitScope,
            _ bus: AudioUnitElement,
            _ value: inout T
        ) throws {
            let status = withUnsafeMutablePointer(to: &value) { pointer in
                AudioUnitSetProperty(
                    unit,
                    selector,
                    scope,
                    bus,
                    pointer,
                    UInt32(MemoryLayout<T>.size)
                )
            }
            if status != noErr {
                throw PassiveCaptureError.audioUnitConfigurationFailed(status)
            }
        }
        var enable: UInt32 = 1
        try setProp(kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enable)
        var disable: UInt32 = 0
        try setProp(kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disable)
        var devID = deviceID
        try setProp(kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &devID)
        var format = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat
                | kAudioFormatFlagIsPacked
                | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        try setProp(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &format)
        var callback = AURenderCallbackStruct(
            inputProc: { refCon, flags, ts, _, frames, _ -> OSStatus in
                let context = Unmanaged<PassiveMicCaptureContext>
                    .fromOpaque(refCon)
                    .takeUnretainedValue()
                return context.fetch(flags: flags, timestamp: ts, frames: frames)
            },
            inputProcRefCon: inputCallbackContext
        )
        try setProp(kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback)

        context.unit = unit
        status = AudioUnitInitialize(unit)
        if status != noErr {
            if status == kPermissionDenied { throw PassiveCaptureError.permissionDenied }
            throw PassiveCaptureError.audioUnitConfigurationFailed(status)
        }
        status = AudioOutputUnitStart(unit)
        if status != noErr {
            if status == kPermissionDenied { throw PassiveCaptureError.permissionDenied }
            throw PassiveCaptureError.audioUnitStartFailed(status)
        }
        ok = true
        return unit
    }
}

private final class PassiveMicCaptureContext {
    let buffer: UnsafeMutablePointer<Float>
    let capacity: Int
    let sampleRate: Double
    var unit: AudioUnit?

    private let lock = OSAllocatedUnfairLock()
    private var written: Int = 0
    private var observedCallback = false
    private var armedAtNs: UInt64?
    private var firstSampleAtNs: UInt64?
    private var startPaddingFrames = 0
    private var warmupFramesDropped = 0
    private let abl: UnsafeMutablePointer<AudioBufferList>
    private let scratch: UnsafeMutablePointer<Float>
    private let scratchCapacity = 8192

    init(
        buffer: UnsafeMutablePointer<Float>,
        capacity: Int,
        sampleRate: Double
    ) {
        self.buffer = buffer
        self.capacity = capacity
        self.sampleRate = sampleRate
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: scratchCapacity)
        scratch.initialize(repeating: 0, count: scratchCapacity)
        self.scratch = scratch
        self.abl = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
        self.abl.pointee = AudioBufferList()
        self.abl.pointee.mNumberBuffers = 1
        self.abl.pointee.mBuffers = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: 0,
            mData: nil
        )
    }

    deinit {
        scratch.deinitialize(count: scratchCapacity)
        scratch.deallocate()
        abl.deallocate()
    }

    var isFull: Bool { lock.withLock { written >= capacity } }
    var hasObservedCallback: Bool { lock.withLock { observedCallback } }
    func writtenFrameCount() -> Int { lock.withLock { written } }
    func arm() -> (armedAtNs: UInt64, warmupFramesDropped: Int) {
        let now = Clock.nowNs()
        return lock.withLock {
            armedAtNs = now
            return (now, warmupFramesDropped)
        }
    }
    func timingSnapshot() -> (
        armedAtNs: UInt64?,
        firstSampleAtNs: UInt64?,
        startPaddingFrames: Int,
        warmupFramesDropped: Int
    ) {
        lock.withLock {
            (
                armedAtNs,
                firstSampleAtNs,
                startPaddingFrames,
                warmupFramesDropped
            )
        }
    }

    func fetch(
        flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timestamp: UnsafePointer<AudioTimeStamp>,
        frames: UInt32
    ) -> OSStatus {
        guard let unit else { return noErr }
        let n = Int(frames)
        guard n > 0, n <= scratchCapacity else { return noErr }
        abl.pointee.mBuffers.mData = UnsafeMutableRawPointer(scratch)
        abl.pointee.mBuffers.mDataByteSize = UInt32(n * MemoryLayout<Float>.size)
        let status = AudioUnitRender(unit, flags, timestamp, 1, frames, abl)
        if status != noErr { return status }
        let stamp = timestamp.pointee
        let callbackFirstHostNs: UInt64?
        if stamp.mFlags.contains(.hostTimeValid) {
            callbackFirstHostNs = Clock.hostTimeToNs(stamp.mHostTime)
        } else {
            callbackFirstHostNs = nil
        }
        let copyPlan = lock.withLock { () -> (start: Int, srcStart: Int, take: Int) in
            observedCallback = true
            let alignment = PassiveMicFrameAlignment.plan(
                callbackFrames: n,
                sampleRate: sampleRate,
                armedAtNs: armedAtNs,
                callbackFirstHostNs: callbackFirstHostNs,
                remainingCapacityFrames: capacity - written,
                alreadyHasFirstSample: firstSampleAtNs != nil
            )
            if alignment.warmupDropFrames > 0 {
                warmupFramesDropped += alignment.warmupDropFrames
                return (-1, 0, 0)
            }
            guard alignment.shouldCopy else { return (-1, 0, 0) }
            if firstSampleAtNs == nil {
                firstSampleAtNs = alignment.firstSampleAtNs
                    ?? armedAtNs.map { max($0, Clock.nowNs()) }
                startPaddingFrames = alignment.startPaddingFrames
            }
            let start = written
            return (start, alignment.copyStartFrame, alignment.copyFrameCount)
        }
        if copyPlan.start < 0 || copyPlan.take <= 0 { return noErr }
        buffer.advanced(by: copyPlan.start)
            .update(from: scratch.advanced(by: copyPlan.srcStart), count: copyPlan.take)
        lock.withLock {
            written = max(written, copyPlan.start + copyPlan.take)
        }
        return noErr
    }
}

private enum WavWriter {
    static func writePCM16(
        channels: [[Float]],
        sampleRate: Int,
        to url: URL
    ) throws {
        guard let first = channels.first else {
            try writeHeaderAndSamples(
                channelCount: 1,
                sampleRate: sampleRate,
                frames: []
            ).write(to: url, options: .atomic)
            return
        }
        let frameCount = first.count
        let channelCount = channels.count
        var interleaved = [Int16]()
        interleaved.reserveCapacity(frameCount * channelCount)
        for frame in 0..<frameCount {
            for channel in channels {
                let sample = frame < channel.count ? channel[frame] : 0
                let clamped = max(-1.0, min(1.0, sample))
                interleaved.append(Int16((clamped * Float(Int16.max)).rounded()))
            }
        }
        try writeHeaderAndSamples(
            channelCount: channelCount,
            sampleRate: sampleRate,
            frames: interleaved
        ).write(to: url, options: .atomic)
    }

    private static func writeHeaderAndSamples(
        channelCount: Int,
        sampleRate: Int,
        frames: [Int16]
    ) -> Data {
        let bytesPerSample = 2
        let dataSize = frames.count * bytesPerSample
        var data = Data()
        data.reserveCapacity(44 + dataSize)
        data.appendASCII("RIFF")
        data.appendLE32(UInt32(36 + dataSize))
        data.appendASCII("WAVE")
        data.appendASCII("fmt ")
        data.appendLE32(16)
        data.appendLE16(1)
        data.appendLE16(UInt16(channelCount))
        data.appendLE32(UInt32(sampleRate))
        data.appendLE32(UInt32(sampleRate * channelCount * bytesPerSample))
        data.appendLE16(UInt16(channelCount * bytesPerSample))
        data.appendLE16(UInt16(bytesPerSample * 8))
        data.appendASCII("data")
        data.appendLE32(UInt32(dataSize))
        for sample in frames {
            data.appendLE16(UInt16(bitPattern: sample))
        }
        return data
    }
}

private extension JSONEncoder {
    static var syncastPretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension Data {
    mutating func appendASCII(_ string: String) {
        append(contentsOf: string.utf8)
    }

    mutating func appendLE16(_ value: UInt16) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
    }

    mutating func appendLE32(_ value: UInt32) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 24) & 0xff))
    }
}
