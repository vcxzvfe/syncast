import Foundation

/// The one volume law SyncCast uses on both output legs.
///
/// # Why this file exists
///
/// Whole-home mode splits one stereo stream across two completely different
/// attenuators:
///
///  * the **AirPlay leg** — OwnTone's per-output `volume` (0…100) travels over
///    REST, and OwnTone converts it to the RTSP `volume:` header the receiver
///    applies;
///  * the **local leg** — `LocalAirPlayBridge` multiplies every Float32 sample
///    it hands to AUHAL by a linear amplitude.
///
/// Feeding the same 0…1 slider position to both is what made the two legs
/// disagree by up to 10.5 dB at the same slider position, because OwnTone's
/// scale is *decibel*-linear and a raw multiplier is *amplitude*-linear.
///
/// # What this file does and does not guarantee
///
/// It guarantees that both legs **request the same attenuation in decibels**
/// at the same slider position: the local leg applies it directly, and the
/// AirPlay leg puts that same figure on the RTSP `volume:` header. That is
/// what `VolumeCurveTests` pins — it reproduces OwnTone's
/// `airplay_volume_from_pct` exactly.
///
/// It does NOT guarantee the two are equally loud in the room. What a receiver
/// does with that header is its own firmware's business; plenty of AirPlay
/// receivers map it onto an internal 0…100 knob with its own taper rather than
/// applying it as a literal dB attenuation. Residual differences are
/// receiver-side and belong to the per-speaker fader, which exists for exactly
/// that. Verifying it by ear is on the human listening checklist; nothing in
/// this tree can check it.
///
/// # The law, read off the OwnTone source (not assumed)
///
/// `build/owntone-server/src/outputs/airplay.c:1805-1821`:
///
/// ```c
/// /* RAOP volume
///  *  -144.0 is off (not really used since we have no concept of muted/off)
///  *  0 - 100 maps to -30.0 - 0 (if no max_volume set)
///  */
/// if (volume >= 0 && volume <= 100)
///   airplay_volume = -30.0 + ((float)max_volume * (float)volume * 30.0)
///                           / (100.0 * AIRPLAY_CONFIG_MAX_VOLUME);
/// else
///   airplay_volume = -144.0;
/// ```
///
/// `AIRPLAY_CONFIG_MAX_VOLUME` is 11 (`airplay.c:116`), and `volume_max_get`
/// (`airplay.c:1786-1801`) returns that same 11 whenever the device has no
/// `max_volume` in the config. SyncCast ships `max_volume` COMMENTED OUT in
/// `owntone.conf.template`, so `max_volume == AIRPLAY_CONFIG_MAX_VOLUME` and
/// the expression collapses to:
///
///     dB(p) = -30 + 0.3 · p        for p in 0…100
///
/// That collapse is the assumption this whole file rests on, so
/// `VolumeCurveTests` pins it numerically: if anyone ever writes `max_volume`
/// into the config template the slope changes and those tests go red rather
/// than the two legs quietly drifting apart again.
///
/// # Consequences worth stating out loud
///
///  * `p = 0` is **-30 dB, not silence.** OwnTone's only "off" value is -144,
///    and `player.c` rejects a REST volume below 0, so -144 is unreachable
///    through the API we use. A slider at 0 therefore leaves an AirPlay
///    receiver audibly playing at 1/32 amplitude. Both legs honour the same
///    floor so they stay matched — including the LOCAL leg, which could write
///    true zeros but deliberately does not, because a local speaker going
///    silent while its AirPlay partner keeps playing is the mismatch this file
///    exists to prevent. `AppModel.volumeFloorHint` says so on screen for
///    every whole-home row, local or AirPlay, since a fader reading `0%` that
///    is still audible reads as a broken control otherwise. Real silence comes
///    from the per-device MUTE (local leg only) or from the MASTER volume,
///    which is applied upstream of OwnTone entirely (see
///    `AudioSocketWriter.setMasterGain`).
///  * This curve doubles as the perceptual UI law. A -30 dB span in equal dB
///    steps is exactly the "feels linear" mapping a raw 0…1 multiplier is not,
///    so there is deliberately no SECOND perceptual curve layered on top —
///    a second curve would re-introduce the leg mismatch it was meant to fix.
///  * 1 % = 0.3 dB, and the percent grid is the same grid OwnTone quantises
///    to, so dragging the slider moves both legs in identical steps.
public enum VolumeCurve {

    // MARK: - Constants

    /// Attenuation at `p = 0`. From the `-30.0 +` term in
    /// `airplay_volume_from_pct`, and from its comment "0 - 100 maps to
    /// -30.0 - 0".
    public static let minDb: Float = -30.0

    /// Decibels per percentage point: `30.0 / 100.0`, the slope left when
    /// `max_volume == AIRPLAY_CONFIG_MAX_VOLUME`. Derived from `minDb` rather
    /// than written as a literal so the two can never disagree.
    public static let dbPerPercent: Float =
        -minDb / Float(percentRange.upperBound)

    /// `AIRPLAY_CONFIG_MAX_VOLUME` (`airplay.c:116`). Carried only as the
    /// documented anchor for `dbPerPercent`'s derivation and as a test
    /// fixture — nothing computes with it, because SyncCast never sets a
    /// per-device `max_volume`.
    public static let ownToneMaxVolumeReference: Int = 11

    /// The scale both legs and the persistence layer speak in.
    public static let percentRange: ClosedRange<Int> = 0...100

    /// Untouched = full scale = 0 dB. Also the "don't write it to the
    /// defaults plist" sentinel.
    public static let defaultPercent: Int = 100

    /// The bottom of the scale. Named rather than spelled `0` inline
    /// precisely because it is NOT silence on the AirPlay leg — see the type
    /// documentation.
    public static let mutePercent: Int = 0

    /// Linear amplitude for a truly silent output. Only the per-device mute
    /// toggle (local leg) and a master volume of `mutePercent` reach it.
    public static let silentAmplitude: Float = 0

    /// Linear amplitude for "no attenuation".
    public static let unityAmplitude: Float = 1

    // MARK: - Conversions

    public static func clampPercent(_ percent: Int) -> Int {
        min(max(percent, percentRange.lowerBound), percentRange.upperBound)
    }

    /// Attenuation in dB for a slider percentage — the same value OwnTone
    /// puts on the wire for the AirPlay leg.
    ///
    /// Written as "attenuation remaining below full scale" rather than the
    /// literal `minDb + dbPerPercent · p` of the C source. The two are
    /// algebraically identical, but 0.3 is not exactly representable in
    /// binary: the additive form lands 1.9e-6 dB ABOVE zero at p = 100, which
    /// would make unity gain 1.00000022 and cost full-scale samples their
    /// bit-transparency. This form is exact at both endpoints.
    public static func decibels(forPercent percent: Int) -> Float {
        let remaining = percentRange.upperBound - clampPercent(percent)
        return minDb * Float(remaining) / Float(percentRange.upperBound)
    }

    /// Linear amplitude the LOCAL leg must multiply by to match the AirPlay
    /// leg's attenuation at the same slider percentage.
    public static func amplitude(forPercent percent: Int) -> Float {
        // 20·log10(a) = dB  ⇒  a = 10^(dB/20). At p = 100 this is exactly
        // 10^0 = 1, so full scale stays bit-transparent.
        pow(10, decibels(forPercent: percent) / 20)
    }

    /// Snap a 0…1 slider position onto the integer percent grid. Rounding
    /// (not truncation) so the top of the slider reaches 100 and the bottom
    /// reaches 0.
    public static func percent(forFraction fraction: Double) -> Int {
        guard fraction.isFinite else { return defaultPercent }
        return clampPercent(Int((fraction * 100).rounded()))
    }

    /// Inverse of `percent(forFraction:)`. This is what goes over IPC to the
    /// sidecar, which multiplies by 100 and rounds — so a value produced here
    /// survives the round trip onto OwnTone's grid exactly.
    public static func fraction(forPercent percent: Int) -> Double {
        Double(clampPercent(percent)) / 100.0
    }

    // MARK: - Composition

    /// Per-device amplitude for the local leg.
    ///
    /// Mute is the one place the two legs legitimately diverge: locally we can
    /// write true zeros, while OwnTone's floor is -30 dB. They are different
    /// physical speakers, so a muted local speaker being silent while a muted
    /// AirPlay speaker is merely very quiet is a per-device limitation to
    /// surface in the UI, not a sync error.
    public static func deviceAmplitude(forPercent percent: Int, muted: Bool) -> Float {
        muted ? silentAmplitude : amplitude(forPercent: percent)
    }

    /// Master amplitude, applied ONCE upstream of OwnTone so both legs get
    /// bit-identical samples and need no curve reconciliation at all.
    ///
    /// `mutePercent` is special-cased to true zero. Upstream is the only
    /// attenuator in the system that can produce real silence on the AirPlay
    /// leg, so spending the special case here is what makes "mute everything"
    /// actually mean it.
    public static func masterAmplitude(forPercent percent: Int) -> Float {
        let clamped = clampPercent(percent)
        return clamped == mutePercent ? silentAmplitude : amplitude(forPercent: clamped)
    }

    /// What a local speaker ends up multiplying the source by, given both
    /// stages. Master is applied in `AudioSocketWriter` (before the s16
    /// quantisation that feeds OwnTone) and the device stage in
    /// `LocalAirPlayBridge.render`, so the product — not either factor — is
    /// the audible result.
    public static func effectiveLocalAmplitude(
        masterPercent: Int,
        devicePercent: Int,
        deviceMuted: Bool
    ) -> Float {
        masterAmplitude(forPercent: masterPercent)
            * deviceAmplitude(forPercent: devicePercent, muted: deviceMuted)
    }

    /// The AirPlay leg's counterpart: the master stage is a real attenuation
    /// of the samples OwnTone receives, and the device stage is OwnTone's own
    /// dB attenuation, so the two add in the dB domain.
    ///
    /// Returns `nil` when the result is digital silence (master muted), which
    /// has no finite dB value.
    public static func effectiveAirPlayDecibels(
        masterPercent: Int,
        devicePercent: Int
    ) -> Float? {
        let master = masterAmplitude(forPercent: masterPercent)
        guard master > 0 else { return nil }
        return 20 * log10(master) + decibels(forPercent: devicePercent)
    }

    // MARK: - Presentation

    /// `"75%"`. Single formatting site so the panel readout and the
    /// accessibility value cannot drift apart.
    public static func percentLabel(_ percent: Int) -> String {
        "\(clampPercent(percent))%"
    }

    /// `"−12.0 dB"`. Used in the hint that tells the user what the bottom of
    /// an AirPlay slider actually means.
    public static func decibelLabel(_ percent: Int) -> String {
        // `+ 0` collapses the negative zero that full scale produces (the
        // formula multiplies -30 by 0), which would otherwise render as
        // "-0.0 dB" in the panel.
        String(format: "%.1f dB", decibels(forPercent: percent) + 0)
    }
}
