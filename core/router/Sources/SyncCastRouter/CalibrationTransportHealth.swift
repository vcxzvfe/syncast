import Foundation

struct CalibrationTransportSnapshot: Sendable {
    struct Writer: Sendable {
        let packetsSent: UInt64
        let underrunPackets: UInt64
        let partialSends: UInt64
        let lastError: String
        let overlaysScheduled: UInt64
        let overlayFramesScheduled: UInt64
        let overlayFramesMixed: UInt64
        let overlaysDroppedLate: UInt64
    }

    struct Bridge: Sendable {
        let packetsReceived: UInt64
        let renderTickCount: UInt64
        let driftResyncCount: UInt64
        let driftResyncReason: String
        let driftResyncFrameDelta: Int64
        let lastError: String
    }

    let writer: Writer?
    let bridges: [String: Bridge]
}

enum CalibrationTransportHealth {
    static func failures(
        before: CalibrationTransportSnapshot,
        after: CalibrationTransportSnapshot,
        requiresWriter: Bool,
        requiredBridgeIDs: Set<String>
    ) -> [String] {
        var failures: [String] = []
        if requiresWriter {
            guard let beforeWriter = before.writer,
                  let afterWriter = after.writer else {
                return ["AirPlay writer inactive"]
            }
            if afterWriter.packetsSent <= beforeWriter.packetsSent {
                failures.append("AirPlay writer sent no packets")
            }
            // Writer underruns mean the capture ring had no program-audio
            // frames and the writer emitted clock-preserving silence. During
            // active acoustic calibration the probe is mixed as an overlay
            // onto those packets, so underruns by themselves are not proof
            // that the AirPlay probe failed to travel. Treat actual transport
            // breakage (no packets, partial sends, or send errors) as fatal.
            if afterWriter.partialSends > beforeWriter.partialSends {
                failures.append(
                    "AirPlay writer partial send +\(afterWriter.partialSends - beforeWriter.partialSends)"
                )
            }
            if !afterWriter.lastError.isEmpty &&
                afterWriter.lastError != beforeWriter.lastError {
                failures.append("AirPlay writer error \(afterWriter.lastError)")
            }
            let scheduledDelta = delta(
                afterWriter.overlaysScheduled,
                beforeWriter.overlaysScheduled
            )
            let scheduledFrameDelta = delta(
                afterWriter.overlayFramesScheduled,
                beforeWriter.overlayFramesScheduled
            )
            let mixedFrameDelta = delta(
                afterWriter.overlayFramesMixed,
                beforeWriter.overlayFramesMixed
            )
            let droppedLateDelta = delta(
                afterWriter.overlaysDroppedLate,
                beforeWriter.overlaysDroppedLate
            )
            if scheduledDelta == 0 {
                failures.append("AirPlay writer scheduled no probe overlays")
            }
            if droppedLateDelta > 0 {
                failures.append("AirPlay writer dropped late probe overlays +\(droppedLateDelta)")
            }
            if scheduledFrameDelta > 0 &&
                Double(mixedFrameDelta) <
                    Double(scheduledFrameDelta) * 0.95 {
                failures.append(
                    "AirPlay writer mixed only \(mixedFrameDelta)/\(scheduledFrameDelta) probe frames"
                )
            }
        }

        for id in requiredBridgeIDs.sorted() {
            guard let beforeBridge = before.bridges[id],
                  let afterBridge = after.bridges[id] else {
                failures.append("local bridge \(id.prefix(8)) missing")
                continue
            }
            if afterBridge.renderTickCount <= beforeBridge.renderTickCount {
                failures.append("local bridge \(id.prefix(8)) rendered no ticks")
            }
            if afterBridge.packetsReceived <= beforeBridge.packetsReceived {
                failures.append("local bridge \(id.prefix(8)) received no packets")
            }
            if afterBridge.driftResyncCount > beforeBridge.driftResyncCount {
                let count = afterBridge.driftResyncCount - beforeBridge.driftResyncCount
                let reason = afterBridge.driftResyncReason
                if reason == "underrun" ||
                    count > 1 ||
                    afterBridge.driftResyncFrameDelta > 12_000 {
                    failures.append(
                        "local bridge \(id.prefix(8)) resynced +\(count) reason=\(reason) frames=\(afterBridge.driftResyncFrameDelta)"
                    )
                }
            }
            if !afterBridge.lastError.isEmpty &&
                afterBridge.lastError != beforeBridge.lastError {
                failures.append("local bridge \(id.prefix(8)) error \(afterBridge.lastError)")
            }
        }
        return failures
    }

    private static func delta(_ after: UInt64, _ before: UInt64) -> UInt64 {
        after >= before ? after - before : 0
    }
}
