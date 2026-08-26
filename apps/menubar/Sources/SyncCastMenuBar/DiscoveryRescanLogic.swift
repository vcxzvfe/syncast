import Foundation

/// Why a manual "rescan devices" request was accepted or dropped.
enum DiscoveryRescanDecision: Equatable {
    /// Run the scan.
    case start
    /// A scan is still running. Mashing the button must not stack scans:
    /// each one cancels and rebuilds an `NWBrowser`, and a burst of those
    /// is exactly the mDNS storm the button is supposed to help with.
    case dropInFlight
    /// The previous scan finished recently. Re-querying immediately buys
    /// nothing — the responder's cache is as fresh as it just got — so the
    /// cooldown keeps a determined user from re-arming a scan every time
    /// the spinner clears.
    case dropCoolingDown
}

/// Pure re-entrancy/cooldown gate for manual device rescans, kept out of
/// `AppModel` so the two drop paths are checkable without a live
/// `NWBrowser` or a wall-clock wait.
enum DiscoveryRescanGate {
    struct State: Equatable {
        /// A scan has been requested and its visible feedback window has
        /// not elapsed yet.
        var inFlight: Bool = false
        /// When the last accepted scan started. `distantPast` means never,
        /// so the first request is always accepted.
        var lastStartedAt: Date = .distantPast

        init(inFlight: Bool = false, lastStartedAt: Date = .distantPast) {
            self.inFlight = inFlight
            self.lastStartedAt = lastStartedAt
        }
    }

    static func decide(
        state: State,
        now: Date,
        cooldown: TimeInterval
    ) -> DiscoveryRescanDecision {
        if state.inFlight { return .dropInFlight }
        // `>=` rather than `>`: with a zero cooldown every request should
        // be accepted, and two requests at the same instant on a coarse
        // clock should not be silently different from two a millisecond
        // apart.
        guard now.timeIntervalSince(state.lastStartedAt) >= cooldown else {
            return .dropCoolingDown
        }
        return .start
    }

    static func started(from state: State, at now: Date) -> State {
        State(inFlight: true, lastStartedAt: now)
    }

    /// The feedback window closed. `lastStartedAt` is deliberately left
    /// alone: the cooldown is measured from the START of the last scan, so
    /// it overlaps the feedback window rather than following it.
    static func finished(from state: State) -> State {
        State(inFlight: false, lastStartedAt: state.lastStartedAt)
    }
}
