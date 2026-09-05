import XCTest
import SyncCastDiscovery
import SyncCastRouter
@testable import SyncCastMenuBar

/// Per-device equalizer curves as `AppModel` and `DeviceEqualizerStore` own
/// them: the CoreAudio-UID keying that makes "每次连接都默认这样" true, the
/// load-boundary validation, and the availability rules that decide whether a
/// row gets the control at all.
///
/// Deliberately unit tests: no router, no CoreAudio. The filter math is
/// specified in `EqualizerBankTests` over in the router package.
@MainActor
final class DeviceEqualizerPersistenceTests: XCTestCase {
    private let storeKey = DeviceEqualizerStore.defaultsKey

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: storeKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: storeKey)
        super.tearDown()
    }

    private func localDevice(id: String, uid: String, name: String = "ExternalDisplay") -> Device {
        Device(id: id, transport: .coreAudio, name: name, coreAudioUID: uid)
    }

    private func airplayDevice(id: String) -> Device {
        Device(
            id: id, transport: .airplay2, name: "Xiaomi Sound",
            host: "192.0.2.20", port: 7000, airplayDeviceID: "AABBCCDDEEFF"
        )
    }

    private func profile(uid: String, bass: Double) -> DeviceEqualizerProfile {
        var settings = EqualizerSettings.graphicFlat
        settings.bands[1].gainDb = bass
        return DeviceEqualizerProfile(uid: uid, displayName: "ExternalDisplay", settings: settings)
    }

    // MARK: - Store round trip

    func test_round_trip_through_defaults() {
        let stored = [
            "uid-a": profile(uid: "uid-a", bass: -6),
            "uid-b": profile(uid: "uid-b", bass: 3.5),
        ]
        DeviceEqualizerStore.save(stored)
        let loaded = DeviceEqualizerStore.load()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded["uid-a"]?.settings.bands[1].gainDb, -6)
        XCTAssertEqual(loaded["uid-b"]?.settings.bands[1].gainDb, 3.5)
        XCTAssertEqual(loaded["uid-a"]?.displayName, "ExternalDisplay")
    }

    func test_saving_an_empty_map_clears_the_key() {
        DeviceEqualizerStore.save(["uid-a": profile(uid: "uid-a", bass: -6)])
        XCTAssertNotNil(UserDefaults.standard.data(forKey: storeKey))
        DeviceEqualizerStore.save([:])
        XCTAssertNil(UserDefaults.standard.data(forKey: storeKey))
    }

    func test_unreadable_data_is_ignored_rather_than_crashing() {
        XCTAssertTrue(DeviceEqualizerStore.decode(Data("not json".utf8)).isEmpty)
        XCTAssertTrue(DeviceEqualizerStore.decode(nil).isEmpty)
    }

    func test_sanitize_drops_empty_uids_duplicates_and_flat_curves() {
        let flat = DeviceEqualizerProfile(uid: "uid-flat", settings: .graphicFlat)
        let blank = profile(uid: "   ", bass: -6)
        let first = profile(uid: "uid-a", bass: -6)
        let duplicate = profile(uid: "uid-a", bass: 6)
        let sanitized = DeviceEqualizerStore.sanitize([flat, blank, first, duplicate])
        XCTAssertEqual(sanitized.map(\.uid), ["uid-a"])
        XCTAssertEqual(sanitized[0].settings.bands[1].gainDb, -6, "first record wins")
    }

    func test_sanitize_keeps_a_bypassed_curve() {
        var bypassed = profile(uid: "uid-a", bass: -6)
        bypassed.settings.bypassed = true
        let sanitized = DeviceEqualizerStore.sanitize([bypassed])
        XCTAssertEqual(sanitized.count, 1, "bypass must not lose the curve behind it")
        XCTAssertTrue(sanitized[0].settings.bypassed)
    }

    func test_out_of_range_and_non_finite_values_are_clamped_on_load() {
        var wild = EqualizerSettings.graphicFlat
        wild.trimDb = 99
        wild.bands[0].gainDb = -400
        wild.bands[2].gainDb = .infinity
        let sanitized = DeviceEqualizerStore.sanitize([
            DeviceEqualizerProfile(uid: "uid-a", settings: wild)
        ])
        XCTAssertEqual(sanitized.count, 1)
        let settings = sanitized[0].settings
        XCTAssertEqual(settings.trimDb, EqualizerLimits.trimRangeDb.upperBound)
        XCTAssertEqual(settings.bands[0].gainDb, EqualizerLimits.bandGainRangeDb.lowerBound)
        XCTAssertTrue(settings.bands.allSatisfy { $0.gainDb.isFinite })
    }

    func test_normalize_snaps_to_the_ui_step() {
        var offGrid = EqualizerSettings.graphicFlat
        offGrid.bands[3].gainDb = 2.26
        offGrid.trimDb = -1.1
        let normalized = DeviceEqualizerStore.normalize(offGrid)
        XCTAssertEqual(normalized.bands[3].gainDb, 2.5, accuracy: 1e-9)
        XCTAssertEqual(normalized.trimDb, -1.0, accuracy: 1e-9)
    }

    // MARK: - AppModel editing

    func test_edit_persists_under_the_core_audio_uid() {
        let model = AppModel()
        model.devices = [localDevice(id: "dev-1", uid: "uid-a")]
        model.setEqualizerBandGain(-6, bandIndex: 1, for: "dev-1")

        XCTAssertEqual(model.deviceEqualizers["uid-a"]?.settings.bands[1].gainDb, -6)
        XCTAssertEqual(DeviceEqualizerStore.load()["uid-a"]?.settings.bands[1].gainDb, -6)
    }

    /// The whole point of the feature: `Device.id` is minted fresh every
    /// process and every Bonjour reappearance, so the curve has to come back
    /// under a NEW id as long as the CoreAudio UID matches.
    func test_curve_survives_a_new_device_id_for_the_same_uid() {
        let first = AppModel()
        first.devices = [localDevice(id: "dev-1", uid: "uid-a")]
        first.setEqualizerBandGain(-6, bandIndex: 1, for: "dev-1")

        let relaunched = AppModel()
        relaunched.devices = [localDevice(id: "dev-99-fresh", uid: "uid-a")]
        XCTAssertEqual(
            relaunched.equalizerSettings(for: "dev-99-fresh").bands[1].gainDb, -6
        )
        XCTAssertTrue(relaunched.hasEqualizerCurve(for: "dev-99-fresh"))
    }

    /// The office monitor must never inherit the home monitor's curve.
    func test_a_different_uid_gets_no_curve() {
        let model = AppModel()
        model.devices = [
            localDevice(id: "dev-home", uid: "uid-home"),
            localDevice(id: "dev-office", uid: "uid-office", name: "Office display"),
        ]
        model.setEqualizerBandGain(-6, bandIndex: 1, for: "dev-home")
        XCTAssertFalse(model.hasEqualizerCurve(for: "dev-office"))
        XCTAssertTrue(model.equalizerSettings(for: "dev-office").isNeutral)
    }

    func test_reset_removes_the_stored_record() {
        let model = AppModel()
        model.devices = [localDevice(id: "dev-1", uid: "uid-a")]
        model.setEqualizerBandGain(-6, bandIndex: 1, for: "dev-1")
        XCTAssertNotNil(DeviceEqualizerStore.load()["uid-a"])

        model.resetEqualizer(for: "dev-1")
        XCTAssertNil(model.deviceEqualizers["uid-a"])
        XCTAssertTrue(DeviceEqualizerStore.load().isEmpty)
        XCTAssertFalse(model.hasEqualizerCurve(for: "dev-1"))
    }

    func test_bypass_keeps_the_curve() {
        let model = AppModel()
        model.devices = [localDevice(id: "dev-1", uid: "uid-a")]
        model.setEqualizerBandGain(-6, bandIndex: 1, for: "dev-1")
        model.setEqualizerBypassed(true, for: "dev-1")

        XCTAssertTrue(model.equalizerIsBypassed(for: "dev-1"))
        XCTAssertTrue(model.hasEqualizerCurve(for: "dev-1"))
        XCTAssertEqual(model.equalizerSettings(for: "dev-1").bands[1].gainDb, -6)
        XCTAssertEqual(DeviceEqualizerStore.load()["uid-a"]?.settings.bypassed, true)
    }

    func test_trim_is_stored_and_clamped() {
        let model = AppModel()
        model.devices = [localDevice(id: "dev-1", uid: "uid-a")]
        model.setEqualizerTrim(-99, for: "dev-1")
        XCTAssertEqual(
            model.equalizerSettings(for: "dev-1").trimDb,
            EqualizerLimits.trimRangeDb.lowerBound
        )
    }

    func test_edits_snap_to_the_half_db_step() {
        let model = AppModel()
        model.devices = [localDevice(id: "dev-1", uid: "uid-a")]
        model.setEqualizerBandGain(-3.26, bandIndex: 0, for: "dev-1")
        XCTAssertEqual(
            model.equalizerSettings(for: "dev-1").bands[0].gainDb, -3.5, accuracy: 1e-9
        )
    }

    func test_editing_an_airplay_receiver_is_refused() {
        let model = AppModel()
        model.devices = [airplayDevice(id: "ap-1")]
        model.setEqualizerBandGain(-6, bandIndex: 1, for: "ap-1")
        XCTAssertTrue(model.deviceEqualizers.isEmpty)
        XCTAssertNil(model.coreAudioUID(forDeviceID: "ap-1"))
    }

    func test_resetting_an_untouched_row_writes_nothing() {
        let model = AppModel()
        model.devices = [localDevice(id: "dev-1", uid: "uid-a")]
        model.resetEqualizer(for: "dev-1")
        XCTAssertNil(UserDefaults.standard.data(forKey: storeKey))
    }

    // MARK: - Availability

    func test_availability_requires_an_enabled_core_audio_output() {
        let model = AppModel()
        model.mode = .stereo
        model.devices = [
            localDevice(id: "dev-1", uid: "uid-a"),
            airplayDevice(id: "ap-1"),
        ]
        // Not enabled yet.
        XCTAssertFalse(model.equalizerIsAvailable(for: "dev-1"))

        model.routing["dev-1"] = DeviceRouting(deviceID: "dev-1", enabled: true)
        model.routing["ap-1"] = DeviceRouting(deviceID: "ap-1", enabled: true)
        // Only meaningful on the paths where we render the samples ourselves;
        // `selectedStereoOutputPath` is resolved once per process, so assert
        // the rule rather than a machine-dependent verdict.
        XCTAssertEqual(
            model.equalizerIsAvailable(for: "dev-1"),
            model.equalizerIsSupportedOnCurrentPath
        )
        XCTAssertFalse(
            model.equalizerIsAvailable(for: "ap-1"),
            "an AirPlay receiver's audio never passes through our render callback"
        )
    }

    /// Whole-home used to hide the control and explain itself. It no longer
    /// has to: each local output renders through its own `LocalAirPlayBridge`,
    /// which runs the same curve, so the control is live and there is nothing
    /// to apologise for.
    func test_whole_home_offers_the_control_on_a_local_output() {
        let model = AppModel()
        model.devices = [localDevice(id: "dev-1", uid: "uid-a")]
        model.routing["dev-1"] = DeviceRouting(deviceID: "dev-1", enabled: true)
        model.setEqualizerBandGain(-6, bandIndex: 1, for: "dev-1")

        model.mode = .wholeHome
        XCTAssertTrue(model.equalizerIsSupportedOnCurrentPath)
        XCTAssertTrue(model.equalizerIsAvailable(for: "dev-1"))
        XCTAssertNil(
            model.equalizerInactiveHint(for: "dev-1"),
            "the curve IS being applied in whole-home; saying otherwise is the bug"
        )
    }

    func test_no_hint_for_a_device_with_no_curve() {
        let model = AppModel()
        model.devices = [localDevice(id: "dev-1", uid: "uid-a")]
        model.mode = .wholeHome
        XCTAssertNil(model.equalizerInactiveHint(for: "dev-1"))
    }

    // MARK: - Labels

    func test_frequency_and_gain_labels() {
        XCTAssertEqual(AppModel.equalizerFrequencyLabel(31.5), "31.5")
        XCTAssertEqual(AppModel.equalizerFrequencyLabel(500), "500")
        XCTAssertEqual(AppModel.equalizerFrequencyLabel(1_000), "1k")
        XCTAssertEqual(AppModel.equalizerFrequencyLabel(16_000), "16k")
        XCTAssertEqual(AppModel.equalizerGainLabel(0), "0.0")
        XCTAssertEqual(AppModel.equalizerGainLabel(3), "+3.0")
        XCTAssertEqual(AppModel.equalizerGainLabel(-6.5), "−6.5")
    }

    func test_summary_reports_the_strongest_band() {
        let model = AppModel()
        model.devices = [localDevice(id: "dev-1", uid: "uid-a")]
        XCTAssertNil(model.equalizerSummary(for: "dev-1"))

        model.setEqualizerBandGain(-6, bandIndex: 1, for: "dev-1")   // 63 Hz
        model.setEqualizerBandGain(2, bandIndex: 5, for: "dev-1")    // 1 kHz
        let summary = model.equalizerSummary(for: "dev-1")
        XCTAssertEqual(summary, "63 −6.0")

        model.setEqualizerTrim(-3, for: "dev-1")
        XCTAssertEqual(model.equalizerSummary(for: "dev-1"), "63 −6.0 · 总量 −3.0")
    }
}
