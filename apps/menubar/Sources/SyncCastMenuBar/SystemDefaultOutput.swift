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

    /// Resolve a UID to a device that can actually be a default OUTPUT.
    ///
    /// The output-channel test is not belt-and-braces. Plenty of hardware
    /// registers its input and output halves as separate `AudioObjectID`s that
    /// report the same device UID (USB interfaces and virtual drivers both do
    /// it), and `allDeviceIDs` returns them in whatever order CoreAudio feels
    /// like. Matching on UID alone can therefore hand back the capture half,
    /// and writing that into `kAudioHardwarePropertyDefaultOutputDevice` fails
    /// with an opaque OSStatus that reads exactly like "the write was refused"
    /// — while the real speakers were sitting right behind it in the list.
    private static func deviceID(forUID uid: String) -> AudioObjectID? {
        allDeviceIDs().first { self.uid(of: $0) == uid && hasOutputChannels($0) }
    }

    /// True when the device's output-scope stream configuration reports at
    /// least one channel.
    private static func hasOutputChannels(_ id: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioBufferList>.size)
        else { return false }
        // AudioBufferList is variable-length, so it cannot be stack-allocated
        // at a fixed size: ask for the reported byte count and rebind.
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else {
            return false
        }
        let list = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self)
        )
        return list.contains { $0.mNumberChannels > 0 }
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
