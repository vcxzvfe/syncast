import Foundation

/// Near-unity, continuously-variable fractional resampler used by
/// `LocalAirPlayBridge`'s Layer-2 clock-following loop.
///
/// # Why this exists
/// `AVAudioConverter` converts the 44.1 kHz OwnTone feed to the output
/// device's nominal rate, but its ratio is *fixed at construction* — it
/// cannot be nudged by a few ppm at runtime without being recreated
/// (which drops its polyphase state and clicks). To lock the local device
/// clock to OwnTone's fifo *write* rate we need a second stage whose ratio
/// can be trimmed smoothly, sample by sample. That is this class.
///
/// The trim ratio the caller passes is `outFrames / inFrames` and stays
/// within a few hundred ppm of 1.0 (the PI controller in
/// `LocalAirPlayBridge` clamps it). At such tiny corrections a 4-point
/// cubic (Catmull-Rom / Hermite) interpolator is inaudible: a steady
/// 100 ppm trim is a 0.17-cent pitch shift, far below the ~5-10 cent JND,
/// and the cubic kernel avoids the HF droop of linear interpolation and
/// the clicks of sample drop/duplicate.
///
/// # Continuity
/// The 4-tap history (`h0…h3`) and the fractional read `phase` persist
/// across `process(...)` calls, so feeding one packet at a time yields a
/// glitch-free continuous stream — exactly like the upstream
/// `AVAudioConverter`. `reset()` re-zeros the state; the bridge calls it
/// only on a genuine stream discontinuity (socket reconnect), never on a
/// steady-state ratio change.
///
/// # Threading
/// Instances are confined to the bridge's non-RT reader task. No locking;
/// `@unchecked Sendable` only so it can be stored on the bridge (itself
/// `@unchecked Sendable`). Never call `process` from the render thread.
final class FractionalTrimResampler: @unchecked Sendable {
    let channelCount: Int
    /// One-input-sample-latency 4-tap history per channel. `h1`/`h2` are
    /// the interpolation endpoints; `h0`/`h3` are the outer taps. Output
    /// samples are produced for the interval between `h1` and `h2` once
    /// `h3` (the sample after the interval) is known.
    private var h0: [Float]
    private var h1: [Float]
    private var h2: [Float]
    private var h3: [Float]
    /// Fractional position within the current `[h1, h2)` input interval,
    /// in `[0, 1)`. Advances by `1/ratio` per output sample and drops by
    /// 1.0 each time a new input sample is consumed.
    private var phase: Double

    init(channelCount: Int) {
        precondition(channelCount > 0)
        self.channelCount = channelCount
        self.h0 = [Float](repeating: 0, count: channelCount)
        self.h1 = [Float](repeating: 0, count: channelCount)
        self.h2 = [Float](repeating: 0, count: channelCount)
        self.h3 = [Float](repeating: 0, count: channelCount)
        self.phase = 0
    }

    /// Drop all filter state. Use ONLY across a real stream break — a
    /// steady-state trim change must NOT reset (it would click).
    func reset() {
        for ch in 0..<channelCount {
            h0[ch] = 0; h1[ch] = 0; h2[ch] = 0; h3[ch] = 0
        }
        phase = 0
    }

    /// Resample one block.
    ///
    /// - Parameters:
    ///   - inputs: `channelCount` non-interleaved Float32 input channels.
    ///   - inFrames: frames available in each input channel.
    ///   - ratio: desired `outFrames / inFrames`; must be > 0 and in
    ///     practice within a few hundred ppm of 1.0.
    ///   - outputs: `channelCount` non-interleaved Float32 output channels.
    ///   - outCapacity: frames each output channel can hold. Production
    ///     stops if the buffer would overflow (guards against a ratio
    ///     spike), so the caller must size `outCapacity` for the worst
    ///     case — a couple frames above `inFrames` at the clamped ratio.
    /// - Returns: frames written to each output channel.
    func process(
        inputs: UnsafePointer<UnsafePointer<Float>>,
        inFrames: Int,
        ratio: Double,
        outputs: UnsafePointer<UnsafeMutablePointer<Float>>,
        outCapacity: Int
    ) -> Int {
        guard inFrames > 0, ratio > 0, outCapacity > 0 else { return 0 }
        // `step` = input frames advanced per output frame. ratio<1 (fewer
        // outputs) ⇒ step>1 ⇒ phase crosses 1.0 sooner ⇒ fewer emits.
        let step = 1.0 / ratio
        var phase = self.phase
        var outCount = 0
        let ch = channelCount
        for i in 0..<inFrames {
            // Shift history and admit the new input sample. After this,
            // the interval [h1, h2] is bracketed by h0 (before) and h3
            // (the just-admitted sample after it), so it is safe to
            // interpolate anywhere inside it.
            for c in 0..<ch {
                h0[c] = h1[c]
                h1[c] = h2[c]
                h2[c] = h3[c]
                h3[c] = inputs[c][i]
            }
            while phase < 1.0 {
                if outCount >= outCapacity { break }
                let x = phase
                for c in 0..<ch {
                    let p0 = h0[c], p1 = h1[c], p2 = h2[c], p3 = h3[c]
                    // Catmull-Rom / 4-point cubic Hermite, evaluated
                    // between p1 and p2 at fractional position x.
                    let c0 = p1
                    let c1 = 0.5 * (p2 - p0)
                    let c2 = p0 - 2.5 * p1 + 2.0 * p2 - 0.5 * p3
                    let c3 = 0.5 * (p3 - p0) + 1.5 * (p1 - p2)
                    let fx = Float(x)
                    outputs[c][outCount] = ((c3 * fx + c2) * fx + c1) * fx + c0
                }
                outCount += 1
                phase += step
            }
            phase -= 1.0
            // Defensive: if outCapacity was hit mid-interval, the remaining
            // outputs for this block are dropped and phase would keep
            // sliding negative across the next inputs. Re-floor so we stay
            // in the valid [0,1) admission cadence rather than starving.
            if phase < 0 { phase += 1.0 }
        }
        self.phase = phase
        return outCount
    }
}
