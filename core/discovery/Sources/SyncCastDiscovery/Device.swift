import Foundation

/// Transport classifies how SyncCast reaches a device.
public enum Transport: String, Codable, Sendable, CaseIterable {
    case coreAudio       // local CoreAudio device (built-in, USB, HDMI/DP, virtual)
    case airplay2        // AirPlay 2 receiver (HomePod, Xiaomi, Mac AirPlay-Receiver)
    /// A second Mac running the SyncCast receiver daemon, reachable over the
    /// LAN with SyncCast's own low-latency PCM link (`_synccast-pcm._udp`).
    /// NOT AirPlay: the sender packetises 5 ms of Int16 straight from the
    /// capture ring and stamps a playout time, so the receiver can be one leg
    /// of the local Stereo path alongside this Mac's own speakers.
    case lanReceiver = "lan_receiver"
    // Future: snapcast, rtp, chromecast, etc.
}

/// A device discoverable by SyncCast. Stable IDs are assigned by the discovery
/// service so the rest of the app can reference devices independently of
/// transport-level identifiers (CoreAudio object IDs / Bonjour records).
public struct Device: Identifiable, Hashable, Sendable, Codable {
    /// SyncCast-assigned identifier. NOT stable across restarts: `StableIDMap`
    /// mints a fresh UUID per key per process. Anything that must survive a
    /// relaunch has to key off `coreAudioUID` (local devices) or
    /// `airplayDeviceID` (AirPlay receivers) instead.
    public let id: String
    public let transport: Transport
    public let name: String
    public let model: String?
    public let host: String?           // network host for AirPlay 2; nil for local
    public let port: Int?              // network port for AirPlay 2; nil for local
    public let coreAudioUID: String?   // kAudioDevicePropertyDeviceUID; nil for AirPlay
    public let isOutputCapable: Bool
    public let supportsHardwareVolume: Bool
    public let nominalSampleRate: Double?
    /// The AirPlay `deviceid` from the Bonjour TXT record, e.g.
    /// `02:00:CA:FE:00:01`. nil for CoreAudio devices and for AirPlay
    /// endpoints whose TXT record omitted it.
    ///
    /// This is the only genuinely stable AirPlay identity available, and it
    /// is the SAME value on all three sides of the system: Bonjour publishes
    /// it, OwnTone derives its output id from it (`int(hex) == output id`),
    /// and pyatv reports it as the device identifier. Persist selections and
    /// pairing credentials against this, never against the display name.
    public let airplayDeviceID: String?
    /// True when this AirPlay receiver is THIS Mac's own AirPlay Receiver.
    ///
    /// Determined at runtime from the Bonjour browse result: only the local
    /// machine advertises `_airplay._tcp` on the loopback interface. The test
    /// is independent of device name, model, hostname, subnet and location,
    /// which is what makes it safe for a laptop that moves between an office
    /// and a home network.
    public let isLocalMachineReceiver: Bool
    /// Bonjour instance name of a `.lanReceiver`, e.g. `receiver-a`. nil for
    /// every other transport.
    ///
    /// This is the receiver's stable identity: it is what the daemon was
    /// started with, it is what the user sees, and it is what
    /// `persistenceKey` is built from. The resolved IP is deliberately NOT
    /// stored — DHCP moves it, and the link re-resolves the service on every
    /// connect.
    public let lanServiceName: String?
    /// Bonjour domain the service was found in (`local` in practice). Carried
    /// so the link can rebuild the exact `NWEndpoint.service` it was seen at.
    public let lanServiceDomain: String?
    /// The 8-hex `token=` hint from the TXT record.
    ///
    /// A HINT, never the secret: it lets the UI say "this is the receiver
    /// whose log printed 3f2a…" without the full token ever being on the
    /// wire unencrypted. The full token is typed once by the user and lives
    /// in the keychain.
    public let lanTokenHint: String?

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
        nominalSampleRate: Double? = nil,
        airplayDeviceID: String? = nil,
        isLocalMachineReceiver: Bool = false,
        lanServiceName: String? = nil,
        lanServiceDomain: String? = nil,
        lanTokenHint: String? = nil
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
        self.airplayDeviceID = airplayDeviceID
        self.isLocalMachineReceiver = isLocalMachineReceiver
        self.lanServiceName = lanServiceName
        self.lanServiceDomain = lanServiceDomain
        self.lanTokenHint = lanTokenHint
    }

    /// Key under which a user's selection of this device should be persisted.
    /// nil when the device exposes no stable identity, in which case the
    /// caller must NOT persist it rather than inventing one.
    public var persistenceKey: String? {
        switch transport {
        case .coreAudio:
            return coreAudioUID.map { "ca:\($0)" }
        case .airplay2:
            return Device.normalizedAirplayDeviceID(airplayDeviceID).map { "ap:\($0)" }
        case .lanReceiver:
            return Device.lanReceiverUID(serviceName: lanServiceName)
        }
    }

    /// Canonical UID of a LAN receiver: `lan:<bonjour instance name>`.
    ///
    /// Namespaced so it cannot collide with a CoreAudio UID in any of the
    /// per-device stores (equalizer, stereo image, channel matrix), which are
    /// all keyed by this same string.
    public static func lanReceiverUID(serviceName: String?) -> String? {
        guard let trimmed = serviceName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return "lan:\(trimmed)"
    }

    /// Canonical uppercase colon-free form of an AirPlay `deviceid`, e.g.
    /// `0200CAFE0001`. OwnTone's output id is this value read as hex.
    public static func normalizedAirplayDeviceID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let stripped = raw
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard !stripped.isEmpty,
              stripped.allSatisfy({ $0.isHexDigit })
        else { return nil }
        return stripped
    }
}

/// A discovery event delivered via `AsyncStream`.
public enum DiscoveryEvent: Sendable {
    case appeared(Device)
    case updated(Device)
    case disappeared(deviceID: String)
    case error(String)
}
