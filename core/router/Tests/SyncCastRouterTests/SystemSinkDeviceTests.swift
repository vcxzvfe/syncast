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

    // MARK: - Sample rate contract

    func testPipelineSampleRateIs48k() {
        // TapCapture refuses any other tap format rather than resampling, so
        // the sink is pinned to this rate for the duration of the path.
        XCTAssertEqual(SystemSinkDevice.requiredSampleRate, 48_000)
    }
}
