import Foundation

/// Per-output equalisation: the user model, its validation rules, and the
/// RBJ ("Audio EQ Cookbook") biquad coefficient math.
///
/// Everything in this file is pure and allocation-free at the arithmetic
/// level, so it is unit-testable without a CoreAudio device. The real-time
/// side lives in `EqualizerBank`, which consumes `BiquadCoefficients` values
/// produced here on the app thread.
///
/// # Why a graphic layout by default
///
/// The user asked for "各个 dB 的调节" — a tone control for a speaker whose
/// bass is too strong. A ten-band ISO graphic EQ is the control people already
/// know from every hi-fi and phone player, so `EqualizerSettings.graphicFlat`
/// is what the UI hands out. The band record is nevertheless fully parametric
/// (kind + frequency + Q + gain), so a later "parametric" editor needs no
/// migration: a v1 store already round-trips arbitrary frequencies.

// MARK: - Band model

/// Filter shape of a single band.
public enum EqualizerBandKind: String, Codable, Sendable, CaseIterable {
    /// Bell centred on `frequency`; `q` sets its width.
    case peaking
    /// Everything below `frequency` is lifted/cut by `gainDb`.
    case lowShelf
    /// Everything above `frequency` is lifted/cut by `gainDb`.
    case highShelf
}

/// One filter section.
public struct EqualizerBand: Codable, Sendable, Equatable {
    public var kind: EqualizerBandKind
    /// Centre frequency (peaking) or corner frequency (shelves), in hertz.
    public var frequency: Double
    /// Quality factor. For shelves this is the cookbook's Q form, so 0.707 is
    /// the maximally flat (Butterworth) shelf.
    public var q: Double
    /// Band gain in decibels. 0 dB is a bit-exact pass-through.
    public var gainDb: Double

    public init(
        kind: EqualizerBandKind = .peaking,
        frequency: Double,
        q: Double = EqualizerLimits.graphicQ,
        gainDb: Double = 0
    ) {
        self.kind = kind
        self.frequency = frequency
        self.q = q
        self.gainDb = gainDb
    }

    /// True when this band cannot change the signal, so the bank can skip it
    /// entirely rather than running an identity biquad.
    public var isNeutral: Bool {
        !gainDb.isFinite || abs(gainDb) < EqualizerLimits.neutralGainEpsilonDb
    }

    /// Clamp every field into a range the coefficient math is defined on, and
    /// reject non-finite values outright. This is the load boundary for data
    /// that has been through `UserDefaults`, so nothing here may trust its
    /// input — a NaN frequency would produce NaN coefficients and a render
    /// thread that emits NaN forever.
    public func sanitized() -> EqualizerBand? {
        guard frequency.isFinite, q.isFinite, gainDb.isFinite else { return nil }
        guard EqualizerLimits.frequencyRangeHz.contains(frequency) else { return nil }
        var out = self
        out.q = EqualizerLimits.clamp(q, to: EqualizerLimits.qRange)
        out.gainDb = EqualizerLimits.clampBandGainDb(gainDb)
        return out
    }
}

// MARK: - Settings

/// One output device's complete curve.
public struct EqualizerSettings: Codable, Sendable, Equatable {
    /// User-facing "off" switch. A bypassed curve is remembered but inert, so
    /// A/B-ing a setting never costs the user the setting.
    public var bypassed: Bool
    /// Pre-gain applied ahead of the bands. Negative buys headroom for a
    /// boost-heavy curve; positive is makeup for a cut-heavy one.
    public var trimDb: Double
    public var bands: [EqualizerBand]

    public init(bypassed: Bool = false, trimDb: Double = 0, bands: [EqualizerBand] = []) {
        self.bypassed = bypassed
        self.trimDb = trimDb
        self.bands = bands
    }

    /// Decoding tolerates a record written before a field existed.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.bypassed = try container.decodeIfPresent(Bool.self, forKey: .bypassed) ?? false
        self.trimDb = try container.decodeIfPresent(Double.self, forKey: .trimDb) ?? 0
        self.bands = try container.decodeIfPresent([EqualizerBand].self, forKey: .bands) ?? []
    }

    /// Nothing dialled in: no bands, no trim, not bypassed.
    public static let flat = EqualizerSettings()

    /// The default ten-band ISO graphic layout, all bands at 0 dB.
    public static var graphicFlat: EqualizerSettings {
        EqualizerSettings(
            bands: EqualizerLimits.graphicFrequencies.map {
                EqualizerBand(kind: .peaking, frequency: $0, q: EqualizerLimits.graphicQ)
            }
        )
    }

    /// True when this curve provably cannot change the signal. The render
    /// path's fast exit keys on this, so the "EQ installed but flat" case
    /// costs exactly what it did before the feature existed.
    public var isNeutral: Bool {
        if bypassed { return true }
        guard trimDb.isFinite, abs(trimDb) < EqualizerLimits.neutralGainEpsilonDb else {
            return false
        }
        return bands.allSatisfy(\.isNeutral)
    }

    /// True when the user has dialled something in, whether or not it is
    /// currently bypassed. Drives "this row has a curve" affordances.
    public var hasUserCurve: Bool {
        var probe = self
        probe.bypassed = false
        return !probe.isNeutral
    }

    /// Load-boundary validation: clamp the trim, sanitise every band, drop the
    /// ones that cannot be made sense of, and cap the band count so a hostile
    /// or corrupt plist cannot make the render thread run an unbounded chain.
    public func sanitized() -> EqualizerSettings {
        var out = self
        out.trimDb = trimDb.isFinite ? EqualizerLimits.clampTrimDb(trimDb) : 0
        out.bands = Array(bands.compactMap { $0.sanitized() }.prefix(EqualizerLimits.maxBands))
        return out
    }

    /// The bands that actually do something, in order. The bank stores only
    /// these, so a flat ten-band graphic curve costs zero biquads.
    public var activeBands: [EqualizerBand] {
        bypassed ? [] : bands.filter { !$0.isNeutral }
    }

    /// Linear pre-gain the bank multiplies by. 1.0 when bypassed, so bypass is
    /// a true pass-through rather than "bands off, trim still applied".
    public var trimAmplitude: Double {
        guard !bypassed, trimDb.isFinite else { return 1 }
        return pow(10, EqualizerLimits.clampTrimDb(trimDb) / 20)
    }

    /// Gain of the whole chain at one frequency, in dB. Used by the tests and
    /// by the offline probe; never on the render thread.
    public func responseDb(atHz hz: Double, sampleRate: Double) -> Double {
        let linear = activeBands.reduce(trimAmplitude) { acc, band in
            acc * BiquadCoefficients.make(band: band, sampleRate: sampleRate)
                .magnitude(atHz: hz, sampleRate: sampleRate)
        }
        return 20 * log10(max(linear, 1e-12))
    }
}

// MARK: - Limits

public enum EqualizerLimits {
    /// Per-band range. ±12 dB is the range a graphic EQ is expected to have,
    /// and it is also as far as we can go before a full-scale source plus a
    /// boost is clipping on every band at once.
    public static let bandGainRangeDb: ClosedRange<Double> = -12...12
    /// Pre-gain range, deliberately the same span so the UI can share a scale.
    public static let trimRangeDb: ClosedRange<Double> = -12...12
    /// UI step. Also the granularity the persistence layer rounds to.
    public static let gainStepDb: Double = 0.5
    /// Below this a gain is treated as exactly 0 dB, which is what lets the
    /// bank drop the band instead of running an identity biquad.
    public static let neutralGainEpsilonDb: Double = 0.01
    /// ISO 1/1-octave centres. The classic ten-slider layout.
    public static let graphicFrequencies: [Double] =
        [31.5, 63, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]
    /// Constant-Q width for the graphic bands: 1.41 ≈ one octave between the
    /// -3 dB points, so adjacent sliders meet rather than overlap heavily.
    public static let graphicQ: Double = 1.41
    /// Hard cap on chain length, enforced at the load boundary and matched by
    /// the bank's per-pair allocation.
    public static let maxBands: Int = 16
    public static let frequencyRangeHz: ClosedRange<Double> = 10...24_000
    public static let qRange: ClosedRange<Double> = 0.1...18

    public static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, value))
    }

    public static func clampBandGainDb(_ db: Double) -> Double {
        db.isFinite ? clamp(db, to: bandGainRangeDb) : 0
    }

    public static func clampTrimDb(_ db: Double) -> Double {
        db.isFinite ? clamp(db, to: trimRangeDb) : 0
    }

    /// Snap to the UI grid so a stored value and a slider position always
    /// agree; without it a 0.4999 read back from JSON renders one step low.
    public static func snapToStep(_ db: Double) -> Double {
        guard db.isFinite else { return 0 }
        return (db / gainStepDb).rounded() * gainStepDb
    }
}

// MARK: - Biquad coefficients

/// Normalised (a0 == 1) direct-form coefficients of one second-order section.
///
/// Doubles rather than floats: at 31.5 Hz / 48 kHz the poles sit within
/// ~0.004 of the unit circle, where single-precision coefficient quantisation
/// visibly moves the corner frequency. The bank keeps its state in double for
/// the same reason and converts at the buffer boundary.
public struct BiquadCoefficients: Sendable, Equatable {
    public var b0: Double
    public var b1: Double
    public var b2: Double
    public var a1: Double
    public var a2: Double

    public init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0
        self.b1 = b1
        self.b2 = b2
        self.a1 = a1
        self.a2 = a2
    }

    public static let identity = BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    /// RBJ Audio EQ Cookbook, Q form for all three shapes.
    ///
    /// Returns `.identity` for anything the formulas are not defined on: a
    /// non-positive sample rate, a corner at or above Nyquist, a degenerate Q,
    /// or a non-finite input. Refusing to produce coefficients is the only
    /// safe failure here — a NaN section poisons the filter state permanently.
    public static func make(band: EqualizerBand, sampleRate: Double) -> BiquadCoefficients {
        guard sampleRate.isFinite, sampleRate > 0,
              band.frequency.isFinite, band.q.isFinite, band.gainDb.isFinite,
              band.frequency > 0, band.q > 0
        else {
            return .identity
        }
        // Leave a margin below Nyquist: a corner AT Nyquist makes sin(w0) == 0
        // and the cookbook's alpha degenerate.
        let nyquist = sampleRate / 2
        guard band.frequency < nyquist * 0.999 else { return .identity }
        guard abs(band.gainDb) >= EqualizerLimits.neutralGainEpsilonDb else { return .identity }

        let amplitude = pow(10, band.gainDb / 40)   // cookbook's A = 10^(dB/40)
        let w0 = 2 * Double.pi * band.frequency / sampleRate
        let cosW0 = cos(w0)
        let sinW0 = sin(w0)
        let alpha = sinW0 / (2 * band.q)

        var b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double
        switch band.kind {
        case .peaking:
            b0 = 1 + alpha * amplitude
            b1 = -2 * cosW0
            b2 = 1 - alpha * amplitude
            a0 = 1 + alpha / amplitude
            a1 = -2 * cosW0
            a2 = 1 - alpha / amplitude
        case .lowShelf:
            let sqrtA = sqrt(amplitude)
            let shared = 2 * sqrtA * alpha
            b0 = amplitude * ((amplitude + 1) - (amplitude - 1) * cosW0 + shared)
            b1 = 2 * amplitude * ((amplitude - 1) - (amplitude + 1) * cosW0)
            b2 = amplitude * ((amplitude + 1) - (amplitude - 1) * cosW0 - shared)
            a0 = (amplitude + 1) + (amplitude - 1) * cosW0 + shared
            a1 = -2 * ((amplitude - 1) + (amplitude + 1) * cosW0)
            a2 = (amplitude + 1) + (amplitude - 1) * cosW0 - shared
        case .highShelf:
            let sqrtA = sqrt(amplitude)
            let shared = 2 * sqrtA * alpha
            b0 = amplitude * ((amplitude + 1) + (amplitude - 1) * cosW0 + shared)
            b1 = -2 * amplitude * ((amplitude - 1) + (amplitude + 1) * cosW0)
            b2 = amplitude * ((amplitude + 1) + (amplitude - 1) * cosW0 - shared)
            a0 = (amplitude + 1) - (amplitude - 1) * cosW0 + shared
            a1 = 2 * ((amplitude - 1) - (amplitude + 1) * cosW0)
            a2 = (amplitude + 1) - (amplitude - 1) * cosW0 - shared
        }
        guard a0.isFinite, abs(a0) > 1e-12 else { return .identity }
        let coefficients = BiquadCoefficients(
            b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0
        )
        guard coefficients.isUsable else { return .identity }
        return coefficients
    }

    /// Finite, and stable in the strict sense (both poles strictly inside the
    /// unit circle, by the Jury test for a second-order section).
    public var isUsable: Bool {
        guard b0.isFinite, b1.isFinite, b2.isFinite, a1.isFinite, a2.isFinite else {
            return false
        }
        return abs(a2) < 1 && abs(a1) < 1 + a2
    }

    /// |H(e^{jω})| at one frequency. Test/probe helper, never on the RT path.
    public func magnitude(atHz hz: Double, sampleRate: Double) -> Double {
        guard sampleRate > 0 else { return 1 }
        let w = 2 * Double.pi * hz / sampleRate
        let cos1 = cos(w), sin1 = sin(w)
        let cos2 = cos(2 * w), sin2 = sin(2 * w)
        // e^{-jw} = cos(w) - j sin(w)
        let numRe = b0 + b1 * cos1 + b2 * cos2
        let numIm = -(b1 * sin1 + b2 * sin2)
        let denRe = 1 + a1 * cos1 + a2 * cos2
        let denIm = -(a1 * sin1 + a2 * sin2)
        let denMagSq = denRe * denRe + denIm * denIm
        guard denMagSq > 1e-30 else { return 1 }
        return sqrt((numRe * numRe + numIm * numIm) / denMagSq)
    }
}
