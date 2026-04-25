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

/// Per-device connection state, derived from `event.device_state`
/// notifications emitted by the sidecar.
///
/// This is the data layer behind the per-row sync dot in MainPopover —
/// it answers "is this device actually connected and receiving audio
/// from OwnTone?", not "did the user toggle the row on?". The previous
/// UI always showed green for any enabled device, which was misleading
/// when OwnTone silently failed to wire up the receiver (e.g. mDNS
/// race, network rejection) — see the matching sidecar fix in
/// `device_manager._apply_output_state`.
public enum DeviceConnectionState: String, Sendable, Codable {
    /// No event received yet. The default, also used after a transient
    /// event the UI doesn't render specially.
    case unknown
    /// Sidecar is in the middle of trying to enable this device's
    /// OwnTone output (or waiting for OwnTone's mDNS scanner to
    /// discover it). UI shows a yellow dot.
    case connecting
    /// OwnTone REST confirmed `selected=True` for the device's output.
    /// Audio is flowing — green dot.
    case connected
    /// REST call failed, or post-call verification observed
    /// `selected=False`. UI shows a red dot plus an inline error
    /// message ("Connection failed — check device").
    case failed
    /// User toggled the device off. UI shows a grey dot.
    case disconnected

    /// Build a `DeviceConnectionState` from the sidecar's wire string
    /// in `event.device_state.state`. Unknown values are mapped to
    /// `.unknown` so a sidecar that adds a new state value in the
    /// future doesn't crash older clients.
    public static func fromWire(_ raw: String) -> DeviceConnectionState {
        switch raw {
        case "connecting":   return .connecting
        case "connected":    return .connected
        case "failed":       return .failed
        case "disconnected": return .disconnected
        default:             return .unknown
        }
    }
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
