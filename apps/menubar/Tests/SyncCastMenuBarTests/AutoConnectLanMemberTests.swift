import XCTest
import SyncCastDiscovery
import SyncCastRouter
@testable import SyncCastMenuBar

/// "Arrive home → MacBook speakers + display + the LAN receiver": a rule may
/// list a LAN receiver as a member, keyed like every per-device store, and
/// the receiver being away never holds the rule back.
@MainActor
final class AutoConnectLanMemberTests: XCTestCase {
    private let displayUID = "display-uid"
    private let lanUID = "lan:receiver-a"

    private func devices() -> [Device] {
        [
            Device(id: "d1", transport: .coreAudio, name: "Display", coreAudioUID: displayUID),
            Device(id: "b1", transport: .coreAudio, name: "Built-in", coreAudioUID: AutoConnect.builtInSpeakerUID),
            Device(id: "l1", transport: .lanReceiver, name: "receiver-a", lanServiceName: "receiver-a"),
        ]
    }

    func testMemberKeysCoverCoreAudioAndLanButNotAirPlay() {
        let all = devices()
        XCTAssertEqual(AutoConnect.memberKey(for: all[0]), displayUID)
        XCTAssertEqual(AutoConnect.memberKey(for: all[2]), lanUID)
        let airplay = Device(id: "a1", transport: .airplay2, name: "Speaker",
                             host: "192.0.2.20", port: 7000, airplayDeviceID: "AABBCCDDEEFF")
        XCTAssertNil(AutoConnect.memberKey(for: airplay))
    }

    func testALanMemberIsOptionalForFiring() {
        let profile = AutoConnectProfile(
            triggerUID: displayUID,
            memberUIDs: [AutoConnect.builtInSpeakerUID, displayUID, lanUID]
        )
        XCTAssertEqual(profile.requiredUIDs, [AutoConnect.builtInSpeakerUID, displayUID],
                       "an asleep receiver must not stop the local outputs coming up")
        XCTAssertTrue(AutoConnect.isOptionalMember(lanUID))
        XCTAssertFalse(AutoConnect.isOptionalMember(displayUID))
    }

    func testCreatingARuleFromTheSelectionIncludesAnEnabledReceiver() {
        UserDefaults.standard.removeObject(forKey: AutoConnectProfileStore.defaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: AutoConnectProfileStore.defaultsKey) }
        let model = AppModel()
        model.mode = .stereo
        model.devices = devices()
        for id in ["d1", "b1", "l1"] { model.routing[id] = DeviceRouting(deviceID: id, enabled: true) }
        XCTAssertEqual(model.autoConnectEnabledUIDs(), [displayUID, AutoConnect.builtInSpeakerUID, lanUID])
        XCTAssertTrue(model.autoConnectPresentUIDs().isSuperset(of: [displayUID, lanUID]))
        model.autoConnectCreateProfile(triggerUID: displayUID)
        let rule = model.autoConnectProfile
        XCTAssertEqual(Set(rule?.memberUIDs ?? []), [displayUID, AutoConnect.builtInSpeakerUID, lanUID])
        XCTAssertEqual(rule?.displayName(for: lanUID), "receiver-a")
    }
}

/// Leaving keeps SyncCast on the laptop at a set level; arriving sets a level.
final class AutoConnectVolumeRuleTests: XCTestCase {
    func testOlderStoredRulesDecodeWithTheNewFieldsOff() throws {
        let json = #"[{"id":"00000000-0000-0000-0000-000000000001","enabled":true,"triggerUID":"d","memberUIDs":["d"],"onDisconnect":{"restoreBuiltIn":false},"displayNames":{}}]"#
        let rules = AutoConnectProfileStore.decode(Data(json.utf8))
        XCTAssertEqual(rules.count, 1)
        XCTAssertNil(rules[0].arriveSystemVolumePercent)
        XCTAssertFalse(rules[0].onDisconnect.keepsBuiltIn)
        XCTAssertNil(rules[0].onDisconnect.systemVolumePercent)
    }

    func testNewFieldsRoundTripAndClamp() throws {
        let rule = AutoConnectProfile(
            triggerUID: "d", memberUIDs: ["d", "lan:receiver-a"],
            onDisconnect: .init(restoreBuiltIn: false, builtInVolumePercent: nil,
                                keepBuiltInViaSyncCast: true, systemVolumePercent: -5),
            arriveSystemVolumePercent: 140
        )
        XCTAssertEqual(rule.arriveSystemVolumePercent, 100)
        XCTAssertEqual(rule.onDisconnect.systemVolumePercent, 0)
        let data = try XCTUnwrap(AutoConnectProfileStore.encode([rule]))
        let back = AutoConnectProfileStore.decode(data)
        XCTAssertEqual(back.first?.arriveSystemVolumePercent, 100)
        XCTAssertEqual(back.first?.onDisconnect.keepsBuiltIn, true)
        XCTAssertEqual(back.first?.onDisconnect.systemVolumePercent, 0)
    }
}
