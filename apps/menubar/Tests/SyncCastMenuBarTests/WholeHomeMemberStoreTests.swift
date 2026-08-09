import XCTest
import SyncCastDiscovery
@testable import SyncCastMenuBar

/// The behaviour these tests pin down is the one that makes the unified clock
/// domain usable on a laptop that moves: selections are stored as CoreAudio
/// UIDs, a device that is not here right now is remembered rather than
/// forgotten, and an empty resolution is visible instead of silent.
final class WholeHomeMemberStoreTests: XCTestCase {

    private func local(_ uid: String, _ name: String) -> Device {
        Device(
            id: UUID().uuidString,
            transport: .coreAudio,
            name: name,
            coreAudioUID: uid
        )
    }

    func testPresentUIDsKeepsOnlyConnectedDevicesInUserOrder() {
        let selected = ["office-display", "builtin", "home-display"]
        let available = [local("builtin", "MacBook Pro Speakers"),
                         local("home-display", "Home Monitor")]

        XCTAssertEqual(
            WholeHomeMemberStore.presentUIDs(selectedUIDs: selected, available: available),
            ["builtin", "home-display"]
        )
    }

    func testAbsentSelectionIsStillListedSoItIsNotSilentlyForgotten() {
        let selected = ["office-display", "builtin"]
        let available = [local("builtin", "MacBook Pro Speakers")]

        let entries = WholeHomeMemberStore.entries(
            selectedUIDs: selected, available: available
        )
        let office = entries.first { $0.uid == "office-display" }

        XCTAssertNotNil(office)
        XCTAssertFalse(office?.isConnected ?? true)
        XCTAssertTrue(office?.isSelected ?? false)
        XCTAssertNil(office?.name)
    }

    func testUnselectedConnectedDevicesAppearAsAvailableChoices() {
        let entries = WholeHomeMemberStore.entries(
            selectedUIDs: ["builtin"],
            available: [local("builtin", "Speakers"), local("hdmi", "Monitor")]
        )
        let monitor = entries.first { $0.uid == "hdmi" }

        XCTAssertEqual(monitor?.name, "Monitor")
        XCTAssertTrue(monitor?.isConnected ?? false)
        XCTAssertFalse(monitor?.isSelected ?? true)
    }

    func testTogglingPreservesOrderAndAppendsNewSelections() {
        var selection = ["a", "b"]
        selection = WholeHomeMemberStore.toggling("c", in: selection)
        XCTAssertEqual(selection, ["a", "b", "c"])
        selection = WholeHomeMemberStore.toggling("b", in: selection)
        XCTAssertEqual(selection, ["a", "c"])
    }

    func testFallbackSelectionUsesTheSystemDefaultWhenItIsAvailable() {
        let available = [local("builtin", "Speakers")]
        XCTAssertEqual(
            WholeHomeMemberStore.fallbackSelection(
                available: available, systemDefaultUID: "builtin"
            ),
            ["builtin"]
        )
    }

    func testFallbackSelectionIsEmptyWhenTheDefaultIsNotAUsableLocalOutput() {
        XCTAssertTrue(
            WholeHomeMemberStore.fallbackSelection(
                available: [local("builtin", "Speakers")],
                systemDefaultUID: "some-airplay-thing"
            ).isEmpty
        )
    }

    func testSaveAndLoadRoundTripsThroughUserDefaults() {
        let suite = "io.syncast.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        WholeHomeMemberStore.save(["one", "two"], defaults: defaults)
        XCTAssertEqual(WholeHomeMemberStore.load(defaults: defaults), ["one", "two"])
    }


    // MARK: - Device identity

    func testAirplayDevicesPersistAgainstTheirDeviceIDNotTheirName() {
        let device = Device(
            id: "ephemeral-uuid",
            transport: .airplay2,
            name: "<this Mac's AirPlay Receiver>",
            airplayDeviceID: "0200CAFE0001"
        )
        XCTAssertEqual(device.persistenceKey, "ap:0200CAFE0001")
    }

    func testAirplayDeviceWithoutADeviceIDHasNoPersistenceKey() {
        let device = Device(id: "x", transport: .airplay2, name: "Someone's HomePod")
        XCTAssertNil(device.persistenceKey)
    }

    func testDeviceIDNormalizationAcceptsTheBonjourFormAndRejectsNonHex() {
        XCTAssertEqual(
            Device.normalizedAirplayDeviceID("02:00:CA:FE:00:01"), "0200CAFE0001"
        )
        XCTAssertEqual(
            Device.normalizedAirplayDeviceID("0200cafe0001"), "0200CAFE0001"
        )
        XCTAssertNil(Device.normalizedAirplayDeviceID("not-a-mac"))
        XCTAssertNil(Device.normalizedAirplayDeviceID(nil))
    }
}
