import XCTest
import CoreAudio
@testable import SyncCastRouter

/// The classification that keeps the sink path from wedging coreaudiod.
///
/// The HAL half (`isVirtualOutput(uid:)`) cannot be tested without the
/// machine's own devices, so what is pinned here is the rule it applies and
/// the message it produces — including the two exclusions that would each turn
/// this guard into a regression if they drifted.
final class VirtualOutputPolicyTests: XCTestCase {
    func testVirtualTransportIsRejected() {
        XCTAssertTrue(
            VirtualOutputPolicy.isVirtualTransport(kAudioDeviceTransportTypeVirtual)
        )
    }

    /// Real endpoints must all stay selectable. These are the transports the
    /// user's actual speakers report (built-in, the DisplayPort monitor, USB
    /// interfaces, Bluetooth headphones).
    func testRealTransportsAreAccepted() {
        let real: [UInt32] = [
            kAudioDeviceTransportTypeBuiltIn,
            kAudioDeviceTransportTypeUSB,
            kAudioDeviceTransportTypeHDMI,
            kAudioDeviceTransportTypeDisplayPort,
            kAudioDeviceTransportTypeThunderbolt,
            kAudioDeviceTransportTypeBluetooth,
            kAudioDeviceTransportTypeBluetoothLE,
            kAudioDeviceTransportTypeFireWire,
            kAudioDeviceTransportTypePCI,
            kAudioDeviceTransportTypeAirPlay,
            kAudioDeviceTransportTypeUnknown,
        ]
        for transport in real {
            XCTAssertFalse(
                VirtualOutputPolicy.isVirtualTransport(transport),
                "transport \(transport) must stay selectable"
            )
        }
    }

    /// An aggregate is a kernel-side composition of real endpoints, not a
    /// plug-in device, and Direct Stereo's own fan-out target is one. Folding
    /// it into this rule would break a working path.
    func testAggregateIsNotTreatedAsVirtual() {
        XCTAssertFalse(
            VirtualOutputPolicy.isVirtualTransport(kAudioDeviceTransportTypeAggregate)
        )
    }

    /// "The sink path failed" with no device name is what made the original
    /// 108 s stall take a second run to understand.
    func testRejectionMessageNamesEveryDevice() {
        let message = VirtualOutputPolicy.rejectionMessage(
            names: ["ZoomAudioDevice (ZoomAudioDevice)", "Teams (MSTeamsAudio)"]
        )
        XCTAssertTrue(message.contains("ZoomAudioDevice"))
        XCTAssertTrue(message.contains("MSTeamsAudio"))
        XCTAssertTrue(message.contains("SYNCAST_STEREO_PATH=direct"))
    }

    /// An unresolvable UID answers "not virtual": this gate removes a
    /// known-bad configuration, it is not a whitelist.
    func testUnknownUIDIsNotClassifiedAsVirtual() {
        VirtualOutputPolicy.resetCache()
        defer { VirtualOutputPolicy.resetCache() }
        XCTAssertFalse(
            VirtualOutputPolicy.isVirtualOutput(uid: "io.syncast.tests.no-such-device")
        )
    }
}
