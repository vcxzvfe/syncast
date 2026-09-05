import XCTest
import SyncCastDiscovery
import SyncCastRouter
@testable import SyncCastMenuBar

/// Per-device local-Stereo delay as `AppModel` and `LocalDelayTrimStore` own
/// it: the CoreAudio-UID keying that makes the value come back with the
/// device, the load-boundary validation, the availability rules that decide
/// whether a row gets the control, and — most importantly — that it stays
/// separate from the whole-home listening-position trim.
///
/// Deliberately unit tests: no router, no CoreAudio. The frame arithmetic is
/// specified in `LocalDelayTrimTests` over in the router package.
@MainActor
final class LocalDelayTrimPersistenceTests: XCTestCase {
    private let storeKey = LocalDelayTrimStore.defaultsKey
    private let wholeHomeKey = AppModel.deviceTrimDefaultsKey

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: storeKey)
        UserDefaults.standard.removeObject(forKey: wholeHomeKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: storeKey)
        UserDefaults.standard.removeObject(forKey: wholeHomeKey)
        super.tearDown()
    }

    private func localDevice(
        id: String, uid: String, name: String = "External display"
    ) -> Device {
        Device(id: id, transport: .coreAudio, name: name, coreAudioUID: uid)
    }

    private func airplayDevice(id: String) -> Device {
        Device(
            id: id, transport: .airplay2, name: "Living-room receiver",
            host: "192.0.2.20", port: 7000, airplayDeviceID: "AABBCCDDEEFF"
        )
    }

    // MARK: - Store round trip

    func test_round_trip_through_defaults() {
        LocalDelayTrimStore.save([
            "uid-a": LocalDelayTrimProfile(uid: "uid-a", displayName: "Display", delayMs: 32),
            "uid-b": LocalDelayTrimProfile(uid: "uid-b", delayMs: -18),
        ])
        let loaded = LocalDelayTrimStore.load()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded["uid-a"]?.delayMs, 32)
        XCTAssertEqual(loaded["uid-a"]?.displayName, "Display")
        XCTAssertEqual(loaded["uid-b"]?.delayMs, -18)
    }

    func test_saving_an_empty_map_clears_the_key() {
        LocalDelayTrimStore.save(["uid-a": LocalDelayTrimProfile(uid: "uid-a", delayMs: 12)])
        XCTAssertNotNil(UserDefaults.standard.data(forKey: storeKey))
        LocalDelayTrimStore.save([:])
        XCTAssertNil(UserDefaults.standard.data(forKey: storeKey))
    }

    func test_unreadable_data_is_ignored_rather_than_crashing() {
        XCTAssertTrue(LocalDelayTrimStore.decode(Data("not json".utf8)).isEmpty)
        XCTAssertTrue(LocalDelayTrimStore.decode(nil).isEmpty)
    }

    func test_sanitize_drops_blanks_duplicates_and_zeroes() {
        let sanitized = LocalDelayTrimStore.sanitize([
            LocalDelayTrimProfile(uid: "  ", delayMs: 20),
            LocalDelayTrimProfile(uid: "uid-zero", delayMs: 0),
            LocalDelayTrimProfile(uid: "uid-a", delayMs: 20),
            LocalDelayTrimProfile(uid: "uid-a", delayMs: -20),
        ])
        XCTAssertEqual(sanitized.map(\.uid), ["uid-a"])
        XCTAssertEqual(sanitized[0].delayMs, 20, "first record wins")
    }

    func test_uid_whitespace_is_trimmed_rather_than_keyed_on() {
        let sanitized = LocalDelayTrimStore.sanitize([
            LocalDelayTrimProfile(uid: "  uid-a\n", delayMs: 7)
        ])
        XCTAssertEqual(sanitized.map(\.uid), ["uid-a"])
    }

    /// A value from a hand-edited plist or a future version must not reach the
    /// render thread: an offset far past the ring's backlog is silence on that
    /// speaker, which presents as the device having failed.
    func test_out_of_range_values_are_clamped_on_load() {
        let sanitized = LocalDelayTrimStore.sanitize([
            LocalDelayTrimProfile(uid: "uid-a", delayMs: 100_000),
            LocalDelayTrimProfile(uid: "uid-b", delayMs: -100_000),
        ])
        XCTAssertEqual(sanitized.first { $0.uid == "uid-a" }?.delayMs,
                       LocalDelayTrim.rangeMs.upperBound)
        XCTAssertEqual(sanitized.first { $0.uid == "uid-b" }?.delayMs,
                       LocalDelayTrim.rangeMs.lowerBound)
    }

    // MARK: - AppModel editing

    func test_edit_persists_under_the_core_audio_uid() {
        let model = AppModel()
        model.devices = [localDevice(id: "dev-1", uid: "uid-a")]
        model.setLocalDelayTrim(24, for: "dev-1")

        XCTAssertEqual(model.localDelayTrimMs(for: "dev-1"), 24)
        XCTAssertEqual(LocalDelayTrimStore.load()["uid-a"]?.delayMs, 24)
        XCTAssertEqual(LocalDelayTrimStore.load()["uid-a"]?.displayName, "External display")
    }

    /// The whole point: `Device.id` is minted fresh every process and every
    /// re-plug, so the value has to come back under a NEW id as long as the
    /// CoreAudio UID matches.
    func test_value_survives_a_new_device_id_for_the_same_uid() {
        let first = AppModel()
        first.devices = [localDevice(id: "dev-1", uid: "uid-a")]
        first.setLocalDelayTrim(-31, for: "dev-1")

        let relaunched = AppModel()
        relaunched.devices = [localDevice(id: "dev-99-fresh", uid: "uid-a")]
        XCTAssertEqual(relaunched.localDelayTrimMs(for: "dev-99-fresh"), -31)
        XCTAssertTrue(relaunched.hasLocalDelayTrim(for: "dev-99-fresh"))
    }

    func test_a_different_uid_gets_no_value() {
        let model = AppModel()
        model.devices = [
            localDevice(id: "dev-1", uid: "uid-one"),
            localDevice(id: "dev-2", uid: "uid-two", name: "Second display"),
        ]
        model.setLocalDelayTrim(40, for: "dev-1")
        XCTAssertEqual(model.localDelayTrimMs(for: "dev-2"), 0)
        XCTAssertFalse(model.hasLocalDelayTrim(for: "dev-2"))
    }

    func test_reset_removes_the_stored_record() {
        let model = AppModel()
        model.devices = [localDevice(id: "dev-1", uid: "uid-a")]
        model.setLocalDelayTrim(24, for: "dev-1")
        XCTAssertNotNil(LocalDelayTrimStore.load()["uid-a"])

        model.resetLocalDelayTrim(for: "dev-1")
        XCTAssertNil(model.localDelayTrims["uid-a"])
        XCTAssertTrue(LocalDelayTrimStore.load().isEmpty)
    }

    func test_edits_are_clamped_to_the_user_range() {
        let model = AppModel()
        model.devices = [localDevice(id: "dev-1", uid: "uid-a")]
        model.setLocalDelayTrim(9_999, for: "dev-1")
        XCTAssertEqual(model.localDelayTrimMs(for: "dev-1"), LocalDelayTrim.rangeMs.upperBound)
        model.setLocalDelayTrim(-9_999, for: "dev-1")
        XCTAssertEqual(model.localDelayTrimMs(for: "dev-1"), LocalDelayTrim.rangeMs.lowerBound)
    }

    func test_nudge_walks_by_the_ui_step() {
        let model = AppModel()
        model.devices = [localDevice(id: "dev-1", uid: "uid-a")]
        model.nudgeLocalDelayTrim(LocalDelayTrim.stepMs, for: "dev-1")
        model.nudgeLocalDelayTrim(LocalDelayTrim.stepMs, for: "dev-1")
        XCTAssertEqual(model.localDelayTrimMs(for: "dev-1"), 2 * LocalDelayTrim.stepMs)
    }

    /// Mid-drag edits are live but unsaved; the release writes them. A crash
    /// mid-drag therefore loses the drag, not the previous value.
    func test_a_drag_is_live_before_it_is_saved() {
        let model = AppModel()
        model.devices = [localDevice(id: "dev-1", uid: "uid-a")]
        model.setLocalDelayTrim(15, for: "dev-1", persist: false)
        XCTAssertEqual(model.localDelayTrimMs(for: "dev-1"), 15)
        XCTAssertNil(UserDefaults.standard.data(forKey: storeKey))

        model.setLocalDelayTrim(15, for: "dev-1", persist: true)
        XCTAssertEqual(LocalDelayTrimStore.load()["uid-a"]?.delayMs, 15)
    }

    func test_editing_an_airplay_receiver_is_refused() {
        let model = AppModel()
        model.devices = [airplayDevice(id: "ap-1")]
        model.setLocalDelayTrim(30, for: "ap-1")
        XCTAssertTrue(model.localDelayTrims.isEmpty)
        XCTAssertEqual(model.localDelayTrimMs(for: "ap-1"), 0)
    }

    func test_resetting_an_untouched_row_writes_nothing() {
        let model = AppModel()
        model.devices = [localDevice(id: "dev-1", uid: "uid-a")]
        model.resetLocalDelayTrim(for: "dev-1")
        XCTAssertNil(UserDefaults.standard.data(forKey: storeKey))
    }

    // MARK: - Independence from the whole-home trim

    /// Same unit, different correction, different leg. Dialling one must not
    /// move the other, or each mode would silently retune the other.
    func test_local_and_whole_home_trims_are_separate_settings() {
        let model = AppModel()
        model.devices = [localDevice(id: "dev-1", uid: "uid-a")]
        model.routing["dev-1"] = DeviceRouting(deviceID: "dev-1", enabled: true)

        model.setLocalDelayTrim(40, for: "dev-1")
        XCTAssertEqual(model.deviceTrimMs(for: "dev-1"), 0)

        model.setDeviceTrim(-12, for: "dev-1")
        XCTAssertEqual(model.localDelayTrimMs(for: "dev-1"), 40)
        XCTAssertEqual(model.deviceTrimMs(for: "dev-1"), -12)
        XCTAssertNotEqual(LocalDelayTrimStore.defaultsKey, AppModel.deviceTrimDefaultsKey)
    }

    // MARK: - Availability

    func test_availability_requires_an_enabled_core_audio_output() {
        let model = AppModel()
        model.mode = .stereo
        model.devices = [
            localDevice(id: "dev-1", uid: "uid-a"),
            airplayDevice(id: "ap-1"),
        ]
        // Not enabled yet: a disabled output is not part of the set the
        // Router normalises, so its control would move nothing.
        XCTAssertFalse(model.localDelayTrimIsAvailable(for: "dev-1"))

        model.routing["dev-1"] = DeviceRouting(deviceID: "dev-1", enabled: true)
        model.routing["ap-1"] = DeviceRouting(deviceID: "ap-1", enabled: true)
        // `selectedStereoOutputPath` is resolved once per process, so assert
        // the rule rather than a machine-dependent verdict.
        XCTAssertEqual(
            model.localDelayTrimIsAvailable(for: "dev-1"),
            model.localDelayTrimIsSupportedOnCurrentPath
        )
        XCTAssertFalse(
            model.localDelayTrimIsAvailable(for: "ap-1"),
            "an AirPlay receiver's audio never passes through our render callback"
        )
    }

    func test_whole_home_hides_the_control_and_says_why() {
        let model = AppModel()
        model.devices = [localDevice(id: "dev-1", uid: "uid-a")]
        model.routing["dev-1"] = DeviceRouting(deviceID: "dev-1", enabled: true)
        model.setLocalDelayTrim(25, for: "dev-1")

        model.mode = .wholeHome
        XCTAssertFalse(model.localDelayTrimIsSupportedOnCurrentPath)
        XCTAssertFalse(model.localDelayTrimIsAvailable(for: "dev-1"))
        XCTAssertNotNil(
            model.localDelayTrimInactiveHint(for: "dev-1"),
            "a stored delay that is not being applied has to say so"
        )
    }

    func test_no_hint_for_a_device_with_no_value() {
        let model = AppModel()
        model.devices = [localDevice(id: "dev-1", uid: "uid-a")]
        model.mode = .wholeHome
        XCTAssertNil(model.localDelayTrimInactiveHint(for: "dev-1"))
    }

    // MARK: - Labels

    func test_label_states_the_sign_with_a_real_minus() {
        XCTAssertEqual(AppModel.localDelayTrimLabel(0), "0 ms")
        XCTAssertEqual(AppModel.localDelayTrimLabel(12), "+12 ms")
        XCTAssertEqual(AppModel.localDelayTrimLabel(-12), "−12 ms")
    }

    func test_hint_carries_the_sign_convention_and_the_distance_scale() {
        let hint = AppModel.localDelayTrimHint
        XCTAssertTrue(hint.contains("34 cm"))
        XCTAssertTrue(hint.contains("晚出声"))
    }
}
