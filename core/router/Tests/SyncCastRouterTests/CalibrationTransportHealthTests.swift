import XCTest
@testable import SyncCastRouter

final class CalibrationTransportHealthTests: XCTestCase {
    func testHealthyFullCalibrationTransportHasNoFailures() {
        let before = snapshot(
            writer: .init(
                packetsSent: 10,
                underrunPackets: 0,
                partialSends: 0,
                lastError: "",
                overlaysScheduled: 0,
                overlayFramesScheduled: 0,
                overlayFramesMixed: 0,
                overlaysDroppedLate: 0
            ),
            bridge: .init(
                packetsReceived: 20,
                renderTickCount: 30,
                driftResyncCount: 0,
                lastError: ""
            )
        )
        let after = snapshot(
            writer: .init(
                packetsSent: 100,
                underrunPackets: 0,
                partialSends: 0,
                lastError: "",
                overlaysScheduled: 5,
                overlayFramesScheduled: 250_000,
                overlayFramesMixed: 250_000,
                overlaysDroppedLate: 0
            ),
            bridge: .init(
                packetsReceived: 110,
                renderTickCount: 130,
                driftResyncCount: 0,
                lastError: ""
            )
        )

        XCTAssertTrue(
            CalibrationTransportHealth.failures(
                before: before,
                after: after,
                requiresWriter: true,
                requiredBridgeIDs: ["display"]
            ).isEmpty
        )
    }

    func testMissingWriterFailsOnlyWhenAirPlayPhaseIsRequired() {
        let before = snapshot(writer: nil, bridge: advancingBridge())
        let after = snapshot(writer: nil, bridge: advancedBridge())

        XCTAssertEqual(
            CalibrationTransportHealth.failures(
                before: before,
                after: after,
                requiresWriter: true,
                requiredBridgeIDs: ["display"]
            ),
            ["AirPlay writer inactive"]
        )
        XCTAssertTrue(
            CalibrationTransportHealth.failures(
                before: before,
                after: after,
                requiresWriter: false,
                requiredBridgeIDs: ["display"]
            ).isEmpty
        )
    }

    func testWriterUnderrunAloneIsAllowedButPartialSendFails() {
        let before = snapshot(writer: stableWriter(), bridge: advancingBridge())
        let after = snapshot(
            writer: .init(
                packetsSent: 100,
                underrunPackets: 42,
                partialSends: 1,
                lastError: "",
                overlaysScheduled: 5,
                overlayFramesScheduled: 250_000,
                overlayFramesMixed: 250_000,
                overlaysDroppedLate: 0
            ),
            bridge: advancedBridge()
        )

        let failures = CalibrationTransportHealth.failures(
            before: before,
            after: after,
            requiresWriter: true,
            requiredBridgeIDs: ["display"]
        )

        XCTAssertTrue(failures.contains("AirPlay writer partial send +1"))
        XCTAssertFalse(failures.contains { $0.contains("underrun") })
    }

    func testBridgeResyncAndStalledCountersFail() {
        let before = snapshot(writer: stableWriter(), bridge: advancingBridge())
        let after = snapshot(
            writer: advancedWriter(),
            bridge: .init(
                packetsReceived: 20,
                renderTickCount: 30,
                driftResyncCount: 2,
                driftResyncReason: "underrun",
                driftResyncFrameDelta: 24_000,
                lastError: ""
            )
        )

        let failures = CalibrationTransportHealth.failures(
            before: before,
            after: after,
            requiresWriter: true,
            requiredBridgeIDs: ["display"]
        )

        XCTAssertTrue(failures.contains("local bridge display rendered no ticks"))
        XCTAssertTrue(failures.contains("local bridge display received no packets"))
        XCTAssertTrue(failures.contains("local bridge display resynced +2 reason=underrun frames=24000"))
    }

    func testSingleSmallOverrunResyncIsAllowed() {
        let before = snapshot(writer: stableWriter(), bridge: advancingBridge())
        let after = snapshot(
            writer: advancedWriter(),
            bridge: .init(
                packetsReceived: 120,
                renderTickCount: 130,
                driftResyncCount: 1,
                driftResyncReason: "overrun",
                driftResyncFrameDelta: 5_344,
                lastError: ""
            )
        )

        XCTAssertTrue(
            CalibrationTransportHealth.failures(
                before: before,
                after: after,
                requiresWriter: true,
                requiredBridgeIDs: ["display"]
            ).isEmpty
        )
    }

    private func snapshot(
        writer: CalibrationTransportSnapshot.Writer?,
        bridge: CalibrationTransportSnapshot.Bridge
    ) -> CalibrationTransportSnapshot {
        .init(writer: writer, bridges: ["display": bridge])
    }

    private func stableWriter() -> CalibrationTransportSnapshot.Writer {
        .init(
            packetsSent: 10,
            underrunPackets: 0,
            partialSends: 0,
            lastError: "",
            overlaysScheduled: 0,
            overlayFramesScheduled: 0,
            overlayFramesMixed: 0,
            overlaysDroppedLate: 0
        )
    }

    private func advancedWriter() -> CalibrationTransportSnapshot.Writer {
        .init(
            packetsSent: 100,
            underrunPackets: 0,
            partialSends: 0,
            lastError: "",
            overlaysScheduled: 5,
            overlayFramesScheduled: 250_000,
            overlayFramesMixed: 250_000,
            overlaysDroppedLate: 0
        )
    }

    private func advancingBridge() -> CalibrationTransportSnapshot.Bridge {
        .init(
            packetsReceived: 20,
            renderTickCount: 30,
            driftResyncCount: 0,
            driftResyncReason: "",
            driftResyncFrameDelta: 0,
            lastError: ""
        )
    }

    private func advancedBridge() -> CalibrationTransportSnapshot.Bridge {
        .init(
            packetsReceived: 120,
            renderTickCount: 130,
            driftResyncCount: 0,
            driftResyncReason: "",
            driftResyncFrameDelta: 0,
            lastError: ""
        )
    }
}
