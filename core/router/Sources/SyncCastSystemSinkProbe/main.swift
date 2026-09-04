import AudioToolbox
import CoreAudio
import Foundation
import SyncCastRouter

// SyncCastSystemSinkProbe — command-line verification for the system-sink
// Stereo path, in the spirit of SyncCastDDCProbe.
//
//   swift run SyncCastSystemSinkProbe            read-only report
//   swift run SyncCastSystemSinkProbe --smoke    end-to-end, restores state
//
// The read-only mode touches nothing. `--smoke` briefly makes the sink the
// system default output (a few seconds), proves that
//   * a Process Tap pinned to the sink captures what is rendered into it, and
//   * changing the SYSTEM volume fires a HAL property notification on the sink
//     — the mechanism the menubar's SystemSinkCoordinator listens to,
// then puts the default output, the default system output and the sink's own
// volume back exactly as it found them.

// MARK: - Small HAL helpers (the probe deliberately does not reach into the
// library's private helpers; it should fail if the PUBLIC surface is wrong).

func deviceID(uid: String) -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var cfUID = uid as CFString
    var result = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = withUnsafeMutablePointer(to: &cfUID) { ptr in
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<CFString>.size), ptr, &size, &result
        )
    }
    return (status == noErr && result != 0) ? result : nil
}

func defaultOutput(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id
    )
    return status == noErr ? id : nil
}

func deviceName(_ id: AudioDeviceID) -> String {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var value: CFString?
    var size = UInt32(MemoryLayout<CFString?>.size)
    let status = withUnsafeMutablePointer(to: &value) { ptr in
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, ptr)
    }
    return status == noErr ? (value as String? ?? "?") : "?"
}

func deviceUID(_ id: AudioDeviceID) -> String? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var value: CFString?
    var size = UInt32(MemoryLayout<CFString?>.size)
    let status = withUnsafeMutablePointer(to: &value) { ptr in
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, ptr)
    }
    return status == noErr ? value as String? : nil
}

func setVolumeScalar(_ id: AudioDeviceID, _ value: Float32) {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyVolumeScalar,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    var v = value
    _ = AudioObjectSetPropertyData(id, &address, 0, nil, 4, &v)
}

func runShell(_ command: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    try? process.run()
    process.waitUntilExit()
}

// MARK: - Read-only report

func report() {
    print("stereo path       : \(StereoOutputPathPolicy.resolvedPath().rawValue)")
    guard let candidate = SystemSinkDevice.resolved else {
        print("sink              : NONE INSTALLED")
        print("                    install SyncCastAudio.driver (scripts/install-driver.sh)")
        print("                    or BlackHole 2ch to enable the system-volume path")
        return
    }
    print("sink              : \(candidate.displayName) (\(candidate.uid), rank \(candidate.rank))")
    guard let id = deviceID(uid: candidate.uid) else {
        print("                    NOT RESOLVABLE — the HAL does not know this UID")
        return
    }
    let law = SystemSinkVolumeLaw.law(forDeviceUID: candidate.uid)
    print("device            : id=\(id) name=\(deviceName(id))")
    print("volume control    : \(SystemSinkDevice.exposesVolumeControl(uid: candidate.uid) ? "yes" : "NO — path will refuse to start")")
    print("current scalar    : \(AggregateDevice.readHardwareVolume(uid: candidate.uid).map { String(format: "%.4f", $0) } ?? "-")")
    print("mute              : \(AggregateDevice.readHardwareMute(uid: candidate.uid).map(String.init) ?? "-")")
    print("law               : minDb=\(law.minDb) (0.5 -> \(String(format: "%.1f", law.decibels(forScalar: 0.5))) dB, amplitude \(String(format: "%.4f", law.amplitude(forScalar: 0.5))))")
    if let current = defaultOutput(kAudioHardwarePropertyDefaultOutputDevice) {
        print("default output    : \(deviceName(current)) [\(deviceUID(current) ?? "?")]")
    }
    if let current = defaultOutput(kAudioHardwarePropertyDefaultSystemOutputDevice) {
        print("default system out: \(deviceName(current)) [\(deviceUID(current) ?? "?")]")
    }
}

// MARK: - Smoke test

final class ListenerBox: @unchecked Sendable {
    var fired = 0
    var lastScalar: Float = -1
}

@available(macOS 14.2, *)
func smoke() -> Int32 {
    guard let candidate = SystemSinkDevice.resolved else {
        print("FAIL: no sink device installed")
        return 1
    }
    guard let sinkID = deviceID(uid: candidate.uid) else {
        print("FAIL: sink \(candidate.uid) not resolvable")
        return 1
    }
    // Refuse to run while something else owns the default output in a way we
    // would disturb: a live SyncCast aggregate means the user's app is
    // playing, and yanking the default under it is exactly the kind of
    // interference this probe must not cause.
    let originalDefault = defaultOutput(kAudioHardwarePropertyDefaultOutputDevice)
    let originalDefaultUID = originalDefault.flatMap { deviceUID($0) }
    if let uid = originalDefaultUID,
       uid.hasPrefix("io.syncast.") {
        print("FAIL: the current default output is a SyncCast-owned device (\(uid)).")
        print("      Stop the running SyncCast first; this probe will not take the default away from it.")
        return 1
    }
    let originalSystemOutput = defaultOutput(kAudioHardwarePropertyDefaultSystemOutputDevice)
    let originalSystemOutputUID = originalSystemOutput.flatMap { deviceUID($0) }
    let originalSinkVolume = AggregateDevice.readHardwareVolume(uid: candidate.uid)
    print("before: default=\(originalDefault.map { deviceName($0) } ?? "?") [\(originalDefaultUID ?? "?")] sinkVolume=\(originalSinkVolume.map { String(format: "%.4f", $0) } ?? "-")")

    var failures: [String] = []

    // --- listener on the sink's volume scalar (what the menubar watches) ---
    let box = ListenerBox()
    let queue = DispatchQueue(label: "io.syncast.probe.listener")
    var scalarAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyVolumeScalar,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    let listener: AudioObjectPropertyListenerBlock = { _, _ in
        box.fired += 1
        box.lastScalar = AggregateDevice.readHardwareVolume(uid: candidate.uid) ?? -1
    }
    let listenerStatus = AudioObjectAddPropertyListenerBlock(
        sinkID, &scalarAddress, queue, listener
    )
    if listenerStatus != noErr {
        failures.append("could not install a volume listener on the sink (OSStatus=\(listenerStatus))")
    }

    // --- take the default output ---
    let sink = SystemSinkDevice(candidate: candidate)
    do {
        try sink.start()
    } catch {
        AudioObjectRemovePropertyListenerBlock(sinkID, &scalarAddress, queue, listener)
        print("FAIL: sink.start() threw: \(error)")
        return 1
    }
    print("sink active: \(sink.diagnostic)")

    // --- pinned process tap + a tone rendered into the sink ---
    // The sink discards audio, so the tone is inaudible; the tap proves the
    // capture leg works on real frames rather than on silence.
    let capture = TapCapture(tapDeviceUID: candidate.uid)
    var tapStarted = false
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        do {
            try await capture.start()
            tapStarted = true
        } catch {
            failures.append("tap on the sink failed to start: \(error)")
        }
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 5)

    if tapStarted {
        // The tone MUST come from another process: `TapCapture` builds a
        // global tap that excludes our own process (so SyncCast never captures
        // its own fan-out), so a tone rendered here would be invisible by
        // design. `afplay` renders to the default output, which is the sink
        // right now — and the sink discards audio, so this is inaudible.
        runShell("afplay /System/Library/Sounds/Submarine.aiff >/dev/null 2>&1 &")
        Thread.sleep(forTimeInterval: 1.5)
    }

    // --- change the SYSTEM volume; the sink must see it ---
    let probeVolumePercent = 40
    runShell("osascript -e 'set volume output volume \(probeVolumePercent)'")
    Thread.sleep(forTimeInterval: 1.0)
    let observedScalar = AggregateDevice.readHardwareVolume(uid: candidate.uid)

    // --- tear everything down, restoring what we found ---
    capture.stop()
    // Restore the sink's own level BEFORE giving the default output back: a
    // write issued in the middle of a default-device switch has been observed
    // not to stick (macOS re-applies its remembered level for the device it is
    // switching away from). Verified again after the switch, with one retry.
    if let originalSinkVolume {
        setVolumeScalar(sinkID, originalSinkVolume)
    }
    let stopped = sink.stop()
    AudioObjectRemovePropertyListenerBlock(sinkID, &scalarAddress, queue, listener)
    if let originalSinkVolume {
        Thread.sleep(forTimeInterval: 0.3)
        if let now = AggregateDevice.readHardwareVolume(uid: candidate.uid),
           abs(now - originalSinkVolume) > 0.005 {
            setVolumeScalar(sinkID, originalSinkVolume)
            Thread.sleep(forTimeInterval: 0.2)
        }
        if let now = AggregateDevice.readHardwareVolume(uid: candidate.uid),
           abs(now - originalSinkVolume) > 0.005 {
            failures.append("could not restore the sink's own volume (\(now) != \(originalSinkVolume))")
        }
    }

    // --- verdict ---
    if !stopped {
        failures.append("sink.stop() reported failure: \(sink.lastStopStatusText ?? "unknown")")
    }
    let restored = defaultOutput(kAudioHardwarePropertyDefaultOutputDevice)
    let restoredUID = restored.flatMap { deviceUID($0) }
    if restoredUID != originalDefaultUID {
        failures.append("default output was NOT restored (\(restoredUID ?? "?") != \(originalDefaultUID ?? "?"))")
    }
    // The SYSTEM output is a separate property and a separate restore path;
    // on this machine the two legitimately point at different devices, which
    // is exactly the case a single-property implementation would corrupt.
    let restoredSystemUID = defaultOutput(kAudioHardwarePropertyDefaultSystemOutputDevice)
        .flatMap { deviceUID($0) }
    if restoredSystemUID != originalSystemOutputUID {
        failures.append("default SYSTEM output was NOT restored (\(restoredSystemUID ?? "?") != \(originalSystemOutputUID ?? "?"))")
    }
    if tapStarted {
        print("tap: written=\(capture.debugBuffersWritten) maxPeak=\(String(format: "%.4f", capture.debugMaxPeak)) asbd={\(capture.debugLastASBD)}")
        if capture.debugBuffersWritten == 0 {
            failures.append("the tap pinned to the sink captured no buffers")
        } else if capture.debugMaxPeak <= 0.01 {
            failures.append("the tap captured buffers but no signal (peak \(capture.debugMaxPeak)) — the tone did not reach it")
        }
    }
    print("volume listener: fired=\(box.fired) lastScalar=\(String(format: "%.4f", box.lastScalar)) readback=\(observedScalar.map { String(format: "%.4f", $0) } ?? "-")")
    if box.fired == 0 {
        failures.append("no property notification fired when the system volume changed")
    }
    if let observedScalar, abs(observedScalar - Float(probeVolumePercent) / 100) > 0.05 {
        failures.append("the sink's scalar did not follow the system volume (\(observedScalar) vs \(Float(probeVolumePercent) / 100))")
    }
    print("after: default=\(restored.map { deviceName($0) } ?? "?") [\(restoredUID ?? "?")] sinkVolume=\(AggregateDevice.readHardwareVolume(uid: candidate.uid).map { String(format: "%.4f", $0) } ?? "-")")

    if failures.isEmpty {
        print("PASS")
        return 0
    }
    for failure in failures { print("FAIL: \(failure)") }
    return 1
}

// MARK: - Entry

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.contains("--smoke") {
    if #available(macOS 14.2, *) {
        exit(smoke())
    } else {
        print("FAIL: --smoke needs macOS 14.2+ (Core Audio Process Tap)")
        exit(1)
    }
} else {
    report()
}
