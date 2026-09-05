import XCTest
@testable import SyncCastRouter

/// Which owner whole-home installs as the macOS default output, and how the
/// owner's volume scalar becomes the master gain.
///
/// Both halves are pure by construction — no HAL, no aggregate creation, no
/// default-output writes — because the consequences of getting either wrong
/// are not the kind you want to discover by ear: the wrong owner means a
/// greyed system slider or a Sound menu that reads "BlackHole 2ch", and the
/// wrong mapping means the system volume no longer matches what comes out of
/// the speakers.
final class WholeHomeSinkOwnerTests: XCTestCase {

    private let syncCast = SystemSinkDevice.Candidate(
        uid: SystemSinkDevice.syncCastDriverUID,
        rank: 0,
        displayName: SystemSinkDevice.syncCastDriverName
    )
    private let blackHole = SystemSinkDevice.Candidate(
        uid: SystemSinkDevice.blackHole2chUID,
        rank: 1,
        displayName: SystemSinkDevice.blackHole2chName
    )

    // MARK: - Owner selection

    /// The whole point of the change: with our own driver installed the device
    /// is already named "SyncCast", so it goes in directly and brings its
    /// volume control with it.
    func testSyncCastDriverBecomesTheDefaultOutputDirectly() {
        let selection = WholeHomeSinkSelection.choose(
            resolved: syncCast,
            exposesVolumeControl: { _ in true }
        )
        XCTAssertEqual(selection, .direct(syncCast))
        XCTAssertTrue(selection.drivesSystemVolume)
    }

    /// BlackHole keeps the aggregate wrapper: it cannot be renamed in place,
    /// so the Sound menu would otherwise read "BlackHole 2ch" and look like a
    /// misconfiguration.
    func testBlackHoleStaysWrapped() {
        let selection = WholeHomeSinkSelection.choose(
            resolved: blackHole,
            exposesVolumeControl: { _ in true }
        )
        XCTAssertEqual(selection, .wrapped)
        XCTAssertFalse(selection.drivesSystemVolume)
    }

    func testNoSinkInstalledFallsBackToTheWrapper() {
        let selection = WholeHomeSinkSelection.choose(
            resolved: nil,
            exposesVolumeControl: { _ in true }
        )
        XCTAssertEqual(selection, .wrapped)
    }

    /// A driver build that lost its volume control would hand the user a
    /// greyed slider AND no event tap — i.e. no volume control at all, which
    /// is strictly worse than the wrapper.
    func testDriverWithoutAVolumeControlIsRefusedForTheDirectPath() {
        let selection = WholeHomeSinkSelection.choose(
            resolved: syncCast,
            exposesVolumeControl: { _ in false }
        )
        XCTAssertEqual(selection, .wrapped)
        XCTAssertFalse(selection.drivesSystemVolume)
    }

    /// The volume-control probe hits the HAL, so it must only run for the
    /// candidate that could actually take the direct path.
    func testVolumeControlIsNotProbedForABlackHoleSink() {
        var probed: [String] = []
        _ = WholeHomeSinkSelection.choose(
            resolved: blackHole,
            exposesVolumeControl: { uid in
                probed.append(uid)
                return true
            }
        )
        XCTAssertEqual(probed, [])
    }

    // MARK: - Scalar → master amplitude

    /// The mapping the whole feature rests on: the sink's dB-linear law,
    /// converted to a linear amplitude for the master stage.
    ///
    /// Checked against the law by hand at the quarter points, so a change to
    /// `amplitude(forScalar:)` cannot silently re-taper the system volume.
    func testScalarMapsThroughTheSinkLawToAnAmplitude() {
        let law = SystemSinkVolumeLaw.ScalarDecibelLaw(minDb: -64)
        // dB(s) = -64 * (1 - s); a = 10^(dB/20).
        let expected: [(Float, Float)] = [
            (0.25, pow(10, -48 / 20)),
            (0.50, pow(10, -32 / 20)),
            (0.75, pow(10, -16 / 20)),
        ]
        for (scalar, amplitude) in expected {
            XCTAssertEqual(
                SystemSinkVolumeLaw.wholeHomeMasterAmplitude(
                    scalar: scalar, muted: false, law: law
                ),
                amplitude,
                accuracy: 1e-6,
                "scalar \(scalar)"
            )
        }
    }

    /// Full scale must be bit-transparent: 10^0 is exactly 1, and anything
    /// less costs full-scale samples their transparency for no reason.
    func testFullScaleIsExactlyUnity() {
        XCTAssertEqual(
            SystemSinkVolumeLaw.wholeHomeMasterAmplitude(
                scalar: 1, muted: false, law: SystemSinkVolumeLaw.appleBuiltInLaw
            ),
            1.0
        )
    }

    /// A system volume of zero that is still faintly audible reads as a bug.
    /// macOS's own slider is silent at the bottom; so is ours.
    func testZeroScalarIsRealSilenceNotTheLawsFloor() {
        XCTAssertEqual(
            SystemSinkVolumeLaw.wholeHomeMasterAmplitude(
                scalar: 0, muted: false, law: SystemSinkVolumeLaw.appleBuiltInLaw
            ),
            0
        )
    }

    /// Mute is the one stage in the system that can silence an AirPlay
    /// receiver at all — OwnTone's per-output volume floors at -30 dB — so it
    /// has to be a true zero regardless of where the scalar sits.
    func testMuteIsSilentAtEveryScalar() {
        for scalar: Float in [0, 0.25, 0.5, 1] {
            XCTAssertEqual(
                SystemSinkVolumeLaw.wholeHomeMasterAmplitude(
                    scalar: scalar,
                    muted: true,
                    law: SystemSinkVolumeLaw.appleBuiltInLaw
                ),
                0,
                "scalar \(scalar)"
            )
        }
    }

    /// The regression this mapping exists to prevent: pushing the system
    /// volume through `VolumeCurve` (OwnTone's -30 dB leg curve) would leave
    /// the bottom of the slider far louder than macOS intends, because 64 dB
    /// of travel would have been compressed into 30.
    func testTheSinkLawIsNotVolumeCurvesMinusThirtyDbFloor() {
        let law = SystemSinkVolumeLaw.ScalarDecibelLaw(minDb: -64)
        let sinkHalf = SystemSinkVolumeLaw.wholeHomeMasterAmplitude(
            scalar: 0.5, muted: false, law: law
        )
        let curveHalf = VolumeCurve.masterAmplitude(forPercent: 50)
        XCTAssertLessThan(sinkHalf, curveHalf / 4)
    }

    /// Out-of-range values come from a HAL read, i.e. from outside the app.
    /// They are clamped at the boundary rather than producing a gain above
    /// unity, which would clip.
    func testScalarsOutsideTheUnitRangeAreClamped() {
        let law = SystemSinkVolumeLaw.appleBuiltInLaw
        XCTAssertEqual(
            SystemSinkVolumeLaw.wholeHomeMasterAmplitude(
                scalar: 1.5, muted: false, law: law
            ),
            1.0
        )
        XCTAssertEqual(
            SystemSinkVolumeLaw.wholeHomeMasterAmplitude(
                scalar: -0.2, muted: false, law: law
            ),
            0
        )
    }

    // MARK: - Owner facade

    /// A `.wrapped` owner has no volume control to watch. `systemVolumeUID`
    /// being nil is what tells the app-side coordinator to attach no listener
    /// and the panel to keep its own fader.
    func testWrappedOwnerExposesNoSystemVolumeDevice() {
        let owner = WholeHomeSinkOwner(selection: .wrapped)
        XCTAssertFalse(owner.drivesSystemVolume)
        XCTAssertNil(owner.systemVolumeUID)
        XCTAssertEqual(owner.displayName, WholeHomeSinkOutput.displayName)
        let master = owner.readMaster()
        XCTAssertNil(master.volume)
        XCTAssertNil(master.muted)
    }

    /// An owner that was never started is not "displaced" — there is nothing
    /// to displace. Guards the banner against firing before start().
    func testInactiveOwnerIsNeitherActiveNorDisplaced() {
        for selection in [WholeHomeSinkSelection.wrapped, .direct(syncCast)] {
            let owner = WholeHomeSinkOwner(selection: selection)
            XCTAssertFalse(owner.isActive, selection.label)
            XCTAssertFalse(owner.isSystemDefaultOutput, selection.label)
        }
    }

    /// The direct owner reports the device the Sound menu will show, which is
    /// the name the panel's status line quotes back to the user.
    func testDirectOwnerReportsTheSinkDeviceIdentity() {
        let owner = WholeHomeSinkOwner(selection: .direct(syncCast))
        XCTAssertTrue(owner.drivesSystemVolume)
        XCTAssertEqual(owner.systemVolumeUID, SystemSinkDevice.syncCastDriverUID)
        XCTAssertEqual(owner.displayName, SystemSinkDevice.syncCastDriverName)
    }
}
