import Foundation
import SyncCastRouter

/// Keep-awake-while-playing: glue between the auto-connect rule (which owns
/// the setting and names the display) and `PlaybackAwakeController` (which
/// measures and holds the assertion).
///
/// The rule's trigger device is the display. That is what keeps the feature
/// to the one monitor the user set it up for: a different monitor somewhere
/// else has a different CoreAudio UID and never matches.
extension AppModel {

    /// What the controller should run with; nil when there is no rule or the
    /// rule has the feature off.
    var playbackAwakeSettings: PlaybackAwakeController.Settings? {
        guard let profile = autoConnectProfile, profile.keepsDisplayAwakeWhilePlaying else {
            return nil
        }
        return .init(
            displayUID: profile.triggerUID,
            releaseAfterSeconds: TimeInterval(profile.resolvedPlaybackAwakeReleaseSeconds)
        )
    }

    /// Called once from bootstrap. Never under XCTest: a test run must not
    /// create a real power assertion or a Process Tap on the developer's Mac.
    func playbackAwakeBootstrap() {
        guard !TestEnvironment.isRunningUnderXCTest, playbackAwake == nil else { return }
        let router = self.router
        let controller = PlaybackAwakeController(
            blocker: IOPMDisplaySleepBlocker(),
            routerSource: { uid in await router.playbackMeterSource(outputUID: uid) }
        )
        controller.onHoldingChanged = { [weak self] holding in
            self?.playbackAwakeHolding = holding
        }
        controller.onMeterProblemChanged = { [weak self] problem in
            self?.playbackAwakeMeterProblem = problem
        }
        playbackAwake = controller
        playbackAwakeSyncSettings(reason: "launch")
    }

    func playbackAwakeSyncSettings(reason: String) {
        playbackAwake?.update(settings: playbackAwakeSettings, reason: reason)
    }

    /// The device list changed: the display may have come or gone.
    func playbackAwakeNoteDeviceChange() {
        playbackAwake?.refresh(reason: "device change")
    }
}
