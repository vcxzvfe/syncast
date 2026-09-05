import XCTest
import SyncCastDiscovery
import SyncCastRouter
@testable import SyncCastMenuBar

/// The UI model of the whole-home equalizer: which rows offer the control in
/// which mode, and how the AirPlay group curve is keyed, edited and
/// remembered.
///
/// Deliberately unit tests: no router, no CoreAudio, no sidecar. The DSP is
/// specified in the router package (`WholeHomeEqualizerTests`).
@MainActor
final class WholeHomeEqualizerUITests: XCTestCase {
    private let storeKey = DeviceEqualizerStore.defaultsKey

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: storeKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: storeKey)
        super.tearDown()
    }

    private func localDevice(id: String, uid: String) -> Device {
        Device(id: id, transport: .coreAudio, name: "External display", coreAudioUID: uid)
    }

    private func airplayDevice(id: String) -> Device {
        Device(
            id: id, transport: .airplay2, name: "AirPlay receiver",
            host: "192.0.2.20", port: 7000, airplayDeviceID: "AABBCCDDEEFF"
        )
    }

    private func wholeHomeModel() -> AppModel {
        let model = AppModel()
        // `enabled: false` on every row on purpose: `setMode` ends in
        // `reconcileEngine()` and an enabled output would ask the real engine
        // to start. Mode is assigned directly for the same reason.
        model.mode = .wholeHome
        model.devices = [localDevice(id: "dev-1", uid: "uid-a"), airplayDevice(id: "ap-1")]
        model.routing["dev-1"] = DeviceRouting(deviceID: "dev-1", enabled: true)
        model.routing["ap-1"] = DeviceRouting(deviceID: "ap-1", enabled: true)
        return model
    }

    // MARK: - Which rows offer the control

    /// Local speakers get a per-device button in BOTH modes; an AirPlay
    /// receiver never does, because there is no per-receiver curve to give it.
    func test_local_rows_offer_the_control_in_whole_home_and_receivers_do_not() {
        let model = wholeHomeModel()
        XCTAssertTrue(model.equalizerIsAvailable(target: .device("dev-1")))
        XCTAssertFalse(
            model.equalizerIsAvailable(target: .device("ap-1")),
            "a receiver's samples are OwnTone's, not ours"
        )
    }

    func test_group_row_is_whole_home_only_and_needs_a_receiver() {
        let model = wholeHomeModel()
        XCTAssertTrue(model.airPlayGroupEqualizerIsAvailable)
        XCTAssertTrue(model.equalizerIsAvailable(target: .airPlayGroup))

        model.devices = [localDevice(id: "dev-1", uid: "uid-a")]
        XCTAssertFalse(
            model.airPlayGroupEqualizerIsAvailable,
            "no receivers, nothing for a group curve to shape"
        )

        model.devices = [localDevice(id: "dev-1", uid: "uid-a"), airplayDevice(id: "ap-1")]
        model.mode = .stereo
        XCTAssertFalse(
            model.airPlayGroupEqualizerIsAvailable,
            "in Local Stereo the receivers are not part of the output at all"
        )
    }

    /// One panel at a time, and the group is a peer of a device row rather than
    /// a second, independent open/closed state.
    func test_only_one_editor_is_open_at_a_time() {
        let model = wholeHomeModel()
        model.equalizerEditorTarget = .device("dev-1")
        XCTAssertNotEqual(model.equalizerEditorTarget, .airPlayGroup)
        model.equalizerEditorTarget = .airPlayGroup
        XCTAssertNotEqual(model.equalizerEditorTarget, .device("dev-1"))
    }

    // MARK: - The device curve is one curve across both modes

    /// The point of the whole track: a curve dialled in on the Stereo path is
    /// the same record the whole-home bridge is handed, with no second store
    /// and no re-entry.
    func test_a_curve_tuned_in_stereo_is_the_same_record_in_whole_home() {
        let model = AppModel()
        model.mode = .stereo
        model.devices = [localDevice(id: "dev-1", uid: "uid-a")]
        model.routing["dev-1"] = DeviceRouting(deviceID: "dev-1", enabled: true)
        model.setEqualizerBandGain(-6, bandIndex: 1, for: "dev-1")

        model.mode = .wholeHome
        XCTAssertEqual(model.equalizerSettings(for: "dev-1").bands[1].gainDb, -6)
        XCTAssertTrue(model.hasEqualizerCurve(target: .device("dev-1")))

        // And a fresh process reading the same defaults sees it too.
        let reloaded = DeviceEqualizerStore.load()
        XCTAssertEqual(reloaded["uid-a"]?.settings.bands[1].gainDb, -6)
    }

    // MARK: - The group curve

    func test_group_curve_is_keyed_by_the_reserved_pseudo_uid() {
        XCTAssertEqual(
            AppModel.airPlayGroupEqualizerUID, Router.airPlayGroupEqualizerUID
        )
        let model = wholeHomeModel()
        XCTAssertEqual(
            model.equalizerUID(for: .airPlayGroup), Router.airPlayGroupEqualizerUID
        )
        XCTAssertEqual(model.equalizerUID(for: .device("dev-1")), "uid-a")
        XCTAssertNil(
            model.equalizerUID(for: .device("ap-1")),
            "an AirPlay receiver has no CoreAudio UID and no curve of its own"
        )
    }

    /// Edited, persisted, reloaded — the group curve is remembered exactly
    /// like a device's, in the same versioned record.
    func test_group_curve_round_trips_through_the_device_store() {
        let model = wholeHomeModel()
        XCTAssertNil(model.equalizerSummary(target: .airPlayGroup))

        model.setEqualizerBandGain(4.5, bandIndex: 3, target: .airPlayGroup)
        model.setEqualizerTrim(-2, target: .airPlayGroup)

        let uid = Router.airPlayGroupEqualizerUID
        XCTAssertEqual(model.deviceEqualizers[uid]?.settings.bands[3].gainDb, 4.5)
        XCTAssertEqual(model.deviceEqualizers[uid]?.settings.trimDb, -2)
        XCTAssertTrue(model.hasEqualizerCurve(target: .airPlayGroup))
        XCTAssertNotNil(model.equalizerSummary(target: .airPlayGroup))
        // No device row inherits it.
        XCTAssertFalse(model.hasEqualizerCurve(target: .device("dev-1")))

        let reloaded = DeviceEqualizerStore.load()
        XCTAssertEqual(reloaded[uid]?.settings.bands[3].gainDb, 4.5)
        XCTAssertEqual(reloaded[uid]?.settings.trimDb, -2)
        XCTAssertEqual(reloaded[uid]?.displayName, AppModel.airPlayGroupEqualizerName)
    }

    func test_group_bypass_keeps_the_curve_and_reset_deletes_the_record() {
        let model = wholeHomeModel()
        model.setEqualizerBandGain(-3, bandIndex: 2, target: .airPlayGroup)

        model.setEqualizerBypassed(true, target: .airPlayGroup)
        XCTAssertTrue(model.equalizerIsBypassed(target: .airPlayGroup))
        XCTAssertTrue(
            model.hasEqualizerCurve(target: .airPlayGroup),
            "bypass is the A/B switch; losing the curve behind it defeats it"
        )
        XCTAssertEqual(
            model.equalizerSettings(target: .airPlayGroup).bands[2].gainDb, -3
        )

        model.resetEqualizer(target: .airPlayGroup)
        XCTAssertFalse(model.hasEqualizerCurve(target: .airPlayGroup))
        XCTAssertNil(model.deviceEqualizers[Router.airPlayGroupEqualizerUID])
        XCTAssertNil(
            UserDefaults.standard.data(forKey: storeKey),
            "an untouched group must leave no trace in the defaults"
        )
    }

    /// The group's limiter warning is keyed by the pseudo-UID like everything
    /// else, so a clipping AirPlay chain lights up the group row and not a
    /// speaker's.
    func test_group_clip_indicator_reads_the_pseudo_uid_counter() {
        let model = wholeHomeModel()
        XCTAssertFalse(model.airPlayGroupEqualizerIsClipping)
        model.equalizerClipCounts = [Router.airPlayGroupEqualizerUID: 12]
        XCTAssertTrue(model.airPlayGroupEqualizerIsClipping)
        XCTAssertTrue(model.equalizerIsClipping(target: .airPlayGroup))
        XCTAssertFalse(model.equalizerIsClipping(target: .device("dev-1")))
    }
}
