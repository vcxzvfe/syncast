import XCTest
@testable import SyncCastRouter

/// The two ways a LAN link can hang without anything failing, and what the
/// link must do about each.
///
/// # Why these exist
///
/// On real hardware the sender connected to a receiver whose Application
/// Firewall was blocking the daemon, and then logged nothing for ten minutes.
/// The kernel completes a TCP handshake before the firewall adjudicates, so
/// the connect reported success; the daemon never saw the connection, so no
/// `hello_ack` came back; and nothing in the link had a deadline. The row
/// showed dashes forever.
///
/// Both timeouts are injected at a fraction of their production values so
/// these run in about a second each. What is under test is the state machine,
/// not the size of the constants — those are asserted separately.
final class LanLinkTimeoutTests: XCTestCase {

    /// Short enough to keep the suite fast, long enough that a loaded runner
    /// cannot mistake scheduling delay for a timeout.
    private let shortTimeout: Double = 0.6

    private var receiver: FakeLanReceiver?
    private var link: LanReceiverLink?

    override func tearDown() {
        link?.stop()
        receiver?.stop()
        link = nil
        receiver = nil
        super.tearDown()
    }

    /// Poll `predicate` on the link's snapshot until it holds or time runs out.
    @discardableResult
    private func wait(
        upTo seconds: TimeInterval,
        on link: LanReceiverLink,
        for predicate: (LanLinkSnapshot) -> Bool
    ) -> LanLinkSnapshot {
        let deadline = Date().addingTimeInterval(seconds)
        var snapshot = link.snapshot
        while Date() < deadline {
            snapshot = link.snapshot
            if predicate(snapshot) { return snapshot }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return snapshot
    }

    // MARK: - The firewall case: accepted, then silent

    func testAReceiverThatAcceptsAndNeverAnswersFailsWithFirewallAdvice() throws {
        let fake = FakeLanReceiver(behaviour: .silent)
        try fake.start()
        receiver = fake
        let link = LanReceiverLink(
            receiverUID: "lan:silent-receiver",
            endpoint: .hostPort(host: "127.0.0.1", port: fake.controlPort),
            token: "cafef00d",
            senderName: "SyncCast",
            streamID: 1,
            targetMs: LanPcmWire.defaultTargetMs,
            connectTimeoutSeconds: 5,
            helloAckTimeoutSeconds: shortTimeout
        )
        self.link = link
        link.start()

        // It really did connect and really did send hello — this is not a
        // connect failure dressed up as a handshake failure.
        XCTAssertTrue(
            fake.wait(upTo: 5) { $0.helloToken == "cafef00d" },
            "the sender never got as far as hello"
        )
        let handshaking = wait(upTo: 2, on: link) { $0.stage == .handshaking }
        XCTAssertEqual(handshaking.stage, .handshaking)
        XCTAssertTrue(handshaking.isConnected)

        let failed = wait(upTo: 5, on: link) {
            $0.lastError == LanReceiverLink.helloAckTimeoutMessage
        }
        XCTAssertEqual(
            failed.lastError, LanReceiverLink.helloAckTimeoutMessage,
            "a receiver that accepts and goes silent must name the likely cause"
        )
        XCTAssertFalse(failed.isAudioReady)
        // And it must keep trying: the user may be answering the firewall
        // prompt right now.
        XCTAssertGreaterThanOrEqual(
            wait(upTo: 5, on: link) { $0.reconnectCount >= 1 }.reconnectCount, 1
        )
    }

    /// The message must name both plausible causes, because from the sender's
    /// side they are indistinguishable.
    func testTheHelloAckMessageNamesTheFirewallAndTheToken() {
        let message = LanReceiverLink.helloAckTimeoutMessage.lowercased()
        XCTAssertTrue(message.contains("firewall"), message)
        XCTAssertTrue(message.contains("token"), message)
    }

    // MARK: - The unreachable case: nothing ever accepts

    /// A link-local address on which nothing exists: the connect stays in
    /// `waiting` (ARP or route resolution never completes) rather than being
    /// refused, which is precisely the state Network framework will sit in
    /// forever if nothing bounds it.
    func testAnUnreachableReceiverIsTornDownAndRetried() {
        let link = LanReceiverLink(
            receiverUID: "lan:unreachable-receiver",
            endpoint: .hostPort(host: "169.254.213.7", port: 9),
            token: "cafef00d",
            senderName: "SyncCast",
            streamID: 2,
            targetMs: LanPcmWire.defaultTargetMs,
            connectTimeoutSeconds: shortTimeout,
            helloAckTimeoutSeconds: 5
        )
        self.link = link
        link.start()

        let failed = wait(upTo: 6, on: link) { $0.reconnectCount >= 1 }
        XCTAssertGreaterThanOrEqual(
            failed.reconnectCount, 1,
            "an unreachable receiver must be retried, not left waiting: \(failed)"
        )
        XCTAssertNotNil(failed.lastError, "the row must be able to say why")
        XCTAssertFalse(failed.isAudioReady)
        XCTAssertFalse(failed.isConnected)

        // Backoff, not a spin: the capped ladder starts at 0.5 s, so a second
        // of retrying cannot have produced a large attempt count.
        let later = wait(upTo: 1.5, on: link) { _ in false }
        XCTAssertLessThan(
            later.reconnectCount, 12,
            "reconnects are not backing off: \(later.reconnectCount) attempts"
        )
    }

    // MARK: - The healthy case must not be affected

    func testAHealthyLinkIsNotTimedOut() throws {
        let fake = FakeLanReceiver()
        try fake.start()
        receiver = fake
        let link = LanReceiverLink(
            receiverUID: "lan:healthy-receiver",
            endpoint: .hostPort(host: "127.0.0.1", port: fake.controlPort),
            token: fake.expectedToken,
            senderName: "SyncCast",
            streamID: 3,
            targetMs: LanPcmWire.defaultTargetMs,
            connectTimeoutSeconds: shortTimeout,
            helloAckTimeoutSeconds: shortTimeout
        )
        self.link = link
        link.start()

        let streaming = wait(upTo: 5, on: link) { $0.stage == .streaming }
        XCTAssertEqual(streaming.stage, .streaming, "the link never reached streaming")
        XCTAssertTrue(streaming.isAudioReady)
        XCTAssertNil(streaming.lastError)

        // Well past both (short) timeouts, it is still up and has not been
        // torn down by a timer that should have been cancelled.
        Thread.sleep(forTimeInterval: shortTimeout * 3)
        let still = link.snapshot
        XCTAssertEqual(still.stage, .streaming)
        XCTAssertEqual(still.reconnectCount, 0, "a healthy link was reconnected")
        XCTAssertNotNil(still.connectedForSeconds)
        XCTAssertGreaterThan(still.connectedForSeconds ?? 0, shortTimeout)
    }

    // MARK: - The production constants

    func testTheProductionTimeoutsAreTheOnesTheSpecCallsFor() {
        XCTAssertEqual(LanReceiverLink.connectTimeoutSeconds, 8)
        XCTAssertEqual(LanReceiverLink.helloAckTimeoutSeconds, 5)
        // The hello_ack deadline must be shorter than the connect deadline:
        // a stalled handshake is the more common fault and should be the one
        // the user hears about first.
        XCTAssertLessThan(
            LanReceiverLink.helloAckTimeoutSeconds,
            LanReceiverLink.connectTimeoutSeconds
        )
    }
}
