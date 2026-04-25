import Foundation
import CoreAudio
import AudioToolbox

/// User-visible info for a CoreAudio input device. Displayed in the
/// "Calibration microphone" picker so the user can override the system
/// default (e.g. they have a USB headset plugged in but want to use the
/// MacBook's built-in mic for the click-listening pass because it sits
/// closer to the speakers).
///
/// `id` is the live `AudioDeviceID` (UInt32 from CoreAudio). It is NOT
/// stable across replug — when a USB mic is unplugged and replugged the
/// id changes. The persisted "selected mic" preference uses the device
/// UID (a string set by the kernel that survives replug) rather than the
/// AudioDeviceID. See `AppModel.persistedMicUID` for the resolution flow.
public struct InputDeviceInfo: Sendable, Identifiable, Equatable {
    public let id: AudioDeviceID
    public let uid: String
    public let name: String
    public let isDefault: Bool
    public let transportType: String

    public init(
        id: AudioDeviceID,
        uid: String,
        name: String,
        isDefault: Bool,
        transportType: String
    ) {
        self.id = id
        self.uid = uid
        self.name = name
        self.isDefault = isDefault
        self.transportType = transportType
    }
}

/// Enumerates CoreAudio devices that have at least one input stream.
///
/// Scoped to "input-capable" because the calibration flow needs a mic;
/// presenting an output-only device (e.g. headphones, an AirPlay receiver)
/// in the picker would be confusing. We also filter out our own private
/// aggregate (UID prefix `io.syncast.aggregate.v1.`) — that device can
/// have an input stream as a side effect of its loopback wiring but is
/// invisible-by-construction to the user.
///
/// All CoreAudio HAL calls run on the calling queue. The caller is
/// responsible for serializing them; in `AppModel` we always invoke from
/// `@MainActor`. CoreAudio HAL accepts concurrent reads on different
/// threads but we keep things single-threaded for clarity.
public enum InputDeviceEnumerator {
    /// One-shot enumeration of currently-attached input devices.
    public static func enumerate() -> [InputDeviceInfo] {
        let allIDs = currentDeviceIDs()
        let defaultID = defaultInputDeviceID()
        return allIDs.compactMap { id -> InputDeviceInfo? in
            guard hasInputStream(id) else { return nil }
            let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) ?? ""
            // Hide our own private aggregate; user must never see it.
            if uid.hasPrefix("io.syncast.aggregate.v1.") { return nil }
            let name = stringProperty(id, kAudioObjectPropertyName) ?? "Unknown"
            let transport = transportTypeLabel(id)
            return InputDeviceInfo(
                id: id,
                uid: uid,
                name: name,
                isDefault: id == defaultID,
                transportType: transport
            )
        }
        .sorted { lhs, rhs in
            // Default first, then alphabetical by name.
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// The system-default input device's `AudioDeviceID`, or `nil` if the
    /// user has no input device at all (rare; even a headless Mac mini
    /// reports the built-in mic if present).
    public static func defaultInputDeviceID() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var devID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr, 0, nil, &size, &devID
        )
        guard status == noErr, devID != 0 else { return nil }
        return devID
    }

    // MARK: - HAL helpers

    private static func currentDeviceIDs() -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize
        )
        guard status == noErr, dataSize > 0 else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr, 0, nil, &dataSize, &ids
        )
        guard status == noErr else { return [] }
        return ids
    }

    /// Mirror of `CoreAudioDiscovery.isOutputCapable` but for the input
    /// scope. A device is "input-capable" iff its input-scope stream
    /// configuration reports at least one channel.
    private static func hasInputStream(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let szStatus = AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &dataSize)
        guard szStatus == noErr, dataSize > 0 else { return false }
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { buffer.deallocate() }
        let getStatus = AudioObjectGetPropertyData(id, &addr, 0, nil, &dataSize, buffer)
        guard getStatus == noErr else { return false }
        let abl = buffer.bindMemory(to: AudioBufferList.self, capacity: 1)
        let bufList = UnsafeMutableAudioBufferListPointer(abl)
        var totalChannels: UInt32 = 0
        for i in 0..<bufList.count { totalChannels += bufList[i].mNumberChannels }
        return totalChannels > 0
    }

    private static func stringProperty(
        _ id: AudioDeviceID,
        _ selector: AudioObjectPropertySelector
    ) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr -> OSStatus in
            ptr.withMemoryRebound(to: CFString?.self, capacity: 1) { cfPtr in
                AudioObjectGetPropertyData(id, &addr, 0, nil, &size, cfPtr)
            }
        }
        guard status == noErr else { return nil }
        return value as String
    }

    /// Map `kAudioDevicePropertyTransportType` to a short user-friendly
    /// label. Names like "Built-in", "USB", "Aggregate" so the picker can
    /// surface a hint to the user (e.g. "MacBook Pro Microphone (Built-in)"
    /// vs "Blue Yeti (USB)").
    private static func transportTypeLabel(_ id: AudioDeviceID) -> String {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value)
        guard status == noErr else { return "Unknown" }
        switch value {
        case kAudioDeviceTransportTypeBuiltIn:      return "Built-in"
        case kAudioDeviceTransportTypeUSB:          return "USB"
        case kAudioDeviceTransportTypeFireWire:     return "FireWire"
        case kAudioDeviceTransportTypeThunderbolt:  return "Thunderbolt"
        case kAudioDeviceTransportTypePCI:          return "PCI"
        case kAudioDeviceTransportTypeBluetooth:    return "Bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE:  return "Bluetooth LE"
        case kAudioDeviceTransportTypeHDMI:         return "HDMI"
        case kAudioDeviceTransportTypeDisplayPort:  return "DisplayPort"
        case kAudioDeviceTransportTypeAirPlay:      return "AirPlay"
        case kAudioDeviceTransportTypeAVB:          return "AVB"
        case kAudioDeviceTransportTypeAggregate:    return "Aggregate"
        case kAudioDeviceTransportTypeVirtual:      return "Virtual"
        case kAudioDeviceTransportTypeContinuityCaptureWired,
             kAudioDeviceTransportTypeContinuityCaptureWireless:
            return "Continuity"
        default:                                    return "Unknown"
        }
    }
}

/// Thin wrapper around `AudioObjectAddPropertyListener` so AppModel can
/// observe `kAudioHardwarePropertyDevices` changes (hot-plug) without
/// embedding the C-style pointer dance inline. Instances must be retained
/// for as long as the listener should fire — drop the reference and the
/// listener is removed by `deinit`.
final class InputDeviceListener {
    private let queue: DispatchQueue
    private let onChange: () -> Void
    /// We must pass the SAME block reference to
    /// `AudioObjectRemovePropertyListenerBlock` that we passed to
    /// `AudioObjectAddPropertyListenerBlock`; otherwise removal silently
    /// fails. Keep the block alive on the instance.
    private var installedBlock: AudioObjectPropertyListenerBlock?
    private var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    init(queue: DispatchQueue = .main, onChange: @escaping () -> Void) {
        self.queue = queue
        self.onChange = onChange
        install()
    }

    deinit {
        guard let block = installedBlock else { return }
        var addr = address
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            queue,
            block
        )
    }

    private func install() {
        let cb: AudioObjectPropertyListenerBlock = { [onChange] _, _ in
            // CoreAudio HAL calls this on `queue`. Hop directly to the
            // caller — `onChange` is responsible for any further actor
            // hopping (AppModel jumps to MainActor).
            onChange()
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queue,
            cb
        )
        if status == noErr {
            installedBlock = cb
        }
    }
}
