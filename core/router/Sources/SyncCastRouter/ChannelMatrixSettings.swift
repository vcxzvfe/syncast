import Foundation

/// Per-output channel assignment ("声道分配"): which source channel reaches
/// which output channel, and at what level.
///
/// Everything in this file is pure and testable without a CoreAudio device.
/// The real-time side lives in `ChannelMatrixBank`, which consumes the
/// `ChannelMatrix` values produced here on the app thread.
///
/// # The problem this describes
///
/// A stereo program played on two independent speakers is not always wanted as
/// a stereo pair. A speaker sitting alone on the left of a desk should carry
/// the LEFT channel — on both of its own drivers, because it is one cabinet,
/// not one half of a pair. A mono-ish bedside speaker wants L+R summed rather
/// than an arbitrary half of the mix. And a display whose panel speakers are
/// only there for dialogue may want the whole program summed and attenuated.
///
/// One 2×2 gain matrix expresses all of that:
///
/// ```
/// out.L = m[0][0]·in.L + m[0][1]·in.R
/// out.R = m[1][0]·in.L + m[1][1]·in.R
/// ```
///
/// The presets are the four answers people actually want; `custom` exposes the
/// four coefficients as decibel sliders for everything else.

// MARK: - Preset

/// The named answers. `custom` means "read the four decibel values instead".
public enum ChannelMatrixPreset: String, Codable, Sendable, CaseIterable {
    /// `[[1,0],[0,1]]` — untouched. The default, and a bit-identical
    /// pass-through in the render path.
    case stereo
    /// `[[1,0],[1,0]]` — BOTH output channels carry the source's left channel.
    /// Not `[[1,0],[0,0]]`: the target is one cabinet with two drivers, and
    /// silencing one of them would just make it quieter and lopsided.
    case left
    /// `[[0,1],[0,1]]` — both output channels carry the source's right channel.
    case right
    /// `[[.5,.5],[.5,.5]]` — L+R summed at −6 dB each, so a full-scale
    /// correlated program sums to exactly full scale rather than clipping.
    case mono
    /// The four coefficients come from `ChannelMatrixSettings`' decibel fields.
    case custom
}

// MARK: - Matrix

/// The four linear coefficients, in the order the render path multiplies them.
///
/// Deliberately a plain value type with no validation of its own: it is the
/// *output* of `ChannelMatrixSettings.matrix`, which is where the clamping and
/// the non-finite rejection happen.
public struct ChannelMatrix: Sendable, Equatable {
    /// Source left → output left.
    public var leftToLeft: Double
    /// Source right → output left.
    public var rightToLeft: Double
    /// Source left → output right.
    public var leftToRight: Double
    /// Source right → output right.
    public var rightToRight: Double

    public init(
        leftToLeft: Double,
        rightToLeft: Double,
        leftToRight: Double,
        rightToRight: Double
    ) {
        self.leftToLeft = leftToLeft
        self.rightToLeft = rightToLeft
        self.leftToRight = leftToRight
        self.rightToRight = rightToRight
    }

    public static let identity = ChannelMatrix(
        leftToLeft: 1, rightToLeft: 0, leftToRight: 0, rightToRight: 1
    )

    /// True when this matrix provably cannot change the signal, within the
    /// tolerance a decibel slider can express.
    public var isIdentity: Bool {
        abs(leftToLeft - 1) < ChannelMatrixLimits.amplitudeEpsilon
            && abs(rightToRight - 1) < ChannelMatrixLimits.amplitudeEpsilon
            && abs(rightToLeft) < ChannelMatrixLimits.amplitudeEpsilon
            && abs(leftToRight) < ChannelMatrixLimits.amplitudeEpsilon
    }

    /// Worst-case output amplitude for a ±1 full-scale input, per output
    /// channel. Used by the UI to warn before the render path's limiter has to
    /// say the same thing in clip counts.
    public var worstCaseGain: Double {
        max(abs(leftToLeft) + abs(rightToLeft), abs(leftToRight) + abs(rightToRight))
    }
}

// MARK: - Settings

/// One output device's complete channel assignment.
public struct ChannelMatrixSettings: Codable, Sendable, Equatable {
    public var preset: ChannelMatrixPreset
    /// Source left → output left, in decibels. Only read when
    /// `preset == .custom`.
    public var leftToLeftDb: Double
    /// Source right → output left, in decibels.
    public var rightToLeftDb: Double
    /// Source left → output right, in decibels.
    public var leftToRightDb: Double
    /// Source right → output right, in decibels.
    public var rightToRightDb: Double

    public init(
        preset: ChannelMatrixPreset = .stereo,
        leftToLeftDb: Double = 0,
        rightToLeftDb: Double = ChannelMatrixLimits.silentDb,
        leftToRightDb: Double = ChannelMatrixLimits.silentDb,
        rightToRightDb: Double = 0
    ) {
        self.preset = preset
        self.leftToLeftDb = leftToLeftDb
        self.rightToLeftDb = rightToLeftDb
        self.leftToRightDb = leftToRightDb
        self.rightToRightDb = rightToRightDb
    }

    /// Decoding tolerates a record written before a field existed, and an
    /// unknown preset string degrades to `.stereo` rather than throwing — a
    /// store written by a newer build must not make this one refuse to start.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawPreset = try container.decodeIfPresent(String.self, forKey: .preset)
        self.preset = rawPreset.flatMap(ChannelMatrixPreset.init(rawValue:)) ?? .stereo
        self.leftToLeftDb = try container.decodeIfPresent(Double.self, forKey: .leftToLeftDb) ?? 0
        self.rightToLeftDb = try container.decodeIfPresent(Double.self, forKey: .rightToLeftDb)
            ?? ChannelMatrixLimits.silentDb
        self.leftToRightDb = try container.decodeIfPresent(Double.self, forKey: .leftToRightDb)
            ?? ChannelMatrixLimits.silentDb
        self.rightToRightDb = try container.decodeIfPresent(Double.self, forKey: .rightToRightDb) ?? 0
    }

    /// The default: plain stereo, and a bit-identical render path.
    public static let stereo = ChannelMatrixSettings()

    /// A `.custom` settings whose decibel fields reproduce `preset`'s matrix,
    /// so opening the custom editor starts from what the user was hearing
    /// rather than from silence.
    public static func custom(seededFrom preset: ChannelMatrixPreset) -> ChannelMatrixSettings {
        let matrix = ChannelMatrixSettings(preset: preset).matrix
        return ChannelMatrixSettings(
            preset: .custom,
            leftToLeftDb: ChannelMatrixLimits.decibels(forAmplitude: matrix.leftToLeft),
            rightToLeftDb: ChannelMatrixLimits.decibels(forAmplitude: matrix.rightToLeft),
            leftToRightDb: ChannelMatrixLimits.decibels(forAmplitude: matrix.leftToRight),
            rightToRightDb: ChannelMatrixLimits.decibels(forAmplitude: matrix.rightToRight)
        )
    }

    /// The linear coefficients this setting means.
    ///
    /// Presets are exact constants, not decibel round-trips: `1.0` has to stay
    /// exactly `1.0` so `.stereo` takes the bank's bit-identical fast path.
    public var matrix: ChannelMatrix {
        switch preset {
        case .stereo:
            return .identity
        case .left:
            return ChannelMatrix(leftToLeft: 1, rightToLeft: 0, leftToRight: 1, rightToRight: 0)
        case .right:
            return ChannelMatrix(leftToLeft: 0, rightToLeft: 1, leftToRight: 0, rightToRight: 1)
        case .mono:
            return ChannelMatrix(
                leftToLeft: ChannelMatrixLimits.monoCoefficient,
                rightToLeft: ChannelMatrixLimits.monoCoefficient,
                leftToRight: ChannelMatrixLimits.monoCoefficient,
                rightToRight: ChannelMatrixLimits.monoCoefficient
            )
        case .custom:
            return ChannelMatrix(
                leftToLeft: ChannelMatrixLimits.amplitude(forDecibels: leftToLeftDb),
                rightToLeft: ChannelMatrixLimits.amplitude(forDecibels: rightToLeftDb),
                leftToRight: ChannelMatrixLimits.amplitude(forDecibels: leftToRightDb),
                rightToRight: ChannelMatrixLimits.amplitude(forDecibels: rightToRightDb)
            )
        }
    }

    /// True when this setting provably cannot change the signal. The render
    /// path's fast exit keys on this, so "the panel exists but nobody opened
    /// it" costs exactly what it did before the feature existed.
    public var isNeutral: Bool {
        preset == .stereo || matrix.isIdentity
    }

    /// True when the user has picked something other than the default. Drives
    /// the "this row has a channel setting" affordance and decides whether the
    /// record is worth persisting.
    public var hasUserSetting: Bool { !isNeutral }

    /// Load-boundary validation. Non-finite decibels collapse to silence
    /// rather than reaching the render path, where a NaN coefficient would
    /// turn the output into NaN forever.
    public func sanitized() -> ChannelMatrixSettings {
        var out = self
        out.leftToLeftDb = ChannelMatrixLimits.clampDb(leftToLeftDb)
        out.rightToLeftDb = ChannelMatrixLimits.clampDb(rightToLeftDb)
        out.leftToRightDb = ChannelMatrixLimits.clampDb(leftToRightDb)
        out.rightToRightDb = ChannelMatrixLimits.clampDb(rightToRightDb)
        return out
    }
}

// MARK: - Limits

public enum ChannelMatrixLimits {
    /// Slider range for the custom coefficients. The bottom of the travel is
    /// the "−∞" stop: it is a real number so the value survives a JSON
    /// round-trip (`JSONEncoder` refuses `-inf` by default), and it is far
    /// enough down — −60 dB is 0.1 % amplitude — that treating it as exact
    /// silence is inaudible rather than a lie.
    public static let silentDb: Double = -60
    /// The top of the travel. +6 dB is one doubling: enough to rebalance a
    /// quiet channel, not enough to make the limiter the main event.
    public static let maximumDb: Double = 6
    public static let rangeDb: ClosedRange<Double> = silentDb...maximumDb
    /// UI step, and the granularity persistence rounds to.
    public static let stepDb: Double = 0.5
    /// −6.02 dB, as an exact binary fraction. Two correlated channels summed
    /// at this level land at exactly full scale.
    public static let monoCoefficient: Double = 0.5
    /// Below this an amplitude difference is treated as none, which is what
    /// lets the bank skip a matrix instead of running an identity multiply.
    /// 1e-4 is ~−80 dB, well under the slider's own resolution.
    public static let amplitudeEpsilon: Double = 1e-4

    public static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, value))
    }

    /// Clamp a decibel value into the slider range. Non-finite input becomes
    /// silence, never a boost: a corrupt store must fail quiet.
    public static func clampDb(_ db: Double) -> Double {
        db.isFinite ? clamp(db, to: rangeDb) : silentDb
    }

    /// Linear amplitude for a decibel value. The bottom of the range is exact
    /// zero, so a slider dragged to its stop is real silence rather than
    /// −60 dB of residual bleed.
    public static func amplitude(forDecibels db: Double) -> Double {
        let clamped = clampDb(db)
        guard clamped > silentDb else { return 0 }
        return pow(10, clamped / 20)
    }

    /// The inverse, for seeding the custom editor from a preset. Zero maps to
    /// the bottom stop rather than to −∞.
    public static func decibels(forAmplitude amplitude: Double) -> Double {
        guard amplitude.isFinite, amplitude > 0 else { return silentDb }
        return clampDb(20 * log10(amplitude))
    }

    /// Snap to the UI grid so a stored value and a slider position always
    /// agree; without it a −5.9999 read back from JSON renders one step low.
    public static func snapToStep(_ db: Double) -> Double {
        guard db.isFinite else { return silentDb }
        return (db / stepDb).rounded() * stepDb
    }
}
