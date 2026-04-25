import XCTest
@testable import SyncCastDiscovery

final class DeviceTests: XCTestCase {
    func testDeviceCodableRoundTrip() throws {
        let dev = Device(
            id: "abc",
            transport: .airplay2,
            name: "Living Room",
            model: "AudioAccessory6,1",
            host: "192.168.1.42",
            port: 7000,
            coreAudioUID: nil,
            isOutputCapable: true,
            supportsHardwareVolume: true,
            nominalSampleRate: 44_100
        )
        let data = try JSONEncoder().encode(dev)
        let decoded = try JSONDecoder().decode(Device.self, from: data)
        XCTAssertEqual(dev, decoded)
    }

    func testStableIDMapIsStablePerKey() {
        let map = StableIDMap()
        let a = map.id(for: "ca:foo")
        let b = map.id(for: "ca:foo")
        let c = map.id(for: "ca:bar")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}
