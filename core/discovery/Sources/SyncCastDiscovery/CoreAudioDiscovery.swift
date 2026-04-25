import Foundation
import CoreAudio
import AudioToolbox

/// Enumerates local CoreAudio output devices and watches for hot-plug changes.
///
/// We deliberately keep this thin: the discovery service reports devices, but
/// it does not start streaming or open IOProcs. The router module is the
/// audio-data consumer.
public final class CoreAudioDiscovery: @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.syncast.discovery.coreaudio")
    private var listenerInstalled = false
    private var continuation: AsyncStream<DiscoveryEvent>.Continuation?
    private var snapshot: [AudioObjectID: Device] = [:]
    private let idMap = StableIDMap()

    public init() {}

    /// Start enumerating devices and emit events as they change.
    public func events() -> AsyncStream<DiscoveryEvent> {
        AsyncStream { continuation in
            self.queue.async {
                self.continuation = continuation
                self.installListener()
                self.refresh(initial: true)
            }
            continuation.onTermination = { @Sendable _ in
                self.queue.async {
                    self.removeListener()
                    self.continuation = nil
                }
            }
        }
    }

    /// One-shot enumeration without subscriptions. Useful for the CLI.
    public func enumerate() -> [Device] {
        let ids = currentDeviceIDs()
        return ids.compactMap { makeDevice(for: $0) }
    }

    // MARK: - Internals

    private func installListener() {
        guard !listenerInstalled else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queue
        ) { [weak self] _, _ in
            self?.refresh(initial: false)
        }
        if status == noErr {
            listenerInstalled = true
        }
    }

    private func removeListener() {
        // Block-form listeners are released when this object dies; nothing
        // strictly required here.
        listenerInstalled = false
    }

    private func refresh(initial: Bool) {
        let ids = currentDeviceIDs()
        var seen = Set<AudioObjectID>()
        for id in ids {
            seen.insert(id)
            guard let dev = makeDevice(for: id) else { continue }
            if let prev = snapshot[id] {
                if prev != dev {
                    snapshot[id] = dev
                    continuation?.yield(.updated(dev))
                }
            } else {
                snapshot[id] = dev
                continuation?.yield(.appeared(dev))
            }
        }
        for (oldID, oldDev) in snapshot where !seen.contains(oldID) {
            snapshot.removeValue(forKey: oldID)
            continuation?.yield(.disappeared(deviceID: oldDev.id))
        }
        _ = initial // reserved for future "initial scan complete" event
    }

    private func currentDeviceIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        )
        guard status == noErr, dataSize > 0 else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &dataSize, &ids
        )
        guard status == noErr else { return [] }
        return ids
    }

    private func makeDevice(for id: AudioObjectID) -> Device? {
        guard isOutputCapable(id) else { return nil }
        let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) ?? ""
        let name = stringProperty(id, kAudioObjectPropertyName) ?? "Unknown"
        let model = stringProperty(id, kAudioDevicePropertyModelUID)
        let sampleRate = nominalSampleRate(id)
        let stableID = idMap.id(for: uid.isEmpty ? "obj-\(id)" : "ca:\(uid)")
        return Device(
            id: stableID,
            transport: .coreAudio,
            name: name,
            model: model,
            host: nil,
            port: nil,
            coreAudioUID: uid.isEmpty ? nil : uid,
            isOutputCapable: true,
            supportsHardwareVolume: hasOutputVolume(id),
            nominalSampleRate: sampleRate
        )
    }

    private func isOutputCapable(_ id: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(id, &address, 0, nil, &dataSize)
        guard status == noErr, dataSize > 0 else { return false }
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { buffer.deallocate() }
        let getStatus = AudioObjectGetPropertyData(id, &address, 0, nil, &dataSize, buffer)
        guard getStatus == noErr else { return false }
        let abl = buffer.bindMemory(to: AudioBufferList.self, capacity: 1)
        let bufList = UnsafeMutableAudioBufferListPointer(abl)
        var totalChannels: UInt32 = 0
        for i in 0..<bufList.count { totalChannels += bufList[i].mNumberChannels }
        return totalChannels > 0
    }

    private func hasOutputVolume(_ id: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        return AudioObjectHasProperty(id, &address)
    }

    private func nominalSampleRate(_ id: AudioObjectID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate)
        return status == noErr ? Double(rate) : nil
    }

    private func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
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
        return value as String
    }
}

/// Maps unstable transport-level keys (CoreAudio UID, Bonjour fullname) to
/// stable SyncCast UUIDs that survive hot-plug. Persistence belongs to a
/// future revision; in-memory is sufficient for P0.
final class StableIDMap {
    private var map: [String: String] = [:]
    private let queue = DispatchQueue(label: "io.syncast.discovery.idmap")

    func id(for key: String) -> String {
        queue.sync {
            if let existing = map[key] { return existing }
            let new = UUID().uuidString.lowercased()
            map[key] = new
            return new
        }
    }
}
