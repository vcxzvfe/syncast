import Foundation

/// "When was ring frame N captured", answered from the capture hardware's own
/// timestamps rather than reconstructed.
///
/// # Why this exists next to `RingWriteClock`
///
/// `RingWriteClock` infers the timeline from `(write cursor, now)` pairs
/// sampled on the producer's 5 ms timer, filtered and servo'd. It has to,
/// because `SCKCapture` publishes nothing else. But a servo has a loop of its
/// own, and a two-machine field run showed what that costs: the sender was
/// trimming its idea of the ring's rate by −130 to −185 ppm while the
/// receiver was independently trimming its playout by another ±100 ppm.
/// Two loops, each correcting the other's correction, with the receiver
/// splicing whenever the disagreement showed up as a level dip.
///
/// `TapCapture`'s IOProc is handed an `AudioTimeStamp` with every block. That
/// stamp is the hardware's, so there is nothing to servo: the timeline is
/// read off the device, and the only estimate left is the rate, fitted by
/// least squares over the last ten seconds of anchors.
///
///     timeNs(frame) = anchorNs + (frame − anchorFrame) · nsPerFrame
///
/// # The fit
///
/// Anchors are kept at a minimum spacing (`historySpacingNs`) over a
/// `historyNs` window — a hundred points over ten seconds, which is plenty
/// for a slope and cheap to refit on every anchor. The fit is computed on
/// CENTRED coordinates: the raw values are ~1e10 ns and ~1e5 frames, and an
/// uncentred normal equation loses the slope to cancellation.
///
/// The line is evaluated at the newest anchor's frame to give the phase, so
/// the stamp's own jitter is averaged rather than passed straight through.
///
/// # What it refuses to do
///
/// A rate further than `maximumRateDeviationPpm` from nominal is not a
/// crystal, it is a broken observation, and it is clamped. An anchor further
/// than `reanchorLimitNs` from the prediction is a discontinuity — the
/// capture device restarted, the ring was rebuilt, the machine slept — and
/// the history is dropped rather than dragged through it.
public struct HostAnchoredRingClock: Equatable, Sendable {

    /// How much history the rate is fitted over. Ten seconds of a device
    /// clock is enough for a slope good to a fraction of a ppm, and short
    /// enough to follow a device that renegotiates its rate.
    public static let historyNs: UInt64 = 10_000_000_000
    /// Minimum spacing between retained anchors. Blocks arrive every ~10 ms;
    /// keeping one in ten bounds the fit's cost without changing its answer.
    public static let historySpacingNs: UInt64 = 100_000_000
    /// Anchors needed before the fitted rate is trusted over nominal.
    public static let minimumAnchorsForRate: Int = 8
    /// How far the fitted rate may sit from nominal. A device clock is within
    /// ±100 ppm; anything past 1000 ppm is a bad observation, not a crystal.
    public static let maximumRateDeviationPpm: Double = 1_000
    /// An anchor this far from the prediction is a discontinuity.
    public static let reanchorLimitNs: Double = 100_000_000

    public private(set) var anchorFrame: Int64 = 0
    public private(set) var anchorNs: Double = 0
    public private(set) var nsPerFrame: Double
    public private(set) var isAnchored: Bool = false
    /// How many times the model was discarded and re-anchored. Non-zero
    /// during playback means the capture device is restarting under us.
    public private(set) var reanchorCount: Int = 0
    /// Anchors folded in since the last re-anchor.
    public private(set) var anchorCount: Int = 0

    private let nominal: Double
    private var history: [CaptureAnchor] = []
    private var lastAnchorFrame: Int64 = .min

    public init(sampleRate: Double = LanPcmWire.sampleRate) {
        self.nominal = RingWriteClock.nominalNsPerFrame(sampleRate: sampleRate)
        self.nsPerFrame = self.nominal
    }

    /// Predicted capture time of `frame`, in sender monotonic ns.
    ///
    /// The LAN producer asks about frames BELOW the newest anchor (it reads a
    /// ring floor behind the write head), so the common case extrapolates
    /// backwards over a few tens of milliseconds.
    public func timeNs(forFrame frame: Int64) -> UInt64 {
        let predicted = predictedNs(forFrame: frame)
        guard predicted.isFinite, predicted > 0 else { return 0 }
        return UInt64(predicted.rounded())
    }

    func predictedNs(forFrame frame: Int64) -> Double {
        anchorNs + Double(frame - anchorFrame) * nsPerFrame
    }

    /// Fold one hardware anchor into the model.
    ///
    /// - Returns: true when the anchor changed the model. An anchor at a
    ///   frame already seen (the consumer polls faster than blocks arrive) is
    ///   ignored.
    @discardableResult
    public mutating func observe(_ anchor: CaptureAnchor) -> Bool {
        guard anchor.frame > lastAnchorFrame else { return false }
        guard isAnchored else {
            reset(to: anchor)
            return true
        }
        let error = Double(anchor.hostNs) - predictedNs(forFrame: anchor.frame)
        guard error.isFinite else { return false }
        if abs(error) > Self.reanchorLimitNs {
            reanchorCount += 1
            reset(to: anchor)
            return true
        }

        lastAnchorFrame = anchor.frame
        anchorCount += 1
        if let newest = history.last, anchor.hostNs >= newest.hostNs,
           anchor.hostNs - newest.hostNs < Self.historySpacingNs {
            // Too close to the last retained point to add anything to the
            // fit, but it still moves the phase.
        } else {
            history.append(anchor)
        }
        while history.count > 2, anchor.hostNs > history[0].hostNs,
              anchor.hostNs - history[0].hostNs > Self.historyNs {
            history.removeFirst()
        }

        if history.count >= Self.minimumAnchorsForRate,
           let fit = Self.fit(history) {
            nsPerFrame = Self.clampRate(fit.slope, nominal: nominal)
            anchorFrame = anchor.frame
            anchorNs = fit.value(atFrame: anchor.frame)
        } else {
            anchorFrame = anchor.frame
            anchorNs = Double(anchor.hostNs)
        }
        return true
    }

    /// Drop the model and rebuild it from this anchor alone.
    public mutating func reset(to anchor: CaptureAnchor) {
        anchorFrame = anchor.frame
        anchorNs = Double(anchor.hostNs)
        nsPerFrame = nominal
        isAnchored = true
        history = [anchor]
        lastAnchorFrame = anchor.frame
        anchorCount = 1
    }

    /// How far the fitted rate sits from nominal, in parts per million.
    /// A real capture device lands within ±50; a figure far outside that band
    /// means the anchors are not what they claim to be.
    public var rateDeviationPpm: Double {
        guard nominal > 0 else { return 0 }
        return (nsPerFrame - nominal) / nominal * 1_000_000
    }

    /// Retained anchors currently feeding the fit.
    public var fittedAnchorCount: Int { history.count }

    // MARK: - Least squares

    struct Fit: Equatable {
        /// Nanoseconds per frame.
        let slope: Double
        /// Frame the intercept is quoted at (the mean of the window).
        let referenceFrame: Double
        /// Fitted time at `referenceFrame`.
        let referenceNs: Double

        func value(atFrame frame: Int64) -> Double {
            referenceNs + (Double(frame) - referenceFrame) * slope
        }
    }

    /// Ordinary least squares of host time against frame, on coordinates
    /// centred at the first anchor and then at the window's mean.
    static func fit(_ anchors: [CaptureAnchor]) -> Fit? {
        guard anchors.count >= 2 else { return nil }
        let baseFrame = Double(anchors[0].frame)
        let baseNs = Double(anchors[0].hostNs)
        let n = Double(anchors.count)
        var sumX = 0.0, sumY = 0.0
        for anchor in anchors {
            sumX += Double(anchor.frame) - baseFrame
            sumY += Double(anchor.hostNs) - baseNs
        }
        let meanX = sumX / n
        let meanY = sumY / n
        var sxx = 0.0, sxy = 0.0
        for anchor in anchors {
            let dx = Double(anchor.frame) - baseFrame - meanX
            let dy = Double(anchor.hostNs) - baseNs - meanY
            sxx += dx * dx
            sxy += dx * dy
        }
        guard sxx > 0, sxy.isFinite else { return nil }
        let slope = sxy / sxx
        guard slope.isFinite, slope > 0 else { return nil }
        return Fit(slope: slope,
                   referenceFrame: baseFrame + meanX,
                   referenceNs: baseNs + meanY)
    }

    static func clampRate(_ value: Double, nominal: Double) -> Double {
        guard value.isFinite else { return nominal }
        let span = nominal * maximumRateDeviationPpm / 1_000_000
        return min(nominal + span, max(nominal - span, value))
    }
}
