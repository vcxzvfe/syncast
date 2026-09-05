import Foundation

/// The two clock estimators the LAN link needs, both pure value types so the
/// arithmetic is pinned by tests rather than by listening.
///
///   * `RingWriteClock` maps a capture-ring frame number to the sender's
///     monotonic nanosecond clock. This is what makes the receiver's playout
///     rate-locked to the RING rather than to the sender's 5 ms timer.
///   * `LanClockOffsetEstimator` turns ping/pong quadruples into an offset and
///     a round-trip time, NTP style.

// MARK: - Ring write clock

/// A model of "when was ring frame N captured", in sender monotonic ns.
///
/// # Why a model and not a timestamp
///
/// Neither capture backend records a host time per written block: `SCKCapture`
/// and `TapCapture` both call `RingBuffer.write` and publish a frame cursor,
/// and nothing downstream has ever needed more than that — the local AUHALs
/// are driven by the same hardware clock domain, so they stay locked by
/// construction. The LAN leg is the first consumer that has to state a time
/// out loud, to a machine with its own DAC clock.
///
/// So the time base is reconstructed from the only two things available: the
/// published write cursor and `Clock.nowNs()`, sampled together on the
/// producer timer. That pair is noisy in one direction — `now` is taken some
/// unknown time AFTER the last block was written, never before — which is
/// exactly the shape a **minimum filter** is for. Over a window of
/// observations the smallest `observed − predicted` is the one taken closest
/// to a block boundary, and it is treated as the truth; the rest are discarded
/// as scheduling delay.
///
/// # What the loop corrects, and how slowly
///
/// A window's minimum error is applied two ways: a fraction of it moves the
/// anchor (phase), and a smaller fraction spread over the window's frame count
/// trims `nsPerFrame` (rate). Both gains are deliberately small. A constant
/// phase bias is harmless — it just shifts the whole link's latency by a fixed
/// amount the target already dwarfs — while a rate error accumulates, so the
/// rate term is the one that matters and the phase term exists mainly to keep
/// the rate estimate honest.
///
/// A deadband sits under both: an error smaller than `deadbandNs` changes
/// nothing at all. That is what makes a producer running at exactly nominal
/// rate produce exactly nominal timestamps, rather than dithering the estimate
/// around it forever.
public struct RingWriteClock: Equatable, Sendable {

    /// Nominal nanoseconds per frame at 48 kHz: 20833.333…
    public static func nominalNsPerFrame(sampleRate: Double) -> Double {
        guard sampleRate > 0 else { return 1_000_000_000.0 / LanPcmWire.sampleRate }
        return 1_000_000_000.0 / sampleRate
    }

    /// Observations folded into one correction. 200 × 5 ms = one second, long
    /// enough for the minimum filter to have seen a block boundary and short
    /// enough to track a real rate change within a few seconds.
    public static let observationsPerWindow: Int = 200
    /// Below this, a window's minimum error is treated as zero. 250 µs is well
    /// under one frame of the 5 ms packet grid and far under any audible
    /// consequence, and it is what keeps a nominal producer's timestamps
    /// exactly nominal.
    public static let deadbandNs: Double = 250_000
    /// Fraction of a window's phase error applied to the anchor.
    ///
    /// The proportional half of the loop, and it is what keeps the loop
    /// DAMPED: a rate-only (pure integral) correction of a phase error has a
    /// state matrix with determinant 1, which oscillates forever instead of
    /// settling.
    public static let phaseGain: Double = 0.25
    /// Hard ceiling on how far one window may move the anchor.
    ///
    /// The anchor is the packet timeline's origin, so moving it puts a STEP in
    /// `play_at_ns` — one packet's spacing is not 5 ms, it is 5 ms plus the
    /// step. 50 µs is 1 % of a packet: far below anything the receiver's water-
    /// level loop reacts to, and far below anything a listener could hear,
    /// while still letting a large phase error walk itself out over a few
    /// windows rather than being ignored.
    public static let maximumPhaseStepNs: Double = 50_000
    /// Fraction applied to the rate. Deliberately an order of magnitude below
    /// the phase gain: the rate integrates, so it has to move slowly or the
    /// loop rings.
    public static let rateGain: Double = 0.02
    /// How far the rate estimate may stray from nominal. A real crystal is
    /// within ±100 ppm; 1000 ppm is a fault, and clamping there keeps a bad
    /// observation from walking the estimate somewhere it cannot come back
    /// from.
    public static let maximumRateDeviationPpm: Double = 1_000
    /// Phase error beyond which the model is discarded and re-anchored rather
    /// than nudged. 100 ms means the producer stalled or the ring was reset;
    /// gliding back from that would take minutes.
    public static let reanchorLimitNs: Double = 100_000_000

    public private(set) var anchorFrame: Int64 = 0
    public private(set) var anchorNs: Double = 0
    public private(set) var nsPerFrame: Double
    public private(set) var isAnchored: Bool = false
    /// How many times the model gave up and re-anchored. Non-zero during
    /// playback means the producer is stalling.
    public private(set) var reanchorCount: Int = 0

    private let nominal: Double
    private var windowCount: Int = 0
    private var windowMinError: Double = .greatestFiniteMagnitude
    private var windowStartFrame: Int64 = 0

    public init(sampleRate: Double = LanPcmWire.sampleRate) {
        self.nominal = Self.nominalNsPerFrame(sampleRate: sampleRate)
        self.nsPerFrame = self.nominal
    }

    /// Drop the model and anchor it on this observation.
    public mutating func reanchor(frame: Int64, nowNs: UInt64) {
        anchorFrame = frame
        anchorNs = Double(nowNs)
        nsPerFrame = nominal
        isAnchored = true
        windowCount = 0
        windowMinError = .greatestFiniteMagnitude
        windowStartFrame = frame
    }

    /// Predicted capture time of `frame`, in sender monotonic ns.
    ///
    /// Defined for frames on either side of the anchor; the LAN producer asks
    /// about frames BELOW the write cursor (it reads a ring floor behind it),
    /// so the common case is an extrapolation backwards.
    public func timeNs(forFrame frame: Int64) -> UInt64 {
        let predicted = predictedNs(forFrame: frame)
        guard predicted.isFinite, predicted > 0 else { return 0 }
        return UInt64(predicted.rounded())
    }

    func predictedNs(forFrame frame: Int64) -> Double {
        anchorNs + Double(frame - anchorFrame) * nsPerFrame
    }

    /// Fold one `(write cursor, now)` observation into the model.
    ///
    /// - Returns: true when this observation completed a window and changed
    ///   something. Used by the diagnostics, never by the audio path.
    @discardableResult
    public mutating func observe(writePosition: Int64, nowNs: UInt64) -> Bool {
        guard isAnchored else {
            reanchor(frame: writePosition, nowNs: nowNs)
            return true
        }
        let error = Double(nowNs) - predictedNs(forFrame: writePosition)
        guard error.isFinite else { return false }
        if abs(error) > Self.reanchorLimitNs {
            reanchorCount += 1
            reanchor(frame: writePosition, nowNs: nowNs)
            return true
        }
        // Minimum filter: keep the least-delayed observation of the window.
        if error < windowMinError { windowMinError = error }
        windowCount += 1
        guard windowCount >= Self.observationsPerWindow else { return false }

        let correction = windowMinError
        let framesInWindow = writePosition - windowStartFrame
        windowCount = 0
        windowMinError = .greatestFiniteMagnitude
        windowStartFrame = writePosition
        guard abs(correction) >= Self.deadbandNs else { return false }

        let phaseStep = min(
            Self.maximumPhaseStepNs,
            max(-Self.maximumPhaseStepNs, Self.phaseGain * correction)
        )
        anchorNs += phaseStep
        if framesInWindow > 0 {
            let rateStep = Self.rateGain * correction / Double(framesInWindow)
            nsPerFrame = Self.clampRate(nsPerFrame + rateStep, nominal: nominal)
        }
        return true
    }

    static func clampRate(_ value: Double, nominal: Double) -> Double {
        guard value.isFinite else { return nominal }
        let span = nominal * maximumRateDeviationPpm / 1_000_000
        return min(nominal + span, max(nominal - span, value))
    }

    /// How far the rate estimate currently sits from nominal, in parts per
    /// million. Reported so a field log can separate "the model is tracking a
    /// real 20 ppm crystal offset" from "the model is lost".
    public var rateDeviationPpm: Double {
        guard nominal > 0 else { return 0 }
        return (nsPerFrame - nominal) / nominal * 1_000_000
    }
}

// MARK: - NTP offset

/// One completed ping/pong exchange.
public struct LanClockSample: Equatable, Sendable {
    /// Receiver clock minus sender clock, in nanoseconds. Signed.
    public let offsetNs: Double
    /// Round-trip time, in nanoseconds. Never negative.
    public let roundTripNs: Double

    public init(offsetNs: Double, roundTripNs: Double) {
        self.offsetNs = offsetNs
        self.roundTripNs = roundTripNs
    }

    /// The textbook NTP four-timestamp reduction.
    ///
    /// `offset = ((t2 − t1) + (t3 − t4)) / 2`, `rtt = (t4 − t1) − (t3 − t2)`.
    /// All four are unsigned monotonic nanoseconds from two different clocks,
    /// so every subtraction is done in `Double` after widening: `t2 − t1`
    /// crosses clock domains and is very often negative, which an unsigned
    /// subtraction would turn into an astronomically large positive number.
    ///
    /// Returns nil for a quadruple that cannot be physical — `t4 < t1` or
    /// `t3 < t2` on a monotonic clock means the peer is lying or the sample is
    /// corrupt, and a negative round trip would poison the minimum filter for
    /// the rest of the session.
    public static func fromTimestamps(
        t1: UInt64, t2: UInt64, t3: UInt64, t4: UInt64
    ) -> LanClockSample? {
        guard t4 >= t1, t3 >= t2 else { return nil }
        let a = Double(t1), b = Double(t2), c = Double(t3), d = Double(t4)
        let roundTrip = (d - a) - (c - b)
        guard roundTrip >= 0, roundTrip.isFinite else { return nil }
        let offset = ((b - a) + (c - d)) / 2
        guard offset.isFinite else { return nil }
        return LanClockSample(offsetNs: offset, roundTripNs: roundTrip)
    }
}

/// Sliding-window NTP offset estimator.
///
/// The sample with the SMALLEST round trip is taken as truth — on a shared
/// LAN, a long round trip means the packet queued somewhere, and a queued
/// packet's offset carries that queue's length as error. The chosen offset is
/// then smoothed with an EMA so a single lucky sample cannot jump the reported
/// figure around.
public struct LanClockOffsetEstimator: Equatable, Sendable {
    /// Sixteen samples at one ping per second is a sixteen-second window: long
    /// enough to contain a quiet moment on a busy network, short enough that a
    /// genuine clock step is followed within a minute.
    public static let windowSize: Int = 16
    /// EMA weight for a newly chosen minimum-RTT offset.
    public static let smoothing: Double = 0.25

    private var samples: [LanClockSample] = []
    public private(set) var smoothedOffsetNs: Double = 0
    public private(set) var hasEstimate: Bool = false

    public init() {}

    @discardableResult
    public mutating func add(_ sample: LanClockSample) -> Bool {
        samples.append(sample)
        if samples.count > Self.windowSize { samples.removeFirst() }
        guard let best = samples.min(by: { $0.roundTripNs < $1.roundTripNs }) else {
            return false
        }
        if hasEstimate {
            smoothedOffsetNs += Self.smoothing * (best.offsetNs - smoothedOffsetNs)
        } else {
            smoothedOffsetNs = best.offsetNs
            hasEstimate = true
        }
        return true
    }

    /// Round trip of the best sample currently in the window, in nanoseconds.
    public var bestRoundTripNs: Double? {
        samples.min(by: { $0.roundTripNs < $1.roundTripNs })?.roundTripNs
    }

    /// The most recent sample's round trip — what the UI shows as "RTT",
    /// because a user watching a link wants the live number, not the best one.
    public var latestRoundTripNs: Double? { samples.last?.roundTripNs }

    public mutating func reset() { self = LanClockOffsetEstimator() }
}
