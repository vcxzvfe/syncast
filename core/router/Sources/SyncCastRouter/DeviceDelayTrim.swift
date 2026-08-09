import Foundation

/// Per-output millisecond delay trim: the user's compensation for how far
/// each speaker sits from where they actually listen, plus whatever residual
/// systematic skew the Layer-1/2/3 stack leaves behind.
///
/// This is deliberately NOT part of the sync machinery. Layers 1-3 make every
/// output leave OwnTone's clock domain together and stay there; this trim is
/// a *steady-state bias* the user dials in afterwards, applied downstream of
/// the Layer-2 control loop's observation point so the loop cannot see it.
///
/// Sign convention: POSITIVE = later (hold this speaker back). A speaker that
/// is further away arrives late by its extra flight time, so the user either
/// dials it NEGATIVE or dials the near ones positive — both express the same
/// relative pattern, which is all that is physically meaningful (see
/// `DelayTrimNormalizer`).
public enum DeviceDelayTrim {
    /// User-facing range. ±200 ms covers ~±68 m of path difference, far
    /// beyond any domestic listening room; the bound exists to keep a
    /// fat-fingered entry from buying a visible lip-sync error rather than
    /// to model any real geometry. Normalisation can concentrate the whole
    /// span on ONE output (−200 here, +200 there ⇒ 400 ms on the later one),
    /// so 400 ms — not 200 — is what the local ring has to serve.
    ///
    /// Safe against the local leg's ring only because
    /// `LocalAirPlayBridge.defaultRingCapacityFrames` is sized to serve the
    /// widest normalised span (`upperBound - lowerBound`) at every device
    /// rate — see `LocalBridgeTrimHeadroomTests`. The bridge additionally
    /// clamps to the headroom it computes at runtime from its real device
    /// rate and render quantum, so this constant is an ergonomic bound and
    /// that clamp is the safety bound. Widening this range without
    /// re-checking that test would make the clamp reachable, and a reachable
    /// clamp silently breaks the relative alignment the feature exists for.
    public static let rangeMs: ClosedRange<Int> = -200...200

    /// UI step and the deadband floor. 1 ms ≈ 34 cm, already finer than
    /// anyone can place a listening chair.
    public static let stepMs: Int = 1

    /// Speed of sound in dry air at ~20 °C, used only for the "≈ 1.0 m"
    /// hint next to the control. Named so the magic 343 never appears
    /// inline.
    public static let speedOfSoundMPerS: Double = 343.0

    /// Clamp an arbitrary integer into `rangeMs`.
    public static func clamp(_ ms: Int) -> Int {
        min(max(ms, rangeMs.lowerBound), rangeMs.upperBound)
    }

    /// Path-length equivalent of a trim, in metres. Always non-negative —
    /// the sign is carried by the caller's wording ("closer" / "further").
    public static func distanceMeters(forMs ms: Int) -> Double {
        abs(Double(ms)) / 1000.0 * speedOfSoundMPerS
    }
}

/// Outcome of pushing the per-output trims to both legs.
///
/// Exists so a failed AirPlay push cannot be mistaken for a successful one.
/// The local leg is applied synchronously and always lands; the AirPlay leg
/// crosses IPC, and if that half is dropped the two legs disagree by exactly
/// the amount the user just dialled in — with the UI showing the new value.
public enum DeviceTrimPushResult: Sendable, Equatable {
    /// The AirPlay leg carries the requested trims, or there was nothing to
    /// send (unchanged map, or no AirPlay output in play).
    case applied
    /// The push did not land. The caller owns the retry; nothing is recorded
    /// as pushed, so a later attempt starts from the real state.
    case failed
}

/// Turns the user's *relative* per-output trims into the *non-negative*
/// delays the two legs can actually apply.
///
/// Why this exists: neither leg can play a sample EARLY. The local leg reads
/// bytes out of OwnTone's fifo and cannot receive one before OwnTone releases
/// it; the AirPlay leg's `offset_ms` is likewise a hold-back. Users, however,
/// think in "this speaker is early / that one is late". So the UI stores
/// signed intent and this normaliser slides the whole set up until the
/// earliest speaker sits at exactly 0, preserving every pairwise difference.
///
/// Pure and total: no I/O, no clock, no device knowledge. That is what makes
/// it unit-testable, and the tests are the specification.
public enum DelayTrimNormalizer {
    /// Normalise `raw` over the currently-enabled output set.
    ///
    /// - Parameters:
    ///   - raw: signed user intent, keyed by device id. Ids missing from the
    ///     map count as 0 — an untouched speaker is still a participant and
    ///     must take part in the minimum, otherwise enabling it would leave
    ///     it un-shifted relative to everyone else.
    ///   - enabled: the outputs actually in play right now. Anything outside
    ///     this set is excluded from BOTH the minimum and the result; a
    ///     disabled speaker holding an extreme value must never shift the
    ///     speakers the user is listening to.
    /// - Returns: one entry per enabled id, every value ≥ 0, at least one
    ///   value exactly 0. Empty in, empty out.
    public static func normalize(
        raw: [String: Int],
        enabled: Set<String>
    ) -> [String: Int] {
        guard !enabled.isEmpty else { return [:] }
        var clamped: [String: Int] = [:]
        clamped.reserveCapacity(enabled.count)
        for id in enabled {
            clamped[id] = DeviceDelayTrim.clamp(raw[id] ?? 0)
        }
        // `enabled` is non-empty, so `min()` cannot be nil.
        guard let minimum = clamped.values.min() else { return [:] }
        let shift = -minimum
        return clamped.mapValues { $0 + shift }
    }
}
