import Foundation

/// Per-device delay compensation for the **local Stereo** render path
/// (`LocalOutput`), as opposed to `DeviceDelayTrim`, which is the whole-home
/// listening-position trim applied to `LocalAirPlayBridge` and OwnTone.
///
/// # The problem this exists for
///
/// When two physical outputs play the same stream through one aggregate — say
/// a machine's built-in speakers and a DisplayPort display — the display's
/// panel does its own audio processing after the HAL has handed the samples
/// over. That processing costs tens of milliseconds and the device does not
/// declare it: `kAudioDevicePropertyLatency` and
/// `kAudioDevicePropertySafetyOffset` describe the transport, not the panel's
/// internal DSP. The result is a small, fixed, audible offset between the two
/// speakers that no amount of clock work can remove, because nothing in the
/// system knows it is there.
///
/// So the value comes from the only instrument that can measure it: the
/// listener. The UI offers a millisecond control per device, this file holds
/// the arithmetic that turns those signed numbers into the non-negative read
/// offsets `LocalOutput.render()` can actually apply, and everything here is
/// pure so the arithmetic is pinned by tests rather than by listening.
///
/// # Why it is not `DeviceDelayTrim`
///
/// Same units, different quantity, different leg, different bound:
///
///   * `DeviceDelayTrim` (±200 ms) corrects **where the listener sits**
///     relative to each speaker, and is applied on the whole-home legs only —
///     `Router.replan()` deliberately hands the Scheduler an empty trim map
///     for the stereo path.
///   * This trim (±100 ms) corrects **a device's undeclared internal
///     latency**, and is applied inside the stereo render callback.
///
/// A user who has dialled both would be dialling two different corrections;
/// folding them into one stored number would make each mode silently retune
/// the other, and the wider whole-home bound would then be reachable on a path
/// that never budgeted for it.
public enum LocalDelayTrim {
    /// User-facing range. ±100 ms is the magnitude the problem actually has —
    /// display panels add tens of milliseconds — with room to spare. It is
    /// deliberately HALF `DeviceDelayTrim.rangeMs`: this trim is added to the
    /// ring backlog every render, and a bound nobody needs is just latency
    /// waiting to be dialled in by accident.
    public static let rangeMs: ClosedRange<Int> = -100...100

    /// UI step. 1 ms ≈ 34 cm of path length, and is already finer than the
    /// offset a listener can resolve on a fixed pair of speakers.
    public static let stepMs: Int = 1

    /// Hard ceiling on the NORMALISED offset any one pair may carry, seed
    /// included. The user range alone can produce a 200 ms span (−100 here,
    /// +100 there); an honest hardware seed adds tens more. 500 ms leaves that
    /// comfortable headroom while keeping a malfunctioning latency probe —
    /// a device reporting nonsense — from parking the read cursor seconds
    /// behind the producer, where the ring would serve silence and the fault
    /// would present as "one speaker went quiet".
    public static let maxOffsetMs: Int = 500

    /// Clamp a user value into `rangeMs`.
    public static func clamp(_ ms: Int) -> Int {
        min(max(ms, rangeMs.lowerBound), rangeMs.upperBound)
    }

    /// Milliseconds → frames, rounded to nearest. Signed: callers combine a
    /// negative hardware seed with a positive user trim before normalising.
    public static func frames(ms: Int, sampleRate: Double) -> Int {
        guard sampleRate > 0 else { return 0 }
        return Int((Double(ms) / 1000.0 * sampleRate).rounded())
    }

    /// Frames → milliseconds, for diagnostics and log lines.
    public static func milliseconds(frames: Int, sampleRate: Double) -> Double {
        guard sampleRate > 0 else { return 0 }
        return Double(frames) / sampleRate * 1000.0
    }
}

/// Turns per-pair *intent* into the per-pair *read offsets* the render callback
/// applies.
///
/// Two inputs, both signed and both meaning "this pair should sound LATER when
/// the number is larger":
///
///   * `seedFrames` — the automatic part. A device that reports a large output
///     latency already sounds late, so the Router passes the NEGATIVE of its
///     reported latency: the honest devices line up before the user touches
///     anything.
///   * `userMs` — the manual part, on top, for the latency no device declares.
///
/// The output is non-negative because a render callback can only ever read
/// OLDER frames from the ring; nothing can be played early. So the whole set
/// slides up until the earliest pair sits at exactly 0, which preserves every
/// pairwise difference — the only physically meaningful part — and costs the
/// earliest speaker no added latency at all.
///
/// Pure and total: no CoreAudio, no clock, no allocation beyond the returned
/// array. That is what makes the tests the specification.
public enum LocalDelayTrimPlanner {
    /// - Parameters:
    ///   - pairCount: number of output channel pairs on this AUHAL. In
    ///     aggregate mode one pair is one physical subdevice; in individual
    ///     mode there is exactly one, and the result is therefore always all
    ///     zeros (nothing to align a lone speaker against).
    ///   - seedFrames: pair → signed automatic seed, in frames. Missing = 0.
    ///   - userMs: pair → signed user trim, in milliseconds. Missing = 0.
    ///   - sampleRate: the ring's rate.
    ///   - headroomFrames: the largest offset the ring can serve. The caller
    ///     derives it from ring capacity and floor; 0 disables the feature
    ///     entirely (every pair gets 0), which is the correct answer for a
    ///     ring too small to hold a backlog.
    /// - Returns: one non-negative offset per pair, index 0..<pairCount, with
    ///   at least one entry equal to 0.
    public static func offsetFrames(
        pairCount: Int,
        seedFrames: [Int: Int],
        userMs: [Int: Int],
        sampleRate: Double,
        headroomFrames: Int
    ) -> [Int] {
        guard pairCount > 0 else { return [] }
        guard headroomFrames > 0 else { return Array(repeating: 0, count: pairCount) }
        var raw: [Int] = []
        raw.reserveCapacity(pairCount)
        for pair in 0..<pairCount {
            let seed = seedFrames[pair] ?? 0
            let user = LocalDelayTrim.frames(
                ms: LocalDelayTrim.clamp(userMs[pair] ?? 0), sampleRate: sampleRate
            )
            raw.append(seed + user)
        }
        // `raw` is non-empty (pairCount > 0), so `min()` cannot be nil.
        let minimum = raw.min() ?? 0
        let ceiling = min(
            headroomFrames,
            LocalDelayTrim.frames(ms: LocalDelayTrim.maxOffsetMs, sampleRate: sampleRate)
        )
        return raw.map { min(max(0, $0 - minimum), ceiling) }
    }

    /// Largest offset the ring can serve behind an already-established floor.
    ///
    /// The offset is backlog: the most-delayed pair reads `offset` frames
    /// further into the past than the least-delayed one, so the ring has to
    /// still hold those frames. Half the ring is reserved for the producer's
    /// own working set and the block itself, mirroring
    /// `LocalOutput.clampRingFloorFrames`, and the floor already claims part
    /// of what is left.
    public static func headroomFrames(capacityFrames: Int, floorFrames: Int) -> Int {
        max(0, capacityFrames / 2 - max(0, floorFrames))
    }
}
