import Foundation
import CoreAudio
import Darwin

/// DRM-oriented Stereo prototype that avoids system-audio capture entirely.
///
/// Instead of ScreenCaptureKit -> RingBuffer -> AUHAL, this path creates a
/// public CoreAudio aggregate/multi-output device from the enabled local
/// outputs and temporarily makes it the macOS default output. Apps then render
/// directly to CoreAudio, so DRM players see an ordinary output device rather
/// than a screen/audio recorder.
///
/// This is intentionally feature-flagged by Router (`SYNCAST_STEREO_PATH=direct`)
/// until default-output restore, crash cleanup, DRM behavior, and volume UX are
/// validated on real hardware.
public final class DirectStereoOutput {
    public struct Target: Sendable {
        public let uid: String
        public let name: String

        public init(uid: String, name: String) {
            self.uid = uid
            self.name = name
        }
    }

    public enum DirectStereoError: Error, CustomStringConvertible {
        case noTargets
        case noMaster
        case deviceNotFound(String)
        case readDefaultFailed(OSStatus)
        case setDefaultFailed(OSStatus)
        case createAggregateFailed(OSStatus)
        case unsafeAggregateChannelLayout(String)
        case stopFailed(String)

        public var description: String {
            switch self {
            case .noTargets:
                return "direct stereo requires at least one local output"
            case .noMaster:
                return "direct stereo could not choose an aggregate master"
            case .deviceNotFound(let uid):
                return "direct stereo device not found: \(uid)"
            case .readDefaultFailed(let status):
                return "read default output failed: OSStatus=\(status)"
            case .setDefaultFailed(let status):
                return "set default output failed: OSStatus=\(status)"
            case .createAggregateFailed(let status):
                return "create direct aggregate failed: OSStatus=\(status)"
            case .unsafeAggregateChannelLayout(let summary):
                return "direct stereo aggregate exposes unsafe channel layout: \(summary)"
            case .stopFailed(let reason):
                return "direct stereo stop failed: \(reason)"
            }
        }
    }

    public static let uidPrefix = "io.syncast.directaggregate.v1."

    private var previousDefaultOutputID: AudioObjectID?
    private var previousDefaultOutputUID: String?
    private var activeDefaultOutputID: AudioObjectID = 0
    private var activeDefaultOutputUID: String?
    private var aggregateID: AudioObjectID = 0
    private var aggregateUID: String = ""
    private var coveredUIDs: Set<String> = []
    private var lastStopStatus: String?

    public var isActive: Bool { activeDefaultOutputID != 0 }

    public var diagnostic: String {
        if !isActive {
            if let lastStopStatus {
                return "directStereo=inactive lastStop=\"\(lastStopStatus)\""
            }
            return "directStereo=inactive"
        }
        let kind = aggregateID == 0 ? "single" : "aggregate"
        return "directStereo=\(kind) default=\(activeDefaultOutputID) aggregate=\(aggregateID) uids=\(coveredUIDs.count)"
    }

    public var lastStopStatusText: String? { lastStopStatus }

    public init() {}

    deinit {
        stop()
    }

    public func reconcile(targets: [Target]) throws {
        let deduped = Self.deduplicate(targets).filter {
            Self.isOrdinaryOutputUID($0.uid)
        }
        let targetUIDs = Set(deduped.map(\.uid))
        guard !targetUIDs.isEmpty else {
            guard stop() else {
                throw DirectStereoError.stopFailed(lastStopStatus ?? "unknown")
            }
            return
        }
        if targetUIDs == coveredUIDs, isActive {
            return
        }
        guard stop() else {
            throw DirectStereoError.stopFailed(lastStopStatus ?? "unknown")
        }
        try startFresh(targets: deduped)
    }

    @discardableResult
    public func stop() -> Bool {
        let active = activeDefaultOutputID
        let current = try? Self.readDefaultOutput()
        let currentUID = current.flatMap { Self.readDeviceUID($0) }
        let currentIsActiveDefault = active != 0 && (
            current == active ||
            (activeDefaultOutputUID != nil && currentUID == activeDefaultOutputUID)
        )
        var canDestroyAggregate = true
        var fullyStopped = true

        if let previous = Self.restoreDefaultOutputID(
            previousID: previousDefaultOutputID,
            previousUID: previousDefaultOutputUID
        ), active != 0 {
            if currentIsActiveDefault {
                let status = Self.setDefaultOutput(previous)
                if status == noErr {
                    lastStopStatus = "restored default \(previous)"
                } else if let fallback = Self.fallbackDefaultOutputID(
                    coveredUIDs: coveredUIDs,
                    excluding: [active]
                ) {
                    let fallbackStatus = Self.setDefaultOutput(fallback)
                    if fallbackStatus == noErr {
                        lastStopStatus = "restore default failed OSStatus=\(status); fell back to \(fallback)"
                    } else {
                        lastStopStatus = "restore default failed OSStatus=\(status); fallback failed OSStatus=\(fallbackStatus)"
                        canDestroyAggregate = false
                        fullyStopped = false
                    }
                } else {
                    lastStopStatus = "restore default failed OSStatus=\(status); no fallback"
                    canDestroyAggregate = false
                    fullyStopped = false
                }
            } else if current == nil {
                lastStopStatus = "restore skipped: current default unreadable"
                canDestroyAggregate = false
                fullyStopped = false
            } else {
                lastStopStatus = "restore skipped: user changed default"
            }
        } else {
            lastStopStatus = "stopped"
        }

        if canDestroyAggregate, aggregateID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }

        if fullyStopped {
            previousDefaultOutputID = nil
            previousDefaultOutputUID = nil
            activeDefaultOutputID = 0
            activeDefaultOutputUID = nil
            coveredUIDs = []
            aggregateID = 0
            aggregateUID = ""
        }
        return fullyStopped
    }

    @discardableResult
    public static func sweepOrphans() -> Int {
        let currentDefault = try? readDefaultOutput()
        let myPID = ProcessInfo.processInfo.processIdentifier
        var destroyed = 0
        for id in enumerateAllDevices() {
            guard let uid = readDeviceUID(id),
                  uid.hasPrefix(Self.uidPrefix) else {
                continue
            }
            if let pid = processID(from: uid), pid == myPID {
                continue
            }
            if let pid = processID(from: uid),
               processOwnsLiveSyncCastAggregate(pid) {
                continue
            }
            if let currentDefault, id == currentDefault,
               !moveDefaultAwayFromDirectAggregate(id) {
                continue
            }
            if AudioHardwareDestroyAggregateDevice(id) == noErr {
                destroyed += 1
            }
        }
        return destroyed
    }

    private func startFresh(targets: [Target]) throws {
        let rawPreviousID = try Self.readDefaultOutput()
        let rawPreviousUID = Self.readDeviceUID(rawPreviousID)
        let targetUIDs = Set(targets.map(\.uid))
        let (previousID, previousUID) = Self.restorablePreviousDefault(
            id: rawPreviousID,
            uid: rawPreviousUID,
            fallbackUIDs: targetUIDs
        )

        if targets.count == 1 {
            let id = try Self.deviceID(forUID: targets[0].uid)
            try Self.setDefaultOutputOrThrow(id)
            previousDefaultOutputID = previousID
            previousDefaultOutputUID = previousUID
            coveredUIDs = targetUIDs
            activeDefaultOutputID = id
            activeDefaultOutputUID = targets[0].uid
            return
        }

        let nameByUID = Dictionary(uniqueKeysWithValues: targets.map { ($0.uid, $0.name) })
        guard let masterUID = AggregateDevice.pickMaster(
            candidateUIDs: targetUIDs,
            deviceNames: nameByUID
        ) else {
            throw DirectStereoError.noMaster
        }
        let slaveUIDs = targets.map(\.uid).filter { $0 != masterUID }
        let aggregate = try Self.createPublicAggregate(
            masterUID: masterUID,
            slaveUIDs: slaveUIDs
        )
        do {
            try Self.setDefaultOutputOrThrow(aggregate.id)
        } catch {
            AudioHardwareDestroyAggregateDevice(aggregate.id)
            throw error
        }
        previousDefaultOutputID = previousID
        previousDefaultOutputUID = previousUID
        coveredUIDs = targetUIDs
        aggregateID = aggregate.id
        aggregateUID = aggregate.uid
        activeDefaultOutputID = aggregate.id
        activeDefaultOutputUID = aggregate.uid
    }

    private static func deduplicate(_ targets: [Target]) -> [Target] {
        var seen = Set<String>()
        var result: [Target] = []
        for target in targets where seen.insert(target.uid).inserted {
            result.append(target)
        }
        return result
    }

    private static func createPublicAggregate(
        masterUID: String,
        slaveUIDs: [String]
    ) throws -> (id: AudioObjectID, uid: String) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let uid = "\(Self.uidPrefix)\(pid).\(UUID().uuidString)"
        var seen = Set<String>()
        let ordered = ([masterUID] + slaveUIDs).filter { seen.insert($0).inserted }
        let subdevices: [[String: Any]] = ordered.map { uid in
            [
                kAudioSubDeviceUIDKey as String: uid,
                kAudioSubDeviceDriftCompensationKey as String:
                    UInt32(uid == masterUID ? 0 : 1),
                kAudioSubDeviceDriftCompensationQualityKey as String:
                    UInt32(kAudioAggregateDriftCompensationHighQuality),
            ]
        }
        let composition: [String: Any] = [
            kAudioAggregateDeviceUIDKey as String: uid,
            kAudioAggregateDeviceNameKey as String: "SyncCast Direct Stereo Output",
            kAudioAggregateDeviceIsPrivateKey as String: 0,
            // Public Direct Stereo is used as the macOS default output, so
            // ordinary apps must see a normal stereo surface. The private
            // SyncCast aggregate can tolerate wider layouts because our AUHAL
            // render callback splats stereo into every channel pair; external
            // apps will not. CoreAudio's Multi-Output flavor is the stacked
            // aggregate form, which should mirror stereo to subdevices.
            kAudioAggregateDeviceIsStackedKey as String: 1,
            kAudioAggregateDeviceMainSubDeviceKey as String: masterUID,
            kAudioAggregateDeviceSubDeviceListKey as String: subdevices,
        ]

        var newID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(
            composition as CFDictionary,
            &newID
        )
        guard status == noErr, newID != kAudioObjectUnknown else {
            throw DirectStereoError.createAggregateFailed(status)
        }
        AggregateDevice.tryNarrowOutputStreamsToStereo(newID)
        let (streamCount, perStream, totalChannels) = AggregateDevice.readStreamChannels(newID)
        guard streamCount > 0, totalChannels > 0, totalChannels <= 2 else {
            AudioHardwareDestroyAggregateDevice(newID)
            let summary = "streams=\(streamCount) ch=[\(perStream.map(String.init).joined(separator: ","))] total=\(totalChannels)"
            throw DirectStereoError.unsafeAggregateChannelLayout(summary)
        }
        return (newID, uid)
    }

    private static func readDefaultOutput() throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &id
        )
        guard status == noErr, id != kAudioObjectUnknown else {
            throw DirectStereoError.readDefaultFailed(status)
        }
        return id
    }

    private static func setDefaultOutputOrThrow(_ id: AudioObjectID) throws {
        let status = setDefaultOutput(id)
        guard status == noErr else {
            throw DirectStereoError.setDefaultFailed(status)
        }
    }

    private static func setDefaultOutput(_ id: AudioObjectID) -> OSStatus {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var mutableID = id
        let size = UInt32(MemoryLayout<AudioObjectID>.size)
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            size,
            &mutableID
        )
    }

    private static func deviceID(forUID uid: String) throws -> AudioObjectID {
        do {
            return try Capture.deviceID(forUID: uid)
        } catch {
            throw DirectStereoError.deviceNotFound(uid)
        }
    }

    private static func fallbackDefaultOutputID(
        coveredUIDs: Set<String>,
        excluding excludedIDs: Set<AudioObjectID> = []
    ) -> AudioObjectID? {
        for uid in coveredUIDs.sorted() {
            if let id = try? deviceID(forUID: uid),
               !excludedIDs.contains(id),
               ordinaryOutputScore(id) != nil {
                return id
            }
        }
        return enumerateAllDevices()
            .filter { !excludedIDs.contains($0) }
            .compactMap { id -> (AudioObjectID, Int)? in
                guard let score = ordinaryOutputScore(id) else { return nil }
                return (id, score)
            }
            .min { left, right in
                if left.1 != right.1 { return left.1 < right.1 }
                return left.0 < right.0
            }?
            .0
    }

    private static func restoreDefaultOutputID(
        previousID: AudioObjectID?,
        previousUID: String?
    ) -> AudioObjectID? {
        if let previousUID, let id = try? deviceID(forUID: previousUID) {
            return id
        }
        return previousID
    }

    private static func moveDefaultAwayFromDirectAggregate(_ aggregateID: AudioObjectID) -> Bool {
        guard let fallback = fallbackDefaultOutputID(
            coveredUIDs: [],
            excluding: [aggregateID]
        ) else {
            return false
        }
        return setDefaultOutput(fallback) == noErr
    }

    private static func restorablePreviousDefault(
        id: AudioObjectID,
        uid: String?,
        fallbackUIDs: Set<String>
    ) -> (AudioObjectID?, String?) {
        guard let uid,
              uid.hasPrefix(Self.uidPrefix),
              let pid = processID(from: uid),
              !processIsAlive(pid)
        else {
            return (id, uid)
        }
        if let fallback = fallbackDefaultOutputID(coveredUIDs: fallbackUIDs) {
            return (fallback, readDeviceUID(fallback))
        }
        return (nil, nil)
    }

    private static func processID(from uid: String) -> pid_t? {
        guard uid.hasPrefix(Self.uidPrefix) else { return nil }
        let suffix = uid.dropFirst(Self.uidPrefix.count)
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

    private static func processOwnsLiveSyncCastAggregate(_ pid: pid_t) -> Bool {
        guard processIsAlive(pid) else { return false }
        guard let looksLikeSyncCast = processExecutableLooksLikeSyncCast(pid) else {
            return true
        }
        return looksLikeSyncCast
    }

    private static func processExecutableLooksLikeSyncCast(_ pid: pid_t) -> Bool? {
        var buffer = [CChar](
            repeating: 0,
            count: 4096
        )
        let result = buffer.withUnsafeMutableBufferPointer { ptr -> Int32 in
            guard let base = ptr.baseAddress else { return 0 }
            return proc_pidpath(pid, base, UInt32(ptr.count))
        }
        guard result > 0 else { return nil }
        let path = String(cString: buffer)
        let executable = URL(fileURLWithPath: path)
            .lastPathComponent
            .lowercased()
        return executable.contains("syncast")
    }

    static func isOrdinaryOutputUID(_ uid: String) -> Bool {
        guard !uid.hasPrefix(Self.uidPrefix),
              !uid.hasPrefix(AggregateDevice.uidPrefix),
              let id = try? deviceID(forUID: uid)
        else {
            return false
        }
        return ordinaryOutputScore(id) != nil
    }

    private static func ordinaryOutputScore(_ id: AudioObjectID) -> Int? {
        guard let uid = readDeviceUID(id),
              !uid.hasPrefix(Self.uidPrefix),
              !uid.hasPrefix(AggregateDevice.uidPrefix),
              !isAggregate(id)
        else {
            return nil
        }
        let (_, _, totalChannels) = AggregateDevice.readStreamChannels(id)
        guard totalChannels > 0 else { return nil }
        guard let transport = readUInt32(id, kAudioDevicePropertyTransportType) else {
            return nil
        }
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn:
            return 0
        case kAudioDeviceTransportTypeUSB,
             kAudioDeviceTransportTypeFireWire,
             kAudioDeviceTransportTypeThunderbolt,
             kAudioDeviceTransportTypePCI:
            return 10
        case kAudioDeviceTransportTypeHDMI,
             kAudioDeviceTransportTypeDisplayPort:
            return 20
        case kAudioDeviceTransportTypeBluetooth,
             kAudioDeviceTransportTypeBluetoothLE:
            return 50
        default:
            return nil
        }
    }

    private static func isAggregate(_ id: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyClass,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var classID: AudioClassID = 0
        var size = UInt32(MemoryLayout<AudioClassID>.size)
        let status = AudioObjectGetPropertyData(
            id,
            &address,
            0,
            nil,
            &size,
            &classID
        )
        return status == noErr && classID == kAudioAggregateDeviceClassID
    }

    private static func readUInt32(
        _ id: AudioObjectID,
        _ selector: AudioObjectPropertySelector
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            id,
            &address,
            0,
            nil,
            &size,
            &value
        )
        return status == noErr ? value : nil
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

    private static func readDeviceUID(_ id: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, ptr)
        }
        guard status == noErr else { return nil }
        return value as String?
    }
}
