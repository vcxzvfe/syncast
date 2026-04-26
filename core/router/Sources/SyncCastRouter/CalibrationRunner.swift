import Foundation
import CoreAudio
import AudioToolbox
import Accelerate
import os.lock

/// Mic-based auto-calibration for whole-home delay (Phase B). Emits a
/// click at `now + 2 s`, captures mic from `now − 100 ms` to
/// `anchor + 3 s`, locates the click by vDSP cross-correlation, then
/// `offsetMs = arrival − anchor`. Across pulses: median per device;
/// `recommendedDelayMs = max(AirPlay) − max(local)`; confidence blends
/// σ with median-vs-sample dispersion. Caller supplies a `ClickEmitter`.
public final class CalibrationRunner: @unchecked Sendable {
    /// Per-class trace gate. `false` ⇒ skip string construction entirely.
    public static var verboseTracing: Bool = true
    @inline(__always)
    private static func trace(_ msg: @autoclosure () -> String) {
        guard verboseTracing else { return }
        CalibTrace.log(msg())
    }

    public struct Result: Sendable {
        public let recommendedDelayMs: Int
        public let perDeviceOffsetMs: [String: Int]
        public let confidence: Double
        public init(recommendedDelayMs: Int, perDeviceOffsetMs: [String: Int], confidence: Double) {
            self.recommendedDelayMs = recommendedDelayMs; self.perDeviceOffsetMs = perDeviceOffsetMs; self.confidence = confidence
        }
    }

    public enum CalibrationError: Error {
        case permissionDenied
        case noInputDevice
        case audioUnitInstantiationFailed(OSStatus)
        case audioUnitConfigurationFailed(OSStatus)
        case audioUnitStartFailed(OSStatus)
        case noClickDetected(deviceID: String)
        case noDevicesProvided
        case alreadyRunning
        case cancelled
    }

    public let microphoneDeviceID: AudioDeviceID?

    private let stateLock = OSAllocatedUnfairLock()
    private var _running = false
    private var _cancelled = false
    private var _liveUnit: AudioUnit?

    public init(microphoneDeviceID: AudioDeviceID? = nil) { self.microphoneDeviceID = microphoneDeviceID }

    public func run(
        emitClicksVia emitter: ClickEmitter,
        deviceIDs: [String],
        pulseCount: Int = 5
    ) async throws -> Result {
        guard !deviceIDs.isEmpty else { throw CalibrationError.noDevicesProvided }
        let pulses = max(1, pulseCount)
        try stateLock.withLock {
            if _running { throw CalibrationError.alreadyRunning }
            _running = true
            _cancelled = false
        }
        defer { stateLock.withLock { _running = false } }

        let click = CalibrationSession.clickPulse(sampleRate: Self.sampleRate)
        let template = Self.toMono(click)
        let templateEnergy = template.reduce(0) { $0 + $1 * $1 }
        Self.trace("[CalibrationRunner] run: deviceIDs=\(deviceIDs) pulses=\(pulses) click_frames=\(click.first?.count ?? 0) template_energy=\(String(format: "%.2f", templateEnergy)) mic_caller_provided=\(microphoneDeviceID.map(String.init) ?? "nil")")

        var perDeviceSamples: [String: [Int]] = [:]
        for id in deviceIDs { perDeviceSamples[id] = [] }

        for pulseIdx in 0..<pulses {
            try checkCancelled()
            let anchorNs = Clock.nowNs() &+ Self.anchorOffsetNs
            let captureStartNs = Clock.nowNs() &- Self.preRollNs
            let captureEndNs = anchorNs &+ Self.postRollNs
            Self.trace("[CalibrationRunner] pulse=\(pulseIdx + 1)/\(pulses) anchorNs=\(anchorNs) captureStart=\(captureStartNs) captureEnd=\(captureEndNs) windowMs=\((captureEndNs - captureStartNs) / 1_000_000)")
            // Concurrent capture + emit — capture arms the AU before
            // emit returns. Single capture window covers every requested
            // device; caller invokes once per device when isolation matters.
            async let captured: [Float] = self.captureMic(
                fromHostNs: captureStartNs, toHostNs: captureEndNs
            )
            await emitter.emit(samples: click, at: anchorNs)
            let buf = try await captured
            try checkCancelled()

            // Zero captured_frames ⇒ AU dead (TCC #6 or render dead #3);
            // mic_rms below ~−60 dBFS ⇒ no audible click in the window.
            let bufRms = Self.rms(buf)
            let bufDb = Self.dbfs(bufRms)
            Self.trace("[CalibrationRunner] pulse=\(pulseIdx + 1) captured_frames=\(buf.count) mic_rms=\(bufDb)dB")

            guard let peak = Self.locatePeak(in: buf, template: template) else {
                Self.trace("[CalibrationRunner] pulse=\(pulseIdx + 1) NO_PEAK (template_energy=\(String(format: "%.2f", templateEnergy)) — score below 10% gate)")
                continue
            }
            let peakNs = captureStartNs &+ UInt64(
                Double(peak.sampleIndex) / Self.sampleRate * 1_000_000_000.0
            )
            let offsetMs = Int((Int64(peakNs) - Int64(anchorNs)) / 1_000_000)
            Self.trace("[CalibrationRunner] pulse=\(pulseIdx + 1) PEAK idx=\(peak.sampleIndex) score=\(String(format: "%.4f", peak.score)) offset=\(offsetMs)ms")
            for id in deviceIDs {
                perDeviceSamples[id, default: []].append(offsetMs)
            }
        }

        var perDeviceOffset: [String: Int] = [:]
        var confidences: [Double] = []
        for id in deviceIDs {
            let s = perDeviceSamples[id] ?? []
            guard !s.isEmpty else {
                Self.trace("[CalibrationRunner] FAIL device=\(id) zero peaks across all \(pulses) pulses — throwing noClickDetected")
                throw CalibrationError.noClickDetected(deviceID: id)
            }
            let sorted = s.sorted()
            let median = sorted[sorted.count / 2]
            perDeviceOffset[id] = median
            let conf = Self.confidence(samples: s, median: median)
            confidences.append(conf)
            Self.trace("[CalibrationRunner] device=\(id) samples=\(s) median=\(median)ms confidence=\(String(format: "%.2f", conf))")
        }
        let aggregate = confidences.min() ?? 0.0

        var maxAir = Int.min
        var maxLoc = Int.min
        for (id, off) in perDeviceOffset {
            if Self.isAirPlay(deviceID: id) {
                if off > maxAir { maxAir = off }
            } else if off > maxLoc { maxLoc = off }
        }
        let recommended: Int
        if maxAir == Int.min { recommended = 0 }
        else if maxLoc == Int.min { recommended = max(0, maxAir) }
        else { recommended = max(0, maxAir - maxLoc) }
        Self.trace("[CalibrationRunner] DONE recommended=\(recommended)ms aggregateConf=\(String(format: "%.2f", aggregate)) perDevice=\(perDeviceOffset)")

        return Result(
            recommendedDelayMs: recommended,
            perDeviceOffsetMs: perDeviceOffset,
            confidence: aggregate
        )
    }

    /// Idempotent. Sets cancel flag + disposes live AU; polling loop
    /// observes it at the next 50-ms tick (≤100 ms cancel SLA).
    public func cancel() {
        stateLock.withLockUnchecked {
            _cancelled = true
            if let u = _liveUnit {
                AudioOutputUnitStop(u)
                AudioUnitUninitialize(u)
                AudioComponentInstanceDispose(u)
                _liveUnit = nil
            }
        }
    }

    // MARK: - Constants & helpers

    private static let sampleRate: Double = 48_000
    private static let anchorOffsetNs: UInt64 = 2_000_000_000   // 2 s lead
    private static let preRollNs: UInt64 = 100_000_000          // 100 ms
    private static let postRollNs: UInt64 = 3_000_000_000       // 3 s tail
    /// Four-CC 'nope' — `kAudio_NoPermissionError` on macOS (iOS-tier
    /// symbol isn't exported in the macOS headers).
    private static let kPermissionDenied = OSStatus(bitPattern: UInt32(0x6E6F7065))

    private func checkCancelled() throws {
        if stateLock.withLock({ _cancelled }) { throw CalibrationError.cancelled }
    }

    private func setLiveUnit(_ unit: AudioUnit?) {
        stateLock.withLockUnchecked { _liveUnit = unit }
    }

    private func disposeLiveUnit() {
        stateLock.withLockUnchecked {
            if let u = _liveUnit {
                AudioOutputUnitStop(u)
                AudioUnitUninitialize(u)
                AudioComponentInstanceDispose(u)
                _liveUnit = nil
            }
        }
    }

    private static func toMono(_ samples: [[Float]]) -> [Float] {
        guard let first = samples.first else { return [] }
        let n = first.count
        var out = [Float](repeating: 0, count: n)
        for ch in samples {
            for i in 0..<min(n, ch.count) { out[i] += ch[i] }
        }
        let cnt = Float(samples.count)
        if cnt > 1 { for i in 0..<n { out[i] /= cnt } }
        return out
    }

    /// (1 − σ/100ms) × (1 − 0.5·max|sample−median|/200ms), clamped.
    /// Single-sample case → 0.5 (no consistency info).
    private static func confidence(samples: [Int], median: Int) -> Double {
        if samples.count < 2 { return 0.5 }
        let mean = Double(samples.reduce(0, +)) / Double(samples.count)
        let sumSq = samples.reduce(0.0) { $0 + pow(Double($1) - mean, 2) }
        let sigma = sqrt(sumSq / Double(samples.count - 1))
        var c = 1.0 - min(1.0, sigma / 100.0)
        let medD = Double(median)
        let disp = samples.map { abs(Double($0) - medD) }.max() ?? 0
        c *= 1.0 - 0.5 * min(1.0, disp / 200.0)
        return max(0.0, min(1.0, c))
    }

    private static func isAirPlay(deviceID: String) -> Bool {
        let s = deviceID.lowercased()
        return s.hasPrefix("airplay") || s.hasPrefix("ap2")
            || s.contains("airplay2") || s.contains(":airplay")
    }

    /// Linear-RMS for diagnostic logs. Same vDSP path as PassiveCalibrator.
    private static func rms(_ x: [Float]) -> Float {
        guard !x.isEmpty else { return 0 }
        var ms: Float = 0
        x.withUnsafeBufferPointer { ptr in
            vDSP_measqv(ptr.baseAddress!, 1, &ms, vDSP_Length(ptr.count))
        }
        return sqrt(ms)
    }
    private static func dbfs(_ rms: Float) -> String {
        if rms <= 0 { return "-inf" }
        return String(format: "%.1f", 20.0 * Foundation.log10(Double(rms)))
    }

    /// Sliding cross-correlation via vDSP_conv; |peak| (some DACs invert
    /// polarity) gated at 10 % of template autocorrelation energy.
    static func locatePeak(in signal: [Float], template: [Float]) -> (sampleIndex: Int, score: Float)? {
        guard !signal.isEmpty, !template.isEmpty,
              signal.count >= template.count else { return nil }
        let outCount = signal.count - template.count + 1
        var corr = [Float](repeating: 0, count: outCount)
        signal.withUnsafeBufferPointer { sig in
            template.withUnsafeBufferPointer { tmp in
                corr.withUnsafeMutableBufferPointer { out in
                    vDSP_conv(
                        sig.baseAddress!, 1,
                        tmp.baseAddress!, 1,
                        out.baseAddress!, 1,
                        vDSP_Length(outCount),
                        vDSP_Length(template.count)
                    )
                }
            }
        }
        var peak: Float = 0
        var idx = 0
        for (i, v) in corr.enumerated() {
            let a = abs(v)
            if a > peak { peak = a; idx = i }
        }
        let energy = template.reduce(0) { $0 + $1 * $1 }
        guard energy > 0, peak >= 0.10 * energy else { return nil }
        return (idx, peak / energy)
    }

    // MARK: - Microphone capture

    fileprivate func captureMic(fromHostNs startNs: UInt64, toHostNs endNs: UInt64) async throws -> [Float] {
        try checkCancelled()
        let durationNs = endNs > startNs ? (endNs &- startNs) : 0
        let frames = Int((Double(durationNs) / 1_000_000_000.0) * Self.sampleRate)
        guard frames > 0 else { return [] }
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        buffer.initialize(repeating: 0, count: frames)
        defer {
            buffer.deinitialize(count: frames)
            buffer.deallocate()
        }
        let context = MicCaptureContext(buffer: buffer, capacity: frames)
        let opaque = Unmanaged.passUnretained(context).toOpaque()
        let resolvedDevice: AudioDeviceID
        do {
            resolvedDevice = try resolveInputDeviceID()
        } catch {
            Self.trace("[CalibrationRunner] captureMic: FAILED to resolve mic device: \(error)")
            throw error
        }
        let unit: AudioUnit
        do {
            unit = try Self.openInputUnit(
                deviceID: resolvedDevice,
                inputCallbackContext: opaque
            )
            Self.trace("[CalibrationRunner] captureMic: AU opened+started OK dev=\(resolvedDevice) target_frames=\(frames)")
        } catch {
            Self.trace("[CalibrationRunner] captureMic: AU FAILED (\(error)) — TCC (hyp #6) if .permissionDenied")
            throw error
        }
        setLiveUnit(unit)
        do {
            // Poll every 50 ms — honours ≤100 ms cancel SLA.
            while !context.isFull {
                try checkCancelled()
                if Clock.nowNs() >= endNs { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        } catch {
            disposeLiveUnit()
            throw error
        }
        disposeLiveUnit()
        let written = min(frames, context.writtenFrameCount())
        Self.trace("[CalibrationRunner] captureMic: AU torn down written=\(written)/\(frames) frames")
        return [Float](unsafeUninitializedCapacity: written) { ptr, count in
            ptr.baseAddress!.update(from: buffer, count: written)
            count = written
        }
    }

    private func resolveInputDeviceID() throws -> AudioDeviceID {
        if let id = microphoneDeviceID, id != 0 { return id }
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
        guard status == noErr, dev != 0 else { throw CalibrationError.noInputDevice }
        return dev
    }

    /// AUHAL with EnableIO flipped: input bus 1 on, output bus 0 off.
    /// Input "render callback" is data-available; we pull frames via
    /// `AudioUnitRender`. TCC denial surfaces as `kPermissionDenied`.
    private static func openInputUnit(
        deviceID: AudioDeviceID,
        inputCallbackContext: UnsafeMutableRawPointer
    ) throws -> AudioUnit {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw CalibrationError.audioUnitInstantiationFailed(-1)
        }
        var unitOut: AudioUnit?
        var status = AudioComponentInstanceNew(component, &unitOut)
        guard status == noErr, let unit = unitOut else {
            throw CalibrationError.audioUnitInstantiationFailed(status)
        }
        var ok = false
        defer {
            if !ok {
                AudioOutputUnitStop(unit)
                AudioUnitUninitialize(unit)
                AudioComponentInstanceDispose(unit)
            }
        }

        // Helper: set one AU property; throw on non-noErr. POD-only.
        func setProp<T>(_ sel: AudioUnitPropertyID, _ scope: AudioUnitScope, _ bus: AudioUnitElement, _ value: inout T) throws {
            let s = withUnsafeMutablePointer(to: &value) { p -> OSStatus in
                AudioUnitSetProperty(unit, sel, scope, bus, p, UInt32(MemoryLayout<T>.size))
            }
            if s != noErr { throw CalibrationError.audioUnitConfigurationFailed(s) }
        }
        var enable: UInt32 = 1
        try setProp(kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enable)
        var disable: UInt32 = 0
        try setProp(kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disable)
        var devID = deviceID
        try setProp(kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &devID)
        var fmt = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0
        )
        try setProp(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &fmt)
        var callback = AURenderCallbackStruct(
            inputProc: { (inRefCon, flags, ts, _, frames, _) -> OSStatus in
                let ctx = Unmanaged<MicCaptureContext>.fromOpaque(inRefCon).takeUnretainedValue()
                return ctx.fetch(fromUnit: ctx.unit, flags: flags, timestamp: ts, frames: frames)
            },
            inputProcRefCon: inputCallbackContext
        )
        try setProp(kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback)

        let ctxObj = Unmanaged<MicCaptureContext>.fromOpaque(inputCallbackContext).takeUnretainedValue()
        ctxObj.unit = unit

        status = AudioUnitInitialize(unit)
        if status != noErr {
            if status == kPermissionDenied { throw CalibrationError.permissionDenied }
            throw CalibrationError.audioUnitConfigurationFailed(status)
        }
        status = AudioOutputUnitStart(unit)
        if status != noErr {
            if status == kPermissionDenied { throw CalibrationError.permissionDenied }
            throw CalibrationError.audioUnitStartFailed(status)
        }
        ok = true
        return unit
    }
}

/// Injects the click into the live pipeline — implementations splice
/// `samples` into SCKCapture's ringBuffer at the anchor frame.
public protocol ClickEmitter: Sendable {
    func emit(samples: [[Float]], at anchorNs: UInt64) async
}

/// AU input-callback state. memcpy's frames from CoreAudio scratch
/// into our run-owned destination under unfair lock.
private final class MicCaptureContext {
    let buffer: UnsafeMutablePointer<Float>
    let capacity: Int
    var unit: AudioUnit?

    private let lock = OSAllocatedUnfairLock()
    private var written: Int = 0
    private let abl: UnsafeMutablePointer<AudioBufferList>
    private let scratch: UnsafeMutablePointer<Float>
    private let scratchCapacity: Int = 4096

    init(buffer: UnsafeMutablePointer<Float>, capacity: Int) {
        self.buffer = buffer
        self.capacity = capacity
        let p = UnsafeMutablePointer<Float>.allocate(capacity: scratchCapacity)
        p.initialize(repeating: 0, count: scratchCapacity)
        self.scratch = p
        self.abl = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
        self.abl.pointee = AudioBufferList()
        self.abl.pointee.mNumberBuffers = 1
        self.abl.pointee.mBuffers = AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: nil)
    }

    deinit {
        scratch.deinitialize(count: scratchCapacity)
        scratch.deallocate()
        abl.deallocate()
    }

    var isFull: Bool { lock.withLock { written >= capacity } }
    func writtenFrameCount() -> Int { lock.withLock { written } }

    func fetch(
        fromUnit unit: AudioUnit?,
        flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timestamp: UnsafePointer<AudioTimeStamp>,
        frames: UInt32
    ) -> OSStatus {
        guard let unit = unit else { return noErr }
        let n = Int(frames)
        guard n > 0, n <= scratchCapacity else { return noErr }
        abl.pointee.mBuffers.mData = UnsafeMutableRawPointer(scratch)
        abl.pointee.mBuffers.mDataByteSize = UInt32(n * MemoryLayout<Float>.size)
        let status = AudioUnitRender(unit, flags, timestamp, 1, frames, abl)
        if status != noErr { return status }
        let start: Int = lock.withLock {
            let avail = capacity - written
            return avail > 0 ? written : -1
        }
        if start < 0 { return noErr }
        let take = min(n, capacity - start)
        buffer.advanced(by: start).update(from: scratch, count: take)
        lock.withLock { written = start + take }
        return noErr
    }
}
