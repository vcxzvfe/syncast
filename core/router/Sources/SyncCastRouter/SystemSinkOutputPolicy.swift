import Foundation

/// The question `startSystemSinkPath` has to answer after it has taken the
/// default output over: is there anywhere for the captured audio to go?
///
/// It is worth its own type because getting it wrong is silent in one
/// direction and loud in the other. Too strict, and a legitimate output set is
/// rejected — a LAN receiver on its own used to fail with
/// `SyncCastRouter` code 112 even though the leg it needs was open and ready.
/// Too lax, and the sink stays the system default with nothing rendering it,
/// which is the "everything is playing but there is no sound" state this
/// check exists to prevent.
///
/// The rule: a leg is a leg. A CoreAudio AUHAL and a LAN receiver leg both
/// read the same capture ring and both end in something audible, so either one
/// alone is enough. Only *neither* is a failure.
public enum SystemSinkOutputPolicy {

    /// Whether the sink path has at least one place to send audio.
    ///
    /// - Parameters:
    ///   - localOutputCount: open CoreAudio AUHALs (individual or the single
    ///     aggregate).
    ///   - lanReceiverLegCount: open LAN receiver legs. A receiver that is
    ///     enabled but has no token yet does NOT count — no leg is opened for
    ///     it, so it plays nothing.
    public static func hasRenderableOutput(
        localOutputCount: Int,
        lanReceiverLegCount: Int
    ) -> Bool {
        localOutputCount > 0 || lanReceiverLegCount > 0
    }

    /// The failure text for the no-output case, with whatever the local driver
    /// last complained about appended.
    ///
    /// Says "no output" rather than "no local output": with LAN legs in the
    /// picture the old wording sent readers looking for a CoreAudio problem
    /// that was not there.
    public static func noOutputMessage(lastError: String?) -> String {
        let base = "system sink is the default output but no output could be opened"
            + " (no CoreAudio output and no LAN receiver leg)"
        guard let lastError, !lastError.isEmpty else { return base }
        return base + ": " + lastError
    }
}
