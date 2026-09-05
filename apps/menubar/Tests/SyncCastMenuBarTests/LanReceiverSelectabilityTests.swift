import XCTest
import SyncCastDiscovery
import SyncCastRouter
@testable import SyncCastMenuBar

/// Where a LAN receiver may and may not be used, and how its token and target
/// are stored.
///
/// Named apart from `LocalReceiverSelectabilityTests`, which is about this
/// Mac's own AirPlay Receiver — a different thing with a confusingly similar
/// name.
@MainActor
final class LanReceiverStoreTests: XCTestCase {

    private func receiver(
        name: String = "receiver-a",
        tokenHint: String? = "3f2a1b0c"
    ) -> Device {
        Device(
            id: "lan-\(name)",
            transport: .lanReceiver,
            name: name,
            model: "SyncCast receiver",
            isOutputCapable: true,
            nominalSampleRate: 48_000,
            lanServiceName: name,
            lanServiceDomain: "local.",
            lanTokenHint: tokenHint
        )
    }

    // MARK: - Identity

    func testThePersistenceKeyIsTheNamespacedInstanceName() {
        XCTAssertEqual(receiver().persistenceKey, "lan:receiver-a")
    }

    func testAReceiverWithNoInstanceNameHasNoKey() {
        let anonymous = Device(
            id: "x", transport: .lanReceiver, name: "nameless", lanServiceName: nil
        )
        XCTAssertNil(anonymous.persistenceKey)
    }

    func testTheKeyCannotCollideWithACoreAudioOne() {
        // Both live in one key space in the Router's per-device stores.
        let coreAudio = Device(
            id: "y", transport: .coreAudio, name: "Speakers",
            coreAudioUID: "BuiltInSpeakerDevice"
        )
        XCTAssertEqual(coreAudio.persistenceKey, "ca:BuiltInSpeakerDevice")
        XCTAssertNotEqual(coreAudio.persistenceKey, receiver().persistenceKey)
    }

    // MARK: - Token store

    func testTokensAreTrimmedAndBoundedInLength() {
        XCTAssertEqual(LanReceiverTokenStore.sanitize("  cafef00d\n"), "cafef00d")
        XCTAssertNil(LanReceiverTokenStore.sanitize("   "))
        XCTAssertNil(
            LanReceiverTokenStore.sanitize(
                String(repeating: "a", count: LanReceiverTokenStore.maximumTokenLength + 1)
            )
        )
    }

    func testTheHintIsTheFirstEightCharactersLowerCased() {
        XCTAssertEqual(LanReceiverTokenStore.hint(for: "3F2A1B0Cdeadbeef"), "3f2a1b0c")
    }

    func testTheDaemonTokenShapeCheckIsAdvisory() {
        XCTAssertTrue(
            LanReceiverTokenStore.looksLikeADaemonToken("0123456789abcdef0123456789abcdef")
        )
        XCTAssertFalse(LanReceiverTokenStore.looksLikeADaemonToken("short"))
        XCTAssertFalse(LanReceiverTokenStore.looksLikeADaemonToken("not hex at all!!!!!!"))
    }

    func testTheTokenRoundTripsThroughTheKeychain() throws {
        // Opt-in: touching the login keychain from an ad-hoc xctest binary makes
        // macOS prompt for the keychain password on EVERY build. Run with
        // SYNCAST_KEYCHAIN_TESTS=1 to exercise the real keychain.
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["SYNCAST_KEYCHAIN_TESTS"] == "1",
            "keychain round-trip is opt-in (SYNCAST_KEYCHAIN_TESTS=1)"
        )
        // A test-only service name, so the suite never touches the real items.
        let service = "syncast.test.lanReceiverTokens.\(UUID().uuidString)"
        let uid = "lan:receiver-a"
        defer { LanReceiverTokenStore.remove(forUID: uid, service: service) }

        XCTAssertNil(LanReceiverTokenStore.token(forUID: uid, service: service))
        XCTAssertTrue(
            LanReceiverTokenStore.save("cafef00dcafef00d", forUID: uid, service: service)
        )
        XCTAssertEqual(
            LanReceiverTokenStore.token(forUID: uid, service: service), "cafef00dcafef00d"
        )
        // Replacing must update in place, not add a second item.
        XCTAssertTrue(
            LanReceiverTokenStore.save("0123456789abcdef", forUID: uid, service: service)
        )
        XCTAssertEqual(
            LanReceiverTokenStore.token(forUID: uid, service: service), "0123456789abcdef"
        )
        XCTAssertEqual(LanReceiverTokenStore.loadAll(service: service), [uid: "0123456789abcdef"])
        XCTAssertTrue(LanReceiverTokenStore.remove(forUID: uid, service: service))
        XCTAssertNil(LanReceiverTokenStore.token(forUID: uid, service: service))
    }

    func testSavingAnEmptyTokenClearsTheItem() throws {
        // Opt-in: touching the login keychain from an ad-hoc xctest binary makes
        // macOS prompt for the keychain password on EVERY build. Run with
        // SYNCAST_KEYCHAIN_TESTS=1 to exercise the real keychain.
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["SYNCAST_KEYCHAIN_TESTS"] == "1",
            "keychain round-trip is opt-in (SYNCAST_KEYCHAIN_TESTS=1)"
        )
        let service = "syncast.test.lanReceiverTokens.\(UUID().uuidString)"
        let uid = "lan:receiver-a"
        defer { LanReceiverTokenStore.remove(forUID: uid, service: service) }
        LanReceiverTokenStore.save("cafef00d", forUID: uid, service: service)
        XCTAssertTrue(LanReceiverTokenStore.save("   ", forUID: uid, service: service))
        XCTAssertNil(LanReceiverTokenStore.token(forUID: uid, service: service))
    }

    // MARK: - Target store

    func testTargetsAreClampedAndDefaultsAreNotStored() {
        let clean = LanReceiverTargetStore.sanitize([
            "lan:a": 5,
            "lan:b": 9_999,
            "lan:c": LanReceiverTargetStore.defaultTargetMs,
            "  ": 120,
        ])
        XCTAssertEqual(clean["lan:a"], LanReceiverTargetStore.rangeMs.lowerBound)
        XCTAssertEqual(clean["lan:b"], LanReceiverTargetStore.rangeMs.upperBound)
        XCTAssertNil(clean["lan:c"], "the default is absence, not a stored value")
        XCTAssertEqual(clean.count, 2)
    }

    func testTargetDecodingIgnoresJunkFromTheDefaultsPlist() {
        let decoded = LanReceiverTargetStore.decode([
            "lan:a": 120,
            "lan:b": "not a number",
            "lan:c": ["nested"],
        ])
        XCTAssertEqual(decoded, ["lan:a": 120])
        XCTAssertTrue(LanReceiverTargetStore.decode(nil).isEmpty)
    }

    func testTheStoresAgreeWithTheProtocolsRange() {
        // Two packages hold this range; a disagreement would clamp the slider
        // somewhere the receiver would not honour.
        XCTAssertEqual(LanReceiverTargetStore.defaultTargetMs, LanPcmWire.defaultTargetMs)
        XCTAssertEqual(LanReceiverTargetStore.rangeMs, LanPcmWire.targetRangeMs)
        XCTAssertEqual(LanReceiverTargetStore.stepMs, LanPcmWire.targetStepMs)
    }
}
