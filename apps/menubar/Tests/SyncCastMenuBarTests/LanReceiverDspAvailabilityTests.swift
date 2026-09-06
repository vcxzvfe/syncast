import XCTest
import SyncCastDiscovery
import SyncCastRouter
@testable import SyncCastMenuBar

/// A LAN receiver runs the same equalizer → stereo image → channel matrix
/// chain as a local output (`LanReceiverOutput`), so its row gets the same
/// three controls. A field build showed only 声道: EQ and 声场 were gated on
/// the CoreAudio UID, which a LAN receiver does not have.
@MainActor
final class LanReceiverDspAvailabilityTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: DeviceEqualizerStore.defaultsKey)
        UserDefaults.standard.removeObject(forKey: DeviceStereoImageStore.defaultsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: DeviceEqualizerStore.defaultsKey)
        UserDefaults.standard.removeObject(forKey: DeviceStereoImageStore.defaultsKey)
        super.tearDown()
    }

    private func lanDevice(id: String = "lan-1", name: String = "receiver-a") -> Device {
        Device(id: id, transport: .lanReceiver, name: name, lanServiceName: name)
    }

    func test_lan_receiver_has_the_same_dsp_uid_as_its_channel_matrix() {
        let model = AppModel()
        model.devices = [lanDevice()]
        XCTAssertEqual(model.dspUID(forDeviceID: "lan-1"), model.channelMatrixUID(forDeviceID: "lan-1"))
        XCTAssertEqual(model.dspUID(forDeviceID: "lan-1"), Device.lanReceiverUID(serviceName: "receiver-a"))
        XCTAssertNil(model.coreAudioUID(forDeviceID: "lan-1"), "a LAN receiver is not a CoreAudio device")
    }

    func test_enabled_lan_receiver_offers_eq_and_stereo_image_like_a_local_output() {
        let model = AppModel()
        model.mode = .stereo
        model.devices = [lanDevice()]
        XCTAssertFalse(model.equalizerIsAvailable(for: "lan-1"), "disabled rows get no control")
        XCTAssertFalse(model.stereoImageIsAvailable(for: "lan-1"))

        model.routing["lan-1"] = DeviceRouting(deviceID: "lan-1", enabled: true)
        XCTAssertEqual(model.equalizerIsAvailable(for: "lan-1"), model.equalizerIsSupportedOnCurrentPath)
        XCTAssertEqual(model.stereoImageIsAvailable(for: "lan-1"), model.stereoImageIsSupportedOnCurrentPath)
        XCTAssertEqual(model.channelMatrixIsAvailable(for: "lan-1"), model.channelMatrixIsSupportedOnCurrentPath)
    }

    /// The editor writes through `EqualizerTarget`, a second UID lookup that
    /// also used to be CoreAudio-only: the sliders rendered but sat at 0.0.
    func test_editor_target_setters_reach_a_lan_receiver() {
        let model = AppModel()
        model.devices = [lanDevice()]
        model.setEqualizerBandGain(-3, bandIndex: 2, target: .device("lan-1"))
        model.setEqualizerTrim(-1.5, target: .device("lan-1"))
        let uid = Device.lanReceiverUID(serviceName: "receiver-a")!
        XCTAssertEqual(model.deviceEqualizers[uid]?.settings.bands[2].gainDb, -3)
        XCTAssertEqual(model.deviceEqualizers[uid]?.settings.trimDb, -1.5)
        XCTAssertEqual(model.equalizerSettings(for: "lan-1").bands[2].gainDb, -3)
    }

    /// The delay trim is the fourth control a LAN row shares with a local one;
    /// it is stored under the same UID the Router pushes to the LAN output,
    /// and it cannot go negative (a LAN leg can only be delayed).
    func test_lan_receiver_gets_a_delay_trim_that_cannot_go_negative() {
        UserDefaults.standard.removeObject(forKey: LocalDelayTrimStore.defaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: LocalDelayTrimStore.defaultsKey) }
        let model = AppModel()
        model.mode = .stereo
        model.devices = [lanDevice()]
        model.routing["lan-1"] = DeviceRouting(deviceID: "lan-1", enabled: true)
        XCTAssertEqual(model.localDelayTrimIsAvailable(for: "lan-1"), model.localDelayTrimIsSupportedOnCurrentPath)
        model.setLocalDelayTrim(12, for: "lan-1")
        XCTAssertEqual(model.localDelayTrimMs(for: "lan-1"), 12)
        let uid = Device.lanReceiverUID(serviceName: "receiver-a")!
        XCTAssertEqual(model.localDelayTrims[uid]?.delayMs, 12)
        model.setLocalDelayTrim(-20, for: "lan-1")
        XCTAssertEqual(model.localDelayTrimMs(for: "lan-1"), 0, "a LAN leg cannot be advanced")
    }

    func test_lan_receiver_curve_is_stored_under_its_service_uid() {
        let model = AppModel()
        model.devices = [lanDevice()]
        model.setEqualizerBandGain(-4, bandIndex: 1, for: "lan-1")
        let uid = Device.lanReceiverUID(serviceName: "receiver-a")!
        XCTAssertEqual(model.deviceEqualizers[uid]?.settings.bands[1].gainDb, -4)
        XCTAssertTrue(model.hasEqualizerCurve(for: "lan-1"))
    }
}
