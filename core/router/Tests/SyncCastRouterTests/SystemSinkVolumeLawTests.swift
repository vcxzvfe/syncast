import XCTest
@testable import SyncCastRouter

/// The volume law is the whole user-visible contract of the sink path: what
/// the macOS slider does to each speaker. These tests pin it against the
/// values MEASURED on the reference machine (2026-09-05), so a refactor that
/// changes loudness fails here rather than in the user's ears.
final class SystemSinkVolumeLawTests: XCTestCase {

    private let law = SystemSinkVolumeLaw.appleBuiltInLaw

    // MARK: - The measured curve

    /// `dbprobe` on MacBook Pro扬声器: rangeDb [-63.50, 0.00] and
    /// scalar→dB 0.25→-47.6, 0.50→-31.8, 0.75→-15.9, 1.00→0.0. That is
    /// dB-linear, which is the single assumption everything else rests on.
    func testMatchesMeasuredAppleBuiltInCurve() {
        XCTAssertEqual(law.decibels(forScalar: 0.0), -63.5, accuracy: 0.05)
        XCTAssertEqual(law.decibels(forScalar: 0.25), -47.6, accuracy: 0.05)
        XCTAssertEqual(law.decibels(forScalar: 0.5), -31.8, accuracy: 0.05)
        XCTAssertEqual(law.decibels(forScalar: 0.75), -15.9, accuracy: 0.05)
        XCTAssertEqual(law.decibels(forScalar: 1.0), 0.0, accuracy: 0.001)
    }

    /// BlackHole's own measured law (SHARED_CONTEXT: scalar 0.5 → −32 dB,
    /// range [-64, 0]) is the same curve with a different floor.
    func testBlackHoleFloorReproducesItsMeasuredAttenuation() {
        let blackHole = SystemSinkVolumeLaw.ScalarDecibelLaw(minDb: -64)
        XCTAssertEqual(blackHole.decibels(forScalar: 0.5), -32, accuracy: 0.01)
        // RMS 0.0178 / 0.7067 measured through BlackHole's loopback ≈ −32 dB.
        XCTAssertEqual(
            Double(blackHole.amplitude(forScalar: 0.5)),
            0.0178 / 0.7067,
            accuracy: 0.002
        )
    }

    func testFullScaleIsBitTransparent() {
        XCTAssertEqual(law.amplitude(forScalar: 1.0), 1.0, accuracy: 1e-6)
    }

    /// Scalar 0 must be SILENCE, not −63.5 dB: a system volume of zero that is
    /// still faintly audible reads as a broken control. (This is the one place
    /// the sink law deliberately differs from `VolumeCurve`, whose −30 dB
    /// floor exists to match OwnTone's wire format.)
    func testZeroScalarIsTrueSilence() {
        XCTAssertEqual(law.amplitude(forScalar: 0), 0)
    }

    func testScalarDecibelRoundTrip() {
        for scalar: Float in [0.1, 0.25, 0.4, 0.5, 0.75, 0.9, 1.0] {
            let db = law.decibels(forScalar: scalar)
            XCTAssertEqual(law.scalar(forDecibels: db), scalar, accuracy: 1e-5)
        }
    }

    /// A driver reporting a nonsensical (positive) range must not produce a
    /// divide-by-zero or an inverted curve.
    func testDegenerateRangeIsClamped() {
        let degenerate = SystemSinkVolumeLaw.ScalarDecibelLaw(minDb: 12)
        XCTAssertLessThan(degenerate.minDb, 0)
        XCTAssertEqual(degenerate.amplitude(forScalar: 1), 1, accuracy: 1e-6)
    }

    // MARK: - Master × balance composition

    /// The common case: balance at unity returns the master scalar unchanged,
    /// bit-for-bit, so the hardware backend really is "copy the scalar".
    func testUnityBalanceIsTheMasterScalarExactly() {
        for master: Float in [0, 0.25, 0.5, 1] {
            XCTAssertEqual(
                SystemSinkVolumeLaw.effectiveScalar(
                    masterScalar: master, balance: 1, law: law
                ),
                master
            )
        }
    }

    /// Balance composes in the dB domain: half master (−31.75 dB) plus half
    /// balance (−31.75 dB) is −63.5 dB, the bottom of the curve.
    func testBalanceComposesInDecibels() {
        let effective = SystemSinkVolumeLaw.effectiveScalar(
            masterScalar: 0.5, balance: 0.5, law: law
        )
        XCTAssertEqual(law.decibels(forScalar: effective), -63.5, accuracy: 0.05)
    }

    func testBalanceCannotExceedTheMaster() {
        let effective = SystemSinkVolumeLaw.effectiveScalar(
            masterScalar: 0.4, balance: 0.9, law: law
        )
        XCTAssertLessThan(effective, 0.4)
    }

    func testZeroBalanceOrZeroMasterIsSilent() {
        XCTAssertEqual(
            SystemSinkVolumeLaw.effectiveScalar(masterScalar: 0.8, balance: 0, law: law), 0
        )
        XCTAssertEqual(
            SystemSinkVolumeLaw.effectiveScalar(masterScalar: 0, balance: 0.8, law: law), 0
        )
    }

    // MARK: - Per-backend plans

    /// Hardware devices get the SCALAR, not an amplitude: the target device
    /// applies the same curve, so copying the scalar reproduces native
    /// loudness. Converting here would taper twice.
    func testHardwareBackendCopiesTheScalar() {
        let plan = SystemSinkVolumeLaw.plan(
            masterScalar: 0.25, masterMuted: false, balance: 1,
            deviceMuted: false, backend: .coreAudioHardware, law: law
        )
        XCTAssertEqual(plan.hardwareScalar, 0.25)
        XCTAssertNil(plan.softwareAmplitude)
        XCTAssertNil(plan.ddcPercent)
        XCTAssertFalse(plan.muted)
    }

    /// While muted, the hardware scalar keeps carrying the USER's level: the
    /// device's Mute property does the silencing, and parking the scalar at 0
    /// destroys the level unmute has to restore (the Direct Stereo Codex P1
    /// regression). Degrading to scalar 0 is the applier's job, and only when
    /// the mute write is refused.
    func testMutedHardwarePlanKeepsTheLevel() {
        let plan = SystemSinkVolumeLaw.plan(
            masterScalar: 0.6, masterMuted: true, balance: 1,
            deviceMuted: false, backend: .coreAudioHardware, law: law
        )
        XCTAssertTrue(plan.muted)
        XCTAssertEqual(plan.hardwareScalar, 0.6)
    }

    func testDDCBackendUsesPercentOfScalar() {
        let plan = SystemSinkVolumeLaw.plan(
            masterScalar: 0.37, masterMuted: false, balance: 1,
            deviceMuted: false, backend: .ddc, law: law
        )
        XCTAssertEqual(plan.ddcPercent, 37)
        XCTAssertNil(plan.hardwareScalar)
    }

    /// Software gain is the one backend that MUST convert through the dB law:
    /// the render path multiplies linear amplitude, so feeding it the raw
    /// scalar would make everything far too loud.
    func testSoftwareBackendConvertsThroughTheDecibelLaw() {
        let plan = SystemSinkVolumeLaw.plan(
            masterScalar: 0.5, masterMuted: false, balance: 1,
            deviceMuted: false, backend: .softwareGain, law: law
        )
        XCTAssertEqual(
            plan.softwareAmplitude ?? -1,
            law.amplitude(forScalar: 0.5),
            accuracy: 1e-6
        )
        XCTAssertNotEqual(plan.softwareAmplitude ?? -1, 0.5, accuracy: 0.001)
    }

    func testSoftwareBackendMutesToTrueZero() {
        for (masterMuted, deviceMuted) in [(true, false), (false, true), (true, true)] {
            let plan = SystemSinkVolumeLaw.plan(
                masterScalar: 0.8, masterMuted: masterMuted, balance: 1,
                deviceMuted: deviceMuted, backend: .softwareGain, law: law
            )
            XCTAssertTrue(plan.muted)
            XCTAssertEqual(plan.softwareAmplitude, 0)
        }
    }

    /// A per-device mute must survive the system volume moving, and a system
    /// mute must silence a device that is not muted itself.
    func testMuteIsTheUnionOfSystemAndDevice() {
        XCTAssertFalse(SystemSinkVolumeLaw.plan(
            masterScalar: 1, masterMuted: false, balance: 1,
            deviceMuted: false, backend: .ddc, law: law
        ).muted)
        XCTAssertTrue(SystemSinkVolumeLaw.plan(
            masterScalar: 1, masterMuted: false, balance: 1,
            deviceMuted: true, backend: .ddc, law: law
        ).muted)
    }

    func testEveryBackendIsPlannable() {
        for backend in SystemSinkVolumeLaw.Backend.allCases {
            let plan = SystemSinkVolumeLaw.plan(
                masterScalar: 0.5, masterMuted: false, balance: 0.8,
                deviceMuted: false, backend: backend, law: law
            )
            XCTAssertEqual(plan.backend, backend)
            let payloads = [
                plan.hardwareScalar != nil,
                plan.ddcPercent != nil,
                plan.softwareAmplitude != nil,
            ].filter { $0 }
            XCTAssertEqual(payloads.count, 1, "exactly one payload per backend")
        }
    }
}
