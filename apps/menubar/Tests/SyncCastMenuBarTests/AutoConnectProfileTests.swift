import XCTest
import SyncCastDiscovery
@testable import SyncCastMenuBar

/// The auto-connect rule is external data twice over: it comes back out of
/// `UserDefaults` (which any process can scribble on) and it decides where the
/// user's audio goes. These tests pin the behaviour that makes a corrupt or
/// half-written rule a no-op rather than a surprise route change.
final class AutoConnectProfileTests: XCTestCase {

    private let monitorUID = "00000000-0000-0000-0000-000000000001"

    private func local(_ uid: String, _ name: String) -> Device {
        Device(id: UUID().uuidString, transport: .coreAudio, name: name, coreAudioUID: uid)
    }

    // MARK: - Codec

    func testRoundTripPreservesEveryField() throws {
        let profile = AutoConnectProfile(
            enabled: true,
            triggerUID: monitorUID,
            memberUIDs: [AutoConnect.builtInSpeakerUID, monitorUID],
            onDisconnect: .init(restoreBuiltIn: true, builtInVolumePercent: 0),
            displayNames: [monitorUID: "ExternalDisplay", AutoConnect.builtInSpeakerUID: "MacBook Pro扬声器"]
        )
        let data = try XCTUnwrap(AutoConnectProfileStore.encode([profile]))
        let decoded = AutoConnectProfileStore.decode(data)
        XCTAssertEqual(decoded, [profile])
        XCTAssertEqual(decoded.first?.onDisconnect.builtInVolumePercent, 0)
        XCTAssertEqual(decoded.first?.triggerDisplayName, "ExternalDisplay")
    }

    func testNilVolumeSurvivesRoundTripAsNil() throws {
        let profile = AutoConnectProfile(
            triggerUID: monitorUID,
            memberUIDs: [monitorUID],
            onDisconnect: .init(restoreBuiltIn: true, builtInVolumePercent: nil)
        )
        let data = try XCTUnwrap(AutoConnectProfileStore.encode([profile]))
        XCTAssertNil(AutoConnectProfileStore.decode(data).first?.onDisconnect.builtInVolumePercent)
    }

    // MARK: - Malformed input

    func testMissingDataDecodesToNoRules() {
        XCTAssertEqual(AutoConnectProfileStore.decode(nil), [])
    }

    func testGarbageDataDecodesToNoRulesInsteadOfThrowing() {
        let garbage = Data([0x00, 0x01, 0xFF, 0xFE])
        XCTAssertEqual(AutoConnectProfileStore.decode(garbage), [])
    }

    func testWrongShapeJSONDecodesToNoRules() {
        let json = Data(#"{"enabled":true}"#.utf8)
        XCTAssertEqual(AutoConnectProfileStore.decode(json), [])
    }

    func testRuleWithoutMembersIsDropped() throws {
        let json = Data("""
        [{"id":"\(UUID().uuidString)","enabled":true,"triggerUID":"\(monitorUID)",
          "memberUIDs":[],"onDisconnect":{"restoreBuiltIn":false},"displayNames":{}}]
        """.utf8)
        XCTAssertEqual(AutoConnectProfileStore.decode(json), [])
    }

    func testRuleWithoutTriggerIsDropped() {
        let json = Data("""
        [{"id":"\(UUID().uuidString)","enabled":true,"triggerUID":"",
          "memberUIDs":["\(AutoConnect.builtInSpeakerUID)"],
          "onDisconnect":{"restoreBuiltIn":false},"displayNames":{}}]
        """.utf8)
        XCTAssertEqual(AutoConnectProfileStore.decode(json), [])
    }

    func testOutOfRangeVolumeIsClampedOnLoad() throws {
        let json = Data("""
        [{"id":"\(UUID().uuidString)","enabled":true,"triggerUID":"\(monitorUID)",
          "memberUIDs":["\(monitorUID)"],
          "onDisconnect":{"restoreBuiltIn":true,"builtInVolumePercent":900},
          "displayNames":{}}]
        """.utf8)
        let decoded = AutoConnectProfileStore.decode(json)
        XCTAssertEqual(decoded.first?.onDisconnect.builtInVolumePercent, 100)
    }

    func testDuplicateMemberUIDsAreCollapsedOnLoad() {
        let json = Data("""
        [{"id":"\(UUID().uuidString)","enabled":true,"triggerUID":"\(monitorUID)",
          "memberUIDs":["\(monitorUID)","\(monitorUID)","\(AutoConnect.builtInSpeakerUID)"],
          "onDisconnect":{"restoreBuiltIn":false},"displayNames":{}}]
        """.utf8)
        XCTAssertEqual(
            AutoConnectProfileStore.decode(json).first?.memberUIDs,
            [monitorUID, AutoConnect.builtInSpeakerUID]
        )
    }

    func testDuplicateRuleIDsAreDroppedSoEpisodeStateStaysUnambiguous() {
        let shared = UUID()
        let a = AutoConnectProfile(id: shared, triggerUID: monitorUID, memberUIDs: [monitorUID])
        let b = AutoConnectProfile(id: shared, triggerUID: "other", memberUIDs: ["other"])
        XCTAssertEqual(AutoConnectProfileStore.sanitize([a, b]), [a])
    }

    // MARK: - Store round trip through UserDefaults

    func testSaveThenLoadUsesTheVersionedKey() throws {
        let suiteName = "syncast.tests.autoconnect.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        let profile = AutoConnectProfile(triggerUID: monitorUID, memberUIDs: [monitorUID])
        AutoConnectProfileStore.save([profile], defaults: suite)
        XCTAssertNotNil(suite.data(forKey: AutoConnectProfileStore.defaultsKey))
        XCTAssertEqual(AutoConnectProfileStore.load(defaults: suite), [profile])
    }

    func testSavingAnEmptyListClearsTheKey() throws {
        let suiteName = "syncast.tests.autoconnect.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        AutoConnectProfileStore.save(
            [AutoConnectProfile(triggerUID: monitorUID, memberUIDs: [monitorUID])],
            defaults: suite
        )
        AutoConnectProfileStore.save([], defaults: suite)
        XCTAssertNil(suite.data(forKey: AutoConnectProfileStore.defaultsKey))
        XCTAssertEqual(AutoConnectProfileStore.load(defaults: suite), [])
    }

    // MARK: - Helpers

    func testHardwareScalarIsLinearSoZeroPercentIsSilence() {
        XCTAssertEqual(AutoConnect.hardwareScalar(forPercent: 0), 0)
        XCTAssertEqual(AutoConnect.hardwareScalar(forPercent: 50), 0.5, accuracy: 0.0001)
        XCTAssertEqual(AutoConnect.hardwareScalar(forPercent: 100), 1)
        XCTAssertEqual(AutoConnect.hardwareScalar(forPercent: -20), 0)
    }

    func testBuiltInLookupPrefersTheExactUID() {
        let devices = [
            local("BuiltInHeadphoneDevice", "耳机"),
            local(AutoConnect.builtInSpeakerUID, "MacBook Pro扬声器"),
            local(monitorUID, "ExternalDisplay"),
        ]
        XCTAssertEqual(AutoConnect.builtInOutputUID(in: devices), AutoConnect.builtInSpeakerUID)
    }

    func testBuiltInLookupFallsBackToPrefixThenName() {
        XCTAssertEqual(
            AutoConnect.builtInOutputUID(in: [local("BuiltInSomethingElse", "内建")]),
            "BuiltInSomethingElse"
        )
        XCTAssertEqual(
            AutoConnect.builtInOutputUID(in: [local("weird-uid", "MacBook Pro扬声器")]),
            "weird-uid"
        )
    }

    func testBuiltInLookupIgnoresAirPlayReceivers() {
        let airplay = Device(
            id: UUID().uuidString,
            transport: .airplay2,
            name: "MacBook Pro Speakers",
            airplayDeviceID: "AA:BB:CC:DD:EE:FF"
        )
        XCTAssertNil(AutoConnect.builtInOutputUID(in: [airplay, local(monitorUID, "ExternalDisplay")]))
    }
}
