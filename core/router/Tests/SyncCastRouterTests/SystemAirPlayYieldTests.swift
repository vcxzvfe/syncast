import XCTest
@testable import SyncCastRouter

/// The sidecar's `event.system_airplay_yield` params, decoded the way the
/// router's notification handler decodes them.
final class SystemAirPlayYieldTests: XCTestCase {
    func testTimelyActivationDecodes() {
        let event = SystemAirPlayYield.fromWire([
            "kind": "activation",
            "endpoint": "Living Room",
            "features": ["BufferedAudio"],
            "previous_mode": "whole_home",
            "device_ids": ["dev-homepod"],
        ], sequence: 3)
        XCTAssertEqual(event, SystemAirPlayYield(
            sequence: 3,
            trigger: .activation,
            endpoint: "Living Room",
            previousMode: "whole_home",
            deviceIDs: ["dev-homepod"]
        ))
    }

    func testLateConflictKeepsItsTrigger() {
        let event = SystemAirPlayYield.fromWire(
            ["kind": "ptp_conflict", "endpoint": NSNull()], sequence: 1
        )
        XCTAssertEqual(event.trigger, .ptpConflict)
        XCTAssertNil(event.endpoint)
        XCTAssertEqual(event.deviceIDs, [])
    }

    func testUnknownKindStillCountsAsAHandOver() {
        let event = SystemAirPlayYield.fromWire(["kind": "something-new"], sequence: 1)
        XCTAssertEqual(event.trigger, .activation)
    }

    func testEmptyEndpointIsNil() {
        let event = SystemAirPlayYield.fromWire(["endpoint": ""], sequence: 1)
        XCTAssertNil(event.endpoint)
    }
}
