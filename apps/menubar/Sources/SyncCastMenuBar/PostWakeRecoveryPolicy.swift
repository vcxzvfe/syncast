import Foundation

/// When the post-wake recovery loop is done, and what it does when it is not.
///
/// # The failure this encodes
///
/// After a wake the menubar rebuilds the local audio path (on the sink path:
/// the sink, the tap pinned to it, the outputs). It used to keep rebuilding
/// until every output enabled before the Mac slept resolved to a live device
/// again, INCLUDING outputs that had disappeared while the Mac was still
/// awake. A display unplugged at home is one: away from home it never comes
/// back, so every wake at the office tore a working path down and rebuilt it
/// four times in about 35 seconds, against a coreaudiod still busy with the
/// wake. The log shows this on every away-from-home wake from 2026-11-20 on;
/// on 2026-11-25 the last two of those rebuilds lost the race to publish the
/// tap, and the app was left "running" with no sink path behind it.
///
/// # The rule
///
/// - Done when capture is up and every output that is enabled NOW resolves to
///   a live device. Those are the outputs the rebuild opens; one that does not
///   resolve was republished under a new id the rebuild missed, which another
///   rebuild does fix.
/// - Outputs that went away before the wake never gate success. The rebuild
///   cannot open them (their routing entry went with them), and one that comes
///   back rejoins the way it always has: the auto-connect arrival or the user
///   switches it on and the ordinary reconcile adds it to the running path.
///   Waiting for it can only cost rebuilds.
/// - Out of attempts with capture up: the path plays. Stop and name the
///   outputs that never resolved.
/// - Out of attempts with capture down: there is no path. Say so, and leave
///   the engine stopped instead of "running" with nothing behind it.
enum PostWakeRecoveryPolicy {

    enum Verdict: Equatable, Sendable {
        /// Capture is up and every enabled output resolves.
        case recovered
        /// Rebuild again after the next backoff.
        case retry
        /// Out of attempts; capture is up, these enabled outputs never
        /// resolved. The path keeps running without them.
        case gaveUpPlaying(unresolved: [String])
        /// Out of attempts and capture never came up.
        case gaveUpSilent
    }

    /// Verdict after rebuild `attempt` (0-based) of `maxAttempts`.
    ///
    /// - Parameter unresolvedEnabledUIDs: outputs enabled at the time of the
    ///   rebuild whose UID does not translate to a live device. Outputs that
    ///   disappeared before the wake are not in here, by design.
    static func verdict(
        captureOK: Bool,
        unresolvedEnabledUIDs: [String],
        attempt: Int,
        maxAttempts: Int
    ) -> Verdict {
        if captureOK && unresolvedEnabledUIDs.isEmpty { return .recovered }
        guard attempt + 1 >= maxAttempts else { return .retry }
        return captureOK
            ? .gaveUpPlaying(unresolved: unresolvedEnabledUIDs.sorted())
            : .gaveUpSilent
    }

    /// Outputs remembered as "enabled when they disappeared" that are still
    /// not present once the recovery has finished. The loop reports them and
    /// forgets them, so a display unplugged days ago is not carried into
    /// every later wake.
    static func stillAbsent(
        remembered: Set<String>,
        presentNow: Set<String>
    ) -> [String] {
        remembered.subtracting(presentNow).sorted()
    }
}
