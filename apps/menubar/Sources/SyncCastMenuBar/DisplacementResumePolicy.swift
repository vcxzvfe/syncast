import Foundation
import SyncCastRouter

/// When a change of the paused sink's own volume is the user asking for the
/// music back.
///
/// # Where this sits
///
/// Picking another output in the Sound menu while SyncCast owns the default
/// output, or macOS doing it on its own for AirPods that just connected,
/// pauses the sink path (`AppModel.pollSystemSinkStatus`). The audio then goes
/// to the device the user picked; when they put SyncCast back, macOS renders
/// into SyncCast's sink again, but the path stays paused and plays nothing
/// until the popover's 「继续」 is clicked. With headphones that come and go
/// that is a click every time.
///
/// A volume-up press on the sink is now the same request as 「继续」, under the
/// conditions where it cannot mean anything else:
///
///   * a displacement pause stands and the engine is idle. Nothing of ours is
///     starting, running or tearing down, and the sink-path start is the one
///     place that writes the sink's level on its own (the seed);
///   * the sink is the macOS default output, and already was when the level
///     being compared against was read. Only then do the volume keys, the
///     menu-bar slider and the scroll wheel act on it at all. A change that
///     spans the switch back is not a press: macOS re-applies a device's
///     remembered level the moment it becomes the default output (measured,
///     see `SystemSinkDevice.start`), and that level can be higher;
///   * the level ROSE. Volume down, the mute key, and an unmute that does not
///     raise the level never resume, and neither does the echo of a level
///     SyncCast itself wrote a moment ago.
///
/// # Why the sink's volume and not the keys
///
/// Reading the keys needs an event tap, and an event tap needs Accessibility,
/// which SyncCast does not ask for on the sink path. It would also miss every
/// volume change that is not a key press: the scroll wheel that writes the
/// default output's volume directly, the Sound menu slider. The sink's
/// `VolumeScalar` is where all of them land.
///
/// # Full scale
///
/// At 100 % a volume-up press changes nothing, and the driver only announces
/// a level that changed, so there is nothing to observe. While the pause
/// stands and the sink is the default output at full scale, SyncCast lowers it
/// by `fullScaleNudge` (about 0.25 dB on the sink's 63.5 dB law, below what an
/// ear can tell apart), so the next press lands on a real change. The level
/// the path resumes at is decided by the sink-path start as before, so the
/// nudge never outlives the pause.
enum DisplacementResumePolicy {

    /// One reading of the watched sink.
    struct Sample: Equatable, Sendable {
        let volume: Float?
        let muted: Bool?
        /// Whether the sink was the macOS default output when this was read.
        let sinkIsDefault: Bool
    }

    enum Verdict: Equatable, Sendable {
        case resume
        case ignore(Reason)
    }

    enum Reason: String, Equatable, Sendable {
        case notPaused = "not paused"
        case engineBusy = "engine not idle"
        case noBaseline = "no level to compare with"
        case notDefaultOutput = "the sink is not the default output"
        case defaultJustChanged = "the sink only just became the default output"
        case notARise = "level did not rise"
        case selfWriteEcho = "echo of SyncCast's own write"
    }

    /// Smallest rise that counts as a press. Well under any real step (the
    /// keys move 1/16, Option-Shift 1/64, the scroll wheel 1/32) and under
    /// `fullScaleNudge`, so a press from the nudged level still counts; well
    /// over float noise.
    static let minimumRise: Float = 0.002

    /// How far a full-scale sink is lowered while it waits for a press.
    static let fullScaleNudge: Float = 1.0 / 256

    /// A level SyncCast wrote is its own echo for this long...
    static let selfWriteEchoWindow: TimeInterval = 2
    /// ...when the level read back is this close to it.
    static let selfWriteEchoTolerance: Float = 0.001

    /// After the default output changes, readings for this long are macOS
    /// settling the switch (re-applying the device's remembered level), not
    /// the user. Longer than the ~360 ms the sink-path start has to keep
    /// re-writing its seed for (`SystemSinkDevice.seedVolumeAfterTakeover`);
    /// short enough that a press right after picking SyncCast is rarely lost,
    /// and a lost one only means pressing again.
    static let defaultSwitchSettleSeconds: TimeInterval = 0.6

    /// The sink to watch while a pause stands, or nil for none.
    ///
    /// `pausedSinkUID` is the sink the pause was taken on (see
    /// `pausedSinkUID(status:)`). Only an idle engine is watched: while it is
    /// starting, running or stopping, the path's own writes and its own
    /// listener are in charge of the level.
    static func watchTarget(
        paused: Bool,
        engineIdle: Bool,
        pausedSinkUID: String?
    ) -> String? {
        guard paused, engineIdle, let uid = pausedSinkUID,
              SystemSinkDevice.isSinkUID(uid)
        else {
            return nil
        }
        return uid
    }

    /// The sink a pause is being taken on, read from the status the
    /// displacement poll just refreshed. Nil when that owner has no volume
    /// control (whole-home's wrapped aggregate), which leaves 「继续」 as the
    /// only way back, exactly as before.
    static func pausedSinkUID(status: Router.SystemSinkStatus) -> String? {
        guard status.drivesSystemVolume, let uid = status.uid,
              SystemSinkDevice.isSinkUID(uid)
        else {
            return nil
        }
        return uid
    }

    /// The name the Sound menu shows for a watched sink, which is what the
    /// paused line has to tell the user to pick. Nil for a UID that is not
    /// one of SyncCast's sinks.
    static func sinkDisplayName(uid: String?) -> String? {
        guard let uid else { return nil }
        return SystemSinkDevice.candidates.first { $0.uid == uid }?.displayName
    }

    /// Is this reading of the watched sink a volume-up that should resume?
    ///
    /// - Parameters:
    ///   - previous: the reading before this one, nil when none was taken.
    ///   - recentSelfWrite: the level SyncCast last wrote to this sink, if it
    ///     did so within `selfWriteEchoWindow` and no reading has consumed it.
    static func verdict(
        previous: Sample?,
        current: Sample,
        paused: Bool,
        engineIdle: Bool,
        recentSelfWrite: Float?
    ) -> Verdict {
        guard paused else { return .ignore(.notPaused) }
        guard engineIdle else { return .ignore(.engineBusy) }
        guard let previous, let before = previous.volume,
              let after = current.volume
        else {
            return .ignore(.noBaseline)
        }
        guard current.sinkIsDefault else { return .ignore(.notDefaultOutput) }
        guard previous.sinkIsDefault else { return .ignore(.defaultJustChanged) }
        guard after - before >= minimumRise else { return .ignore(.notARise) }
        if let written = recentSelfWrite,
           abs(after - written) <= selfWriteEchoTolerance {
            return .ignore(.selfWriteEcho)
        }
        return .resume
    }

    /// Is a reading taken at `now` still inside the settle window of a
    /// default-output change made at `switchedAt`?
    static func isSettlingDefaultSwitch(switchedAt: Date?, now: Date) -> Bool {
        guard let switchedAt else { return false }
        let age = now.timeIntervalSince(switchedAt)
        return age >= 0 && age < defaultSwitchSettleSeconds
    }

    /// The level SyncCast last wrote to `uid`, if that write is recent enough
    /// to still be echoing.
    static func recentSelfWrite(
        _ write: SystemSinkCoordinator.AppVolumeWrite?,
        uid: String,
        now: Date
    ) -> Float? {
        guard let write, write.uid == uid else { return nil }
        let age = now.timeIntervalSince(write.at)
        guard age >= 0, age <= selfWriteEchoWindow else { return nil }
        return write.volume
    }

    /// Should a waiting full-scale sink be lowered by `fullScaleNudge`?
    ///
    /// Only when the settled baseline is full scale too, not just the level
    /// read now. A level that has just reached full scale from below is a
    /// press the listener has not read yet (it debounces); lowering it then
    /// would swallow the press it was meant to make visible.
    static func shouldNudgeOffFullScale(
        paused: Bool,
        engineIdle: Bool,
        sinkIsDefaultOutput: Bool,
        baselineVolume: Float?,
        volume: Float?
    ) -> Bool {
        guard paused, engineIdle, sinkIsDefaultOutput,
              let baselineVolume, let volume
        else {
            return false
        }
        return isFullScale(baselineVolume) && isFullScale(volume)
    }

    private static func isFullScale(_ volume: Float) -> Bool {
        volume >= 1 - fullScaleNudge / 2
    }

    /// The level a nudged sink waits at.
    static var nudgedFullScale: Float { 1 - fullScaleNudge }
}
