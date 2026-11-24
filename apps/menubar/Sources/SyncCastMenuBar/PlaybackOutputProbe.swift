import CoreAudio
import Foundation
import SyncCastRouter

/// Read-only CoreAudio questions the keep-awake controller asks once a second.
///
/// Every call is a property read; nothing here opens IO, creates a tap or
/// needs a privacy permission, which is what makes it cheap enough to be the
/// first gate. Unreadable properties come back as nil / empty and the caller
/// treats that as "not playing", never as an error worth surfacing.
///
/// Each read is an IPC to coreaudiod, which can stall during hot-plug and
/// wake, so callers run `snapshot` off the main thread.
enum PlaybackOutputProbe {

    struct Snapshot: Equatable, Sendable {
        var displayPresent: Bool
        var feed: DisplayFeed
        /// The display device's own mute / volume; nil when it has none (a
        /// monitor whose level lives in DDC).
        var displayMuted: Bool?
        var displayScalar: Float?

        static let absent = Snapshot(
            displayPresent: false, feed: .none, displayMuted: nil, displayScalar: nil
        )
    }

    static func snapshot(displayUID: String, ownPID: Int32) -> Snapshot {
        guard deviceID(forUID: displayUID) != nil else { return .absent }
        return Snapshot(
            displayPresent: true,
            feed: DisplayFeed.classify(processOutputs(), ownPID: ownPID, displayUID: displayUID),
            displayMuted: AggregateDevice.readHardwareMute(uid: displayUID),
            displayScalar: AggregateDevice.readHardwareVolume(uid: displayUID)
        )
    }

    static func isPresent(uid: String) -> Bool {
        deviceID(forUID: uid) != nil
    }

    /// The live device for a UID, or nil when it is not connected.
    static func deviceID(forUID uid: String) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfUID = uid as CFString
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &cfUID) { uidPtr in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<CFString>.size), uidPtr, &size, &id
            )
        }
        guard status == noErr, id != kAudioObjectUnknown else { return nil }
        return id
    }

    /// Every process CoreAudio knows about that is running output IO, with
    /// the devices it outputs to.
    ///
    /// Measured on macOS 26: a process rendering through a private aggregate
    /// is reported with the aggregate's real sub-devices. Whether a public
    /// aggregate is reported the same way was not measured, so an aggregate
    /// that does show up is expanded to its ACTIVE members as well (an
    /// inactive member gets no audio).
    static func processOutputs() -> [DisplayFeed.ProcessOutput] {
        var uidCache: [AudioObjectID: [String]] = [:]
        func uids(_ id: AudioObjectID) -> [String] {
            if let cached = uidCache[id] { return cached }
            guard let own = stringProperty(id, kAudioDevicePropertyDeviceUID) else { return [] }
            let value = [own] + activeAggregateMemberUIDs(deviceID: id)
            uidCache[id] = value
            return value
        }
        var result: [DisplayFeed.ProcessOutput] = []
        for process in objectList(
            AudioObjectID(kAudioObjectSystemObject),
            kAudioHardwarePropertyProcessObjectList,
            scope: kAudioObjectPropertyScopeGlobal
        ) {
            guard uint32Property(process, kAudioProcessPropertyIsRunningOutput) == 1 else {
                continue
            }
            let pid = int32Property(process, kAudioProcessPropertyPID) ?? -1
            let devices = objectList(
                process, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput
            ).flatMap(uids)
            result.append(.init(
                objectID: process, pid: pid, runningOutput: true, outputDeviceUIDs: devices
            ))
        }
        return result
    }

    /// UIDs of the members an aggregate (or Multi-Output Device) is
    /// currently sending audio to; empty for an ordinary device.
    private static func activeAggregateMemberUIDs(deviceID id: AudioObjectID) -> [String] {
        objectList(id, kAudioAggregateDevicePropertyActiveSubDeviceList, scope: kAudioObjectPropertyScopeGlobal)
            .compactMap { stringProperty($0, kAudioDevicePropertyDeviceUID) }
    }

    // MARK: - Property plumbing

    private static func objectList(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var ids = [AudioObjectID](
            repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size
        )
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private static func uint32Property(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    private static func int32Property(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector
    ) -> Int32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Int32 = 0
        var size = UInt32(MemoryLayout<Int32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    private static func stringProperty(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let string = value as String? else { return nil }
        return string
    }
}
