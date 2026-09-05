import Foundation

/// Per-output stereo imaging: the user model, its validation rules, and the
/// geometry that turns "how far apart are the drivers, how far away am I"
/// into a crosstalk-cancellation delay.
///
/// Everything in this file is pure and testable without a CoreAudio device.
/// The real-time side lives in `StereoImageProcessor`, which consumes the
/// values produced here on the app thread.
///
/// # The problem this describes
///
/// A compact stereo speaker carries its two tweeters a handful of centimetres
/// apart above a single mono woofer. Stereo information therefore exists only
/// in the tweeter band; everything below the crossover is L+R summed by the
/// cabinet. From a fixed seat a metre or so away the two tweeters subtend a
/// very small angle, and each ear hears both of them almost equally, so the
/// image collapses to a point between them.
///
/// Two stages, in this order, address the two halves of that:
///
/// 1. **Mid/side width** widens what difference information there is, and only
///    above a corner frequency, because below it there is no usable side
///    signal to widen (the cabinet sums it anyway) and boosting it would just
///    lift room-coupled bass.
/// 2. **Recursive crosstalk cancellation** attacks the reason the difference
///    information does not survive the trip to the listener: each ear hears
///    the opposite driver too, a few tens of microseconds later.
///
/// Both are individually switchable, and the whole module has one A/B bypass,
/// because the only instrument that can judge either of them is the listener.

// MARK: - Width stage

/// Mid/side width, applied above a corner frequency.
///
/// `M = (L+R)/2`, `S = (L−R)/2`. The side signal is high-passed and the
/// high-passed part is scaled, so the recombined output is
/// `S' = S + (width − 1)·HP(S)`: exactly `S` below the corner, `width·S` well
/// above it. `M` is untouched apart from the optional trim, which makes the
/// stage **mono-compatible by construction** — summing L'+R' gives back 2M
/// regardless of `width`, so nothing this stage does can cancel when a
/// downstream device sums to mono.
public struct StereoWidthSettings: Codable, Sendable, Equatable {
    /// Whether the stage runs at all. Off by default: this is a taste
    /// control, and an unopened panel must leave the render path untouched.
    public var enabled: Bool
    /// Side gain above the corner. 1 = unchanged, 0 = mono, 2 = double.
    public var width: Double
    /// Corner of the side high-pass, in hertz. Below it the side signal is
    /// passed through unchanged.
    public var cornerHz: Double
    /// Optional mid attenuation, −1…0 dB, to keep perceived loudness roughly
    /// constant when the side signal is widened. Applied to M only, so it
    /// does not disturb the mono sum's *balance*, only its level.
    public var midTrimDb: Double

    public init(
        enabled: Bool = false,
        width: Double = StereoImageLimits.defaultWidth,
        cornerHz: Double = StereoImageLimits.defaultWidthCornerHz,
        midTrimDb: Double = 0
    ) {
        self.enabled = enabled
        self.width = width
        self.cornerHz = cornerHz
        self.midTrimDb = midTrimDb
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        self.width = try container.decodeIfPresent(Double.self, forKey: .width)
            ?? StereoImageLimits.defaultWidth
        self.cornerHz = try container.decodeIfPresent(Double.self, forKey: .cornerHz)
            ?? StereoImageLimits.defaultWidthCornerHz
        self.midTrimDb = try container.decodeIfPresent(Double.self, forKey: .midTrimDb) ?? 0
    }

    /// True when this stage provably cannot change the signal.
    public var isNeutral: Bool {
        guard enabled else { return true }
        guard width.isFinite, midTrimDb.isFinite else { return true }
        return abs(width - 1) < StereoImageLimits.widthEpsilon
            && abs(midTrimDb) < StereoImageLimits.gainEpsilonDb
    }

    /// Linear mid gain. 1 when the stage is off, so "off" is a true
    /// pass-through rather than "width off, trim still applied".
    public var midAmplitude: Double {
        guard enabled, midTrimDb.isFinite else { return 1 }
        return pow(10, StereoImageLimits.clampMidTrimDb(midTrimDb) / 20)
    }

    /// Load-boundary validation. Non-finite values collapse to the default
    /// rather than reaching the coefficient math — a NaN corner would produce
    /// NaN coefficients and a render thread that emits NaN forever.
    public func sanitized() -> StereoWidthSettings {
        var out = self
        out.width = width.isFinite
            ? StereoImageLimits.clamp(width, to: StereoImageLimits.widthRange)
            : StereoImageLimits.defaultWidth
        out.cornerHz = cornerHz.isFinite
            ? StereoImageLimits.clamp(cornerHz, to: StereoImageLimits.widthCornerRangeHz)
            : StereoImageLimits.defaultWidthCornerHz
        out.midTrimDb = midTrimDb.isFinite
            ? StereoImageLimits.clampMidTrimDb(midTrimDb)
            : 0
        return out
    }
}

// MARK: - Crosstalk stage

/// Recursive crosstalk cancellation, of the shape usually called RACE.
///
/// For each output channel the opposite channel's *output* is subtracted,
/// delayed by τ and attenuated by `a`:
///
/// ```
/// L' = L − a·z^(−τ)·R'
/// R' = R − a·z^(−τ)·L'
/// ```
///
/// Recursive rather than a single feed-forward subtraction because the
/// correction itself crosses to the far ear and needs correcting in turn; the
/// closed form is `L' = (L − a·z^(−τ)·R) / (1 − a²·z^(−2τ))`, whose poles sit
/// strictly inside the unit circle for `|a| < 1` — which is why `a` is clamped
/// there and not merely documented as "should be".
///
/// It is band-limited: below `lowHz` there is no usable interaural difference
/// to correct (and on this cabinet no stereo content at all), above `highHz`
/// head shadowing and pinna effects make the simple two-tap model wrong. The
/// out-of-band signal is split off and added back unprocessed.
public struct StereoCrosstalkSettings: Codable, Sendable, Equatable {
    /// Whether the stage runs at all. Off by default.
    public var enabled: Bool
    /// Crosstalk attenuation in dB, −6…−1. More negative = gentler.
    public var attenuationDb: Double
    /// 0…1 scale on the *linear* `a`, so 0 is a true bypass. The dial the
    /// user is expected to move: it trades image width against the recursion's
    /// own colouration (see `peakColourationDb`).
    public var strength: Double
    /// Centre-to-centre spacing of the two drivers, in metres.
    public var spanMeters: Double
    /// Listening distance, in metres.
    public var distanceMeters: Double
    /// Low edge of the processed band, in hertz. At the minimum the low split
    /// is switched off entirely — there is nothing left to separate.
    public var lowHz: Double
    /// High edge of the processed band, in hertz.
    public var highHz: Double

    public init(
        enabled: Bool = false,
        attenuationDb: Double = StereoImageLimits.defaultAttenuationDb,
        strength: Double = StereoImageLimits.defaultStrength,
        spanMeters: Double = StereoImageLimits.defaultSpanMeters,
        distanceMeters: Double = StereoImageLimits.defaultDistanceMeters,
        lowHz: Double = StereoImageLimits.defaultCrosstalkLowHz,
        highHz: Double = StereoImageLimits.defaultCrosstalkHighHz
    ) {
        self.enabled = enabled
        self.attenuationDb = attenuationDb
        self.strength = strength
        self.spanMeters = spanMeters
        self.distanceMeters = distanceMeters
        self.lowHz = lowHz
        self.highHz = highHz
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        self.attenuationDb = try container.decodeIfPresent(Double.self, forKey: .attenuationDb)
            ?? StereoImageLimits.defaultAttenuationDb
        self.strength = try container.decodeIfPresent(Double.self, forKey: .strength)
            ?? StereoImageLimits.defaultStrength
        self.spanMeters = try container.decodeIfPresent(Double.self, forKey: .spanMeters)
            ?? StereoImageLimits.defaultSpanMeters
        self.distanceMeters = try container.decodeIfPresent(Double.self, forKey: .distanceMeters)
            ?? StereoImageLimits.defaultDistanceMeters
        self.lowHz = try container.decodeIfPresent(Double.self, forKey: .lowHz)
            ?? StereoImageLimits.defaultCrosstalkLowHz
        self.highHz = try container.decodeIfPresent(Double.self, forKey: .highHz)
            ?? StereoImageLimits.defaultCrosstalkHighHz
    }

    /// Interaural path-length difference between the two drivers, in seconds.
    ///
    /// Small-angle approximation: with the head facing the cabinet, the extra
    /// distance from one driver to the far ear over the near ear is
    /// `span · earSpacing / distance`, and τ is that over the speed of sound.
    /// Good to a few percent for the geometry this control exists for (a
    /// narrow cabinet at desk distance); it is the *scale* of τ that matters,
    /// and the user can trim it by moving either slider.
    public var delaySeconds: Double {
        let span = spanMeters.isFinite ? spanMeters : StereoImageLimits.defaultSpanMeters
        let distance = distanceMeters.isFinite
            ? distanceMeters : StereoImageLimits.defaultDistanceMeters
        let clampedSpan = StereoImageLimits.clamp(span, to: StereoImageLimits.spanRangeMeters)
        let clampedDistance = StereoImageLimits.clamp(
            distance, to: StereoImageLimits.distanceRangeMeters
        )
        let pathDifference = clampedSpan * StereoImageLimits.earSpacingMeters / clampedDistance
        return pathDifference / StereoImageLimits.speedOfSoundMetersPerSecond
    }

    /// τ in samples, clamped to something the delay line can serve and to at
    /// least one whole sample.
    ///
    /// The one-sample floor is load-bearing, not cosmetic: the recursion reads
    /// its own past output, and a fractional delay below one sample would need
    /// the sample being computed. Extreme geometry (a very narrow cabinet very
    /// far away) is therefore held at one sample and the UI reports what is
    /// actually in force.
    public func delaySamples(sampleRate: Double) -> Double {
        guard sampleRate.isFinite, sampleRate > 0 else { return 1 }
        let raw = delaySeconds * sampleRate
        guard raw.isFinite else { return 1 }
        return StereoImageLimits.clamp(raw, to: 1...Double(StereoImageLimits.maxDelaySamples))
    }

    /// The linear `a` actually used by the recursion: strength × 10^(dB/20),
    /// hard-clamped below 1 so the closed-form poles stay inside the unit
    /// circle no matter what a corrupt store or a future UI hands over.
    public var feedbackAmplitude: Double {
        guard enabled, attenuationDb.isFinite, strength.isFinite else { return 0 }
        let scale = StereoImageLimits.clamp(strength, to: StereoImageLimits.strengthRange)
        guard scale > StereoImageLimits.strengthEpsilon else { return 0 }
        let linear = pow(10, StereoImageLimits.clampAttenuationDb(attenuationDb) / 20)
        return min(scale * linear, StereoImageLimits.maxFeedbackAmplitude)
    }

    /// Worst-case in-band gain the recursion applies to *correlated* (centred)
    /// content, in dB: `1/(1−a)` at `f = 1/(2τ)`.
    ///
    /// This is inherent to the structure, not a bug — the same recursion that
    /// cancels crosstalk boosts what is common to both channels near that
    /// frequency. Surfaced because it is the number that decides whether the
    /// user's setting is going to sound coloured, and because it is what drives
    /// the output limiter.
    public var peakColourationDb: Double {
        let a = feedbackAmplitude
        guard a > 0, a < 1 else { return 0 }
        return -20 * log10(1 - a)
    }

    /// Frequency at which that peak lands, in hertz (`1/(2τ)`).
    public var peakColourationHz: Double {
        let tau = delaySeconds
        guard tau > 0 else { return 0 }
        return 1 / (2 * tau)
    }

    /// True when this stage provably cannot change the signal.
    public var isNeutral: Bool {
        guard enabled else { return true }
        return feedbackAmplitude <= 0
    }

    /// Load-boundary validation. Also enforces `lowHz < highHz` with a minimum
    /// separation, because a collapsed or inverted band would make the split
    /// filters fight each other rather than sum to the input.
    public func sanitized() -> StereoCrosstalkSettings {
        var out = self
        out.attenuationDb = attenuationDb.isFinite
            ? StereoImageLimits.clampAttenuationDb(attenuationDb)
            : StereoImageLimits.defaultAttenuationDb
        out.strength = strength.isFinite
            ? StereoImageLimits.clamp(strength, to: StereoImageLimits.strengthRange)
            : StereoImageLimits.defaultStrength
        out.spanMeters = spanMeters.isFinite
            ? StereoImageLimits.clamp(spanMeters, to: StereoImageLimits.spanRangeMeters)
            : StereoImageLimits.defaultSpanMeters
        out.distanceMeters = distanceMeters.isFinite
            ? StereoImageLimits.clamp(distanceMeters, to: StereoImageLimits.distanceRangeMeters)
            : StereoImageLimits.defaultDistanceMeters
        out.lowHz = lowHz.isFinite
            ? StereoImageLimits.clamp(lowHz, to: StereoImageLimits.crosstalkLowRangeHz)
            : StereoImageLimits.defaultCrosstalkLowHz
        out.highHz = highHz.isFinite
            ? StereoImageLimits.clamp(highHz, to: StereoImageLimits.crosstalkHighRangeHz)
            : StereoImageLimits.defaultCrosstalkHighHz
        if out.highHz < out.lowHz * StereoImageLimits.minimumBandRatio {
            out.highHz = StereoImageLimits.clamp(
                out.lowHz * StereoImageLimits.minimumBandRatio,
                to: StereoImageLimits.crosstalkHighRangeHz
            )
        }
        return out
    }
}

// MARK: - Settings

/// One output device's complete stereo-image setting.
public struct StereoImageSettings: Codable, Sendable, Equatable {
    /// The A/B switch. A bypassed module is remembered but inert, so
    /// comparing "with" against "without" never costs the user the setting.
    public var bypassed: Bool
    public var width: StereoWidthSettings
    public var crosstalk: StereoCrosstalkSettings

    public init(
        bypassed: Bool = false,
        width: StereoWidthSettings = StereoWidthSettings(),
        crosstalk: StereoCrosstalkSettings = StereoCrosstalkSettings()
    ) {
        self.bypassed = bypassed
        self.width = width
        self.crosstalk = crosstalk
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.bypassed = try container.decodeIfPresent(Bool.self, forKey: .bypassed) ?? false
        self.width = try container.decodeIfPresent(StereoWidthSettings.self, forKey: .width)
            ?? StereoWidthSettings()
        self.crosstalk = try container
            .decodeIfPresent(StereoCrosstalkSettings.self, forKey: .crosstalk)
            ?? StereoCrosstalkSettings()
    }

    /// Nothing engaged: both stages off, everything at its default.
    public static let neutral = StereoImageSettings()

    /// True when this setting provably cannot change the signal. The render
    /// path's fast exit keys on this, so "module installed but off" costs
    /// exactly what it did before the feature existed.
    public var isNeutral: Bool {
        if bypassed { return true }
        return width.isNeutral && crosstalk.isNeutral
    }

    /// True when the user has dialled something in, whether or not it is
    /// currently bypassed. Drives "this row has a setting" affordances and
    /// decides whether the record is worth persisting.
    public var hasUserSetting: Bool {
        var probe = self
        probe.bypassed = false
        return !probe.isNeutral
    }

    public func sanitized() -> StereoImageSettings {
        var out = self
        out.width = width.sanitized()
        out.crosstalk = crosstalk.sanitized()
        return out
    }
}

// MARK: - Limits

public enum StereoImageLimits {

    // Physical constants. Named rather than inlined because they are the
    // assumptions the derived delay rests on, and a reader checking the
    // arithmetic needs to find them.

    /// Speed of sound in air at room temperature, m/s.
    public static let speedOfSoundMetersPerSecond: Double = 343
    /// Interaural distance used by the path-difference model, in metres.
    /// A population average; it is not offered as a control because the
    /// listening-distance slider already covers the same axis of the answer.
    public static let earSpacingMeters: Double = 0.15

    // Width stage.

    public static let widthRange: ClosedRange<Double> = 0...2
    public static let defaultWidth: Double = 1.4
    public static let widthStep: Double = 0.05
    /// Below this, a width is treated as exactly 1 — which is what lets the
    /// stage be skipped rather than run as an identity.
    public static let widthEpsilon: Double = 0.005
    public static let widthCornerRangeHz: ClosedRange<Double> = 200...6_000
    public static let defaultWidthCornerHz: Double = 1_500
    public static let widthCornerStepHz: Double = 50
    public static let midTrimRangeDb: ClosedRange<Double> = -1...0
    public static let midTrimStepDb: Double = 0.1
    public static let gainEpsilonDb: Double = 0.01

    // Crosstalk stage.

    public static let attenuationRangeDb: ClosedRange<Double> = -6...(-1)
    public static let defaultAttenuationDb: Double = -2.5
    public static let attenuationStepDb: Double = 0.1
    public static let strengthRange: ClosedRange<Double> = 0...1
    /// Deliberately below 1. At full strength the recursion's own colouration
    /// (`peakColourationDb`) is +12 dB at the default attenuation, which is a
    /// lot to hand someone as a starting point; ~60% puts it near +5 dB, wide
    /// enough to hear the effect and mild enough to live with. The user can
    /// take it further while watching the clip indicator.
    public static let defaultStrength: Double = 0.6
    public static let strengthStep: Double = 0.05
    public static let strengthEpsilon: Double = 0.001
    /// Hard ceiling on the linear feedback coefficient. `|a| < 1` is the
    /// stability condition for the closed form; the margin absorbs float
    /// arithmetic and leaves the peak gain finite.
    public static let maxFeedbackAmplitude: Double = 0.95

    public static let spanRangeMeters: ClosedRange<Double> = 0.05...0.60
    public static let defaultSpanMeters: Double = 0.17
    public static let spanStepMeters: Double = 0.005
    public static let distanceRangeMeters: ClosedRange<Double> = 0.20...3.00
    public static let defaultDistanceMeters: Double = 0.65
    public static let distanceStepMeters: Double = 0.05

    public static let crosstalkLowRangeHz: ClosedRange<Double> = 20...4_000
    public static let defaultCrosstalkLowHz: Double = 1_500
    public static let crosstalkHighRangeHz: ClosedRange<Double> = 2_000...24_000
    public static let defaultCrosstalkHighHz: Double = 7_000
    public static let crosstalkBandStepHz: Double = 100
    /// The high edge is pushed up if the user drags the low edge past it, so
    /// the band never collapses or inverts.
    public static let minimumBandRatio: Double = 1.5

    /// Longest τ the delay line can serve, in samples. `spanMax·ear/distanceMin`
    /// is 1.31 ms, which is 252 samples at 192 kHz — the highest rate any of
    /// these outputs is opened at. Anything beyond is clamped.
    public static let maxDelaySamples: Int = 250
    /// Power-of-two ring length so the read index can be masked rather than
    /// branched. Must exceed `maxDelaySamples` by at least two, because linear
    /// interpolation reads `floor(τ)` and `floor(τ)+1` samples back.
    public static let delayLineLength: Int = 256

    /// Setting the low edge to its minimum means "no low edge": the high-pass
    /// half of the split is switched off rather than run at 20 Hz, where it
    /// would only add phase.
    public static func lowSplitIsEngaged(_ lowHz: Double) -> Bool {
        lowHz > crosstalkLowRangeHz.lowerBound + 0.5
    }

    /// A corner this close to Nyquist cannot be realised as a meaningful
    /// second-order section, so the low-pass half of the split is switched off
    /// instead of being asked for coefficients it cannot produce. At 48 kHz
    /// this is what the 24 kHz maximum means.
    public static func highSplitIsEngaged(_ highHz: Double, sampleRate: Double) -> Bool {
        guard sampleRate > 0 else { return false }
        return highHz < 0.45 * sampleRate
    }

    public static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, value))
    }

    public static func clampAttenuationDb(_ db: Double) -> Double {
        db.isFinite ? clamp(db, to: attenuationRangeDb) : defaultAttenuationDb
    }

    public static func clampMidTrimDb(_ db: Double) -> Double {
        db.isFinite ? clamp(db, to: midTrimRangeDb) : 0
    }

    /// Snap to a UI grid so a stored value and a slider position always agree.
    public static func snap(_ value: Double, step: Double) -> Double {
        guard value.isFinite, step > 0 else { return 0 }
        return (value / step).rounded() * step
    }
}

// MARK: - Butterworth sections

/// Second-order Butterworth low-/high-pass coefficients, in the same
/// normalised form the equalizer uses (`BiquadCoefficients`, a0 == 1), so the
/// stability check and the offline magnitude helper are shared rather than
/// re-derived.
public enum StereoImageFilter {

    /// Q of a maximally flat (Butterworth) second-order section.
    public static let butterworthQ: Double = 0.7071067811865476

    public static func highpass(cornerHz: Double, sampleRate: Double) -> BiquadCoefficients {
        section(cornerHz: cornerHz, sampleRate: sampleRate, highpass: true)
    }

    public static func lowpass(cornerHz: Double, sampleRate: Double) -> BiquadCoefficients {
        section(cornerHz: cornerHz, sampleRate: sampleRate, highpass: false)
    }

    /// RBJ cookbook LPF/HPF, Q form. Returns `.identity` for anything the
    /// formulas are not defined on — a corner at or above Nyquist, a
    /// non-positive rate, a non-finite input. Refusing to produce coefficients
    /// is the only safe failure: a NaN section poisons the filter state
    /// permanently, and here it would poison a *feedback* loop.
    private static func section(
        cornerHz: Double,
        sampleRate: Double,
        highpass: Bool
    ) -> BiquadCoefficients {
        guard cornerHz.isFinite, sampleRate.isFinite, sampleRate > 0, cornerHz > 0 else {
            return .identity
        }
        let nyquist = sampleRate / 2
        guard cornerHz < nyquist * 0.999 else { return .identity }

        let w0 = 2 * Double.pi * cornerHz / sampleRate
        let cosW0 = cos(w0)
        let sinW0 = sin(w0)
        let alpha = sinW0 / (2 * butterworthQ)

        let b0: Double, b1: Double, b2: Double
        if highpass {
            let shared = (1 + cosW0) / 2
            b0 = shared
            b1 = -(1 + cosW0)
            b2 = shared
        } else {
            let shared = (1 - cosW0) / 2
            b0 = shared
            b1 = 1 - cosW0
            b2 = shared
        }
        let a0 = 1 + alpha
        let a1 = -2 * cosW0
        let a2 = 1 - alpha
        guard a0.isFinite, abs(a0) > 1e-12 else { return .identity }
        let coefficients = BiquadCoefficients(
            b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0
        )
        return coefficients.isUsable ? coefficients : .identity
    }
}
