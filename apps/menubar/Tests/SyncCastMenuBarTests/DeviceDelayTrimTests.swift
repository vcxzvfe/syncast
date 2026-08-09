import XCTest
import SyncCastDiscovery
import SyncCastRouter
@testable import SyncCastMenuBar

/// Unit tests for the per-speaker delay trim as `AppModel` owns it: signed
/// user intent, its clamp, and — the part that actually bites — persistence
/// keyed by the device's STABLE identity rather than by `Device.id`, which is
/// regenerated every process.
///
/// Deliberately unit tests: no sidecar IPC, no router, no discovery. The
/// normalisation arithmetic these values feed into is specified separately in
/// `DelayTrimNormalizerTests` over in the router package.
@MainActor
final class DeviceDelayTrimTests: XCTestCase {
    private let trimKey = "syncast.deviceDelayTrimMs"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: trimKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: trimKey)
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

    // MARK: - Basic intent

    func test_default_trim_is_zero() {
        let m = AppModel()
        XCTAssertEqual(m.deviceTrimMs(for: "dev-1"), 0)
        XCTAssertFalse(m.hasAnyDeviceTrim)
    }

    func test_set_trim_is_readable_back_signed() {
        let m = AppModel()
        m.setDeviceTrim(-7, for: "dev-1")
        XCTAssertEqual(m.deviceTrimMs(for: "dev-1"), -7)
        XCTAssertTrue(m.hasAnyDeviceTrim)
    }

    func test_set_trim_clamps_to_the_named_range() {
        let m = AppModel()
        m.setDeviceTrim(9_999, for: "dev-1")
        XCTAssertEqual(m.deviceTrimMs(for: "dev-1"),
                       DeviceDelayTrim.rangeMs.upperBound)
        m.setDeviceTrim(-9_999, for: "dev-1")
        XCTAssertEqual(m.deviceTrimMs(for: "dev-1"),
                       DeviceDelayTrim.rangeMs.lowerBound)
    }

    func test_nudge_moves_by_the_step_and_clamps() {
        let m = AppModel()
        m.nudgeDeviceTrim(DeviceDelayTrim.stepMs, for: "dev-1")
        XCTAssertEqual(m.deviceTrimMs(for: "dev-1"), DeviceDelayTrim.stepMs)
        m.setDeviceTrim(DeviceDelayTrim.rangeMs.upperBound, for: "dev-1")
        m.nudgeDeviceTrim(DeviceDelayTrim.stepMs, for: "dev-1")
        XCTAssertEqual(m.deviceTrimMs(for: "dev-1"),
                       DeviceDelayTrim.rangeMs.upperBound)
    }

    func test_reset_clears_one_device_only() {
        let m = AppModel()
        m.setDeviceTrim(5, for: "dev-1")
        m.setDeviceTrim(9, for: "dev-2")
        m.resetDeviceTrim(for: "dev-1")
        XCTAssertEqual(m.deviceTrimMs(for: "dev-1"), 0)
        XCTAssertEqual(m.deviceTrimMs(for: "dev-2"), 9)
    }

    func test_reset_all_clears_every_device() {
        let m = AppModel()
        m.setDeviceTrim(5, for: "dev-1")
        m.setDeviceTrim(-9, for: "dev-2")
        m.resetAllDeviceTrims()
        XCTAssertEqual(m.deviceTrimMs(for: "dev-1"), 0)
        XCTAssertEqual(m.deviceTrimMs(for: "dev-2"), 0)
        XCTAssertFalse(m.hasAnyDeviceTrim)
    }

    // MARK: - Persistence

    func test_trim_persists_under_the_stable_device_key_not_the_transient_id() {
        let uid = "AppleHDAEngineOutput:1B,0,1,2:0"
        let m = AppModel()
        m.devices = [localDevice(id: "transient-id-A", uid: uid)]
        m.setDeviceTrim(12, for: "transient-id-A")

        let stored = UserDefaults.standard.dictionary(forKey: trimKey) as? [String: Int]
        XCTAssertEqual(stored, ["ca:\(uid)": 12])
        // The regenerated-per-process id must appear nowhere in storage.
        XCTAssertNil(stored?["transient-id-A"])
    }

    func test_airplay_trim_persists_under_the_normalized_bonjour_device_id() {
        let m = AppModel()
        m.devices = [airplayDevice(id: "transient-id-B", deviceID: "02:AB:00:CD:00:EF")]
        m.setDeviceTrim(-4, for: "transient-id-B")

        let stored = UserDefaults.standard.dictionary(forKey: trimKey) as? [String: Int]
        XCTAssertEqual(stored, ["ap:02AB00CD00EF": -4])
    }

    func test_zero_trim_leaves_nothing_behind_in_storage() {
        let uid = "uid-1"
        let m = AppModel()
        m.devices = [localDevice(id: "dev-1", uid: uid)]
        m.setDeviceTrim(12, for: "dev-1")
        m.setDeviceTrim(0, for: "dev-1")

        let stored = UserDefaults.standard.dictionary(forKey: trimKey) as? [String: Int]
        XCTAssertEqual(stored, [:])
    }

    func test_device_without_a_stable_key_is_held_in_memory_only() {
        // Device.persistenceKey is nil when there is no stable identity, and
        // its own documentation says to hold the value rather than invent a
        // key. The trim must still work for the session.
        let m = AppModel()
        m.devices = [
            Device(id: "dev-1", transport: .coreAudio, name: "Mystery Output")
        ]
        m.setDeviceTrim(6, for: "dev-1")
        XCTAssertEqual(m.deviceTrimMs(for: "dev-1"), 6)
        XCTAssertNil(UserDefaults.standard.dictionary(forKey: trimKey))
    }

    func test_persisted_trim_is_restored_on_a_fresh_model() {
        let uid = "uid-restored"
        UserDefaults.standard.set(["ca:\(uid)": 15], forKey: trimKey)

        let m = AppModel()
        // Simulate discovery re-minting a DIFFERENT id for the same hardware,
        // which is exactly what happens across a relaunch.
        m.devices = [localDevice(id: "fresh-id", uid: uid)]
        m.routing["fresh-id"] = DeviceRouting(deviceID: "fresh-id")
        m.applyPersistedDeviceTrims()

        XCTAssertEqual(m.deviceTrimMs(for: "fresh-id"), 15)
    }

    func test_persisted_values_outside_the_range_are_clamped_on_load() {
        UserDefaults.standard.set(["ca:uid-x": 50_000], forKey: trimKey)
        let m = AppModel()
        m.devices = [localDevice(id: "dev-x", uid: "uid-x")]
        m.routing["dev-x"] = DeviceRouting(deviceID: "dev-x")
        m.applyPersistedDeviceTrims()
        XCTAssertEqual(m.deviceTrimMs(for: "dev-x"),
                       DeviceDelayTrim.rangeMs.upperBound)
    }

    // MARK: - Distance hint

    /// The hint states the CORRECTION, not the speaker's distance.
    ///
    /// `DeviceDelayTrim` defines positive as "hold this speaker back", so a
    /// speaker that is further away (and therefore arrives late) wants a
    /// NEGATIVE trim. The earlier wording labelled `+3 ms` as "further",
    /// which is the AV-receiver convention and the exact opposite: a user
    /// following it pressed `+` on their distant speaker and doubled the skew
    /// they were trying to remove. This test and
    /// `test_distance_hint_matches_the_speed_of_sound` pin the two ends of
    /// the convention so they cannot drift apart again.
    func test_distance_hint_states_the_correction_not_the_distance() {
        let m = AppModel()
        XCTAssertEqual(m.deviceTrimDistanceHint(for: "dev-1"), "0 ms")
        m.setDeviceTrim(3, for: "dev-1")
        XCTAssertEqual(
            m.deviceTrimDistanceHint(for: "dev-1"),
            "+3 ms, held back ≈ 1.0 m"
        )
        m.setDeviceTrim(-3, for: "dev-1")
        XCTAssertEqual(
            m.deviceTrimDistanceHint(for: "dev-1"),
            "−3 ms, brought forward ≈ 1.0 m"
        )
    }

    func test_distance_hint_matches_the_speed_of_sound() {
        let m = AppModel()
        // 1 ms of air is ~34 cm, so 10 ms must read as ~3.4 m whichever way
        // the sign points — the magnitude is pure physics and independent of
        // the correction's direction.
        m.setDeviceTrim(10, for: "dev-1")
        XCTAssertTrue(
            m.deviceTrimDistanceHint(for: "dev-1").hasSuffix("≈ 3.4 m"),
            m.deviceTrimDistanceHint(for: "dev-1")
        )
        m.setDeviceTrim(-10, for: "dev-1")
        XCTAssertTrue(
            m.deviceTrimDistanceHint(for: "dev-1").hasSuffix("≈ 3.4 m"),
            m.deviceTrimDistanceHint(for: "dev-1")
        )
    }

    // MARK: - Re-seeding queues a commit

    /// A re-seed moves the normalisation baseline for EVERY enabled output,
    /// so it has to reach both legs. Before this, `applyPersistedDeviceTrims`
    /// wrote `routing` and stopped: the local leg picked the change up
    /// incidentally via the reconcile loop's `setRouting`, and the AirPlay
    /// leg never did.
    func test_reseeding_a_changed_trim_queues_a_commit() {
        let uid = "uid-reseed"
        UserDefaults.standard.set(["ca:\(uid)": 9], forKey: trimKey)
        let m = AppModel()
        m.devices = [localDevice(id: "fresh-id", uid: uid)]
        m.routing["fresh-id"] = DeviceRouting(deviceID: "fresh-id")

        XCTAssertTrue(m.applyPersistedDeviceTrims())
        XCTAssertTrue(m.pendingTrimDeviceIDs.contains("fresh-id"))
    }

    /// ...and a re-seed that changes nothing must queue nothing, or every
    /// discovery event would buy the user an AirPlay relatch.
    func test_reseeding_an_unchanged_trim_queues_nothing() {
        let uid = "uid-steady"
        let m = AppModel()
        m.devices = [localDevice(id: "steady-id", uid: uid)]
        m.routing["steady-id"] = DeviceRouting(deviceID: "steady-id")

        XCTAssertFalse(m.applyPersistedDeviceTrims())
        XCTAssertTrue(m.pendingTrimDeviceIDs.isEmpty)
        // And again for a device the store DOES know about, once seeded.
        UserDefaults.standard.set(["ca:\(uid)": 4], forKey: trimKey)
        let n = AppModel()
        n.devices = [localDevice(id: "steady-id", uid: uid)]
        n.routing["steady-id"] = DeviceRouting(deviceID: "steady-id")
        XCTAssertTrue(n.applyPersistedDeviceTrims())
        XCTAssertFalse(n.applyPersistedDeviceTrims())
    }

    /// A device that discovery has reported but that has no `routing` entry
    /// yet must not be reported as changed. Writing through the optional
    /// chain silently no-ops, so a "changed" verdict there would re-queue a
    /// commit on every single discovery event, forever.
    func test_reseeding_a_device_without_a_routing_entry_reports_no_change() {
        let uid = "uid-unrouted"
        UserDefaults.standard.set(["ca:\(uid)": 11], forKey: trimKey)
        let m = AppModel()
        m.devices = [localDevice(id: "unrouted-id", uid: uid)]
        // No m.routing entry on purpose.
        XCTAssertFalse(m.applyPersistedDeviceTrims())
        XCTAssertTrue(m.pendingTrimDeviceIDs.isEmpty)
    }
}
