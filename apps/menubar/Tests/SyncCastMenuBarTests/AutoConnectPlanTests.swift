import XCTest
@testable import SyncCastMenuBar

/// The translation layer used to make these judgements inline inside an
/// extension on `AppModel` — a `@MainActor @Observable` class that owns a
/// router, discovery and a live audio engine, so none of it was reachable
/// without a monitor to unplug. `AutoConnectPlan` is that judgement extracted;
/// these are the cases the code review found by reading, which is the only way
/// they were ever going to be found otherwise.
final class AutoConnectPlanTests: XCTestCase {

    private let monitor = "00000000-0000-0000-0000-000000000001"
    private let builtIn = AutoConnect.builtInSpeakerUID
    private let macMini = "MacMiniUID"

    // MARK: - Deactivation scope

    /// The bug: the teardown disabled every enabled device, so unplugging the
    /// monitor after the user had built a whole-home session switched off
    /// receivers the rule never touched.
    func testTeardownIsScopedToTheRulesOwnMembers() {
        let plan = AutoConnectPlan.deactivation(
            memberUIDs: [builtIn, monitor],
            restoreBuiltIn: true,
            builtInVolumePercent: 0,
            isWholeHome: false,
            builtInUID: builtIn
        )
        XCTAssertEqual(plan.disableUIDs, [builtIn, monitor])
        XCTAssertFalse(plan.disableUIDs.contains(macMini))
    }

    /// In stereo — the mode the rule fires in — the built-in half stands.
    func testBuiltInHalfStandsInStereo() {
        let plan = AutoConnectPlan.deactivation(
            memberUIDs: [builtIn, monitor],
            restoreBuiltIn: true,
            builtInVolumePercent: 0,
            isWholeHome: false,
            builtInUID: builtIn
        )
        XCTAssertTrue(plan.restoreBuiltIn)
        XCTAssertEqual(plan.builtInVolumePercent, 0)
        XCTAssertNil(plan.skipReason)
    }

    /// The whole-home carve-out: the user has moved the audio to the house, so
    /// re-pointing the default output and zeroing speakers the rule did not
    /// switch on is not the rule's call.
    func testWholeHomeDropsTheBuiltInHalfWhenItIsNotAMember() {
        let plan = AutoConnectPlan.deactivation(
            memberUIDs: [monitor],
            restoreBuiltIn: true,
            builtInVolumePercent: 0,
            isWholeHome: true,
            builtInUID: builtIn
        )
        XCTAssertFalse(plan.restoreBuiltIn)
        XCTAssertNil(plan.builtInVolumePercent)
        XCTAssertNotNil(plan.skipReason)
        // The member teardown still happens — that part IS the rule's to undo.
        XCTAssertEqual(plan.disableUIDs, [monitor])
    }

    /// …but if the built-in is one of the rule's members, the rule is the
    /// reason it is playing and undoing it is fair even in whole-home.
    func testWholeHomeKeepsTheBuiltInHalfWhenItIsAMember() {
        let plan = AutoConnectPlan.deactivation(
            memberUIDs: [builtIn, monitor],
            restoreBuiltIn: true,
            builtInVolumePercent: 0,
            isWholeHome: true,
            builtInUID: builtIn
        )
        XCTAssertTrue(plan.restoreBuiltIn)
        XCTAssertEqual(plan.builtInVolumePercent, 0)
        XCTAssertNil(plan.skipReason)
    }

    func testNoBuiltInDeviceDropsTheBuiltInHalfWithAReason() {
        let plan = AutoConnectPlan.deactivation(
            memberUIDs: [monitor],
            restoreBuiltIn: true,
            builtInVolumePercent: 0,
            isWholeHome: false,
            builtInUID: nil
        )
        XCTAssertFalse(plan.touchesBuiltIn)
        XCTAssertNotNil(plan.skipReason)
    }

    /// A rule with the disconnect action switched off says nothing about the
    /// built-in in either mode, and must not invent a skip reason to log.
    func testDisconnectActionOffTouchesNothingBeyondTheMembers() {
        for wholeHome in [false, true] {
            let plan = AutoConnectPlan.deactivation(
                memberUIDs: [builtIn, monitor],
                restoreBuiltIn: false,
                builtInVolumePercent: nil,
                isWholeHome: wholeHome,
                builtInUID: builtIn
            )
            XCTAssertFalse(plan.touchesBuiltIn)
            XCTAssertNil(plan.skipReason)
            XCTAssertEqual(plan.disableUIDs, [builtIn, monitor])
        }
    }

    // MARK: - The delayed built-in fallback

    func testFallbackRunsOnlyWhileTheTriggerIsStillGoneAndNothingIsPlaying() {
        XCTAssertTrue(
            AutoConnectPlan.builtInFallbackStillWanted(triggerPresent: false, isStreaming: false)
        )
        // The monitor came straight back inside the 0.8 s window (DPMS blink,
        // KVM switch): leave the default output where it is.
        XCTAssertFalse(
            AutoConnectPlan.builtInFallbackStillWanted(triggerPresent: true, isStreaming: false)
        )
        // Something is playing again — yanking the default output out from
        // under it is exactly what the delay exists to avoid.
        XCTAssertFalse(
            AutoConnectPlan.builtInFallbackStillWanted(triggerPresent: false, isStreaming: true)
        )
        XCTAssertFalse(
            AutoConnectPlan.builtInFallbackStillWanted(triggerPresent: true, isStreaming: true)
        )
    }

    // MARK: - Snapshotting the level before forcing it down

    func testCaptureRemembersAnAudibleLevel() {
        XCTAssertEqual(
            AutoConnectPlan.capture(existing: nil, uid: builtIn, currentScalar: 0.62),
            .capture(scalar: 0.62)
        )
    }

    /// The one that makes the fix work: a second unplug with no plug-in
    /// between must not overwrite the remembered level with the 0 % the first
    /// one wrote, or the user's real level is gone for good.
    func testCaptureNeverOverwritesAnExistingSnapshotForTheSameDevice() {
        let held = AutoConnectBuiltInVolumeSnapshot(
            uid: builtIn, scalar: 0.62, capturedAt: Date()
        )
        XCTAssertEqual(
            AutoConnectPlan.capture(existing: held, uid: builtIn, currentScalar: 0.0),
            .skip(reason: "snapshot already held")
        )
    }

    /// A snapshot belonging to a different device (speakers vs headphones) is
    /// not ours to trust; take a fresh one.
    func testCaptureIgnoresASnapshotForADifferentDevice() {
        let held = AutoConnectBuiltInVolumeSnapshot(
            uid: "BuiltInHeadphoneDevice", scalar: 0.3, capturedAt: Date()
        )
        XCTAssertEqual(
            AutoConnectPlan.capture(existing: held, uid: builtIn, currentScalar: 0.62),
            .capture(scalar: 0.62)
        )
    }

    func testCaptureSkipsAnAlreadySilentOrUnreadableLevel() {
        XCTAssertEqual(
            AutoConnectPlan.capture(existing: nil, uid: builtIn, currentScalar: 0.0),
            .skip(reason: "already silent; nothing worth restoring")
        )
        XCTAssertEqual(
            AutoConnectPlan.capture(existing: nil, uid: builtIn, currentScalar: nil),
            .skip(reason: "level unreadable")
        )
    }

    // MARK: - Handing the level back

    /// The headline fix: without this, forcing 0 % is one-way, because Direct
    /// Stereo mirrors the hardware scalar into `routing[*].volume` on
    /// activation and every replug comes back silent.
    func testRestoreWritesTheRememberedLevelAndClearsTheSnapshot() {
        let held = AutoConnectBuiltInVolumeSnapshot(
            uid: builtIn, scalar: 0.62, capturedAt: Date()
        )
        XCTAssertEqual(
            AutoConnectPlan.restore(
                memberUIDs: [builtIn, monitor],
                builtInUID: builtIn,
                snapshot: held,
                currentScalar: 0.0
            ),
            .write(
                scalar: 0.62,
                clearSnapshot: true,
                reason: "restoring the level from before the forced silence"
            )
        )
    }

    /// No snapshot, built-in reads silent, and it IS a member: a history that
    /// never produced one (feature enabled while already at 0, defaults
    /// cleared, an older build). Coming back quiet is recoverable; coming back
    /// silent with no visible cause is the bug.
    func testRestoreFallsBackToTheFloorWhenSilentWithNoSnapshot() {
        XCTAssertEqual(
            AutoConnectPlan.restore(
                memberUIDs: [builtIn, monitor],
                builtInUID: builtIn,
                snapshot: nil,
                currentScalar: 0.0
            ),
            .write(
                scalar: AutoConnectPlan.recoveryScalar,
                clearSnapshot: false,
                reason: "built-in found silent with no snapshot; restoring the floor"
            )
        )
    }

    /// A stored snapshot that is itself silent would restore nothing. Treat it
    /// like the no-snapshot case rather than writing 0 back.
    func testRestoreUsesTheFloorWhenTheStoredSnapshotIsItselfSilent() {
        let held = AutoConnectBuiltInVolumeSnapshot(
            uid: builtIn, scalar: 0.0, capturedAt: Date()
        )
        XCTAssertEqual(
            AutoConnectPlan.restore(
                memberUIDs: [builtIn, monitor],
                builtInUID: builtIn,
                snapshot: held,
                currentScalar: 0.0
            ),
            .write(
                scalar: AutoConnectPlan.recoveryScalar,
                clearSnapshot: true,
                reason: "stored snapshot was itself silent; using the floor"
            )
        )
    }

    /// The rule does not drive the built-in this episode, so its level is the
    /// user's business — and the snapshot is kept for an activation that does.
    func testRestoreLeavesANonMemberBuiltInAlone() {
        let held = AutoConnectBuiltInVolumeSnapshot(
            uid: builtIn, scalar: 0.62, capturedAt: Date()
        )
        XCTAssertEqual(
            AutoConnectPlan.restore(
                memberUIDs: [monitor],
                builtInUID: builtIn,
                snapshot: held,
                currentScalar: 0.0
            ),
            .none(reason: "built-in is not a rule member")
        )
    }

    /// An audible built-in with no snapshot is simply the normal case; do not
    /// move a level the user is happy with.
    func testRestoreLeavesAnAudibleBuiltInAlone() {
        XCTAssertEqual(
            AutoConnectPlan.restore(
                memberUIDs: [builtIn, monitor],
                builtInUID: builtIn,
                snapshot: nil,
                currentScalar: 0.55
            ),
            .none(reason: "built-in is already audible")
        )
    }

    func testRestoreDoesNothingWithoutABuiltInOrAReadableLevel() {
        XCTAssertEqual(
            AutoConnectPlan.restore(
                memberUIDs: [builtIn], builtInUID: nil, snapshot: nil, currentScalar: 0.5
            ),
            .none(reason: "no built-in output found")
        )
        XCTAssertEqual(
            AutoConnectPlan.restore(
                memberUIDs: [builtIn], builtInUID: builtIn, snapshot: nil, currentScalar: nil
            ),
            .none(reason: "level unreadable")
        )
    }

    /// A snapshot taken from the speakers must never be written into the
    /// headphones, so a UID mismatch falls through to the read-the-hardware
    /// path rather than trusting the stored scalar.
    func testRestoreIgnoresASnapshotForADifferentDevice() {
        let held = AutoConnectBuiltInVolumeSnapshot(
            uid: "BuiltInHeadphoneDevice", scalar: 0.9, capturedAt: Date()
        )
        XCTAssertEqual(
            AutoConnectPlan.restore(
                memberUIDs: [builtIn],
                builtInUID: builtIn,
                snapshot: held,
                currentScalar: 0.55
            ),
            .none(reason: "built-in is already audible")
        )
    }

    // MARK: - Snapshot persistence

    func testSnapshotRoundTripsThroughJSON() {
        let original = AutoConnectBuiltInVolumeSnapshot(
            uid: builtIn,
            scalar: 0.62,
            capturedAt: Date(timeIntervalSince1970: 1_756_000_000)
        )
        let decoded = AutoConnectBuiltInVolumeStore
            .decode(AutoConnectBuiltInVolumeStore.encode(original))
        XCTAssertEqual(decoded, original)
    }

    /// External data: a scalar that would go straight into
    /// `kAudioDevicePropertyVolumeScalar` is rejected rather than clamped, so
    /// the "found silent → restore a floor" path takes over instead.
    func testMalformedSnapshotsAreRejected() {
        XCTAssertNil(AutoConnectBuiltInVolumeStore.decode(nil))
        XCTAssertNil(AutoConnectBuiltInVolumeStore.decode(Data("not json".utf8)))
        XCTAssertNil(
            AutoConnectBuiltInVolumeStore.decode(
                Data(#"{"uid":"","scalar":0.5,"capturedAt":0}"#.utf8)
            )
        )
        XCTAssertNil(
            AutoConnectBuiltInVolumeStore.decode(
                Data(#"{"uid":"BuiltInSpeakerDevice","scalar":9.5,"capturedAt":0}"#.utf8)
            )
        )
        XCTAssertNil(
            AutoConnectBuiltInVolumeStore.decode(
                Data(#"{"uid":"BuiltInSpeakerDevice","scalar":-1,"capturedAt":0}"#.utf8)
            )
        )
    }

    func testSnapshotSurvivesAUserDefaultsRoundTripAndCanBeCleared() throws {
        let suite = "syncast.tests.autoconnect.builtinvolume"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertNil(AutoConnectBuiltInVolumeStore.load(defaults: defaults))
        let snapshot = AutoConnectBuiltInVolumeSnapshot(
            uid: builtIn, scalar: 0.42, capturedAt: Date(timeIntervalSince1970: 1_756_000_000)
        )
        AutoConnectBuiltInVolumeStore.save(snapshot, defaults: defaults)
        XCTAssertEqual(AutoConnectBuiltInVolumeStore.load(defaults: defaults), snapshot)
        AutoConnectBuiltInVolumeStore.clear(defaults: defaults)
        XCTAssertNil(AutoConnectBuiltInVolumeStore.load(defaults: defaults))
    }

    /// The full unplug → replug cycle the fix exists for, driven through the
    /// same two decisions the app calls in that order.
    func testForcedSilenceIsUndoneOnTheNextActivation() {
        var stored: AutoConnectBuiltInVolumeSnapshot?
        var hardware: Float = 0.62

        // Unplug: remember, then force 0 %.
        if case .capture(let scalar) = AutoConnectPlan.capture(
            existing: stored, uid: builtIn, currentScalar: hardware
        ) {
            stored = AutoConnectBuiltInVolumeSnapshot(
                uid: builtIn, scalar: scalar, capturedAt: Date()
            )
        }
        hardware = AutoConnect.hardwareScalar(forPercent: 0)
        XCTAssertEqual(hardware, 0)

        // Replug: restore before the members go on.
        guard case .write(let scalar, let clear, _) = AutoConnectPlan.restore(
            memberUIDs: [builtIn, monitor],
            builtInUID: builtIn,
            snapshot: stored,
            currentScalar: hardware
        ) else { return XCTFail("expected a restore write") }
        hardware = scalar
        if clear { stored = nil }

        XCTAssertEqual(hardware, 0.62)
        XCTAssertNil(stored, "the snapshot is spent once it has been handed back")

        // And a second replug does not move the level again.
        XCTAssertEqual(
            AutoConnectPlan.restore(
                memberUIDs: [builtIn, monitor],
                builtInUID: builtIn,
                snapshot: stored,
                currentScalar: hardware
            ),
            .none(reason: "built-in is already audible")
        )
    }
}
