import XCTest
import SyncCastRouter
@testable import SyncCastMenuBar

/// Volume-up resumes a displacement pause.
///
/// Unit tests only: the rule (`DisplacementResumePolicy`) and the model glue
/// that acts on it. Nothing here attaches a HAL listener or writes a volume
/// (`DisplacementResumeWatcher.watch` is inert under XCTest); "press the key
/// and the music comes back" is checked on the real machine.
@MainActor
final class DisplacementResumeTests: XCTestCase {
    private typealias Policy = DisplacementResumePolicy
    private typealias Sample = DisplacementResumePolicy.Sample

    private let sink = SystemSinkDevice.syncCastDriverUID
    private let builtIn = "BuiltInSpeakerDevice"

    /// A reading; by default taken while the sink is the default output.
    private func sample(
        _ volume: Float?, muted: Bool? = false, isDefault: Bool = true
    ) -> Sample {
        Sample(volume: volume, muted: muted, sinkIsDefault: isDefault)
    }

    private func verdict(
        from previous: Sample?,
        to current: Sample,
        paused: Bool = true,
        engineIdle: Bool = true,
        recentSelfWrite: Float? = nil
    ) -> Policy.Verdict {
        Policy.verdict(
            previous: previous,
            current: current,
            paused: paused,
            engineIdle: engineIdle,
            recentSelfWrite: recentSelfWrite
        )
    }

    // MARK: - What counts as a volume-up

    /// The feature: one key press on the sink while it is the default output
    /// again.
    func testVolumeUpOnTheDefaultSinkResumes() {
        XCTAssertEqual(verdict(from: sample(0.75), to: sample(0.8125)), .resume)
    }

    /// Every step size a user can produce is a press: the keys (1/16),
    /// Option-Shift (1/64), the scroll wheel (1/32).
    func testEveryRealStepSizeCounts() {
        for step: Float in [1.0 / 16, 1.0 / 32, 1.0 / 64] {
            XCTAssertEqual(
                verdict(from: sample(0.5), to: sample(0.5 + step)),
                .resume,
                "step \(step)"
            )
        }
    }

    func testVolumeDownNeverResumes() {
        XCTAssertEqual(
            verdict(from: sample(0.8125), to: sample(0.75)),
            .ignore(.notARise)
        )
    }

    /// The mute key moves the mute flag, never the level, in either direction.
    func testTheMuteKeyNeverResumes() {
        XCTAssertEqual(
            verdict(from: sample(0.75, muted: false), to: sample(0.75, muted: true)),
            .ignore(.notARise)
        )
        XCTAssertEqual(
            verdict(from: sample(0.75, muted: true), to: sample(0.75, muted: false)),
            .ignore(.notARise)
        )
    }

    /// Volume-up while muted unmutes AND raises the level: still a press.
    func testVolumeUpWhileMutedResumes() {
        XCTAssertEqual(
            verdict(from: sample(0.75, muted: true), to: sample(0.8125, muted: false)),
            .resume
        )
    }

    /// Float noise and sub-step jitter are not a press.
    func testATinyRiseIsNotAPress() {
        XCTAssertEqual(
            verdict(from: sample(0.75), to: sample(0.7505)),
            .ignore(.notARise)
        )
    }

    /// Without a level from before, there is no direction to judge.
    func testNoBaselineNoResume() {
        XCTAssertEqual(verdict(from: nil, to: sample(0.8)), .ignore(.noBaseline))
        XCTAssertEqual(
            verdict(from: sample(nil), to: sample(0.8)),
            .ignore(.noBaseline)
        )
        XCTAssertEqual(
            verdict(from: sample(0.5), to: sample(nil)),
            .ignore(.noBaseline)
        )
    }

    // MARK: - When a volume-up is not a request to resume

    /// While another output is the default, the keys do not act on the sink at
    /// all, so a rise there came from somewhere else and is not "SyncCast is
    /// the output again, play".
    func testARiseWhileAnotherOutputIsTheDefaultDoesNotResume() {
        XCTAssertEqual(
            verdict(
                from: sample(0.5, isDefault: false),
                to: sample(0.5625, isDefault: false)
            ),
            .ignore(.notDefaultOutput)
        )
    }

    /// The switch back itself can raise the level: macOS re-applies the
    /// sink's remembered level the moment it becomes the default output. A
    /// rise measured from a baseline read before the switch is that, not a
    /// press.
    func testARiseAcrossTheSwitchBackIsNotAPress() {
        XCTAssertEqual(
            verdict(from: sample(0.4375, isDefault: false), to: sample(0.75)),
            .ignore(.defaultJustChanged)
        )
    }

    func testNothingResumesUnlessPaused() {
        XCTAssertEqual(
            verdict(from: sample(0.5), to: sample(0.5625), paused: false),
            .ignore(.notPaused)
        )
    }

    /// A starting or stopping engine writes the sink's level itself (the seed
    /// on start), and a running one has its own listener.
    func testNothingResumesWhileTheEngineIsBusy() {
        XCTAssertEqual(
            verdict(from: sample(0.5), to: sample(0.5625), engineIdle: false),
            .ignore(.engineBusy)
        )
    }

    /// The level SyncCast just wrote, read back, is its own echo however much
    /// it rose: the arrival and departure rules, the panel's master slider.
    func testTheEchoOfSyncCastsOwnWriteDoesNotResume() {
        XCTAssertEqual(
            verdict(from: sample(0.5), to: sample(0.9), recentSelfWrite: 0.9),
            .ignore(.selfWriteEcho)
        )
        // A real press landing somewhere else inside the window still counts.
        XCTAssertEqual(
            verdict(from: sample(0.5), to: sample(0.5625), recentSelfWrite: 0.9),
            .resume
        )
    }

    func testOnlyARecentWriteToTheSameSinkIsAnEcho() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let write = SystemSinkCoordinator.AppVolumeWrite(
            uid: sink, volume: 0.9, at: now.addingTimeInterval(-1)
        )
        XCTAssertEqual(Policy.recentSelfWrite(write, uid: sink, now: now), 0.9)
        XCTAssertNil(Policy.recentSelfWrite(write, uid: builtIn, now: now))
        XCTAssertNil(Policy.recentSelfWrite(
            write,
            uid: sink,
            now: now.addingTimeInterval(Policy.selfWriteEchoWindow + 1)
        ))
        XCTAssertNil(Policy.recentSelfWrite(nil, uid: sink, now: now))
        // A write stamped in the future (clock change) is not trusted.
        XCTAssertNil(Policy.recentSelfWrite(
            write, uid: sink, now: now.addingTimeInterval(-10)
        ))
    }

    // MARK: - The settle window after a default-output switch

    func testReadingsJustAfterADefaultSwitchAreSettling() {
        let switchedAt = Date(timeIntervalSince1970: 2_000_000)
        XCTAssertTrue(Policy.isSettlingDefaultSwitch(
            switchedAt: switchedAt, now: switchedAt.addingTimeInterval(0.1)
        ))
        XCTAssertFalse(Policy.isSettlingDefaultSwitch(
            switchedAt: switchedAt,
            now: switchedAt.addingTimeInterval(Policy.defaultSwitchSettleSeconds)
        ))
        XCTAssertFalse(Policy.isSettlingDefaultSwitch(switchedAt: nil, now: switchedAt))
        // A switch stamped in the future (clock change) does not hold readings.
        XCTAssertFalse(Policy.isSettlingDefaultSwitch(
            switchedAt: switchedAt, now: switchedAt.addingTimeInterval(-5)
        ))
    }

    /// The window has to outlast the measured settle of a takeover, which the
    /// sink-path start covers by re-writing its seed for up to ~360 ms.
    func testTheSettleWindowOutlastsTheMeasuredSwitch() {
        XCTAssertGreaterThan(Policy.defaultSwitchSettleSeconds, 0.36)
        XCTAssertLessThan(Policy.defaultSwitchSettleSeconds, 1.5)
    }

    // MARK: - What is watched

    func testOnlyAPausedIdleSinkIsWatched() {
        XCTAssertEqual(
            Policy.watchTarget(paused: true, engineIdle: true, pausedSinkUID: sink),
            sink
        )
        XCTAssertNil(Policy.watchTarget(paused: false, engineIdle: true, pausedSinkUID: sink))
        XCTAssertNil(Policy.watchTarget(paused: true, engineIdle: false, pausedSinkUID: sink))
        XCTAssertNil(Policy.watchTarget(paused: true, engineIdle: true, pausedSinkUID: nil))
        // Never anything that is not one of SyncCast's sinks.
        XCTAssertNil(Policy.watchTarget(paused: true, engineIdle: true, pausedSinkUID: builtIn))
    }

    func testThePausedSinkIsTheOneThatCarriedTheSystemVolume() {
        let stereo = Router.SystemSinkStatus(
            active: true, uid: sink, displayName: "SyncCast",
            isSystemDefaultOutput: false, masterVolume: 0.8, masterMuted: false,
            drivesSystemVolume: true
        )
        XCTAssertEqual(Policy.pausedSinkUID(status: stereo), sink)
        // Whole-home's wrapped aggregate holds the default output with no
        // volume control: nothing to press, 「继续」 stays the way back.
        let wrapped = Router.SystemSinkStatus(
            active: true, uid: nil, displayName: "SyncCast Whole Home",
            isSystemDefaultOutput: false, masterVolume: 1, masterMuted: false,
            drivesSystemVolume: false
        )
        XCTAssertNil(Policy.pausedSinkUID(status: wrapped))
        let foreign = Router.SystemSinkStatus(
            active: true, uid: builtIn, displayName: "MacBook Pro",
            isSystemDefaultOutput: false, masterVolume: 1, masterMuted: false,
            drivesSystemVolume: true
        )
        XCTAssertNil(Policy.pausedSinkUID(status: foreign))
    }

    func testTheSinkIsNamedAsTheSoundMenuShowsIt() {
        XCTAssertEqual(Policy.sinkDisplayName(uid: sink), SystemSinkDevice.syncCastDriverName)
        XCTAssertEqual(
            Policy.sinkDisplayName(uid: SystemSinkDevice.blackHole2chUID),
            SystemSinkDevice.blackHole2chName
        )
        XCTAssertNil(Policy.sinkDisplayName(uid: builtIn))
        XCTAssertNil(Policy.sinkDisplayName(uid: nil))
    }

    // MARK: - Full scale

    private func shouldNudge(
        paused: Bool = true,
        engineIdle: Bool = true,
        isDefault: Bool = true,
        baseline: Float? = 1,
        volume: Float?
    ) -> Bool {
        Policy.shouldNudgeOffFullScale(
            paused: paused,
            engineIdle: engineIdle,
            sinkIsDefaultOutput: isDefault,
            baselineVolume: baseline,
            volume: volume
        )
    }

    /// At 100 % a press changes nothing the driver would announce, so a
    /// waiting full-scale sink is lowered one notch...
    func testAFullScaleSinkWaitingForAPressIsNudged() {
        XCTAssertTrue(shouldNudge(volume: 1))
        // ...once: the nudged level is not full scale any more.
        XCTAssertFalse(shouldNudge(
            baseline: Policy.nudgedFullScale, volume: Policy.nudgedFullScale
        ))
        XCTAssertFalse(shouldNudge(baseline: 0.9, volume: 0.9))
    }

    /// A level that has only just reached full scale is a press the debounced
    /// listener has not read yet. Lowering it would swallow that press.
    func testAPressThatJustReachedFullScaleIsNotNudgedAway() {
        XCTAssertFalse(shouldNudge(baseline: Policy.nudgedFullScale, volume: 1))
        XCTAssertFalse(shouldNudge(baseline: 0.9375, volume: 1))
        XCTAssertFalse(shouldNudge(baseline: nil, volume: 1))
    }

    /// ...and only in the one state where a press is being waited for.
    func testTheNudgeTouchesNothingOutsideThePause() {
        XCTAssertFalse(shouldNudge(paused: false, volume: 1))
        XCTAssertFalse(shouldNudge(engineIdle: false, volume: 1))
        XCTAssertFalse(shouldNudge(isDefault: false, volume: 1))
        XCTAssertFalse(shouldNudge(volume: nil))
    }

    /// The press from the nudged level back to full scale is a press, and the
    /// nudge itself (a fall) never is.
    func testAPressFromTheNudgedLevelResumesAndTheNudgeDoesNot() {
        XCTAssertGreaterThan(Policy.fullScaleNudge, Policy.minimumRise)
        XCTAssertEqual(
            verdict(from: sample(Policy.nudgedFullScale), to: sample(1)),
            .resume
        )
        XCTAssertEqual(
            verdict(from: sample(1), to: sample(Policy.nudgedFullScale)),
            .ignore(.notARise)
        )
        // Even inside the echo window of the nudge: full scale is not the
        // written level.
        XCTAssertEqual(
            verdict(
                from: sample(Policy.nudgedFullScale), to: sample(1),
                recentSelfWrite: Policy.nudgedFullScale
            ),
            .resume
        )
    }

    // MARK: - Model glue

    private func pausedModel() -> AppModel {
        let m = AppModel()
        m.systemSinkPauseSinkUID = sink
        m.systemSinkPausedByDisplacement = true
        m.systemSinkPauseMode = .stereo
        return m
    }

    /// A volume-up retires the pause exactly as 「继续」 does.
    func testVolumeUpRetiresThePauseLikeTheButton() {
        let m = pausedModel()
        XCTAssertTrue(m.engineIsIdleForDisplacementResume)
        m.handleDisplacedSinkVolumeChange(
            uid: sink, previous: sample(0.5), current: sample(0.5625)
        )
        XCTAssertFalse(m.systemSinkPausedByDisplacement)
        XCTAssertNil(m.systemSinkPauseMode)
        XCTAssertNil(m.systemSinkPauseSinkUID)
    }

    func testVolumeDownLeavesThePause() {
        let m = pausedModel()
        m.handleDisplacedSinkVolumeChange(
            uid: sink, previous: sample(0.5625), current: sample(0.5)
        )
        XCTAssertTrue(m.systemSinkPausedByDisplacement)
        XCTAssertEqual(m.systemSinkPauseSinkUID, sink)
    }

    func testARiseWhileTheHeadphonesAreTheOutputLeavesThePause() {
        let m = pausedModel()
        m.handleDisplacedSinkVolumeChange(
            uid: sink,
            previous: sample(0.5, isDefault: false),
            current: sample(0.5625, isDefault: false)
        )
        XCTAssertTrue(m.systemSinkPausedByDisplacement)
    }

    func testTheEchoOfThePanelsOwnWriteLeavesThePause() {
        let m = pausedModel()
        let now = Date()
        m.systemSink.noteAppVolumeWrite(uid: sink, volume: 0.9, at: now)
        m.handleDisplacedSinkVolumeChange(
            uid: sink, previous: sample(0.5), current: sample(0.9),
            now: now.addingTimeInterval(0.4)
        )
        XCTAssertTrue(m.systemSinkPausedByDisplacement)
    }

    /// The echo marker covers the first reading after the write only. A user
    /// who then goes down and back up to the written level is pressing.
    func testAnEchoIsConsumedByTheFirstReadingAfterTheWrite() {
        let m = pausedModel()
        let now = Date()
        m.systemSink.noteAppVolumeWrite(uid: sink, volume: 0.9, at: now)
        m.handleDisplacedSinkVolumeChange(
            uid: sink, previous: sample(0.5), current: sample(0.9),
            now: now.addingTimeInterval(0.4)
        )
        XCTAssertNil(m.systemSink.lastAppVolumeWrite)
        m.handleDisplacedSinkVolumeChange(
            uid: sink, previous: sample(0.9), current: sample(0.8375),
            now: now.addingTimeInterval(0.8)
        )
        m.handleDisplacedSinkVolumeChange(
            uid: sink, previous: sample(0.8375), current: sample(0.9),
            now: now.addingTimeInterval(1.2)
        )
        XCTAssertFalse(m.systemSinkPausedByDisplacement)
    }

    func testABusyEngineLeavesThePause() {
        let m = pausedModel()
        m.streamingState = .starting
        XCTAssertFalse(m.engineIsIdleForDisplacementResume)
        m.handleDisplacedSinkVolumeChange(
            uid: sink, previous: sample(0.5), current: sample(0.5625)
        )
        XCTAssertTrue(m.systemSinkPausedByDisplacement)
    }

    /// Retiring the pause by any route (a mode switch here) forgets the sink,
    /// so a later pause never inherits a stale one.
    func testRetiringThePauseForgetsTheSink() {
        let m = AppModel()
        m.mode = .wholeHome
        m.systemSinkPauseSinkUID = sink
        m.systemSinkPausedByDisplacement = true
        m.systemSinkPauseMode = .wholeHome
        m.mode = .stereo
        XCTAssertFalse(m.systemSinkPausedByDisplacement)
        XCTAssertNil(m.systemSinkPauseSinkUID)
    }

    /// Under XCTest the listener never attaches, whatever the model says.
    func testTheWatcherStaysOffTheRealSinkUnderTest() {
        let m = pausedModel()
        m.refreshDisplacementResumeWatcher(reason: "test")
        XCTAssertNil(m.displacementResumeWatcher.watchedUID)
        XCTAssertFalse(m.displacementResumeWatcher.isSettlingDefaultSwitch)
    }

    // MARK: - The paused line

    func testThePausedLineOffersVolumeUpOnlyWithASinkToWatch() {
        let m = pausedModel()
        let watched = m.displacementPauseLine(sinkName: "SyncCast")
        XCTAssertTrue(watched.contains("音量加"), watched)
        XCTAssertTrue(watched.contains("继续"), watched)
        m.systemSinkPauseSinkUID = nil
        let unwatched = m.displacementPauseLine(sinkName: "SyncCast")
        XCTAssertFalse(unwatched.contains("音量加"), unwatched)
        XCTAssertTrue(unwatched.contains("点继续"), unwatched)
    }

    /// Whole-home on SyncCast's own driver, paused: the idle whole-home status
    /// carries no name, and the line must still send the user to the device
    /// the Sound menu calls "SyncCast", not to the wrapped aggregate.
    func testTheWholeHomePausedLineNamesTheWatchedSink() {
        let m = AppModel()
        m.mode = .wholeHome
        m.systemSinkPauseSinkUID = sink
        m.systemSinkPausedByDisplacement = true
        m.systemSinkPauseMode = .wholeHome
        let line = m.wholeHomeSinkStatusLine ?? ""
        XCTAssertTrue(line.contains("「\(SystemSinkDevice.syncCastDriverName)」"), line)
        XCTAssertFalse(line.contains(WholeHomeSinkOutput.displayName), line)
    }
}
