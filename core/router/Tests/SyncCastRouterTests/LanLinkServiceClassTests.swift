import Network
import XCTest
@testable import SyncCastRouter

/// The LAN link's sockets must not be best-effort.
///
/// # Why these exist
///
/// On real hardware a Time Machine backup to the receiver's disk shared the
/// sender's Wi-Fi uplink. With both sockets at the default service class the
/// audio queued behind the backup: the receiver's p95 jitter went from 12 to
/// 58 ms and it dropped ~6 late packets a second. Pausing the backup brought
/// the ping spread from 8.2 ms back to 1.0 ms.
final class LanLinkServiceClassTests: XCTestCase {

    func testAudioDatagramsUseTheVoiceClass() {
        let parameters = LanReceiverLink.audioParameters()
        XCTAssertEqual(parameters.serviceClass, .interactiveVoice)
        XCTAssertEqual(LanReceiverLink.audioServiceClass, .interactiveVoice)
    }

    func testControlChannelUsesTheSignalingClass() {
        let parameters = LanReceiverLink.controlParameters()
        XCTAssertEqual(parameters.serviceClass, .signaling)
        XCTAssertEqual(LanReceiverLink.controlServiceClass, .signaling)
    }

    /// The factories replaced inline setup; the protocol and the peer-to-peer
    /// opt-out must survive the move. AWDL is the interface this link was
    /// built to avoid.
    func testFactoriesKeepProtocolAndStayOffPeerToPeer() {
        let audio = LanReceiverLink.audioParameters()
        let control = LanReceiverLink.controlParameters()
        XCTAssertFalse(audio.includePeerToPeer)
        XCTAssertFalse(control.includePeerToPeer)
        XCTAssertTrue(audio.defaultProtocolStack.transportProtocol is NWProtocolUDP.Options)
        XCTAssertTrue(control.defaultProtocolStack.transportProtocol is NWProtocolTCP.Options)
    }

    /// `NWParameters.udp` and `.tcp` are class properties that return a fresh
    /// object each time, so setting the class on one link cannot leak into
    /// another. Pinned because the opposite would silently re-class every
    /// UDP socket in the process.
    func testFactoriesReturnIndependentObjects() {
        let first = LanReceiverLink.audioParameters()
        let second = LanReceiverLink.audioParameters()
        XCTAssertFalse(first === second)
        XCTAssertEqual(NWParameters.udp.serviceClass, .bestEffort)
    }
}
