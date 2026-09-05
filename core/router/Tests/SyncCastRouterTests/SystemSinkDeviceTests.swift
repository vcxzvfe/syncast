import XCTest
import CoreAudio
@testable import SyncCastRouter

/// Hermetic tests for the system-sink path's decision logic.
///
/// Deliberately NOT covered: actually moving the macOS default output and
/// starting a Process Tap. Both have global side effects on the developer's
/// machine (they would yank the default output mid-test-run), so they stay on
/// the manual hardware checklist in
/// `docs/requirements_2026-09-05-system-sink.md`. What IS covered is every
/// branch that decides which sink to use and whether the user gets their
/// default output back — the parts where a mistake leaves the machine silent.
final class SystemSinkDeviceTests: XCTestCase {

    // MARK: - Sink detection / preference order

    func testPrefersOwnDriverWhenBothInstalled() {
        let picked = SystemSinkDevice.preferredSink(installedUIDs: [
            SystemSinkDevice.blackHole2chUID,
            SystemSinkDevice.syncCastDriverUID,
        ])
        XCTAssertEqual(picked?.uid, SystemSinkDevice.syncCastDriverUID)
    }

    func testFallsBackToBlackHoleWhenOnlyItIsInstalled() {
        let picked = SystemSinkDevice.preferredSink(installedUIDs: [
            SystemSinkDevice.blackHole2chUID
        ])
        XCTAssertEqual(picked?.uid, SystemSinkDevice.blackHole2chUID)
    }

    func testNoSinkWhenNeitherInstalled() {
        XCTAssertNil(SystemSinkDevice.preferredSink(installedUIDs: []))
        XCTAssertNil(SystemSinkDevice.preferredSink(
            installedUIDs: ["SomeOtherVirtualDevice_UID"]
        ))
    }

    /// Preference must come from the declared rank, not from set iteration
    /// order (which is unordered and would make this flaky in production).
    func testPreferenceIsRankOrderedNotIterationOrdered() {
        let reversed = SystemSinkDevice.candidates.reversed().map { $0 }
        let picked = SystemSinkDevice.preferredSink(
            installedUIDs: Set(SystemSinkDevice.candidates.map(\.uid)),
            candidates: reversed
        )
        XCTAssertEqual(picked?.uid, SystemSinkDevice.syncCastDriverUID)
    }

    func testSinkUIDsAreRecognised() {
        XCTAssertTrue(SystemSinkDevice.isSinkUID(SystemSinkDevice.syncCastDriverUID))
        XCTAssertTrue(SystemSinkDevice.isSinkUID(SystemSinkDevice.blackHole2chUID))
        XCTAssertFalse(SystemSinkDevice.isSinkUID("BuiltInSpeakerDevice"))
    }

    /// The sink namespace must not collide with the aggregate flavours: the
    /// route filters and orphan sweeps key on these and apply different
    /// protections.
    func testSinkUIDsAreNotAggregatePrefixes() {
        for candidate in SystemSinkDevice.candidates {
            XCTAssertFalse(candidate.uid.hasPrefix(DirectStereoOutput.uidPrefix))
            XCTAssertFalse(candidate.uid.hasPrefix(WholeHomeSinkOutput.uidPrefix))
            XCTAssertFalse(candidate.uid.hasPrefix(AggregateDevice.uidPrefix))
        }
    }

    /// The whole-home sink wraps BlackHole; the stereo sink may BE BlackHole.
    /// They must still be distinguishable, or teardown would restore the
    /// default output to a destroyed device.
    func testWholeHomeSinkWrapperIsNotAStereoSink() {
        XCTAssertFalse(SystemSinkDevice.isSinkUID(
            WholeHomeSinkOutput.uidPrefix + "1234.abcd"
        ))
    }

    // MARK: - Default-output restore state machine

    func testRestoresPreviousWhenSinkIsStillTheDefault() {
        XCTAssertEqual(
            SystemSinkDevice.restoreAction(
                currentID: 42, currentUID: "SyncCastAudio_UID",
                activeID: 42, activeUID: "SyncCastAudio_UID",
                hasPrevious: true
            ),
            .restorePrevious
        )
    }

    /// AudioObjectIDs are transient; a UID match is authoritative even when
    /// the id moved (replug while running).
    func testMatchesByUIDWhenTheDeviceIDChanged() {
        XCTAssertEqual(
            SystemSinkDevice.restoreAction(
                currentID: 99, currentUID: "SyncCastAudio_UID",
                activeID: 42, activeUID: "SyncCastAudio_UID",
                hasPrevious: true
            ),
            .restorePrevious
        )
    }

    /// The "don't fight the user" policy: they picked another output in the
    /// Sound menu, so teardown leaves it alone.
    func testUserMovedDefaultIsNotRestored() {
        XCTAssertEqual(
            SystemSinkDevice.restoreAction(
                currentID: 7, currentUID: "BuiltInSpeakerDevice",
                activeID: 42, activeUID: "SyncCastAudio_UID",
                hasPrevious: true
            ),
            .userMoved
        )
    }

    /// An unreadable default cannot prove anything, so we must not write over
    /// it — reported as a failed stop, which blocks quit and tells the user.
    func testUnreadableCurrentDefaultIsItsOwnBranch() {
        XCTAssertEqual(
            SystemSinkDevice.restoreAction(
                currentID: nil, currentUID: nil,
                activeID: 42, activeUID: "SyncCastAudio_UID",
                hasPrevious: true
            ),
            .unknownCurrent
        )
    }

    /// No usable snapshot (e.g. the previous default was itself one of ours)
    /// still has to move the default OFF the sink, or the machine stays mute.
    func testMissingPreviousFallsBackRatherThanLeavingTheSink() {
        XCTAssertEqual(
            SystemSinkDevice.restoreAction(
                currentID: 42, currentUID: "SyncCastAudio_UID",
                activeID: 42, activeUID: "SyncCastAudio_UID",
                hasPrevious: false
            ),
            .fallback
        )
    }

    /// A device whose UID could not be read still matches on the id, so a
    /// UID-read failure cannot turn a live sink into "the user moved it".
    func testUnreadableUIDStillMatchesOnDeviceID() {
        XCTAssertEqual(
            SystemSinkDevice.restoreAction(
                currentID: 42, currentUID: nil,
                activeID: 42, activeUID: "SyncCastAudio_UID",
                hasPrevious: true
            ),
            .restorePrevious
        )
    }

    // MARK: - Ownership claim (crash-recovery gate)
    //
    // BlackHole is a SHARED device. Someone may deliberately have it selected
    // as their default output for a recording setup, and SyncCast launching
    // must never disturb that. The claim is the only evidence that lets the
    // crash sweep act.

    /// A throwaway suite per test, torn down in `tearDown` so the developer's
    /// real preferences never accumulate test domains.
    private var temporarySuites: [String] = []

    override func tearDown() {
        for suite in temporarySuites {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            UserDefaults.standard.removeSuite(named: suite)
        }
        temporarySuites = []
        super.tearDown()
    }

    private func makeDefaults(_ name: String) -> UserDefaults {
        let suite = "io.syncast.tests.\(name).\(UUID().uuidString)"
        temporarySuites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testNoClaimMeansNoSweep() {
        let defaults = makeDefaults("noclaim")
        XCTAssertNil(SystemSinkDevice.staleOwnershipClaimUID(defaults: defaults))
    }

    /// The exact scenario Codex flagged: the user picked BlackHole themselves,
    /// SyncCast has never run. Nothing may move.
    func testUserSelectedSinkWithoutAClaimIsNotStale() {
        let defaults = makeDefaults("userselected")
        XCTAssertNil(SystemSinkDevice.staleOwnershipClaimUID(
            defaults: defaults, isProcessAlive: { _ in false }
        ))
    }

    func testClaimFromADeadProcessIsStale() {
        let defaults = makeDefaults("dead")
        defaults.set(
            ["pid": 424242, "uid": SystemSinkDevice.blackHole2chUID],
            forKey: SystemSinkDevice.claimDefaultsKey
        )
        XCTAssertEqual(
            SystemSinkDevice.staleOwnershipClaimUID(
                defaults: defaults, isProcessAlive: { _ in false }
            ),
            SystemSinkDevice.blackHole2chUID
        )
    }

    /// A second SyncCast instance is alive and owns the sink — leave it alone.
    func testClaimFromALiveProcessIsNotStale() {
        let defaults = makeDefaults("live")
        defaults.set(
            ["pid": 424242, "uid": SystemSinkDevice.syncCastDriverUID],
            forKey: SystemSinkDevice.claimDefaultsKey
        )
        XCTAssertNil(SystemSinkDevice.staleOwnershipClaimUID(
            defaults: defaults, isProcessAlive: { _ in true }
        ))
    }

    func testOwnProcessClaimIsNotStale() {
        let defaults = makeDefaults("self")
        SystemSinkDevice.writeOwnershipClaim(
            uid: SystemSinkDevice.blackHole2chUID, defaults: defaults
        )
        XCTAssertNil(SystemSinkDevice.staleOwnershipClaimUID(
            defaults: defaults, isProcessAlive: { _ in false }
        ))
    }

    /// UserDefaults is external input: a malformed or hand-edited entry must
    /// read as "no claim", never as licence to move the default output.
    func testMalformedClaimsAreIgnored() {
        let cases: [Any] = [
            "not a dictionary",
            ["pid": "not an int", "uid": SystemSinkDevice.blackHole2chUID],
            ["pid": 424242],
            ["uid": SystemSinkDevice.blackHole2chUID],
            ["pid": 0, "uid": SystemSinkDevice.blackHole2chUID],
            ["pid": 424242, "uid": "SomeoneElsesDevice_UID"],
        ]
        for (index, value) in cases.enumerated() {
            let defaults = makeDefaults("malformed\(index)")
            defaults.set(value, forKey: SystemSinkDevice.claimDefaultsKey)
            XCTAssertNil(
                SystemSinkDevice.staleOwnershipClaimUID(
                    defaults: defaults, isProcessAlive: { _ in false }
                ),
                "case \(index)"
            )
        }
    }

    func testClearingTheClaimRemovesIt() {
        let defaults = makeDefaults("clear")
        defaults.set(
            ["pid": 424242, "uid": SystemSinkDevice.blackHole2chUID],
            forKey: SystemSinkDevice.claimDefaultsKey
        )
        SystemSinkDevice.clearOwnershipClaim(defaults: defaults)
        XCTAssertNil(SystemSinkDevice.staleOwnershipClaimUID(
            defaults: defaults, isProcessAlive: { _ in false }
        ))
    }

    // MARK: - Sample rate contract

    func testPipelineSampleRateIs48k() {
        // TapCapture refuses any other tap format rather than resampling, so
        // the sink is pinned to this rate for the duration of the path.
        XCTAssertEqual(SystemSinkDevice.requiredSampleRate, 48_000)
    }
}
