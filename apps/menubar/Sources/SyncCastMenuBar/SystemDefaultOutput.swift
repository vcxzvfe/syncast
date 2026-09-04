import CoreAudio
import Foundation

/// Minimal "point macOS at this output" helper.
///
/// `SyncCastRouter` has equivalent private machinery inside
/// `DirectStereoOutput`, but it is not public and it is bound to the lifetime
/// of a Direct Stereo session. The disconnect action needs to set a default
/// output precisely when no session exists — after the engine has been torn
/// down because the monitor went away — so it gets its own tiny surface rather
/// than a widened router API it would then have to keep in sync.
///
/// Returns `Bool`/optionals rather than throwing: every caller's fallback is
/// "log it and leave the system alone", and there is no recovery to branch on.
enum SystemDefaultOutput {

    /// UID of the device macOS is currently rendering to, or nil if the
    /// property is unreadable.
    static func currentUID() -> String? {
        guard let id = currentDeviceID() else { return nil }
        return uid(of: id)
    }

    /// Make the device with this UID the system default output.
    /// - Returns: true when CoreAudio accepted the write.
    @discardableResult
    static func setDefaultOutput(uid: String) -> Bool {
        guard let target = deviceID(forUID: uid) else {
            SyncCastLog.log("autoconnect: default-output target \(uid) not found")
            return false
        }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var mutableID = target
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioObjectID>.size),
            &mutableID
        )
        if status != noErr {
            SyncCastLog.log("autoconnect: set default output \(uid) failed OSStatus=\(status)")
        }
        return status == noErr
    }

    // MARK: - Internals

    private static func currentDeviceID() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id
        )
        guard status == noErr, id != kAudioObjectUnknown else { return nil }
        return id
    }

    private static func deviceID(forUID uid: String) -> AudioObjectID? {
        allDeviceIDs().first { self.uid(of: $0) == uid }
    }

    private static func allDeviceIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](
            repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }
        return ids
    }

    private static func uid(of id: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr -> OSStatus in
            ptr.withMemoryRebound(to: CFString?.self, capacity: 1) { cfPtr in
                AudioObjectGetPropertyData(id, &address, 0, nil, &size, cfPtr)
            }
        }
        guard status == noErr else { return nil }
        let string = value as String
        return string.isEmpty ? nil : string
    }
}
