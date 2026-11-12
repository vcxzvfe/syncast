import Foundation

/// One PTP hand-over from SyncCast to macOS's own AirPlay sender.
///
/// OwnTone holds UDP 319/320 for AirPlay 2 PTP timing for as long as it runs,
/// and while it does macOS cannot start an AirPlay session of its own: Apple
/// Music ticks the HomePod and plays silence. The sidecar watches
/// AirPlayXPCHelper's log and kills OwnTone the moment macOS activates an
/// endpoint (see `sidecar/src/syncast_sidecar/system_airplay_watch.py`), then
/// reports it with `event.system_airplay_yield`. This is that report.
public struct SystemAirPlayYield: Equatable, Sendable {
    /// What the sidecar reacted to.
    public enum Trigger: String, Sendable {
        /// macOS was about to add its PTP peer; the hand-over came in time
        /// and its session starts normally.
        case activation
        /// macOS had already failed to add its peer. The ports are free now,
        /// but that one session will not recover on its own: the user has to
        /// pick the speaker again.
        case ptpConflict = "ptp_conflict"
    }

    /// Monotonic per Router; lets a poller handle each event exactly once.
    public let sequence: Int
    public let trigger: Trigger
    /// The AirPlay receiver macOS activated, when the log line named one.
    public let endpoint: String?
    /// Sidecar mode at the moment of the hand-over ("whole_home"/"stereo").
    public let previousMode: String?
    /// SyncCast devices whose AirPlay leg stopped.
    public let deviceIDs: [String]

    public init(
        sequence: Int,
        trigger: Trigger,
        endpoint: String?,
        previousMode: String?,
        deviceIDs: [String]
    ) {
        self.sequence = sequence
        self.trigger = trigger
        self.endpoint = endpoint
        self.previousMode = previousMode
        self.deviceIDs = deviceIDs
    }

    /// Decode the notification's params. Unknown or missing `kind` decodes
    /// as `.activation`: either way the ports were handed over, and only the
    /// recovery hint differs.
    public static func fromWire(_ params: [String: Any], sequence: Int) -> SystemAirPlayYield {
        let kind = params["kind"] as? String
        let endpoint = (params["endpoint"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return SystemAirPlayYield(
            sequence: sequence,
            trigger: kind.flatMap(Trigger.init(rawValue:)) ?? .activation,
            endpoint: endpoint,
            previousMode: params["previous_mode"] as? String,
            deviceIDs: params["device_ids"] as? [String] ?? []
        )
    }
}

extension Router {
    func recordSystemAirPlayYield(_ decoded: SystemAirPlayYield) {
        systemAirPlayYieldCount += 1
        let event = SystemAirPlayYield(
            sequence: systemAirPlayYieldCount,
            trigger: decoded.trigger,
            endpoint: decoded.endpoint,
            previousMode: decoded.previousMode,
            deviceIDs: decoded.deviceIDs
        )
        systemAirPlayYieldStorage = event
        RouterLog.write(
            "[Router] handed PTP to macOS AirPlay (\(event.trigger.rawValue)) endpoint=\(event.endpoint ?? "?") previousMode=\(event.previousMode ?? "?")\n"
        )
    }

    /// Latest hand-over, or nil if there has been none since launch.
    public func latestSystemAirPlayYield() -> SystemAirPlayYield? {
        systemAirPlayYieldStorage
    }
}
