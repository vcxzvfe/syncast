import XCTest
import SyncCastDiscovery
import SyncCastRouter
@testable import SyncCastMenuBar

@MainActor
final class DspProfileTests: XCTestCase {
    private let keys = [DspProfileStore.defaultsKey, DeviceEqualizerStore.defaultsKey,
                        DeviceStereoImageStore.defaultsKey, DeviceChannelMatrixStore.defaultsKey,
                        LocalDelayTrimStore.defaultsKey]

    override func setUp() { super.setUp(); keys.forEach { UserDefaults.standard.removeObject(forKey: $0) } }
    override func tearDown() { keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }; super.tearDown() }

    private func model() -> AppModel {
        let m = AppModel()
        m.devices = [
            Device(id: "d1", transport: .coreAudio, name: "Display", coreAudioUID: "uid-display"),
            Device(id: "lan", transport: .lanReceiver, name: "receiver-a", lanServiceName: "receiver-a"),
        ]
        return m
    }

    func test_save_apply_and_round_trip() {
        let m = model()
        m.setEqualizerBandGain(-4, bandIndex: 1, for: "d1")
        m.setChannelMatrixPreset(.right, for: "lan")
        m.setLocalDelayTrim(15, for: "lan")
        let a = m.saveCurrentDspProfile(named: "A")!
        XCTAssertEqual(m.activeDspProfileID, a.id, "the live state IS the profile just saved")

        // Change everything, save B, then go back to A.
        m.setEqualizerBandGain(3, bandIndex: 1, for: "d1")
        m.setChannelMatrixPreset(.mono, for: "lan")
        m.setLocalDelayTrim(0, for: "lan")
        XCTAssertNil(m.activeDspProfileID, "an edited state matches no profile")
        let b = m.saveCurrentDspProfile(named: "B")!
        XCTAssertEqual(m.activeDspProfileID, b.id)

        m.applyDspProfile(a)
        XCTAssertEqual(m.equalizerSettings(for: "d1").bands[1].gainDb, -4)
        XCTAssertEqual(m.channelMatrixSettings(for: "lan").preset, .right)
        XCTAssertEqual(m.localDelayTrimMs(for: "lan"), 15)
        XCTAssertEqual(m.activeDspProfileID, a.id)

        // Persisted: a fresh load sees both, and the per-setting stores hold A.
        let reloaded = DspProfileStore.load()
        XCTAssertEqual(reloaded.map(\.name), ["A", "B"])
        XCTAssertEqual(DeviceChannelMatrixStore.load()[Device.lanReceiverUID(serviceName: "receiver-a")!]?.settings.preset, .right)

        m.deleteDspProfile(b)
        XCTAssertEqual(DspProfileStore.load().map(\.name), ["A"])
    }

    /// A profile written to the defaults by something other than the app must
    /// survive the app's next save rather than being overwritten by its
    /// in-memory list.
    func test_externally_added_profiles_are_picked_up_and_kept() {
        let m = model()
        m.saveCurrentDspProfile(named: "A")
        var stored = DspProfileStore.load()
        stored.append(DspProfile(name: "外部", equalizers: [], stereoImages: [], channelMatrices: [], delayTrims: []))
        DspProfileStore.save(stored)
        XCTAssertEqual(m.dspProfiles.map(\.name), ["A"], "not seen yet")
        m.reloadDspProfilesFromStore()
        XCTAssertEqual(m.dspProfiles.map(\.name), ["A", "外部"])
        m.setEqualizerBandGain(2, bandIndex: 0, for: "d1")
        m.saveCurrentDspProfile(named: "B")
        XCTAssertEqual(DspProfileStore.load().map(\.name), ["A", "外部", "B"])
    }

    func test_default_names_are_numbered() {
        let name = DspProfileStore.defaultName(existing: [], now: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(name.hasPrefix("方案 1 · "), name)
    }
}
