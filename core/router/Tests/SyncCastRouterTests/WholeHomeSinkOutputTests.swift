import XCTest
import CoreAudio
@testable import SyncCastRouter

/// Hermetic tests for `WholeHomeSinkOutput`'s decision logic.
///
/// Deliberately NOT covered here: creating/destroying the real aggregate and
/// moving the macOS default output. Those have global side effects on the
/// developer's machine (they would yank the default output mid-test-run) and
/// need BlackHole installed, so they stay in the manual hardware checklist.
/// What IS covered is every branch that decides whether we may destroy a
/// device or trust a UID — the parts where a mistake leaves the user with no
/// audio output at all.
final class WholeHomeSinkOutputTests: XCTestCase {

    // MARK: - UID namespace

    /// The three SyncCast aggregate flavours must not share a namespace: the
    /// sweeps apply different protections, so a prefix collision would let one
    /// sweep destroy another's live device.
    func testUIDPrefixIsDistinctFromTheOtherAggregateNamespaces() {
        let prefixes = [
            WholeHomeSinkOutput.uidPrefix,
            DirectStereoOutput.uidPrefix,
            AggregateDevice.uidPrefix,
        ]
        XCTAssertEqual(Set(prefixes).count, 3, "prefixes must be distinct")
        for other in [DirectStereoOutput.uidPrefix, AggregateDevice.uidPrefix] {
            XCTAssertFalse(
                WholeHomeSinkOutput.uidPrefix.hasPrefix(other),
                "\(WholeHomeSinkOutput.uidPrefix) must not be nested under \(other)"
            )
            XCTAssertFalse(
                other.hasPrefix(WholeHomeSinkOutput.uidPrefix),
                "\(other) must not be nested under \(WholeHomeSinkOutput.uidPrefix)"
            )
        }
    }

    func testMakeUIDRoundTripsThroughProcessID() {
        let uid = WholeHomeSinkOutput.makeUID(pid: 4321, uuid: UUID().uuidString)
        XCTAssertTrue(uid.hasPrefix(WholeHomeSinkOutput.uidPrefix))
        XCTAssertEqual(WholeHomeSinkOutput.processID(from: uid), 4321)
    }

    func testProcessIDRejectsForeignAndMalformedUIDs() {
        let uuid = UUID().uuidString
        XCTAssertNil(
            WholeHomeSinkOutput.processID(from: "\(DirectStereoOutput.uidPrefix)77.\(uuid)"),
            "another namespace's UID must not be parsed as ours"
        )
        XCTAssertNil(WholeHomeSinkOutput.processID(from: "BlackHole2ch_UID"))
        XCTAssertNil(
            WholeHomeSinkOutput.processID(from: "\(WholeHomeSinkOutput.uidPrefix)notapid.\(uuid)")
        )
        XCTAssertNil(
            WholeHomeSinkOutput.processID(from: "\(WholeHomeSinkOutput.uidPrefix)0.\(uuid)"),
            "pid 0 is not a real owner"
        )
        XCTAssertNil(
            WholeHomeSinkOutput.processID(from: "\(WholeHomeSinkOutput.uidPrefix)-9.\(uuid)")
        )
    }

    // MARK: - Silent-sink preference order

    /// The point of the whole change: once SyncCast's own driver is installed,
    /// whole-home wraps THAT and BlackHole can be uninstalled.
    func testPrefersSyncCastDriverWhenBothAreInstalled() {
        XCTAssertEqual(
            WholeHomeSinkOutput.preferredSinkUID(installedUIDs: [
                SystemSinkDevice.blackHole2chUID,
                SystemSinkDevice.syncCastDriverUID,
            ]),
            SystemSinkDevice.syncCastDriverUID
        )
    }

    func testUsesSyncCastDriverWhenItIsTheOnlySinkInstalled() {
        XCTAssertEqual(
            WholeHomeSinkOutput.preferredSinkUID(
                installedUIDs: [SystemSinkDevice.syncCastDriverUID]
            ),
            SystemSinkDevice.syncCastDriverUID
        )
    }

    /// The fallback has to keep working: machines that never ran the
    /// sudo-requiring driver install still have BlackHole and nothing else.
    func testFallsBackToBlackHoleWhenTheDriverIsAbsent() {
        XCTAssertEqual(
            WholeHomeSinkOutput.preferredSinkUID(
                installedUIDs: [SystemSinkDevice.blackHole2chUID]
            ),
            SystemSinkDevice.blackHole2chUID
        )
    }

    /// The error path. `resolveSilentSinkUID` still has a name-based scan
    /// behind this decision, but with no candidate installed and no
    /// BlackHole-shaped device on the machine it must throw rather than let
    /// whole-home come up with the real speakers as default output — the
    /// silent double-playback failure this error exists to prevent.
    func testNoPreferenceWhenNoKnownSinkIsInstalled() {
        XCTAssertNil(WholeHomeSinkOutput.preferredSinkUID(installedUIDs: []))
        XCTAssertNil(
            WholeHomeSinkOutput.preferredSinkUID(
                installedUIDs: ["ZoomAudioDevice", "BuiltInSpeakerDevice"]
            ),
            "an unrelated virtual device is not a sink we know is silent"
        )
    }

    /// Whole-home and the stereo sink path must never disagree about which
    /// device is preferred: one list, one rule.
    func testCandidateListIsSharedWithTheStereoSinkPath() {
        XCTAssertEqual(
            WholeHomeSinkOutput.sinkCandidates.map(\.uid),
            SystemSinkDevice.candidates.map(\.uid)
        )
        XCTAssertEqual(
            WholeHomeSinkOutput.sinkCandidates.first?.uid,
            SystemSinkDevice.syncCastDriverUID,
            "SyncCast's own driver must rank first in both paths"
        )
    }

    /// The error message is the only instruction the user gets when nothing is
    /// installed, so it has to name BOTH options — naming only BlackHole is
    /// what this change exists to undo.
    func testNoSilentSinkErrorNamesBothInstallOptions() {
        let text = String(
            describing: WholeHomeSinkOutput.WholeHomeSinkError.noSilentSinkInstalled
        )
        XCTAssertTrue(text.contains("SyncCast"), "must offer our own driver")
        XCTAssertTrue(text.contains("BlackHole 2ch"), "must still offer the fallback")
        XCTAssertTrue(
            text.contains("install-driver.sh") || text.contains("安装 SyncCast 音频驱动"),
            "must say HOW to install the driver"
        )
    }

    // MARK: - BlackHole fallback matching

    func testMatchesBlackHoleAcceptsStereoLoopbackByName() {
        XCTAssertTrue(
            WholeHomeSinkOutput.matchesBlackHole(name: "BlackHole 2ch", outputChannels: 2)
        )
        XCTAssertTrue(
            WholeHomeSinkOutput.matchesBlackHole(name: "blackhole 2ch", outputChannels: 2),
            "match must be case-insensitive"
        )
    }

    func testMatchesBlackHoleRejectsWrongChannelCountAndOtherDevices() {
        XCTAssertFalse(
            WholeHomeSinkOutput.matchesBlackHole(name: "BlackHole 16ch", outputChannels: 16),
            "the whole pipeline is stereo; a 16ch loopback is not a drop-in"
        )
        XCTAssertFalse(
            WholeHomeSinkOutput.matchesBlackHole(name: "BlackHole 2ch", outputChannels: 0),
            "an input-only device has no output channels to wrap"
        )
        XCTAssertFalse(
            WholeHomeSinkOutput.matchesBlackHole(name: "MacBook Pro扬声器", outputChannels: 2)
        )
        XCTAssertFalse(WholeHomeSinkOutput.matchesBlackHole(name: nil, outputChannels: 2))
    }

    /// The sink itself is a 2-channel device whose name is NOT "BlackHole", so
    /// the fallback scan can never pick a previous sink as its own subdevice.
    func testMatchesBlackHoleRejectsOurOwnSinkName() {
        XCTAssertFalse(
            WholeHomeSinkOutput.matchesBlackHole(
                name: WholeHomeSinkOutput.displayName,
                outputChannels: 2
            )
        )
    }

    // MARK: - Orphan sweep protections

    func testSweepSkipsDevicesOutsideOurNamespace() {
        let decision = WholeHomeSinkOutput.sweepDecision(
            uid: "BuiltInSpeakerDevice",
            myPID: 100,
            isCurrentDefault: false,
            ownerOwnsLiveSyncCast: { _ in XCTFail("must not probe foreign devices"); return false },
            moveDefaultAway: { XCTFail("must not move the default"); return false }
        )
        XCTAssertEqual(decision, .skipForeign)
    }

    func testSweepSkipsNilUID() {
        let decision = WholeHomeSinkOutput.sweepDecision(
            uid: nil,
            myPID: 100,
            isCurrentDefault: false,
            ownerOwnsLiveSyncCast: { _ in false },
            moveDefaultAway: { false }
        )
        XCTAssertEqual(decision, .skipForeign)
    }

    /// Protection 1: our OWN sink is owned by `start()`/`stop()`/`deinit`.
    /// Sweeping it would destroy the live default output mid-session.
    func testSweepSkipsOurOwnProcess() {
        let uid = WholeHomeSinkOutput.makeUID(pid: 100, uuid: UUID().uuidString)
        let decision = WholeHomeSinkOutput.sweepDecision(
            uid: uid,
            myPID: 100,
            isCurrentDefault: true,
            ownerOwnsLiveSyncCast: { _ in XCTFail("own PID short-circuits first"); return false },
            moveDefaultAway: { XCTFail("must not move our own default"); return false }
        )
        XCTAssertEqual(decision, .skipOwnProcess)
    }

    /// Protection 2: a second SyncCast instance is alive and using it.
    func testSweepSkipsLiveSyncCastOwner() {
        let uid = WholeHomeSinkOutput.makeUID(pid: 555, uuid: UUID().uuidString)
        var probed: [pid_t] = []
        let decision = WholeHomeSinkOutput.sweepDecision(
            uid: uid,
            myPID: 100,
            isCurrentDefault: false,
            ownerOwnsLiveSyncCast: { probed.append($0); return true },
            moveDefaultAway: { XCTFail("live owner short-circuits first"); return false }
        )
        XCTAssertEqual(decision, .skipLiveOwner)
        XCTAssertEqual(probed, [555], "the owner PID must come from the UID")
    }

    /// Protection 3: it is the live system default and we could not point the
    /// system at a real speaker first. Destroying it would leave macOS mute.
    func testSweepRefusesToDestroyAnUnmovableDefault() {
        let uid = WholeHomeSinkOutput.makeUID(pid: 555, uuid: UUID().uuidString)
        let decision = WholeHomeSinkOutput.sweepDecision(
            uid: uid,
            myPID: 100,
            isCurrentDefault: true,
            ownerOwnsLiveSyncCast: { _ in false },
            moveDefaultAway: { false }
        )
        XCTAssertEqual(decision, .skipUnmovableDefault)
    }

    func testSweepDestroysAnOrphanAfterMovingTheDefaultAway() {
        let uid = WholeHomeSinkOutput.makeUID(pid: 555, uuid: UUID().uuidString)
        var moved = 0
        let decision = WholeHomeSinkOutput.sweepDecision(
            uid: uid,
            myPID: 100,
            isCurrentDefault: true,
            ownerOwnsLiveSyncCast: { _ in false },
            moveDefaultAway: { moved += 1; return true }
        )
        XCTAssertEqual(decision, .destroy)
        XCTAssertEqual(moved, 1)
    }

    func testSweepDestroysAnOrphanThatIsNotTheDefaultWithoutTouchingTheDefault() {
        let uid = WholeHomeSinkOutput.makeUID(pid: 555, uuid: UUID().uuidString)
        let decision = WholeHomeSinkOutput.sweepDecision(
            uid: uid,
            myPID: 100,
            isCurrentDefault: false,
            ownerOwnsLiveSyncCast: { _ in false },
            moveDefaultAway: { XCTFail("no default move needed"); return false }
        )
        XCTAssertEqual(decision, .destroy)
    }

    /// A UID inside our namespace that carries no parsable PID still gets
    /// destroyed (it cannot belong to a live owner we can identify), but only
    /// after the default-output protection has had its say.
    func testSweepStillProtectsTheDefaultForUnparsablePID() {
        let decision = WholeHomeSinkOutput.sweepDecision(
            uid: "\(WholeHomeSinkOutput.uidPrefix)garbage",
            myPID: 100,
            isCurrentDefault: true,
            ownerOwnsLiveSyncCast: { _ in XCTFail("no PID to probe"); return false },
            moveDefaultAway: { false }
        )
        XCTAssertEqual(decision, .skipUnmovableDefault)
    }

    // MARK: - Previous-default restorability

    func testRestorableDefaultAcceptsOrdinaryDevices() {
        XCTAssertTrue(
            WholeHomeSinkOutput.isRestorableDefault(
                uid: "BuiltInSpeakerDevice", name: "MacBook Pro扬声器"
            )
        )
        XCTAssertTrue(
            WholeHomeSinkOutput.isRestorableDefault(uid: nil, name: nil),
            "an unreadable UID/name falls back to the raw AudioObjectID snapshot"
        )
    }

    /// A user-created multi-output device is a legitimate default. Refusing it
    /// would silently move the user to built-in speakers on every quit.
    func testRestorableDefaultAcceptsUserCreatedAggregates() {
        XCTAssertTrue(
            WholeHomeSinkOutput.isRestorableDefault(
                uid: "~:AMS2_StackedOutput:0", name: "多输出设备"
            )
        )
    }

    /// Remembering any SyncCast-owned device as "the user's previous default"
    /// means restoring the system to a device that is destroyed with us —
    /// which presents as total silence with no error anywhere.
    func testRestorableDefaultRejectsEverySyncCastOwnedDevice() {
        let uuid = UUID().uuidString
        for prefix in [
            WholeHomeSinkOutput.uidPrefix,
            DirectStereoOutput.uidPrefix,
            AggregateDevice.uidPrefix,
        ] {
            XCTAssertFalse(
                WholeHomeSinkOutput.isRestorableDefault(
                    uid: "\(prefix)7.\(uuid)", name: WholeHomeSinkOutput.displayName
                ),
                "\(prefix) must never be a restore target"
            )
        }
    }

    /// The upgrade case: existing users already have "BlackHole 2ch" selected
    /// by hand, so that is what the first run with this feature snapshots.
    /// Handing it back on quit would leave their Mac silent for every app.
    func testRestorableDefaultRejectsRawBlackHole() {
        XCTAssertFalse(
            WholeHomeSinkOutput.isRestorableDefault(
                uid: "BlackHole2ch_UID", name: "BlackHole 2ch"
            )
        )
        XCTAssertFalse(
            WholeHomeSinkOutput.isRestorableDefault(
                uid: "BlackHole16ch_UID", name: "BlackHole 16ch"
            )
        )
    }

    /// Same rule for our own driver, and it can ONLY be caught by UID: the
    /// device is named "SyncCast", which the BlackHole name needle does not
    /// match. Restoring it as "the user's previous default" would leave every
    /// other app rendering into a silent device with nothing to explain it.
    func testRestorableDefaultRejectsRawSyncCastDriver() {
        XCTAssertFalse(
            WholeHomeSinkOutput.isRestorableDefault(
                uid: SystemSinkDevice.syncCastDriverUID,
                name: SystemSinkDevice.syncCastDriverName
            )
        )
        XCTAssertFalse(
            SystemSinkDevice.syncCastDriverName.lowercased()
                .contains(WholeHomeSinkOutput.blackHoleNameNeedle),
            "guards the reason this needs its own UID check"
        )
    }

    /// The rejection must not over-reach: a user-created multi-output device
    /// (Audio MIDI Setup's 多输出设备) is a legitimate destination.
    func testRestorableDefaultStillAcceptsOrdinaryAndUserAggregateOutputs() {
        XCTAssertTrue(
            WholeHomeSinkOutput.isRestorableDefault(
                uid: "BuiltInSpeakerDevice", name: "MacBook Pro扬声器"
            )
        )
        XCTAssertTrue(
            WholeHomeSinkOutput.isRestorableDefault(
                uid: "~:AMS2_StackedOutput:0", name: "多输出设备"
            )
        )
    }

    // MARK: - Naming contract

    /// The user-visible name is the whole point of the feature; a silent
    /// change here would put "BlackHole 2ch" back in System Settings.
    func testDisplayNameIsTheUserFacingWholeHomeLabel() {
        XCTAssertEqual(WholeHomeSinkOutput.displayName, "AirPlay 全屋")
        XCTAssertFalse(
            WholeHomeSinkOutput.displayName.lowercased()
                .contains(WholeHomeSinkOutput.blackHoleNameNeedle),
            "the sink name must not trip the name-based BlackHole route filters"
        )
    }

    /// The sink becomes the macOS default output, so ordinary apps must see a
    /// plain stereo surface — same gate Direct Stereo uses.
    func testSafeChannelGateIsStereo() {
        XCTAssertEqual(WholeHomeSinkOutput.maxSafeOutputChannels, 2)
        XCTAssertEqual(WholeHomeSinkOutput.blackHoleOutputChannelCount, 2)
    }

    // MARK: - Route filters

    /// `DirectStereoOutput.isOrdinaryOutputUID` is what keeps the sink out of
    /// the Direct Stereo target set. It must reject our namespace by prefix
    /// alone, without needing the device to exist.
    func testDirectStereoRejectsTheSinkUIDAsAnOrdinaryOutput() {
        let uid = WholeHomeSinkOutput.makeUID(pid: 42, uuid: UUID().uuidString)
        XCTAssertFalse(DirectStereoOutput.isOrdinaryOutputUID(uid))
    }

    // MARK: - "Is our sink still the default output?"
    //
    // `isSystemDefaultOutput` is the running-time guard against the exact
    // failure the sink exists to prevent: if macOS stops pointing at us
    // mid-session (headphones plugged in, or the user re-picking their real
    // speakers because our aggregate greys out the system volume slider),
    // system audio goes straight to that device AND still flows through the
    // ScreenCaptureKit tap into OwnTone — every track plays twice at two
    // different latencies, with nothing on screen to say so. Only the pure
    // comparison is covered here; reading the live HAL default would depend on
    // whatever is plugged into the developer's machine.

    func testSinkIsTheDefaultWhenTheObjectIDMatches() {
        XCTAssertTrue(
            WholeHomeSinkOutput.isSinkTheDefault(
                currentID: 77, currentUID: nil, activeID: 77, activeUID: "uid-a"
            )
        )
    }

    /// AudioObjectIDs are transient — a replug mints a new one for the same
    /// device — so a UID match is authoritative even when the ids differ.
    func testSinkIsTheDefaultWhenOnlyTheUIDMatches() {
        XCTAssertTrue(
            WholeHomeSinkOutput.isSinkTheDefault(
                currentID: 91, currentUID: "uid-a", activeID: 77, activeUID: "uid-a"
            )
        )
    }

    /// The displacement case: a real speaker is the default while our sink is
    /// still alive. This is what raises the panel banner.
    func testSinkIsNotTheDefaultWhenNeitherIDNorUIDMatch() {
        XCTAssertFalse(
            WholeHomeSinkOutput.isSinkTheDefault(
                currentID: 91, currentUID: "BuiltInSpeakerDevice",
                activeID: 77, activeUID: "uid-a"
            )
        )
    }

    /// An empty `activeUID` (sink not started, or the UID could not be read)
    /// must never match on the UID at all — not even against another device
    /// whose UID also read back empty. Matching there would report an
    /// arbitrary output as "our sink" and, in `stop()`, authorise restoring
    /// the previous default over a device we do not own.
    func testEmptyActiveUIDNeverMatchesOnUID() {
        XCTAssertFalse(
            WholeHomeSinkOutput.isSinkTheDefault(
                currentID: 91, currentUID: "", activeID: 77, activeUID: ""
            )
        )
        XCTAssertFalse(
            WholeHomeSinkOutput.isSinkTheDefault(
                currentID: 91, currentUID: nil, activeID: 77, activeUID: ""
            )
        )
    }

    /// An inactive sink is not "displaced" — there is nothing to displace.
    /// Guards the banner against firing in stereo mode or before start().
    func testInactiveSinkReportsNeitherActiveNorDefault() {
        let sink = WholeHomeSinkOutput()
        XCTAssertFalse(sink.isActive)
        XCTAssertFalse(sink.isSystemDefaultOutput)
        XCTAssertFalse(sink.reassertDefaultOutput())
    }
}
