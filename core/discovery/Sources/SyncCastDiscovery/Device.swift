import Foundation

/// Transport classifies how SyncCast reaches a device.
public enum Transport: String, Codable, Sendable, CaseIterable {
    case coreAudio       // local CoreAudio device (built-in, USB, HDMI/DP, virtual)
    case airplay2        // AirPlay 2 receiver (HomePod, Xiaomi, Mac AirPlay-Receiver)
    // Future: snapcast, rtp, chromecast, etc.
}

/// A device discoverable by SyncCast. Stable IDs are assigned by the discovery
/// service so the rest of the app can reference devices independently of
/// transport-level identifiers (CoreAudio object IDs / Bonjour records).
public struct Device: Identifiable, Hashable, Sendable, Codable {
    public let id: String              // SyncCast-assigned UUID, stable across restarts where possible
    public let transport: Transport
    public let name: String
    public let model: String?
    public let host: String?           // network host for AirPlay 2; nil for local
    public let port: Int?              // network port for AirPlay 2; nil for local
    public let coreAudioUID: String?   // kAudioDevicePropertyDeviceUID; nil for AirPlay
    public let isOutputCapable: Bool
    public let supportsHardwareVolume: Bool
    public let nominalSampleRate: Double?

    public init(
        id: String,
        transport: Transport,
        name: String,
        model: String? = nil,
        host: String? = nil,
        port: Int? = nil,
        coreAudioUID: String? = nil,
        isOutputCapable: Bool = true,
        supportsHardwareVolume: Bool = true,
        nominalSampleRate: Double? = nil
    ) {
        self.id = id
        self.transport = transport
        self.name = name
        self.model = model
        self.host = host
        self.port = port
        self.coreAudioUID = coreAudioUID
        self.isOutputCapable = isOutputCapable
        self.supportsHardwareVolume = supportsHardwareVolume
        self.nominalSampleRate = nominalSampleRate
    }
}

/// A discovery event delivered via `AsyncStream`.
public enum DiscoveryEvent: Sendable {
    case appeared(Device)
    case updated(Device)
    case disappeared(deviceID: String)
    case error(String)
}
