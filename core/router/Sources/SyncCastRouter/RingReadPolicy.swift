import Foundation

/// How far behind the capture ring's write cursor a local AUHAL renders.
///
/// The "floor" is the steady-state water level: the render callback aims to
/// read `floor` frames behind the producer, so a late producer callback still
/// finds written frames waiting. It is pure added latency, so it should be no
/// larger than the producer's worst-case jitter demands.
///
/// Two producers exist and they are not alike:
///
///   * **ScreenCaptureKit** (`SCKCapture`, the default Stereo/whole-home
///     capture) delivers 1024-frame chunks on a media-service thread whose
///     scheduling we do not control and have seen bunch up. The 100 ms floor
///     was chosen for it and stays its default.
///   * **Core Audio Process Tap** (`TapCapture`, the system-sink Stereo path)
///     is an IOProc on the HAL's real-time thread delivering regular
///     512-frame blocks — the same clock class as the output AUHAL that
///     consumes them. It does not need 100 ms of slack, and every millisecond
///     of it is A/V lag the user sees.
///
/// Nothing here talks to CoreAudio; it is arithmetic and env-var validation so
/// both the Router and `SyncCastSystemSinkProbe` read the SAME numbers rather
/// than each carrying its own copy of the budget.
public enum RingFloorPolicy {
    /// Floor for the ScreenCaptureKit-fed paths (individual / aggregate /
    /// whole-home). 100 ms — unchanged from the hardcoded value it replaced.
    public static let legacyFloorMs: Int = 100
    /// Floor for the system-sink path (Process Tap producer). 30 ms is ~3
    /// producer blocks at 512 frames / 48 kHz, so a single late IOProc still
    /// finds data and a resync is not triggered by ±1 block of jitter.
    public static let sinkDefaultFloorMs: Int = 30
    /// Accepted range for the env override. Below 10 ms the floor is smaller
    /// than one 512-frame block (10.67 ms) and every render underruns; above
    /// 500 ms the path is worse than the SCK one it replaced.
    public static let minFloorMs: Int = 10
    public static let maxFloorMs: Int = 500
    /// Override for the sink path's floor, in milliseconds.
    public static let sinkFloorEnvVar: String = "SYNCAST_SINK_RING_FLOOR_MS"

    /// Result of validating the env override: the floor to use, plus a
    /// human-readable warning when the raw value was rejected. Callers log the
    /// warning; nothing is silently swallowed.
    public struct ResolvedFloor: Equatable, Sendable {
        public let ms: Int
        public let warning: String?
        public init(ms: Int, warning: String?) {
            self.ms = ms
            self.warning = warning
        }
    }

    /// Validate `SYNCAST_SINK_RING_FLOOR_MS`.
    ///
    /// Unset (or set to whitespace, which is how a shell passes "I did not
    /// mean to set this") -> the default, no warning. Anything else that is
    /// not an integer in `[minFloorMs, maxFloorMs]` -> the default plus a
    /// warning naming the bad value.
    public static func resolveSinkFloorMs(rawValue: String?) -> ResolvedFloor {
        guard let rawValue else { return ResolvedFloor(ms: sinkDefaultFloorMs, warning: nil) }
        let trimmed = rawValue.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return ResolvedFloor(ms: sinkDefaultFloorMs, warning: nil) }
        guard let parsed = Int(trimmed) else {
            return ResolvedFloor(
                ms: sinkDefaultFloorMs,
                warning: "\(sinkFloorEnvVar)=\"\(rawValue)\" is not an integer; using \(sinkDefaultFloorMs) ms"
            )
        }
        guard parsed >= minFloorMs, parsed <= maxFloorMs else {
            return ResolvedFloor(
                ms: sinkDefaultFloorMs,
                warning: "\(sinkFloorEnvVar)=\(parsed) is outside \(minFloorMs)...\(maxFloorMs) ms; using \(sinkDefaultFloorMs) ms"
            )
        }
        return ResolvedFloor(ms: parsed, warning: nil)
    }

    /// Same, reading the process environment. Separated so tests drive the
    /// pure function above without mutating `setenv`.
    public static func resolveSinkFloorMs(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ResolvedFloor {
        resolveSinkFloorMs(rawValue: environment[sinkFloorEnvVar])
    }

    /// Milliseconds -> frames at a given sample rate. Rounds to nearest; never
    /// negative.
    public static func frames(ms: Int, sampleRate: Double) -> Int {
        guard sampleRate > 0, ms > 0 else { return 0 }
        return Int((Double(ms) / 1000.0 * sampleRate).rounded())
    }

    /// Frames -> milliseconds, for diagnostics.
    public static func milliseconds(frames: Int, sampleRate: Double) -> Double {
        guard sampleRate > 0 else { return 0 }
        return Double(frames) / sampleRate * 1000.0
    }
}

/// The pure part of `LocalOutput.render()`'s cursor arithmetic.
///
/// Extracted so the decision — resync or continue, and how much of the block
/// is backed by written frames — is unit-testable without a CoreAudio device.
/// Value types and integer arithmetic only: this runs on the real-time thread,
/// so it must not allocate.
public struct RingReadPlan: Equatable, Sendable {
    /// Absolute frame the render should read from.
    public let startFrame: Int64
    /// True when the cursor was discarded and re-anchored on the target.
    /// Audible as a discontinuity, so it is counted, not ignored.
    public let didResync: Bool
    /// Frames of this block that sit past the producer's write cursor. The
    /// `RingBuffer` zero-fills them (see its `read` contract), so the audible
    /// result is a short silence, never stale ring content — but it is still a
    /// dropout and is counted.
    public let underrunFrames: Int
    /// Written frames available ahead of `startFrame` at decision time. The
    /// running minimum of this is the headroom the floor actually bought.
    public let waterLevelFrames: Int64

    public init(startFrame: Int64, didResync: Bool, underrunFrames: Int, waterLevelFrames: Int64) {
        self.startFrame = startFrame
        self.didResync = didResync
        self.underrunFrames = underrunFrames
        self.waterLevelFrames = waterLevelFrames
    }
}

/// Glitch bookkeeping over a sequence of `RingReadPlan`s.
///
/// The rule lives here — as a plain value type folded by the render thread —
/// so it can be unit-tested without a CoreAudio device. `LocalOutput` owns one
/// instance (written only by its render callback) and republishes it into
/// lock-free atomics for readers on other threads.
///
/// The very first render is deliberately NOT recorded: the cursor is 0 by
/// construction there, so it always resyncs, and recording it would put a
/// permanent 1 in every session's glitch column. Warm-up renders right after
/// that (the producer has not written `floor` frames yet) DO count — hiding
/// them would hide a genuinely bad floor. The claim a run supports is
/// therefore "these numbers stopped moving", not "these numbers are zero".
public struct GlitchTally: Equatable, Sendable {
    /// Renders that re-anchored the cursor. Each one is an audible
    /// discontinuity.
    public private(set) var resyncCount: Int64 = 0
    /// Renders that asked for frames past the producer's write cursor. The
    /// ring zero-fills those, so the artefact is a short silence.
    public private(set) var underrunCount: Int64 = 0
    /// Smallest water level seen, or nil before the first recorded render.
    public private(set) var minWaterLevelFrames: Int64?
    /// How many renders have been folded in (excludes the skipped first one).
    public private(set) var recordedRenders: UInt64 = 0

    public init() {}

    public mutating func record(_ plan: RingReadPlan) {
        recordedRenders &+= 1
        if plan.didResync { resyncCount &+= 1 }
        if plan.underrunFrames > 0 { underrunCount &+= 1 }
        if let current = minWaterLevelFrames {
            minWaterLevelFrames = Swift.min(current, plan.waterLevelFrames)
        } else {
            minWaterLevelFrames = plan.waterLevelFrames
        }
    }

    public mutating func reset() { self = GlitchTally() }
}

public enum RingReadPlanner {
    /// Decide where the next render block reads from.
    ///
    /// - Parameters:
    ///   - writePosition: producer's published cursor (absolute frames).
    ///   - cursor: this consumer's previous read end position; 0 means "never
    ///     rendered", which always resyncs.
    ///   - frames: block size the AUHAL is asking for.
    ///   - floorFrames: steady-state lag behind the producer (`RingFloorPolicy`).
    ///   - compensationFrames: extra lag so a low-latency device waits for the
    ///     slowest peer (inter-device alignment).
    ///   - capacityFrames: ring size; a cursor older than this has been
    ///     overwritten.
    ///   - driftLimitFrames: how far the cursor may wander from the target
    ///     before we re-anchor.
    ///
    /// Resync triggers, in order: first render, cursor overwritten by the
    /// producer, cursor reading past the write head (underrun), and drift
    /// beyond `driftLimitFrames`. Normal ±1-block jitter moves the cursor by
    /// one block, so `driftLimitFrames` must stay several blocks above it —
    /// see `LocalOutput.driftResyncLimitMs`.
    public static func plan(
        writePosition: Int64,
        cursor: Int64,
        frames: Int,
        floorFrames: Int64,
        compensationFrames: Int64,
        capacityFrames: Int,
        driftLimitFrames: Int64
    ) -> RingReadPlan {
        let blockFrames = Int64(frames)
        let target = max(0, writePosition - floorFrames - compensationFrames - blockFrames)
        // Oldest frame still backed by the ring for a full block.
        let lowerValid = max(0, writePosition - Int64(capacityFrames) + blockFrames)
        let needsResync =
            cursor == 0 ||
            cursor < lowerValid ||
            cursor &+ blockFrames > writePosition ||
            abs(cursor - target) > driftLimitFrames
        let startFrame = needsResync ? target : cursor
        let underrun = max(0, startFrame &+ blockFrames - writePosition)
        return RingReadPlan(
            startFrame: startFrame,
            didResync: needsResync,
            underrunFrames: Int(min(underrun, blockFrames)),
            waterLevelFrames: writePosition - startFrame
        )
    }
}
