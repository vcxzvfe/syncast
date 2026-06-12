import XCTest
@testable import SyncCastMenuBar

/// Unit tests for the pure Direct Stereo media-volume-key logic:
///   - `DirectStereoVolumeLogic` (relative stepping, group mute decision)
///   - `SystemVolumeKeyController` static event decoding (NX_SYSDEFINED
///     subtype-8 payload parsing) and the event-tap consumption rule.
///   - `SystemVolumeKeyTapLifecycle` (stop/start race state machine for
///     the event-tap thread).
///
/// Deliberately NO `AppModel` instantiation and NO CoreAudio/AppKit
/// interaction — these are the decision functions the tap thread and the
/// main-actor key handler delegate to, exercised over raw values.
final class VolumeKeyLogicTests: XCTestCase {
    // NX_SYSDEFINED subtype-8 payload layout:
    //   data1 = (keyCode << 16) | (keyState << 8) | repeatBit
    private func data1(
        keyCode: Int,
        keyState: Int,
        isRepeat: Bool = false
    ) -> Int {
        (keyCode << 16) | (keyState << 8) | (isRepeat ? 1 : 0)
    }

    private let keyDown = 0x0A
    private let keyUp = 0x0B
    private let auxSubtype = 8

    // MARK: - Relative volume stepping

    func test_stepUp_addsOneSixteenth() {
        XCTAssertEqual(
            DirectStereoVolumeLogic.steppedVolume(from: 0.5, direction: .up),
            0.5 + 1.0 / 16.0,
            accuracy: 0.0001
        )
    }

    func test_stepDown_subtractsOneSixteenth() {
        XCTAssertEqual(
            DirectStereoVolumeLogic.steppedVolume(from: 0.5, direction: .down),
            0.5 - 1.0 / 16.0,
            accuracy: 0.0001
        )
    }

    func test_stepUp_clampsAtOne() {
        XCTAssertEqual(
            DirectStereoVolumeLogic.steppedVolume(from: 0.99, direction: .up),
            1.0
        )
        XCTAssertEqual(
            DirectStereoVolumeLogic.steppedVolume(from: 1.0, direction: .up),
            1.0
        )
    }

    func test_stepDown_clampsAtZero() {
        XCTAssertEqual(
            DirectStereoVolumeLogic.steppedVolume(from: 0.01, direction: .down),
            0.0
        )
        XCTAssertEqual(
            DirectStereoVolumeLogic.steppedVolume(from: 0.0, direction: .down),
            0.0
        )
    }

    /// The core balance-preservation property: two devices at different
    /// volumes stay exactly `offset` apart after any number of steps
    /// that don't clamp.
    func test_step_preservesInterDeviceOffset() {
        var a: Float = 0.25
        var b: Float = 0.75
        let offset = b - a
        for _ in 0..<3 {
            a = DirectStereoVolumeLogic.steppedVolume(from: a, direction: .up)
            b = DirectStereoVolumeLogic.steppedVolume(from: b, direction: .up)
        }
        XCTAssertEqual(b - a, offset, accuracy: 0.0001)
    }

    func test_unmutesOnStep_upOnly() {
        XCTAssertTrue(DirectStereoVolumeLogic.unmutesOnStep(.up))
        XCTAssertFalse(DirectStereoVolumeLogic.unmutesOnStep(.down))
    }

    // MARK: - Group mute decision

    func test_groupMute_anyAudible_mutesAll() {
        XCTAssertTrue(
            DirectStereoVolumeLogic.groupMuteTarget(
                currentlyMuted: [false, false]
            )
        )
        XCTAssertTrue(
            DirectStereoVolumeLogic.groupMuteTarget(
                currentlyMuted: [true, false]
            )
        )
    }

    func test_groupMute_allMuted_unmutesAll() {
        XCTAssertFalse(
            DirectStereoVolumeLogic.groupMuteTarget(
                currentlyMuted: [true, true]
            )
        )
        XCTAssertFalse(
            DirectStereoVolumeLogic.groupMuteTarget(currentlyMuted: [true])
        )
    }

    // MARK: - External hardware change mirror decision

    /// THE mute-echo bug (Codex P1): our own mute write parks the
    /// hardware scalar at 0 (emulated mute), the observer's suppression
    /// window defers the listener read and republishes it as an external
    /// change ~0.4 s later — that 0 must NOT overwrite the saved
    /// route.volume, or unmute "restores" silence.
    func test_externalChange_mutedZeroEcho_doesNotOverwriteVolume() {
        let decision = DirectStereoVolumeLogic.externalHardwareChange(
            routeVolume: 0.6,
            routeMuted: true,
            observedVolume: 0.0,
            observedMuted: nil
        )
        XCTAssertNil(decision.volume)
        XCTAssertNil(decision.muted)
        XCTAssertFalse(decision.changesAnything)
    }

    /// Same echo with an explicit still-muted report (drivers that expose
    /// a Mute property AND zero the scalar while muted).
    func test_externalChange_mutedZeroEchoWithMuteReport_ignored() {
        let decision = DirectStereoVolumeLogic.externalHardwareChange(
            routeVolume: 0.6,
            routeMuted: true,
            observedVolume: 0.003,
            observedMuted: true
        )
        XCTAssertNil(decision.volume)
        XCTAssertNil(decision.muted)
    }

    /// A real external level change during mute (System Settings drag)
    /// must update the route volume while mute stays put.
    func test_externalChange_mutedNonZeroVolume_updatesVolumeKeepsMute() {
        let decision = DirectStereoVolumeLogic.externalHardwareChange(
            routeVolume: 0.6,
            routeMuted: true,
            observedVolume: 0.3,
            observedMuted: true
        )
        XCTAssertEqual(decision.volume, 0.3)
        XCTAssertNil(decision.muted)
    }

    /// An explicit external unmute applies as observed — including a
    /// genuine zero level (hardware really is unmuted at 0 now; keeping
    /// the stale route volume would make the slider lie).
    func test_externalChange_externalUnmuteAtZero_appliesBoth() {
        let decision = DirectStereoVolumeLogic.externalHardwareChange(
            routeVolume: 0.6,
            routeMuted: true,
            observedVolume: 0.0,
            observedMuted: false
        )
        XCTAssertEqual(decision.volume, 0.0)
        XCTAssertEqual(decision.muted, false)
    }

    /// While unmuted there is no echo to guard against: dragging the
    /// hardware level to 0 is a real user intent and must mirror.
    func test_externalChange_unmutedZeroVolume_applies() {
        let decision = DirectStereoVolumeLogic.externalHardwareChange(
            routeVolume: 0.6,
            routeMuted: false,
            observedVolume: 0.0,
            observedMuted: nil
        )
        XCTAssertEqual(decision.volume, 0.0)
        XCTAssertNil(decision.muted)
    }

    /// Sub-threshold deltas are our own write echoing back through driver
    /// quantization and must not churn routing.
    func test_externalChange_tinyDelta_ignored() {
        let decision = DirectStereoVolumeLogic.externalHardwareChange(
            routeVolume: 0.5,
            routeMuted: false,
            observedVolume: 0.502,
            observedMuted: false
        )
        XCTAssertNil(decision.volume)
        XCTAssertNil(decision.muted)
        XCTAssertFalse(decision.changesAnything)
    }

    /// An external mute report flips the route's muted flag even when the
    /// level did not move (mute-writable device after the core fix: the
    /// scalar stays at the user level while Mute silences).
    func test_externalChange_externalMute_appliesMuteOnly() {
        let decision = DirectStereoVolumeLogic.externalHardwareChange(
            routeVolume: 0.6,
            routeMuted: false,
            observedVolume: 0.6,
            observedMuted: true
        )
        XCTAssertNil(decision.volume)
        XCTAssertEqual(decision.muted, true)
        XCTAssertTrue(decision.changesAnything)
    }

    // MARK: - Covered-set snapshot fingerprint

    /// THE id-migration bug: discovery republishes the same CoreAudio UID
    /// under a new SyncCast device id (routing migration keeps playback).
    /// The fingerprint must change so the reconcile path re-snapshots —
    /// backend capabilities and the hardware observer are keyed by device
    /// id and would otherwise stay pinned to the dead id.
    func test_fingerprint_changesWhenDeviceIDMigrates() {
        let before = DirectStereoVolumeLogic.coveredSetFingerprint(
            idUIDPairs: [(id: "device-old", uid: "uid-1")]
        )
        let after = DirectStereoVolumeLogic.coveredSetFingerprint(
            idUIDPairs: [(id: "device-new", uid: "uid-1")]
        )
        XCTAssertNotEqual(before, after)
    }

    func test_fingerprint_changesWhenUIDChanges() {
        let before = DirectStereoVolumeLogic.coveredSetFingerprint(
            idUIDPairs: [(id: "device-1", uid: "uid-old")]
        )
        let after = DirectStereoVolumeLogic.coveredSetFingerprint(
            idUIDPairs: [(id: "device-1", uid: "uid-new")]
        )
        XCTAssertNotEqual(before, after)
    }

    /// Reconcile passes that do NOT change the covered set must keep the
    /// fingerprint stable (snapshots racing queued DDC / async router
    /// writes would yank the slider) — including order-insensitivity.
    func test_fingerprint_stableForSameSetRegardlessOfOrder() {
        let a = DirectStereoVolumeLogic.coveredSetFingerprint(
            idUIDPairs: [
                (id: "device-1", uid: "uid-1"),
                (id: "device-2", uid: "uid-2"),
            ]
        )
        let b = DirectStereoVolumeLogic.coveredSetFingerprint(
            idUIDPairs: [
                (id: "device-2", uid: "uid-2"),
                (id: "device-1", uid: "uid-1"),
            ]
        )
        XCTAssertEqual(a, b)
    }

    // MARK: - Hardware observer rewatch decision

    /// Same UID, same HAL device, NEW SyncCast device id (discovery
    /// republish) must retarget — keeping the old entry meant the
    /// listener kept reporting the dead id and AppModel dropped external
    /// volume/mute changes (routing[old id] no longer exists).
    func test_rewatch_sameHALDeviceNewSyncCastID_retargets() {
        XCTAssertEqual(
            HardwareVolumeRewatchLogic.action(
                watchedDeviceID: "device-old",
                watchedAudioDeviceID: 41,
                wantedDeviceID: "device-new",
                resolvedAudioDeviceID: 41
            ),
            .retarget
        )
    }

    func test_rewatch_unchangedIdentity_keeps() {
        XCTAssertEqual(
            HardwareVolumeRewatchLogic.action(
                watchedDeviceID: "device-1",
                watchedAudioDeviceID: 41,
                wantedDeviceID: "device-1",
                resolvedAudioDeviceID: 41
            ),
            .keep
        )
    }

    /// Sleep/wake reissues a fresh AudioDeviceID for the same UID —
    /// listeners on the dead id never fire again, so rebuild. A moved HAL
    /// id wins over an id migration (rebuild re-registers with the new
    /// device identity anyway).
    func test_rewatch_movedAudioDeviceID_rebuilds() {
        XCTAssertEqual(
            HardwareVolumeRewatchLogic.action(
                watchedDeviceID: "device-1",
                watchedAudioDeviceID: 41,
                wantedDeviceID: "device-1",
                resolvedAudioDeviceID: 77
            ),
            .rebuild
        )
        XCTAssertEqual(
            HardwareVolumeRewatchLogic.action(
                watchedDeviceID: "device-old",
                watchedAudioDeviceID: 41,
                wantedDeviceID: "device-new",
                resolvedAudioDeviceID: 77
            ),
            .rebuild
        )
    }

    func test_rewatch_unresolvableUID_rebuilds() {
        XCTAssertEqual(
            HardwareVolumeRewatchLogic.action(
                watchedDeviceID: "device-1",
                watchedAudioDeviceID: 41,
                wantedDeviceID: "device-1",
                resolvedAudioDeviceID: nil
            ),
            .rebuild
        )
    }

    // MARK: - Media-key event decoding

    func test_action_decodesVolumeKeys_onKeyDown() {
        XCTAssertEqual(
            SystemVolumeKeyController.action(
                subtypeRaw: auxSubtype,
                data1: data1(keyCode: 0, keyState: keyDown)
            ),
            .volumeUp
        )
        XCTAssertEqual(
            SystemVolumeKeyController.action(
                subtypeRaw: auxSubtype,
                data1: data1(keyCode: 1, keyState: keyDown)
            ),
            .volumeDown
        )
        XCTAssertEqual(
            SystemVolumeKeyController.action(
                subtypeRaw: auxSubtype,
                data1: data1(keyCode: 7, keyState: keyDown)
            ),
            .mute
        )
    }

    func test_action_decodesHeldKeyRepeat() {
        XCTAssertEqual(
            SystemVolumeKeyController.action(
                subtypeRaw: auxSubtype,
                data1: data1(keyCode: 0, keyState: keyDown, isRepeat: true)
            ),
            .volumeUp
        )
    }

    func test_action_nilOnKeyUp() {
        XCTAssertNil(
            SystemVolumeKeyController.action(
                subtypeRaw: auxSubtype,
                data1: data1(keyCode: 0, keyState: keyUp)
            )
        )
    }

    func test_action_nilOnOtherSubtype() {
        // Subtype 7 = NX_SUBTYPE_POWER_KEY family, not aux control.
        XCTAssertNil(
            SystemVolumeKeyController.action(
                subtypeRaw: 7,
                data1: data1(keyCode: 0, keyState: keyDown)
            )
        )
    }

    func test_action_nilOnNonVolumeMediaKey() {
        // keyCode 16 = NX_KEYTYPE_PLAY.
        XCTAssertNil(
            SystemVolumeKeyController.action(
                subtypeRaw: auxSubtype,
                data1: data1(keyCode: 16, keyState: keyDown)
            )
        )
    }

    // MARK: - Tap consumption rule

    func test_shouldConsume_eligible_volumeKeyDownAndUp() {
        for keyCode in [0, 1, 7] {
            XCTAssertTrue(
                SystemVolumeKeyController.shouldConsume(
                    eligible: true,
                    subtypeRaw: auxSubtype,
                    data1: data1(keyCode: keyCode, keyState: keyDown)
                ),
                "keyDown for keyCode \(keyCode) must be consumed"
            )
            XCTAssertTrue(
                SystemVolumeKeyController.shouldConsume(
                    eligible: true,
                    subtypeRaw: auxSubtype,
                    data1: data1(keyCode: keyCode, keyState: keyUp)
                ),
                "matching keyUp for keyCode \(keyCode) must also be consumed"
            )
        }
    }

    func test_shouldConsume_notEligible_passesEverything() {
        XCTAssertFalse(
            SystemVolumeKeyController.shouldConsume(
                eligible: false,
                subtypeRaw: auxSubtype,
                data1: data1(keyCode: 0, keyState: keyDown)
            )
        )
    }

    func test_shouldConsume_passesOtherMediaKeys() {
        // Play/pause (16), fast-forward (19), brightness (2/3): never ours.
        for keyCode in [2, 3, 16, 19] {
            XCTAssertFalse(
                SystemVolumeKeyController.shouldConsume(
                    eligible: true,
                    subtypeRaw: auxSubtype,
                    data1: data1(keyCode: keyCode, keyState: keyDown)
                ),
                "keyCode \(keyCode) must pass through"
            )
        }
    }

    func test_shouldConsume_passesOtherSubtypesAndStates() {
        XCTAssertFalse(
            SystemVolumeKeyController.shouldConsume(
                eligible: true,
                subtypeRaw: 7,
                data1: data1(keyCode: 0, keyState: keyDown)
            )
        )
        // Unknown key state (neither 0x0A down nor 0x0B up).
        XCTAssertFalse(
            SystemVolumeKeyController.shouldConsume(
                eligible: true,
                subtypeRaw: auxSubtype,
                data1: data1(keyCode: 0, keyState: 0x0C)
            )
        )
    }

    // MARK: - Tap thread stop/start lifecycle (race state machine)

    func test_tapLifecycle_normalStartPublishStopTeardown() {
        let start = SystemVolumeKeyTapLifecycle.beginStart(.init())
        XCTAssertTrue(start.shouldSpawnThread)
        XCTAssertEqual(start.threadGeneration, 1)
        XCTAssertFalse(start.state.stopRequested)

        let install = SystemVolumeKeyTapLifecycle.resolveInstall(
            start.state, threadGeneration: start.threadGeneration
        )
        XCTAssertTrue(install.shouldPublish)
        XCTAssertTrue(install.state.installed)

        let stopped = SystemVolumeKeyTapLifecycle.requestStop(install.state)
        XCTAssertTrue(stopped.stopRequested)

        let teardown = SystemVolumeKeyTapLifecycle.finishTeardown(
            stopped, threadGeneration: start.threadGeneration
        )
        XCTAssertTrue(teardown.shouldClearHandles)
        XCTAssertFalse(teardown.state.installed)
    }

    /// THE leak bug: stop lands between `thread.start()` and the tap
    /// thread publishing its handles. The thread must observe the stop in
    /// `resolveInstall` and discard the tap instead of entering
    /// CFRunLoopRun unstoppable.
    func test_tapLifecycle_stopBeforePublish_discardsTap() {
        let start = SystemVolumeKeyTapLifecycle.beginStart(.init())
        let stopped = SystemVolumeKeyTapLifecycle.requestStop(start.state)
        let install = SystemVolumeKeyTapLifecycle.resolveInstall(
            stopped, threadGeneration: start.threadGeneration
        )
        XCTAssertFalse(install.shouldPublish)
        XCTAssertFalse(install.state.installed)
    }

    /// Follow-on of the leak bug: after a raced stop, the next start must
    /// not be short-circuited by stale state ("already installed") and
    /// must clear the old stop request.
    func test_tapLifecycle_restartAfterRacedStop_publishes() {
        let start1 = SystemVolumeKeyTapLifecycle.beginStart(.init())
        let stopped = SystemVolumeKeyTapLifecycle.requestStop(start1.state)
        let discarded = SystemVolumeKeyTapLifecycle.resolveInstall(
            stopped, threadGeneration: start1.threadGeneration
        )

        let start2 = SystemVolumeKeyTapLifecycle.beginStart(discarded.state)
        XCTAssertTrue(start2.shouldSpawnThread)
        XCTAssertFalse(start2.state.stopRequested)
        let install2 = SystemVolumeKeyTapLifecycle.resolveInstall(
            start2.state, threadGeneration: start2.threadGeneration
        )
        XCTAssertTrue(install2.shouldPublish)
    }

    /// stop→start while the FIRST thread is still pre-publication: the
    /// superseded thread (stale generation) must discard; only the new
    /// generation publishes — never two live taps.
    func test_tapLifecycle_supersededThread_neverPublishes() {
        let start1 = SystemVolumeKeyTapLifecycle.beginStart(.init())
        let stopped = SystemVolumeKeyTapLifecycle.requestStop(start1.state)
        let start2 = SystemVolumeKeyTapLifecycle.beginStart(stopped)
        XCTAssertTrue(start2.shouldSpawnThread)

        // Stale thread #1 reaches its publish point AFTER start #2.
        let staleInstall = SystemVolumeKeyTapLifecycle.resolveInstall(
            start2.state, threadGeneration: start1.threadGeneration
        )
        XCTAssertFalse(staleInstall.shouldPublish)

        let freshInstall = SystemVolumeKeyTapLifecycle.resolveInstall(
            staleInstall.state, threadGeneration: start2.threadGeneration
        )
        XCTAssertTrue(freshInstall.shouldPublish)
    }

    /// While a tap is installed, a second start must be refused (no
    /// double tap, and the generation of the live thread survives).
    func test_tapLifecycle_startWhileInstalled_refused() {
        let start = SystemVolumeKeyTapLifecycle.beginStart(.init())
        let install = SystemVolumeKeyTapLifecycle.resolveInstall(
            start.state, threadGeneration: start.threadGeneration
        )
        let again = SystemVolumeKeyTapLifecycle.beginStart(install.state)
        XCTAssertFalse(again.shouldSpawnThread)
        XCTAssertEqual(again.state, install.state)
    }

    /// A stale thread's teardown must never wipe a successor's handles.
    func test_tapLifecycle_staleTeardown_keepsSuccessorHandles() {
        let start1 = SystemVolumeKeyTapLifecycle.beginStart(.init())
        let stopped = SystemVolumeKeyTapLifecycle.requestStop(start1.state)
        let start2 = SystemVolumeKeyTapLifecycle.beginStart(stopped)
        let install2 = SystemVolumeKeyTapLifecycle.resolveInstall(
            start2.state, threadGeneration: start2.threadGeneration
        )
        XCTAssertTrue(install2.shouldPublish)

        let staleTeardown = SystemVolumeKeyTapLifecycle.finishTeardown(
            install2.state, threadGeneration: start1.threadGeneration
        )
        XCTAssertFalse(staleTeardown.shouldClearHandles)
        XCTAssertTrue(staleTeardown.state.installed)

        let currentTeardown = SystemVolumeKeyTapLifecycle.finishTeardown(
            staleTeardown.state, threadGeneration: start2.threadGeneration
        )
        XCTAssertTrue(currentTeardown.shouldClearHandles)
        XCTAssertFalse(currentTeardown.state.installed)
    }

    /// Full revoke→grant cycle: teardown completes, then a fresh start
    /// spawns with a bumped generation and publishes again.
    func test_tapLifecycle_fullRestartCycle() {
        let start1 = SystemVolumeKeyTapLifecycle.beginStart(.init())
        let install1 = SystemVolumeKeyTapLifecycle.resolveInstall(
            start1.state, threadGeneration: start1.threadGeneration
        )
        let stopped = SystemVolumeKeyTapLifecycle.requestStop(install1.state)
        let teardown = SystemVolumeKeyTapLifecycle.finishTeardown(
            stopped, threadGeneration: start1.threadGeneration
        )

        let start2 = SystemVolumeKeyTapLifecycle.beginStart(teardown.state)
        XCTAssertTrue(start2.shouldSpawnThread)
        XCTAssertEqual(start2.threadGeneration, 2)
        let install2 = SystemVolumeKeyTapLifecycle.resolveInstall(
            start2.state, threadGeneration: start2.threadGeneration
        )
        XCTAssertTrue(install2.shouldPublish)
    }
}
