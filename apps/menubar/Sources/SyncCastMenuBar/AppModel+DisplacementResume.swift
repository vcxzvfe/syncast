import Foundation
import SyncCastRouter

/// Volume-up resumes a displacement pause.
///
/// The rule is `DisplacementResumePolicy`, the listener is
/// `DisplacementResumeWatcher`; this is the glue that feeds the listener's
/// readings and the model's state into the rule and acts on the verdict.
/// Acting means calling the same `resumeAfterSystemSinkDisplacement` the
/// 「继续」 button calls, so a resume by key and a resume by click are one code
/// path.
extension AppModel {

    /// What resumed a displacement pause, for the log.
    enum DisplacementResumeTrigger: String, Sendable {
        case button = "继续 button"
        case volumeUp = "volume up"
    }

    /// Nothing of the engine is starting, running or stopping.
    var engineIsIdleForDisplacementResume: Bool {
        streamingState == .idle || streamingState == .error
    }

    /// Hook the watcher's callbacks up to the model. Called once, from init.
    func wireDisplacementResumeWatcher() {
        displacementResumeWatcher.onChange = { [weak self] uid, previous, current in
            self?.handleDisplacedSinkVolumeChange(
                uid: uid, previous: previous, current: current
            )
        }
        // A fresh baseline is the moment to check for full scale: right after
        // SyncCast became the default output again, before the first press.
        displacementResumeWatcher.onBaselineTaken = { [weak self] _, _ in
            self?.nudgeDisplacedSinkOffFullScaleIfNeeded()
        }
    }

    /// Attach, keep or detach the volume-up listener to match the state.
    /// Called on every pause and engine transition and on every poll tick.
    func refreshDisplacementResumeWatcher(reason: String) {
        let target = DisplacementResumePolicy.watchTarget(
            paused: systemSinkPausedByDisplacement,
            engineIdle: engineIsIdleForDisplacementResume,
            pausedSinkUID: systemSinkPauseSinkUID
        )
        displacementResumeWatcher.watch(uid: target, reason: reason)
    }

    /// One listener reading of the paused sink: resume when it is a volume-up
    /// on the sink while the sink is, and already was, the default output.
    ///
    /// `now` is a parameter so tests can drive the echo window.
    func handleDisplacedSinkVolumeChange(
        uid: String,
        previous: DisplacementResumePolicy.Sample?,
        current: DisplacementResumePolicy.Sample,
        now: Date = Date()
    ) {
        let selfWrite = DisplacementResumePolicy.recentSelfWrite(
            systemSink.lastAppVolumeWrite, uid: uid, now: now
        )
        // A write's echo is the first reading after it, and only that one:
        // anything later already reflects whatever moved the level since.
        if selfWrite != nil {
            systemSink.consumeAppVolumeWrite(uid: uid)
        }
        let verdict = DisplacementResumePolicy.verdict(
            previous: previous,
            current: current,
            paused: systemSinkPausedByDisplacement,
            engineIdle: engineIsIdleForDisplacementResume,
            recentSelfWrite: selfWrite
        )
        let change = DisplacementResumeWatcher.describe(previous)
            + "→" + DisplacementResumeWatcher.describe(current)
        switch verdict {
        case .resume:
            SyncCastLog.log(
                "systemSink: volume up on \(uid) while paused (\(change)) — resuming"
            )
            resumeAfterSystemSinkDisplacement(trigger: .volumeUp)
        case .ignore(let reason):
            SyncCastLog.log(
                "systemSink: paused sink \(uid) level \(change) — not resuming: \(reason.rawValue)"
            )
        }
    }

    /// Keep a paused full-scale sink one notch under full while it is the
    /// default output, so a volume-up press still changes something the
    /// listener can see. See "Full scale" in `DisplacementResumePolicy`.
    func nudgeDisplacedSinkOffFullScaleIfNeeded() {
        guard let uid = displacementResumeWatcher.watchedUID,
              !displacementResumeWatcher.isSettlingDefaultSwitch
        else {
            return
        }
        let volume = AggregateDevice.readHardwareVolume(uid: uid)
        guard DisplacementResumePolicy.shouldNudgeOffFullScale(
            paused: systemSinkPausedByDisplacement,
            engineIdle: engineIsIdleForDisplacementResume,
            sinkIsDefaultOutput: SystemDefaultOutput.currentUID() == uid,
            baselineVolume: displacementResumeWatcher.lastSample?.volume,
            volume: volume
        ) else {
            return
        }
        let target = DisplacementResumePolicy.nudgedFullScale
        systemSink.noteAppVolumeWrite(uid: uid, volume: target)
        displacementResumeWatcher.noteOwnWrite(uid: uid)
        let ok = AggregateDevice.applyHardwareVolume(uid: uid, volume: target)
        if ok {
            displacementResumeWatcher.adoptOwnWrite(uid: uid, volume: target)
        }
        SyncCastLog.log(
            "systemSink: paused sink \(uid) is the default output at full scale — "
            + "level → \(String(format: "%.4f", target)) so a volume-up registers (ok=\(ok))"
        )
    }
}
