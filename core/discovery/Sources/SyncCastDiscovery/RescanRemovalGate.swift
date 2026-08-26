import Foundation

/// Bookkeeping for the grace window that follows a manual AirPlay rescan.
///
/// # Why this is its own type
///
/// A just-restarted `NWBrowser` delivers its first
/// `browseResultsChangedHandler` callbacks with whatever it has resolved so
/// far — frequently an empty or partial set. `AirPlayDiscovery.handleResults`
/// treats "absent from this callback" as gone, so the refresh itself would
/// report every currently-playing receiver as disappeared and tear down the
/// routing it was meant to help.
///
/// The first fix was to DROP removals inside the window, and that was unsound:
/// `NWBrowser` only invokes the handler when the result set CHANGES. A
/// receiver powered off two seconds after a rescan produces exactly one
/// callback, inside the window; if nothing else on the network moves there is
/// never another callback, so the departure is never reported at all and the
/// dead receiver stays listed — and, in whole-home mode, stays registered as
/// an OwnTone output — for the rest of the session.
///
/// So removals are DEFERRED instead: the gate remembers the keys the browser
/// last reported and asks its owner to re-run the diff once the window closes.
///
/// # Why it is pure
///
/// `Set<NWBrowser.Result>` cannot be constructed in a test, so any logic left
/// inside `handleResults` is only reachable with live Bonjour traffic — which
/// is exactly how the drop-instead-of-defer bug survived. Everything here is
/// value-typed and clock-injected; `AirPlayDiscoveryTests` drives every branch
/// with no network at all.
///
/// Not thread-safe by itself: `AirPlayDiscovery` confines its instance to the
/// same serial queue as `seen` and the browser callbacks.
struct RescanRemovalGate {

    /// What the owner should do about the removal pass right now.
    enum Action: Equatable {
        /// Diff the registry against `lastBrowserKeys` and emit `.disappeared`.
        case emitNow
        /// Hold the removals and schedule one re-check this many seconds out.
        case deferBy(TimeInterval)
        /// Removals are held and a re-check is already queued — do nothing, or
        /// a burst of suppressed callbacks would queue one timer each.
        case alreadyScheduled
    }

    /// Removals are held until this instant. `.distantPast` = no window.
    private(set) var suppressedUntil: Date = .distantPast

    /// Whether a deferred re-check is queued. Owned here rather than by the
    /// caller so "queue exactly one" is part of the tested contract.
    private(set) var recheckScheduled = false

    /// Registry keys present in the browser's most recent callback. This is
    /// what the deferred pass diffs against, so a departure observed inside
    /// the window is still actionable after it closes.
    private(set) var lastBrowserKeys: Set<String> = []

    /// Open (or extend) the grace window. Called from `rescan()`.
    ///
    /// A second rescan during an open window pushes the deadline out rather
    /// than shortening it: the newest browser is the one whose first callbacks
    /// are incomplete.
    mutating func suppressRemovals(until deadline: Date) {
        suppressedUntil = max(suppressedUntil, deadline)
    }

    /// Record a browser callback's key set and decide what to do with the
    /// removal pass it implies.
    mutating func observe(keys: Set<String>, now: Date) -> Action {
        lastBrowserKeys = keys
        return decide(now: now)
    }

    /// A previously scheduled re-check has fired.
    ///
    /// Re-arms rather than emitting when the window has been extended by a
    /// second rescan in the meantime: removing against a set the newest
    /// browser has not refreshed is the original bug in slow motion.
    mutating func recheckFired(now: Date) -> Action {
        recheckScheduled = false
        return decide(now: now)
    }

    private mutating func decide(now: Date) -> Action {
        guard now < suppressedUntil else {
            // Window closed. Leaving `recheckScheduled` set here would block
            // every future deferral, so it is cleared on the way out; an
            // already-queued timer that fires later is harmless because the
            // diff it triggers is idempotent.
            recheckScheduled = false
            return .emitNow
        }
        if recheckScheduled { return .alreadyScheduled }
        recheckScheduled = true
        return .deferBy(suppressedUntil.timeIntervalSince(now))
    }
}
