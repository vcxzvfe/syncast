import Foundation
import SyncCastDiscovery

/// Per-device routing configuration. Mutable from UI / IPC; consumed by the
/// audio engine on its own thread via a snapshot copy, never by reference.
public struct DeviceRouting: Hashable, Sendable {
    public var deviceID: String
    public var enabled: Bool
    public var volume: Float          // 0.0 – 1.0
    public var muted: Bool
    public var manualDelayMs: Int     // user-overridable trim (-2000…+2000)

    public init(
        deviceID: String,
        enabled: Bool = true,
        volume: Float = 1.0,
        muted: Bool = false,
        manualDelayMs: Int = 0
    ) {
        self.deviceID = deviceID
        self.enabled = enabled
        self.volume = volume
        self.muted = muted
        self.manualDelayMs = manualDelayMs
    }
}

/// Sync status reported per device.
public enum SyncStatus: String, Sendable, Codable {
    case unknown
    case aligned         // measured offset within target window
    case drifting        // offset growing; correction in progress
    case degraded        // packet loss / underrun in last window
    case error
}

/// A snapshot of the router state, suitable for passing across actor /
/// thread boundaries. Immutable.
public struct RouterSnapshot: Sendable {
    public let isStreaming: Bool
    public let masterAnchorTimeNs: UInt64?
    public let devices: [Device]
    public let routing: [String: DeviceRouting]
    public let perDeviceStatus: [String: SyncStatus]
    public let measuredAirplayLatencyMs: Int?  // worst-case from sidecar
}
