import XCTest
import SyncCastDiscovery
import SyncCastRouter
@testable import SyncCastMenuBar

/// Per-device and master volume as `AppModel` owns them: the percent grid, the
/// two-stage composition, and — the part that actually bites — persistence
/// keyed by the device's STABLE identity rather than by `Device.id`, which is
/// regenerated every process and every Bonjour reappearance.
///
/// Deliberately unit tests: no sidecar IPC, no router, no discovery. The
/// curve arithmetic these values feed into is specified separately in
/// `VolumeCurveTests` over in the router package.
@MainActor
final class DeviceVolumePersistenceTests: XCTestCase {
    private let volumeKey = "syncast.deviceVolumePercent"
    private let masterKey = "syncast.masterVolumePercent"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: volumeKey)
        UserDefaults.standard.removeObject(forKey: masterKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: volumeKey)
        UserDefaults.standard.removeObject(forKey: masterKey)
        super.tearDown()
    }

    private func localDevice(id: String, uid: String) -> Device {
        Device(
            id: id,
            transport: .coreAudio,
            name: "Built-in Output",
            coreAudioUID: uid
        )
    }

    private func airplayDevice(id: String, deviceID: String) -> Device {
        Device(
            id: id,
            transport: .airplay2,
            name: "Xiaomi Sound",
            host: "192.0.2.20",
            port: 7000,
            airplayDeviceID: deviceID
        )
    }

    // MARK: - Percent grid

    func test_default_volume_is_full_scale() {
        let m = AppModel()
        m.mode = .wholeHome
        XCTAssertEqual(m.deviceVolumePercent(for: "dev-1"), 100)
    }

    func test_set_and_read_back_on_the_percent_grid() {
        let m = AppModel()
        m.mode = .wholeHome
        m.setDeviceVolumePercent(63, for: "dev-1")
        XCTAssertEqual(m.deviceVolumePercent(for: "dev-1"), 63)
    }

    /// The 0…1 entry point (media-key automation, the old API) has to land on
    /// the same grid as the panel, or the two legs quantise differently.
    func test_fraction_entry_point_snaps_to_the_same_grid() {
        let m = AppModel()
        m.mode = .wholeHome
        m.setVolume(0.637, for: "dev-1")
        XCTAssertEqual(m.deviceVolumePercent(for: "dev-1"), 64)
    }

    func test_out_of_range_is_clamped() {
        let m = AppModel()
        m.mode = .wholeHome
        m.setDeviceVolumePercent(-20, for: "dev-1")
        XCTAssertEqual(m.deviceVolumePercent(for: "dev-1"), 0)
        m.setDeviceVolumePercent(400, for: "dev-1")
        XCTAssertEqual(m.deviceVolumePercent(for: "dev-1"), 100)
    }

    func test_reset_returns_to_full_scale() {
        let m = AppModel()
        m.mode = .wholeHome
        m.setDeviceVolumePercent(20, for: "dev-1")
        m.resetDeviceVolume(for: "dev-1")
        XCTAssertEqual(m.deviceVolumePercent(for: "dev-1"), 100)
    }

    // MARK: - Persistence keying

    func test_persisted_under_stable_key_not_transient_device_id() {
        let uid = "AppleHDAEngineOutput:1B,0,1,2:0"
        let m = AppModel()
        m.mode = .wholeHome
        m.devices = [localDevice(id: "transient-id-A", uid: uid)]
        m.setDeviceVolumePercent(42, for: "transient-id-A")

        let stored = UserDefaults.standard.dictionary(forKey: volumeKey)
        XCTAssertEqual(stored?["ca:\(uid)"] as? Int, 42)
        XCTAssertNil(stored?["transient-id-A"])
    }

    func test_airplay_persists_under_bonjour_device_id() {
        let m = AppModel()
        m.mode = .wholeHome
        m.devices = [airplayDevice(id: "transient-id-B", deviceID: "02:AB:00:CD:00:EF")]
        m.setDeviceVolumePercent(55, for: "transient-id-B")

        // `Device.persistenceKey` normalises the Bonjour `deviceid` to
        // uppercase hex with the colons stripped.
        let stored = UserDefaults.standard.dictionary(forKey: volumeKey)
        XCTAssertEqual(stored?["ap:02AB00CD00EF"] as? Int, 55)
    }

    /// Full scale is the default, so it must leave no trace — otherwise every
    /// speaker the user ever touched accumulates in the plist forever.
    func test_full_scale_is_removed_rather_than_stored() {
        let uid = "uid-x"
        let m = AppModel()
        m.mode = .wholeHome
        m.devices = [localDevice(id: "dev-1", uid: uid)]
        m.setDeviceVolumePercent(30, for: "dev-1")
        XCTAssertNotNil(
            UserDefaults.standard.dictionary(forKey: volumeKey)?["ca:\(uid)"]
        )
        m.setDeviceVolumePercent(100, for: "dev-1")
        XCTAssertNil(
            UserDefaults.standard.dictionary(forKey: volumeKey)?["ca:\(uid)"]
        )
    }

    /// A device with no stable identity is held in memory only. Silently
    /// writing it under a per-process id would resurrect the wrong speaker's
    /// volume on the next launch.
    func test_device_without_stable_identity_is_not_persisted() {
        let m = AppModel()
        m.mode = .wholeHome
        m.devices = [
            Device(id: "no-key", transport: .coreAudio, name: "Ghost Output")
        ]
        m.setDeviceVolumePercent(25, for: "no-key")
        XCTAssertEqual(m.deviceVolumePercent(for: "no-key"), 25)
        XCTAssertNil(UserDefaults.standard.dictionary(forKey: volumeKey))
    }

    // MARK: - Re-seeding across a fresh Device.id

    func test_reseed_restores_volume_under_a_fresh_device_id() {
        let uid = "AppleHDAEngineOutput:1B,0,1,2:0"
        let first = AppModel()
        first.mode = .wholeHome
        first.devices = [localDevice(id: "old-id", uid: uid)]
        first.setDeviceVolumePercent(38, for: "old-id")

        // New process: same speaker, brand-new Device.id.
        let second = AppModel()
        second.mode = .wholeHome
        second.devices = [localDevice(id: "fresh-id", uid: uid)]
        second.routing["fresh-id"] = DeviceRouting(deviceID: "fresh-id")
        XCTAssertTrue(second.applyPersistedDeviceVolumes())
        XCTAssertEqual(second.deviceVolumePercent(for: "fresh-id"), 38)
    }

    func test_reseed_is_idempotent() {
        let uid = "uid-steady"
        let m = AppModel()
        m.mode = .wholeHome
        m.devices = [localDevice(id: "steady-id", uid: uid)]
        m.routing["steady-id"] = DeviceRouting(deviceID: "steady-id")
        m.setDeviceVolumePercent(70, for: "steady-id")
        XCTAssertFalse(m.applyPersistedDeviceVolumes())
        XCTAssertFalse(m.applyPersistedDeviceVolumes())
    }

    /// A device with no routing entry has nothing to re-seed into. Reporting
    /// a change here would queue a push on every single discovery event.
    func test_reseed_reports_no_change_without_a_routing_entry() {
        let uid = "uid-unrouted"
        let first = AppModel()
        first.mode = .wholeHome
        first.devices = [localDevice(id: "a", uid: uid)]
        first.setDeviceVolumePercent(15, for: "a")

        let second = AppModel()
        second.mode = .wholeHome
        second.devices = [localDevice(id: "unrouted-id", uid: uid)]
        XCTAssertFalse(second.applyPersistedDeviceVolumes())
    }

    /// Stereo's slider is a MIRROR of the device's own hardware volume, which
    /// macOS already persists and `applyDirectStereoVolumeSnapshot` writes
    /// back into `routing` on every run. Keeping a second copy would restore a
    /// stale value on launch only for the next hardware snapshot to overwrite
    /// it — a visible slider jump and two authorities over one number.
    func test_stereo_volume_is_not_persisted() {
        let uid = "uid-stereo"
        let m = AppModel()
        m.mode = .stereo
        m.devices = [localDevice(id: "dev-1", uid: uid)]
        m.setDeviceVolumePercent(35, for: "dev-1")

        // Still honoured in memory for this session…
        XCTAssertEqual(m.deviceVolumePercent(for: "dev-1"), 35)
        // …but nothing is written, and nothing is re-seeded.
        XCTAssertNil(UserDefaults.standard.dictionary(forKey: volumeKey))
        XCTAssertFalse(m.applyPersistedDeviceVolumes())
    }

    /// A value stored while in whole-home must not be re-applied over the
    /// hardware mirror after the user switches to stereo.
    func test_stereo_does_not_reseed_a_whole_home_value() {
        let uid = "uid-mixed"
        let first = AppModel()
        first.mode = .wholeHome
        first.devices = [localDevice(id: "a", uid: uid)]
        first.setDeviceVolumePercent(22, for: "a")

        let second = AppModel()
        second.mode = .stereo
        second.devices = [localDevice(id: "b", uid: uid)]
        second.routing["b"] = DeviceRouting(deviceID: "b")
        XCTAssertFalse(second.applyPersistedDeviceVolumes())
        XCTAssertEqual(second.deviceVolumePercent(for: "b"), 100)
    }

    // MARK: - Master fader

    func test_master_defaults_to_full_scale_and_persists() {
        let m = AppModel()
        m.mode = .wholeHome
        XCTAssertEqual(m.masterVolumePercent, 100)
        m.setMasterVolumePercent(45)
        XCTAssertEqual(
            UserDefaults.standard.integer(forKey: masterKey), 45
        )
        XCTAssertEqual(AppModel().masterVolumePercent, 45)
    }

    func test_master_clamps() {
        let m = AppModel()
        m.mode = .wholeHome
        m.setMasterVolumePercent(999)
        XCTAssertEqual(m.masterVolumePercent, 100)
        m.setMasterVolumePercent(-5)
        XCTAssertEqual(m.masterVolumePercent, 0)
    }

    /// Master mute is true digital silence, because the master stage sits
    /// upstream of OwnTone's -30 dB floor.
    func test_master_mute_is_silent_and_restores_the_previous_level() {
        let m = AppModel()
        m.mode = .wholeHome
        m.setMasterVolumePercent(60)
        m.toggleMasterMute()
        XCTAssertTrue(m.masterMuted)
        XCTAssertEqual(m.masterVolumeAmplitude, 0)
        m.toggleMasterMute()
        XCTAssertFalse(m.masterMuted)
        XCTAssertEqual(m.masterVolumePercent, 60)
        XCTAssertEqual(
            m.masterVolumeAmplitude,
            VolumeCurve.amplitude(forPercent: 60),
            accuracy: 1e-6
        )
    }

    /// A mute that survives a relaunch reads as "the app is broken", with no
    /// visible cause. The fader position is remembered; the mute is not.
    func test_master_mute_does_not_survive_a_relaunch() {
        let m = AppModel()
        m.mode = .wholeHome
        m.setMasterVolumePercent(60)
        m.setMasterMuted(true)
        XCTAssertFalse(AppModel().masterMuted)
        XCTAssertEqual(AppModel().masterVolumePercent, 60)
    }

    func test_master_reset_clears_mute_and_returns_to_full_scale() {
        let m = AppModel()
        m.mode = .wholeHome
        m.setMasterVolumePercent(20)
        m.setMasterMuted(true)
        m.resetMasterVolume()
        XCTAssertFalse(m.masterMuted)
        XCTAssertEqual(m.masterVolumePercent, 100)
        XCTAssertEqual(m.masterVolumeAmplitude, 1.0, accuracy: 1e-6)
    }

    // MARK: - Media keys (whole-home)

    /// With the named sink installed, the system default output exposes no
    /// hardware volume, so an uncaptured volume key does nothing at all.
    /// Captured, it has to drive the master — never the per-device faders,
    /// which carry the balance the user dialled in.
    func test_volume_keys_step_the_master_not_the_devices() {
        let m = AppModel()
        m.mode = .wholeHome
        m.setMasterVolumePercent(50)
        m.setDeviceVolumePercent(40, for: "dev-1")

        m.handleWholeHomeVolumeKey(.volumeUp)
        XCTAssertEqual(m.masterVolumePercent, 55)
        m.handleWholeHomeVolumeKey(.volumeDown)
        m.handleWholeHomeVolumeKey(.volumeDown)
        XCTAssertEqual(m.masterVolumePercent, 45)
        // The per-speaker balance is untouched.
        XCTAssertEqual(m.deviceVolumePercent(for: "dev-1"), 40)
    }

    /// The step has to divide the range exactly, or the ends become
    /// unreachable by keyboard.
    func test_volume_keys_reach_both_ends_exactly() {
        let m = AppModel()
        m.mode = .wholeHome
        m.setMasterVolumePercent(100)
        for _ in 0..<(100 / AppModel.masterVolumeKeyStepPercent) {
            m.handleWholeHomeVolumeKey(.volumeDown)
        }
        XCTAssertEqual(m.masterVolumePercent, 0)
        m.handleWholeHomeVolumeKey(.volumeDown)
        XCTAssertEqual(m.masterVolumePercent, 0, "must clamp, not wrap")

        for _ in 0..<(100 / AppModel.masterVolumeKeyStepPercent) {
            m.handleWholeHomeVolumeKey(.volumeUp)
        }
        XCTAssertEqual(m.masterVolumePercent, 100)
        m.handleWholeHomeVolumeKey(.volumeUp)
        XCTAssertEqual(m.masterVolumePercent, 100, "must clamp, not wrap")
    }

    func test_mute_key_toggles_master_mute() {
        let m = AppModel()
        m.mode = .wholeHome
        m.handleWholeHomeVolumeKey(.mute)
        XCTAssertTrue(m.masterMuted)
        m.handleWholeHomeVolumeKey(.mute)
        XCTAssertFalse(m.masterMuted)
    }

    /// Stepping up out of a muted state unmutes, matching macOS and the
    /// Direct Stereo path.
    func test_volume_up_unmutes() {
        let m = AppModel()
        m.mode = .wholeHome
        m.setMasterVolumePercent(30)
        m.setMasterMuted(true)
        m.handleWholeHomeVolumeKey(.volumeUp)
        XCTAssertFalse(m.masterMuted)
        XCTAssertEqual(m.masterVolumePercent, 35)
    }

    // MARK: - Two-stage composition

    /// The user-visible contract: master is the total, per-device is the
    /// balance, and the audible result is their product.
    func test_master_and_device_compose_multiplicatively() {
        let m = AppModel()
        m.mode = .wholeHome
        m.setMasterVolumePercent(70)
        m.setDeviceVolumePercent(40, for: "dev-1")

        let expected = VolumeCurve.amplitude(forPercent: 70)
            * VolumeCurve.amplitude(forPercent: 40)
        XCTAssertEqual(
            m.masterVolumeAmplitude
                * VolumeCurve.amplitude(
                    forPercent: m.deviceVolumePercent(for: "dev-1")
                ),
            expected,
            accuracy: 1e-6
        )
        XCTAssertEqual(
            expected,
            VolumeCurve.effectiveLocalAmplitude(
                masterPercent: 70, devicePercent: 40, deviceMuted: false
            ),
            accuracy: 1e-6
        )
    }

    /// Master mute wins over any per-device setting — it is upstream of them.
    func test_master_mute_silences_a_device_at_full_scale() {
        let m = AppModel()
        m.mode = .wholeHome
        m.setDeviceVolumePercent(100, for: "dev-1")
        m.setMasterMuted(true)
        XCTAssertEqual(m.masterVolumeAmplitude, 0)
    }


    // MARK: - The -30 dB floor, and saying so

    /// `VolumeCurve`'s floor applies to the LOCAL leg too — the bridge could
    /// write true zeros but deliberately does not, so the two legs stay
    /// matched. A CoreAudio row at 0 % is therefore still audible and needs
    /// the same explanation an AirPlay row gets; gating the hint on
    /// `.airplay2` left a local speaker reading "0%" while playing at ~1/32
    /// amplitude with nothing on screen to explain it.
    func test_floor_hint_is_shown_for_a_local_speaker_at_zero() {
        let m = AppModel()
        m.mode = .wholeHome
        m.devices = [localDevice(id: "dev-1", uid: "uid-floor-local")]
        m.routing["dev-1"] = DeviceRouting(deviceID: "dev-1", enabled: true)
        m.setDeviceVolumePercent(0, for: "dev-1")

        let hint = m.volumeFloorHint(for: "dev-1")
        XCTAssertNotNil(hint, "a local speaker at the floor must be explained too")
        XCTAssertEqual(hint?.contains("-30.0 dB"), true)
    }

    func test_floor_hint_is_shown_for_an_airplay_receiver_at_zero() {
        let m = AppModel()
        m.mode = .wholeHome
        m.devices = [airplayDevice(id: "ap-1", deviceID: "02:AB:00:CD:00:EF")]
        m.routing["ap-1"] = DeviceRouting(deviceID: "ap-1", enabled: true)
        m.setDeviceVolumePercent(0, for: "ap-1")

        XCTAssertNotNil(m.volumeFloorHint(for: "ap-1"))
    }

    /// Mute is the one place the legs legitimately diverge: the local bridge
    /// reaches `VolumeCurve.silentAmplitude`, OwnTone cannot. So a muted local
    /// speaker is genuinely silent and must NOT be told it is still audible.
    func test_muted_local_speaker_gets_no_floor_hint() {
        let m = AppModel()
        m.mode = .wholeHome
        m.devices = [localDevice(id: "dev-1", uid: "uid-floor-mute")]
        m.routing["dev-1"] = DeviceRouting(
            deviceID: "dev-1", enabled: true, volume: 0.8, muted: true
        )
        XCTAssertNil(m.volumeFloorHint(for: "dev-1"))
    }

    /// …whereas a muted AirPlay receiver really is only at -30 dB.
    func test_muted_airplay_receiver_still_gets_the_floor_hint() {
        let m = AppModel()
        m.mode = .wholeHome
        m.devices = [airplayDevice(id: "ap-1", deviceID: "02:AB:00:CD:00:EF")]
        m.routing["ap-1"] = DeviceRouting(
            deviceID: "ap-1", enabled: true, volume: 0.8, muted: true
        )
        XCTAssertNotNil(m.volumeFloorHint(for: "ap-1"))
    }

    func test_no_floor_hint_above_the_floor_or_outside_whole_home() {
        let m = AppModel()
        m.mode = .wholeHome
        m.devices = [localDevice(id: "dev-1", uid: "uid-floor-off")]
        m.routing["dev-1"] = DeviceRouting(deviceID: "dev-1", enabled: true)
        m.setDeviceVolumePercent(1, for: "dev-1")
        XCTAssertNil(m.volumeFloorHint(for: "dev-1"))

        m.setDeviceVolumePercent(0, for: "dev-1")
        XCTAssertNotNil(m.volumeFloorHint(for: "dev-1"))
        m.mode = .stereo
        XCTAssertNil(m.volumeFloorHint(for: "dev-1"))
    }

    // MARK: - Materialising the routing entry

    /// `deviceVolumePercent` reports 100 for a device with no routing entry,
    /// so guarding "unchanged ⇒ do nothing" on it made setting 100 % a silent
    /// no-op that never created the entry. `resetDeviceVolume` IS that call,
    /// so the Reset button did nothing on any row whose entry had not been
    /// created yet (fresh appearance, or after an id migration).
    func test_reset_creates_the_routing_entry_when_there_is_none() {
        let m = AppModel()
        m.mode = .wholeHome
        XCTAssertNil(m.routing["fresh-id"])

        m.resetDeviceVolume(for: "fresh-id")

        XCTAssertNotNil(
            m.routing["fresh-id"],
            "reset must materialise the entry so the bridge is actually pushed"
        )
        XCTAssertEqual(m.routing["fresh-id"]?.volume, 1.0)
    }

    /// The guard must still suppress the per-pixel churn of a slider drag once
    /// the entry exists — that is what it is for.
    func test_setting_the_same_percent_twice_is_still_a_no_op() {
        let m = AppModel()
        m.mode = .wholeHome
        m.devices = [localDevice(id: "dev-1", uid: "uid-noop")]
        m.setDeviceVolumePercent(40, for: "dev-1")
        let before = m.routing["dev-1"]
        m.setDeviceVolumePercent(40, for: "dev-1")
        XCTAssertEqual(m.routing["dev-1"], before)
    }
}
