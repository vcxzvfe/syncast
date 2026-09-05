import XCTest
import SyncCastRouter
@testable import SyncCastMenuBar

/// Whole-home's native system volume: when the media-key event tap is allowed
/// to exist, and which authority the panel's master slider is a view of.
///
/// Deliberately unit tests. Nothing here installs a default output or touches
/// the HAL — the mapping arithmetic lives in the router package's
/// `WholeHomeSinkOwnerTests`, and "does the volume actually come out of the
/// speakers" is a listening check no test in this tree can make.
@MainActor
final class WholeHomeSystemVolumeTests: XCTestCase {
    private let masterKey = "syncast.masterVolumePercent"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: masterKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: masterKey)
        super.tearDown()
    }

    // MARK: - Event-tap eligibility matrix

    /// The headline of the whole change: with SyncCast's own sink as the
    /// default output, macOS owns the volume keys and the tap must NOT be
    /// armed. Capturing them there would suppress a working HUD in order to
    /// re-implement it.
    func testTapStandsDownWhenTheSinkDrivesTheSystemVolume() {
        XCTAssertFalse(
            SystemVolumeKeyEligibility.wholeHome(
                modeIsWholeHome: true, running: true, sinkDrivesSystemVolume: true
            )
        )
    }

    /// The fallback still needs it: an aggregate exposes no VolumeScalar, so
    /// an uncaptured key raises the "forbidden" HUD and does nothing.
    func testTapSurvivesForTheWrappedAggregateFallback() {
        XCTAssertTrue(
            SystemVolumeKeyEligibility.wholeHome(
                modeIsWholeHome: true, running: true, sinkDrivesSystemVolume: false
            )
        )
    }

    /// Nothing arms the tap while the engine is idle, in either flavour: the
    /// keys belong to whatever the user's real default output is.
    func testTapIsNeverArmedWhileIdle() {
        for driven in [true, false] {
            XCTAssertFalse(
                SystemVolumeKeyEligibility.wholeHome(
                    modeIsWholeHome: true,
                    running: false,
                    sinkDrivesSystemVolume: driven
                ),
                "sinkDrivesSystemVolume=\(driven)"
            )
        }
    }

    func testTapIsNotArmedOutsideWholeHome() {
        XCTAssertFalse(
            SystemVolumeKeyEligibility.wholeHome(
                modeIsWholeHome: false, running: true, sinkDrivesSystemVolume: false
            )
        )
    }

    /// Legacy Direct Stereo is untouched by this round: a public aggregate of
    /// the real speakers is the default output, and nothing else can carry the
    /// keys.
    func testDirectStereoKeepsTheTap() {
        XCTAssertTrue(
            SystemVolumeKeyEligibility.directStereo(
                modeIsStereo: true, pathIsDirect: true, running: true
            )
        )
        // The sink Stereo path is the case the previous round removed it for.
        XCTAssertFalse(
            SystemVolumeKeyEligibility.directStereo(
                modeIsStereo: true, pathIsDirect: false, running: true
            )
        )
        XCTAssertFalse(
            SystemVolumeKeyEligibility.directStereo(
                modeIsStereo: true, pathIsDirect: true, running: false
            )
        )
        XCTAssertFalse(
            SystemVolumeKeyEligibility.directStereo(
                modeIsStereo: false, pathIsDirect: true, running: true
            )
        )
    }

    // MARK: - Master slider authority

    /// Without a sink driving the master, the slider is the panel's own fader,
    /// exactly as before.
    func testSliderShowsThePanelFaderWhenNoSinkDrivesTheMaster() {
        let m = AppModel()
        m.mode = .wholeHome
        m.setMasterVolumePercent(40)
        XCTAssertFalse(m.wholeHomeMasterFollowsSystemVolume)
        XCTAssertEqual(m.masterSliderPercent, 40)
        m.setMasterSliderPercent(65)
        XCTAssertEqual(m.masterVolumePercent, 65)
        XCTAssertEqual(m.masterSliderPercent, 65)
    }

    func testSliderMuteFollowsThePanelFaderWhenNoSinkDrivesTheMaster() {
        let m = AppModel()
        m.mode = .wholeHome
        XCTAssertFalse(m.masterSliderMuted)
        m.toggleMasterSliderMute()
        XCTAssertTrue(m.masterMuted)
        XCTAssertTrue(m.masterSliderMuted)
    }

    /// Reset means "put my own attenuation back to none". Offering it while
    /// the slider is a view of the system volume would mean a button in a
    /// third-party panel that turns the user's Mac up to 100 %.
    func testResetIsOfferedOnlyForThePanelsOwnFader() {
        let m = AppModel()
        m.mode = .wholeHome
        XCTAssertFalse(m.showsMasterVolumeReset, "nothing to reset at full scale")
        m.setMasterVolumePercent(30)
        XCTAssertTrue(m.showsMasterVolumeReset)
        m.systemSink.applyStatusForTesting(
            Self.status(active: true, drivesSystemVolume: true, volume: 0.3)
        )
        XCTAssertTrue(m.wholeHomeMasterFollowsSystemVolume)
        XCTAssertFalse(m.showsMasterVolumeReset)
    }

    /// The slider mirrors the sink's scalar on the same integer grid the panel
    /// already speaks, so 0.25 reads as 25 % rather than as whatever the
    /// panel's own fader was left at.
    func testSliderMirrorsTheSystemVolumeScalar() {
        let m = AppModel()
        m.mode = .wholeHome
        m.setMasterVolumePercent(80)
        for (scalar, percent) in [(Float(0), 0), (0.25, 25), (0.5, 50), (1, 100)] {
            m.systemSink.applyStatusForTesting(
                Self.status(active: true, drivesSystemVolume: true, volume: scalar)
            )
            XCTAssertEqual(m.masterSliderPercent, percent, "scalar \(scalar)")
        }
        // The panel's own fader is remembered underneath, so falling back to
        // the wrapped aggregate does not lose what the user dialled.
        XCTAssertEqual(m.masterVolumePercent, 80)
    }

    func testSliderMirrorsTheSystemMute() {
        let m = AppModel()
        m.mode = .wholeHome
        m.systemSink.applyStatusForTesting(
            Self.status(
                active: true, drivesSystemVolume: true, volume: 0.5, muted: true
            )
        )
        XCTAssertTrue(m.masterSliderMuted)
        XCTAssertFalse(m.masterMuted, "the panel's own mute is a separate flag")
    }

    /// A sink that holds the default output but exposes no volume control (the
    /// wrapped aggregate) must NOT capture the slider — the panel's fader is
    /// the only master there.
    func testAnActiveSinkWithoutAVolumeControlLeavesTheFaderInCharge() {
        let m = AppModel()
        m.mode = .wholeHome
        m.setMasterVolumePercent(45)
        m.systemSink.applyStatusForTesting(
            Self.status(active: true, drivesSystemVolume: false, volume: 1)
        )
        XCTAssertFalse(m.wholeHomeMasterFollowsSystemVolume)
        XCTAssertEqual(m.masterSliderPercent, 45)
    }

    /// Stereo never shows this control, and must never be talked into
    /// mirroring a sink status left over from whole-home.
    func testStereoNeverFollowsTheSystemVolumeHere() {
        let m = AppModel()
        m.mode = .stereo
        m.systemSink.applyStatusForTesting(
            Self.status(active: true, drivesSystemVolume: true, volume: 0.1)
        )
        XCTAssertFalse(m.wholeHomeMasterFollowsSystemVolume)
    }

    // MARK: - Status line

    /// The surprising part of the mode is that the panel's 总音量 now follows
    /// the menu bar, so the line says the level and which device carries it.
    func testStatusLineReportsTheSystemVolumeWhenTheSinkDrivesIt() {
        let m = AppModel()
        m.mode = .wholeHome
        m.systemSink.applyStatusForTesting(
            Self.status(active: true, drivesSystemVolume: true, volume: 0.4)
        )
        let line = m.wholeHomeSinkStatusLine ?? ""
        XCTAssertTrue(line.contains("40%"), line)
        XCTAssertTrue(line.contains(SystemSinkDevice.syncCastDriverName), line)
    }

    func testStatusLineReportsMuteRatherThanZeroPercent() {
        let m = AppModel()
        m.mode = .wholeHome
        m.systemSink.applyStatusForTesting(
            Self.status(
                active: true, drivesSystemVolume: true, volume: 0, muted: true
            )
        )
        XCTAssertTrue((m.wholeHomeSinkStatusLine ?? "").contains("静音"))
    }

    /// On the wrapped fallback the system slider is greyed, which is exactly
    /// the state a user needs told — otherwise they go hunting for a broken
    /// control.
    func testStatusLineSendsTheUserToThePanelFaderOnTheWrappedFallback() {
        let m = AppModel()
        m.mode = .wholeHome
        m.systemSink.applyStatusForTesting(
            Self.status(active: true, drivesSystemVolume: false, volume: 1)
        )
        let line = m.wholeHomeSinkStatusLine ?? ""
        XCTAssertTrue(line.contains(WholeHomeSinkOutput.displayName), line)
        XCTAssertTrue(line.contains("总音量"), line)
    }

    /// The displacement pause outranks everything else the line could say: it
    /// is the only state where nothing is playing and there is a button.
    func testPausedByDisplacementOutranksTheVolumeReadout() {
        let m = AppModel()
        m.mode = .wholeHome
        m.systemSink.applyStatusForTesting(
            Self.status(active: true, drivesSystemVolume: true, volume: 0.4)
        )
        m.systemSinkPausedByDisplacement = true
        XCTAssertTrue((m.wholeHomeSinkStatusLine ?? "").contains("已暂停"))
    }

    /// A pause taken in one mode must not block the engine in the other:
    /// switching modes is an explicit user action that re-establishes the
    /// default output.
    func testSwitchingModesRetiresADisplacementPause() {
        let m = AppModel()
        m.mode = .wholeHome
        m.systemSinkPausedByDisplacement = true
        m.systemSinkPauseMode = .wholeHome
        m.mode = .stereo
        XCTAssertFalse(m.systemSinkPausedByDisplacement)
        XCTAssertNil(m.systemSinkPauseMode)
    }

    /// …but it must survive within the mode it was taken in, or the reconciler
    /// restarts and grabs the default output straight back.
    func testADisplacementPauseSurvivesWithinItsOwnMode() {
        let m = AppModel()
        m.mode = .wholeHome
        m.systemSinkPausedByDisplacement = true
        m.systemSinkPauseMode = .wholeHome
        m.refreshSystemSinkPath(reason: "test")
        XCTAssertTrue(m.systemSinkPausedByDisplacement)
    }

    private static func status(
        active: Bool,
        drivesSystemVolume: Bool,
        volume: Float,
        muted: Bool = false
    ) -> Router.SystemSinkStatus {
        Router.SystemSinkStatus(
            active: active,
            uid: drivesSystemVolume ? SystemSinkDevice.syncCastDriverUID : nil,
            displayName: drivesSystemVolume
                ? SystemSinkDevice.syncCastDriverName
                : WholeHomeSinkOutput.displayName,
            isSystemDefaultOutput: true,
            masterVolume: volume,
            masterMuted: muted,
            drivesSystemVolume: drivesSystemVolume
        )
    }
}
