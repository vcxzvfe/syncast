import XCTest
import SyncCastDiscovery
import SyncCastRouter
@testable import SyncCastMenuBar

/// Per-device stereo-image settings as `AppModel` and `DeviceStereoImageStore`
/// own them: the CoreAudio-UID keying that makes a setting come back on every
/// connect, the load-boundary validation, and the availability rules that
/// decide whether a row gets the control at all.
///
/// Deliberately unit tests: no router, no CoreAudio. The DSP is specified in
/// `StereoImageProcessorTests` over in the router package.
@MainActor
final class DeviceStereoImagePersistenceTests: XCTestCase {
    private let storeKey = DeviceStereoImageStore.defaultsKey

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
            id: id, transport: .airplay2, name: "Living-room receiver",
            host: "192.0.2.20", port: 7000, airplayDeviceID: "AABBCCDDEEFF"
        )
    }

    private func profile(uid: String, width: Double) -> DeviceStereoImageProfile {
        var settings = StereoImageSettings.neutral
        settings.width = StereoWidthSettings(enabled: true, width: width)
        return DeviceStereoImageProfile(
            uid: uid, displayName: "ExternalDisplay", settings: settings
        )
    }

    // MARK: - Store round trip

    func test_round_trip_through_defaults() {
        var crosstalkProfile = profile(uid: "uid-b", width: 1.0)
        crosstalkProfile.settings.width.enabled = false
        crosstalkProfile.settings.crosstalk = StereoCrosstalkSettings(
            enabled: true, attenuationDb: -3.5, strength: 0.8,
            spanMeters: 0.2, distanceMeters: 0.8, lowHz: 1_200, highHz: 6_000
        )
        DeviceStereoImageStore.save([
            "uid-a": profile(uid: "uid-a", width: 1.6),
            "uid-b": crosstalkProfile,
        ])
        let loaded = DeviceStereoImageStore.load()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded["uid-a"]?.settings.width.width, 1.6)
        XCTAssertEqual(loaded["uid-a"]?.displayName, "ExternalDisplay")
        let crosstalk = loaded["uid-b"]?.settings.crosstalk
        XCTAssertEqual(crosstalk?.attenuationDb, -3.5)
        XCTAssertEqual(crosstalk?.strength, 0.8)
        XCTAssertEqual(crosstalk?.spanMeters, 0.2)
        XCTAssertEqual(crosstalk?.distanceMeters, 0.8)
        XCTAssertEqual(crosstalk?.lowHz, 1_200)
        XCTAssertEqual(crosstalk?.highHz, 6_000)
    }

    func test_saving_an_empty_map_clears_the_key() {
        DeviceStereoImageStore.save(["uid-a": profile(uid: "uid-a", width: 1.6)])
        XCTAssertNotNil(UserDefaults.standard.data(forKey: storeKey))
        DeviceStereoImageStore.save([:])
        XCTAssertNil(UserDefaults.standard.data(forKey: storeKey))
    }

    func test_unreadable_data_is_ignored_rather_than_crashing() {
        XCTAssertTrue(DeviceStereoImageStore.decode(Data("not json".utf8)).isEmpty)
        XCTAssertTrue(DeviceStereoImageStore.decode(nil).isEmpty)
    }

    func test_sanitize_drops_empty_uids_duplicates_and_neutral_settings() {
        let neutral = DeviceStereoImageProfile(uid: "uid-neutral", settings: .neutral)
        let blank = profile(uid: "   ", width: 1.6)
        let first = profile(uid: "uid-a", width: 1.6)
        let duplicate = profile(uid: "uid-a", width: 0.5)
        let sanitized = DeviceStereoImageStore.sanitize([neutral, blank, first, duplicate])
        XCTAssertEqual(sanitized.map(\.uid), ["uid-a"])
        XCTAssertEqual(sanitized[0].settings.width.width, 1.6, "first record wins")
    }

    func test_sanitize_keeps_a_bypassed_setting() {
        var bypassed = profile(uid: "uid-a", width: 1.6)
        bypassed.settings.bypassed = true
        let sanitized = DeviceStereoImageStore.sanitize([bypassed])
        XCTAssertEqual(sanitized.count, 1, "bypass must not lose the setting behind it")
        XCTAssertTrue(sanitized[0].settings.bypassed)
    }

    func test_out_of_range_and_non_finite_values_are_clamped_on_load() {
        var wild = StereoImageSettings.neutral
        wild.width = StereoWidthSettings(
            enabled: true, width: 12, cornerHz: .nan, midTrimDb: -99
        )
        wild.crosstalk = StereoCrosstalkSettings(
            enabled: true, attenuationDb: 40, strength: .infinity,
            spanMeters: 99, distanceMeters: -1, lowHz: 4_000, highHz: 2_100
        )
        let sanitized = DeviceStereoImageStore.sanitize([
            DeviceStereoImageProfile(uid: "uid-a", settings: wild)
        ])
        XCTAssertEqual(sanitized.count, 1)
        let settings = sanitized[0].settings
        XCTAssertEqual(settings.width.width, StereoImageLimits.widthRange.upperBound)
        XCTAssertEqual(settings.width.cornerHz, StereoImageLimits.defaultWidthCornerHz)
        XCTAssertEqual(settings.width.midTrimDb, StereoImageLimits.midTrimRangeDb.lowerBound)
        XCTAssertEqual(
            settings.crosstalk.attenuationDb, StereoImageLimits.attenuationRangeDb.upperBound
        )
        XCTAssertEqual(
            settings.crosstalk.strength, StereoImageLimits.defaultStrength, accuracy: 1e-9
        )
        XCTAssertEqual(settings.crosstalk.spanMeters, StereoImageLimits.spanRangeMeters.upperBound)
        XCTAssertEqual(
            settings.crosstalk.distanceMeters, StereoImageLimits.distanceRangeMeters.lowerBound
        )
        XCTAssertGreaterThan(settings.crosstalk.highHz, settings.crosstalk.lowHz)
        // The one that would be a runaway rather than merely wrong.
        XCTAssertLessThan(settings.crosstalk.feedbackAmplitude, 1)
    }

    func test_normalize_snaps_to_the_ui_steps() {
        var offGrid = StereoImageSettings.neutral
        offGrid.width = StereoWidthSettings(
            enabled: true, width: 1.437, cornerHz: 1_522, midTrimDb: -0.44
        )
        offGrid.crosstalk = StereoCrosstalkSettings(
            enabled: true, attenuationDb: -2.53, strength: 0.63,
            spanMeters: 0.172, distanceMeters: 0.66, lowHz: 1_540, highHz: 6_980
        )
        let normalized = DeviceStereoImageStore.normalize(offGrid)
        XCTAssertEqual(normalized.width.width, 1.45, accuracy: 1e-9)
        XCTAssertEqual(normalized.width.cornerHz, 1_500, accuracy: 1e-9)
        XCTAssertEqual(normalized.width.midTrimDb, -0.4, accuracy: 1e-9)
        XCTAssertEqual(normalized.crosstalk.attenuationDb, -2.5, accuracy: 1e-9)
        XCTAssertEqual(normalized.crosstalk.strength, 0.65, accuracy: 1e-9)
        XCTAssertEqual(normalized.crosstalk.spanMeters, 0.17, accuracy: 1e-9)
        XCTAssertEqual(normalized.crosstalk.distanceMeters, 0.65, accuracy: 1e-9)
        XCTAssertEqual(normalized.crosstalk.lowHz, 1_500, accuracy: 1e-9)
        XCTAssertEqual(normalized.crosstalk.highHz, 7_000, accuracy: 1e-9)
    }

    // MARK: - AppModel editing

    func test_edit_persists_under_the_core_audio_uid() {
        let model = AppModel()
        model.devices = [localDevice(id: "dev-1", uid: "uid-a")]
        model.setStereoWidthEnabled(true, for: "dev-1")
        model.setStereoWidth(1.6, for: "dev-1")

        XCTAssertEqual(model.deviceStereoImages["uid-a"]?.settings.width.width, 1.6)
        XCTAssertEqual(DeviceStereoImageStore.load()["uid-a"]?.settings.width.width, 1.6)
    }

    func test_setting_survives_a_new_device_id_for_the_same_uid() {
        let model = AppModel()
        model.devices = [localDevice(id: "dev-1", uid: "uid-a")]
        model.setStereoWidthEnabled(true, for: "dev-1")
        model.setStereoWidth(1.6, for: "dev-1")

        // `Device.id` is re-minted every process; the UID is not.
        let reopened = AppModel()
        reopened.devices = [localDevice(id: "dev-99", uid: "uid-a")]
        XCTAssertEqual(reopened.stereoImageSettings(for: "dev-99").width.width, 1.6)
        XCTAssertTrue(reopened.hasStereoImageSetting(for: "dev-99"))
    }

    func test_a_different_uid_gets_nothing() {
        let model = AppModel()
        model.devices = [localDevice(id: "dev-1", uid: "uid-a")]
        model.setStereoWidthEnabled(true, for: "dev-1")

        let other = AppModel()
        other.devices = [localDevice(id: "dev-1", uid: "uid-other")]
        XCTAssertFalse(other.hasStereoImageSetting(for: "dev-1"))
        XCTAssertTrue(other.stereoImageSettings(for: "dev-1").isNeutral)
    }

    func test_enabling_a_stage_moves_it_off_its_no_op_value() {
        // A switch that visibly turns on but changes nothing is the worst
        // possible first impression of the feature.
        let model = AppModel()
        model.devices = [localDevice(id: "dev-1", uid: "uid-a")]
        model.setStereoWidthEnabled(true, for: "dev-1")
        XCTAssertEqual(
            model.stereoImageSettings(for: "dev-1").width.width,
            StereoImageLimits.defaultWidth, accuracy: 1e-9
        )
        model.setStereoCrosstalkEnabled(true, for: "dev-1")
        XCTAssertEqual(
            model.stereoImageSettings(for: "dev-1").crosstalk.strength,
            StereoImageLimits.defaultStrength, accuracy: 1e-9
        )
        XCTAssertFalse(model.stereoImageSettings(for: "dev-1").isNeutral)
    }

    func test_reset_removes_the_stored_record() {
        let model = AppModel()
        model.devices = [localDevice(id: "dev-1", uid: "uid-a")]
        model.setStereoWidthEnabled(true, for: "dev-1")
        XCTAssertNotNil(UserDefaults.standard.data(forKey: storeKey))

        model.resetStereoImage(for: "dev-1")
        XCTAssertNil(model.deviceStereoImages["uid-a"])
        XCTAssertNil(UserDefaults.standard.data(forKey: storeKey))
    }

    func test_bypass_keeps_the_setting() {
        let model = AppModel()
        model.devices = [localDevice(id: "dev-1", uid: "uid-a")]
        model.setStereoWidthEnabled(true, for: "dev-1")
        model.setStereoWidth(1.8, for: "dev-1")
        model.setStereoImageBypassed(true, for: "dev-1")

        XCTAssertTrue(model.stereoImageIsBypassed(for: "dev-1"))
        XCTAssertEqual(model.stereoImageSettings(for: "dev-1").width.width, 1.8)
        XCTAssertTrue(model.hasStereoImageSetting(for: "dev-1"))
        XCTAssertEqual(DeviceStereoImageStore.load()["uid-a"]?.settings.width.width, 1.8)
    }

    func test_geometry_edits_move_the_derived_delay() {
        let model = AppModel()
        model.devices = [localDevice(id: "dev-1", uid: "uid-a")]
        model.setStereoCrosstalkEnabled(true, for: "dev-1")
        let before = model.stereoImageSettings(for: "dev-1").crosstalk.delaySeconds
        model.setStereoCrosstalkDistance(1.3, for: "dev-1")
        let after = model.stereoImageSettings(for: "dev-1").crosstalk.delaySeconds
        XCTAssertEqual(after, before / 2, accuracy: 1e-9, "twice the distance, half the delay")
    }

    func test_editing_an_airplay_receiver_is_refused() {
        let model = AppModel()
        model.devices = [airplayDevice(id: "ap-1")]
        model.setStereoWidthEnabled(true, for: "ap-1")
        XCTAssertTrue(model.deviceStereoImages.isEmpty)
        XCTAssertNil(UserDefaults.standard.data(forKey: storeKey))
    }

    func test_resetting_an_untouched_row_writes_nothing() {
        let model = AppModel()
        model.devices = [localDevice(id: "dev-1", uid: "uid-a")]
        model.resetStereoImage(for: "dev-1")
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
        XCTAssertFalse(model.stereoImageIsAvailable(for: "dev-1"), "not enabled yet")

        model.routing["dev-1"] = DeviceRouting(deviceID: "dev-1", enabled: true)
        model.routing["ap-1"] = DeviceRouting(deviceID: "ap-1", enabled: true)
        // `selectedStereoOutputPath` is resolved once per process, so assert
        // the rule rather than a machine-dependent verdict.
        XCTAssertEqual(
            model.stereoImageIsAvailable(for: "dev-1"),
            model.stereoImageIsSupportedOnCurrentPath
        )
        XCTAssertFalse(
            model.stereoImageIsAvailable(for: "ap-1"),
            "an AirPlay receiver's audio never passes through our render callback"
        )
    }

    func test_whole_home_offers_the_control_on_a_local_output() {
        let model = AppModel()
        model.devices = [localDevice(id: "dev-1", uid: "uid-a")]
        model.routing["dev-1"] = DeviceRouting(deviceID: "dev-1", enabled: true)
        model.setStereoWidthEnabled(true, for: "dev-1")

        model.mode = .wholeHome
        XCTAssertTrue(model.stereoImageIsSupportedOnCurrentPath)
        XCTAssertTrue(model.stereoImageIsAvailable(for: "dev-1"))
        XCTAssertNil(
            model.stereoImageInactiveHint(for: "dev-1"),
            "the setting IS applied in whole-home; saying otherwise is the bug"
        )
    }

    func test_no_hint_for_a_device_with_no_setting() {
        let model = AppModel()
        model.devices = [localDevice(id: "dev-1", uid: "uid-a")]
        XCTAssertNil(model.stereoImageInactiveHint(for: "dev-1"))
    }

    // MARK: - Labels

    func test_labels() {
        XCTAssertEqual(AppModel.stereoImageWidthLabel(1.4), "1.40×")
        XCTAssertEqual(AppModel.stereoImagePercentLabel(0.6), "60%")
        XCTAssertEqual(AppModel.stereoImageDecibelLabel(-2.5), "−2.5 dB")
        XCTAssertEqual(AppModel.stereoImageCentimetreLabel(0.65), "65 cm")
        XCTAssertEqual(AppModel.stereoImageHertzLabel(1_500), "1.5 kHz")
        XCTAssertEqual(AppModel.stereoImageHertzLabel(300), "300 Hz")
    }

    func test_delay_label_reports_the_derived_tau() {
        let crosstalk = StereoCrosstalkSettings(enabled: true)
        let label = AppModel.stereoImageDelayLabel(crosstalk)
        XCTAssertTrue(label.hasPrefix("计算延迟 114 µs"), label)
        XCTAssertTrue(label.contains("5.5 采样"), label)
    }

    func test_colouration_warning_appears_only_when_it_matters() {
        var gentle = StereoCrosstalkSettings(enabled: true)
        gentle.attenuationDb = -6
        gentle.strength = 0.1
        XCTAssertNil(
            AppModel.stereoImageColourationLabel(gentle),
            "a fraction of a dB is not worth a warning"
        )
        var strong = StereoCrosstalkSettings(enabled: true)
        strong.strength = 1
        let warning = AppModel.stereoImageColourationLabel(strong)
        XCTAssertNotNil(warning)
        XCTAssertTrue(warning?.contains("+12.0 dB") ?? false, warning ?? "nil")
    }

    func test_summary_reports_both_stages() {
        var settings = StereoImageSettings.neutral
        settings.width = StereoWidthSettings(enabled: true, width: 1.4)
        settings.crosstalk = StereoCrosstalkSettings(enabled: true, strength: 0.6)
        XCTAssertEqual(AppModel.stereoImageSummary(of: settings), "宽度 1.40× · 串扰 60%")
        settings.bypassed = true
        XCTAssertEqual(
            AppModel.stereoImageSummary(of: settings), "宽度 1.40× · 串扰 60% · 已旁路"
        )
        XCTAssertNil(AppModel.stereoImageSummary(of: .neutral))
    }
}
