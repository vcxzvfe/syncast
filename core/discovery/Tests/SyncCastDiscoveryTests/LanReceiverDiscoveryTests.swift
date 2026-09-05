import XCTest
@testable import SyncCastDiscovery

/// What the LAN browser makes of a receiver's Bonjour record.
///
/// TXT values come from an unauthenticated service on the network and go
/// straight into the UI, so every one of them is validated here rather than
/// trusted.
final class LanReceiverDiscoveryTests: XCTestCase {

    // MARK: - Discovery TXT handling

    func testAdvertisedNameWinsOverTheInstanceName() {
        let device = LanReceiverDiscovery.makeDevice(
            instanceName: "receiver-a",
            domain: "local.",
            txt: ["v": "1", "name": "Kitchen", "token": "3F2A1B0C", "rate": "48000"],
            id: "id"
        )
        XCTAssertEqual(device.name, "Kitchen")
        XCTAssertEqual(device.lanServiceName, "receiver-a", "identity is the instance name")
        XCTAssertEqual(device.lanTokenHint, "3f2a1b0c", "the hint is lower-cased")
        XCTAssertEqual(device.transport, .lanReceiver)
    }

    func testABlankAdvertisedNameFallsBackRatherThanRenderingEmpty() {
        let device = LanReceiverDiscovery.makeDevice(
            instanceName: "receiver-a", domain: nil, txt: ["name": "   "], id: "id"
        )
        XCTAssertEqual(device.name, "receiver-a")
    }

    func testAVersionMismatchIsShownRatherThanHidden() {
        let device = LanReceiverDiscovery.makeDevice(
            instanceName: "receiver-a", domain: nil, txt: ["v": "9"], id: "id"
        )
        XCTAssertEqual(device.model, "SyncCast receiver (protocol v9)")
    }

    func testAMalformedTokenHintIsDroppedNotRendered() {
        // The hint goes straight into the UI, and it comes from an
        // unauthenticated LAN service.
        for bad in ["", "zz", "not-hex!", "3f2a1b0", "3f2a1b0c9", "<script>"] {
            XCTAssertNil(
                LanReceiverDiscovery.sanitizedTokenHint(bad),
                "\"\(bad)\" should not have been accepted as a hint"
            )
        }
        XCTAssertEqual(LanReceiverDiscovery.sanitizedTokenHint(" DEADBEEF "), "deadbeef")
    }

}
