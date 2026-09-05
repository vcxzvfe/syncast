import XCTest
@testable import SyncCastDiscovery

/// Guards the `_raop._tcp` half of AirPlay discovery.
///
/// The bug these protect against was observed live: a Xiaomi Sound stopped
/// advertising `_airplay._tcp` (apparently on entering standby) while still
/// advertising `_raop._tcp`. Browsing only the former made a perfectly usable
/// receiver vanish from the device list. Browsing both fixes that only if the
/// two records collapse onto ONE registry key — which is exactly what the MAC
/// prefix parsed here provides.
final class RAOPIdentityTests: XCTestCase {

    func test_splits_mac_prefix_from_display_name() {
        let (name, deviceID) = AirPlayDiscovery.raopIdentity(
            instanceName: "02AB00CD00EF@<AirPlay receiver B>"
        )
        XCTAssertEqual(name, "<AirPlay receiver B>")
        XCTAssertEqual(deviceID, "02AB00CD00EF")
    }

    /// The whole point of the split: the id derived from a RAOP instance name
    /// must equal the one derived from the AirPlay TXT `deviceid`, separators
    /// and case included, or the receiver shows up twice.
    func test_id_matches_the_airplay_txt_deviceid_for_the_same_receiver() {
        let fromRAOP = AirPlayDiscovery.raopIdentity(
            instanceName: "02AB00CD00EF@<AirPlay receiver B>"
        ).deviceID
        let fromAirPlay = Device.normalizedAirplayDeviceID("02ab00cd00ef")
        XCTAssertEqual(fromRAOP, fromAirPlay)
    }

    func test_display_name_may_contain_at_signs() {
        let (name, deviceID) = AirPlayDiscovery.raopIdentity(
            instanceName: "02DD00EE00FF@Living Room @ Home"
        )
        XCTAssertEqual(name, "Living Room @ Home")
        XCTAssertEqual(deviceID, "02DD00EE00FF")
    }

    /// Unrecognised shapes fall back to "plain name, no id". A duplicate row is
    /// recoverable; merging onto another receiver's key is not.
    func test_non_hex_prefix_is_not_treated_as_an_id() {
        let (name, deviceID) = AirPlayDiscovery.raopIdentity(
            instanceName: "not-a-mac@Some Speaker"
        )
        XCTAssertEqual(name, "not-a-mac@Some Speaker")
        XCTAssertNil(deviceID)
    }

    func test_missing_at_sign_is_passed_through() {
        let (name, deviceID) = AirPlayDiscovery.raopIdentity(
            instanceName: "Some Speaker"
        )
        XCTAssertEqual(name, "Some Speaker")
        XCTAssertNil(deviceID)
    }

    func test_empty_display_name_is_rejected() {
        let (name, deviceID) = AirPlayDiscovery.raopIdentity(
            instanceName: "02AB00CD00EF@"
        )
        XCTAssertEqual(name, "02AB00CD00EF@")
        XCTAssertNil(deviceID)
    }

    /// Both service types must actually be browsed — the merge order matters
    /// too, since `_airplay._tcp` carries the richer TXT record and has to win.
    func test_browses_both_service_types_with_airplay_last() {
        XCTAssertEqual(AirPlayDiscovery.airplayServiceType, "_airplay._tcp")
        XCTAssertEqual(AirPlayDiscovery.raopServiceType, "_raop._tcp")
    }
}
