import XCTest
@testable import SyncCastRouter

final class LanEndpointPlannerTests: XCTestCase {
    private let serviceName = LanReceiverEndpoint.bonjour(name: "receiver-a", domain: "local.")
    private let last = LanReceiverLastEndpoint(host: "192.0.2.10", port: 47_100)

    func testTheNameIsTriedFirstAndTheAddressEveryOtherAttempt() {
        let picks = (0..<4).map { LanEndpointPlanner.endpoint(primary: serviceName, fallback: last, attempt: $0) }
        XCTAssertEqual(picks, [serviceName, .hostPort(host: "192.0.2.10", port: 47_100),
                               serviceName, .hostPort(host: "192.0.2.10", port: 47_100)])
    }

    func testWithoutARememberedAddressOnlyTheNameIsUsed() {
        for attempt in 0..<4 {
            XCTAssertEqual(LanEndpointPlanner.endpoint(primary: serviceName, fallback: nil, attempt: attempt), serviceName)
        }
    }

    func testALiteralPrimaryIsNeverReplaced() {
        let literal = LanReceiverEndpoint.hostPort(host: "127.0.0.1", port: 9)
        XCTAssertEqual(LanEndpointPlanner.endpoint(primary: literal, fallback: last, attempt: 1), literal)
    }
}
