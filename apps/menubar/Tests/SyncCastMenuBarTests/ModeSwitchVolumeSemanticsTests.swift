import XCTest
import SyncCastDiscovery
import SyncCastRouter
@testable import SyncCastMenuBar

/// `routing[*].volume` carries TWO incompatible meanings and `setMode` is the
/// only place that can reconcile them:
///
///  * whole-home — a POSITION on `VolumeCurve`. `Router.localBridgeGain` turns
///    50 into -15 dB of bridge gain and the same 50 goes to OwnTone's
///    per-output volume.
///  * stereo — a plain linear gain, and in Direct Stereo a live MIRROR of the
///    device's own hardware level, continuously rewritten by
///    `applyDirectStereoVolumeSnapshot` and `HardwareVolumeObserver`.
///
/// Nothing re-seeded the field at the boundary, so the number survived the
/// switch and was re-read under the wrong law: a 30 % hardware mirror became
/// -21 dB of EXTRA bridge gain on entry (ignoring whatever the user had
/// persisted for whole-home, until an unrelated discovery event fired the
/// re-seed and snapped the room ~21 dB louder mid-track), and a whole-home
/// 50 % (-15 dB) became a raw 0.5 linear gain (-6 dB) on the way out — a ~9 dB
/// jump with the slider unmoved.
///
/// Every routing entry here is created with `enabled: false` on purpose:
/// `setMode` ends in `reconcileEngine()`, and an enabled output would ask the
/// real engine to start (ScreenCaptureKit, sidecar, CoreAudio) from a unit
/// test.
@MainActor
final class ModeSwitchVolumeSemanticsTests: XCTestCase {
    private let volumeKey = "syncast.deviceVolumePercent"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: volumeKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: volumeKey)
        super.tearDown()
    }

    private func localDevice(id: String, uid: String) -> Device {
        Device(
            id: id,
            transport: .coreAudio,
            name: "MacBook Pro扬声器",
            coreAudioUID: uid
        )
    }

    private func idleRouting(_ id: String, volume: Float) -> DeviceRouting {
        DeviceRouting(deviceID: id, enabled: false, volume: volume)
    }

    // MARK: - Entering whole-home

    /// The persisted whole-home level must be in force the moment the mode
    /// comes up, not whenever the next discovery event happens to fire.
    func test_entering_whole_home_installs_the_persisted_level() {
        let uid = "uid-entering"
        let seed = AppModel()
        seed.mode = .wholeHome
        seed.devices = [localDevice(id: "seed-id", uid: uid)]
        seed.setDeviceVolumePercent(80, for: "seed-id")

        let m = AppModel()
        m.devices = [localDevice(id: "dev-1", uid: uid)]
        // Direct Stereo left the HARDWARE level here, not a curve position.
        m.routing["dev-1"] = idleRouting("dev-1", volume: 0.30)

        m.setMode(.wholeHome)

        XCTAssertEqual(m.deviceVolumePercent(for: "dev-1"), 80)
    }

    /// With nothing persisted, entering whole-home must not inherit the
    /// hardware mirror either — the untouched whole-home level is full scale.
    func test_entering_whole_home_drops_the_hardware_mirror_when_nothing_is_persisted() {
        let m = AppModel()
        m.devices = [localDevice(id: "dev-1", uid: "uid-nothing-stored")]
        m.routing["dev-1"] = idleRouting("dev-1", volume: 0.30)

        m.setMode(.wholeHome)

        XCTAssertEqual(m.deviceVolumePercent(for: "dev-1"), 100)
        // Same composition `Router.localBridgeGain` performs (that helper is
        // internal to the router module, so the curve is exercised directly).
        XCTAssertEqual(
            VolumeCurve.deviceAmplitude(
                forPercent: m.deviceVolumePercent(for: "dev-1"),
                muted: m.routing["dev-1"]?.muted ?? false
            ),
            1.0,
            accuracy: 1e-6,
            "a fresh whole-home session must start bit-transparent, not -21 dB down"
        )
    }

    // MARK: - Leaving whole-home

    /// A dB position must never leave whole-home: `Router.replan()` hands the
    /// same field to the stereo path as a raw linear gain.
    func test_leaving_whole_home_resets_to_unity() {
        let m = AppModel()
        m.mode = .wholeHome
        m.devices = [localDevice(id: "dev-1", uid: "uid-leaving")]
        m.routing["dev-1"] = idleRouting("dev-1", volume: 0.50)

        m.setMode(.stereo)

        XCTAssertEqual(m.deviceVolumePercent(for: "dev-1"), 100)
        XCTAssertEqual(m.routing["dev-1"]?.volume, 1.0)
    }

    /// The reset is the state stereo can safely hold until the hardware
    /// snapshot lands; it must not disturb anything else on the entry.
    func test_leaving_whole_home_preserves_the_rest_of_the_routing_entry() {
        let m = AppModel()
        m.mode = .wholeHome
        m.devices = [localDevice(id: "dev-1", uid: "uid-preserve")]
        m.routing["dev-1"] = DeviceRouting(
            deviceID: "dev-1", enabled: false, volume: 0.4,
            muted: true, manualDelayMs: 7
        )

        m.setMode(.stereo)

        XCTAssertEqual(m.routing["dev-1"]?.muted, true)
        XCTAssertEqual(m.routing["dev-1"]?.manualDelayMs, 7)
    }

    func test_reset_to_unity_reports_whether_anything_changed() {
        let m = AppModel()
        m.mode = .wholeHome
        m.routing["a"] = idleRouting("a", volume: 0.25)
        XCTAssertTrue(m.resetDeviceVolumesToUnity())
        XCTAssertFalse(m.resetDeviceVolumesToUnity())
    }

    // MARK: - Round trip

    /// The user's whole-home tuning must survive a detour through stereo:
    /// that round trip is the everyday case (switch to stereo for a video,
    /// switch back for music).
    func test_round_trip_restores_the_whole_home_level() {
        let uid = "uid-round-trip"
        let m = AppModel()
        m.mode = .wholeHome
        m.devices = [localDevice(id: "dev-1", uid: uid)]
        m.routing["dev-1"] = idleRouting("dev-1", volume: 1.0)
        m.setDeviceVolumePercent(45, for: "dev-1")

        m.setMode(.stereo)
        XCTAssertEqual(m.deviceVolumePercent(for: "dev-1"), 100)

        m.setMode(.wholeHome)
        XCTAssertEqual(m.deviceVolumePercent(for: "dev-1"), 45)
    }
}
