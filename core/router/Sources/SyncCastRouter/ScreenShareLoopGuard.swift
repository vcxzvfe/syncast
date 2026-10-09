import Foundation
import CoreAudio
import Darwin

// Screen-sharing feedback-loop guard for the system-sink path.
//
// # The loop
//
// With a LAN receiver live, SyncCast plays this Mac's audio on another Mac.
// If this Mac is ALSO showing that Mac's screen through Screen Sharing (the
// high-performance mode carries the remote Mac's audio), the remote audio
// comes back:
//
//     sink tap → LAN link → receiver Mac's speakers → Screen Sharing
//       captures the receiver Mac's audio → this Mac plays it into the
//       default output (the sink) → sink tap → …
//
// A digital loop with no acoustic damping: any sound circulates, grows until
// it saturates near full scale, and keeps going after the music stops, on
// every output at once. Observed on real hardware: a sustained high-pitched
// squeal on all speakers, mostly-clipped samples (the receiver counted ~4 %
// of all samples above full scale), and the only process rendering into the
// sink was the conferencing daemon carrying the Screen Sharing session.
//
// # The cut
//
// The tap already excludes SyncCast's own process. While a LAN leg is live
// and the Screen Sharing app is running, the guard also excludes whichever
// processes are playing Screen Sharing's return audio into the sink. Music
// from every other app still reaches every speaker; only the echo is dropped.
// The exclusion is lifted as soon as either condition ends, so the
// conferencing daemon's other job (FaceTime calls) is untouched whenever
// Screen Sharing is not open.

/// One process that is currently rendering audio into the sink.
public struct SinkRenderer: Equatable, Sendable {
    public let processObjectID: AudioObjectID
    public let pid: pid_t
    public let bundleID: String?
    public let executablePath: String?

    public init(
        processObjectID: AudioObjectID,
        pid: pid_t,
        bundleID: String?,
        executablePath: String?
    ) {
        self.processObjectID = processObjectID
        self.pid = pid
        self.bundleID = bundleID
        self.executablePath = executablePath
    }
}

/// Pure decision (unit-checkable).
public enum ScreenShareLoopGuard {

    /// Processes that play a Screen Sharing session's remote audio: the app
    /// itself, and the conferencing daemon that carries its high-performance
    /// media stream.
    static let returnAudioBundleIDs: Set<String> = [
        "com.apple.ScreenSharing",
        "com.apple.avconferenced",
    ]
    static let returnAudioExecutableNames: Set<String> = [
        "Screen Sharing",
        "avconferenced",
    ]

    /// The executable that marks a live Screen Sharing viewer.
    static let screenSharingAppExecutableSuffix =
        "/Screen Sharing.app/Contents/MacOS/Screen Sharing"

    /// How often the Router re-checks while a LAN leg is live.
    public static let pollSeconds: Double = 2

    public static func isReturnAudioRenderer(_ renderer: SinkRenderer) -> Bool {
        if let bundleID = renderer.bundleID,
           returnAudioBundleIDs.contains(bundleID) {
            return true
        }
        if let path = renderer.executablePath,
           returnAudioExecutableNames.contains(
               (path as NSString).lastPathComponent
           ) {
            return true
        }
        return false
    }

    /// Which renderers to exclude from the sink tap, sorted for stable
    /// comparison. Empty unless a loop is actually possible: a LAN leg is
    /// carrying audio to another Mac AND a Screen Sharing viewer is open here.
    public static func processesToExclude(
        renderers: [SinkRenderer],
        lanLegLive: Bool,
        screenSharingViewerRunning: Bool
    ) -> [AudioObjectID] {
        guard lanLegLive, screenSharingViewerRunning else { return [] }
        return renderers
            .filter(isReturnAudioRenderer)
            .map(\.processObjectID)
            .sorted()
    }

    // MARK: - System queries

    /// Processes currently rendering output into the device `deviceID`.
    static func renderers(into deviceID: AudioObjectID) -> [SinkRenderer] {
        objectIDs(
            AudioObjectID(kAudioObjectSystemObject),
            kAudioHardwarePropertyProcessObjectList
        ).compactMap { process in
            guard uint32(process, kAudioProcessPropertyIsRunningOutput) == 1,
                  objectIDs(
                      process,
                      kAudioProcessPropertyDevices,
                      scope: kAudioObjectPropertyScopeOutput
                  ).contains(deviceID)
            else {
                return nil
            }
            let pid = pid_t(bitPattern: uint32(process, kAudioProcessPropertyPID) ?? 0)
            return SinkRenderer(
                processObjectID: process,
                pid: pid,
                bundleID: string(process, kAudioProcessPropertyBundleID),
                executablePath: executablePath(pid: pid)
            )
        }
    }

    /// True when a Screen Sharing viewer window can be open on this Mac.
    static func screenSharingViewerRunning() -> Bool {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return false }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let filled = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listallpids(
                buffer.baseAddress,
                Int32(buffer.count * MemoryLayout<pid_t>.size)
            )
        }
        guard filled > 0 else { return false }
        return pids.prefix(Int(filled)).contains { pid in
            pid > 0
                && executablePath(pid: pid)?
                    .hasSuffix(screenSharingAppExecutableSuffix) == true
        }
    }

    private static func executablePath(pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func objectIDs(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr,
              size > 0
        else {
            return []
        }
        var ids = [AudioObjectID](
            repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size
        )
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr
        else {
            return []
        }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private static func uint32(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
        else {
            return nil
        }
        return value
    }

    private static func string(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        let text = value as String
        return text.isEmpty ? nil : text
    }
}
