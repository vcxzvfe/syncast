import CoreAudio
import Foundation
import SyncCastRouter

// TEMPORARY SHIM — remove on integration.
// `PassiveCalibrator` engine + `Router.startPassiveCalibration` /
// `stopPassiveCalibration` are owned by a parallel agent and don't
// exist yet. Once they land, the integrator should:
//   1. Delete this file.
//   2. Replace `BackgroundCalibrationSample` references in AppModel
//      with `PassiveCalibrator.Sample` (field-for-field identical).
// Until then, the shim's `start*` is a logged no-op so the AppModel
// reconciliation logic exercises end-to-end without the engine.

public struct BackgroundCalibrationSample: Sendable {
    public let measuredDelayMs: Int
    public let confidence: Double
    public let suggestedDelayMs: Int
    public let timestamp: Date
    public init(measuredDelayMs: Int, confidence: Double,
                suggestedDelayMs: Int, timestamp: Date) {
        self.measuredDelayMs = measuredDelayMs
        self.confidence = confidence
        self.suggestedDelayMs = suggestedDelayMs
        self.timestamp = timestamp
    }
}

extension Router {
    func startPassiveCalibration(
        intervalSeconds: Int, micID: AudioDeviceID?,
        onSample: @escaping @Sendable (BackgroundCalibrationSample) -> Void
    ) async {
        print("[ShimCalibrator] start interval=\(intervalSeconds)s mic=\(micID.map(String.init) ?? "default") (no-op)")
        _ = onSample
    }
    func stopPassiveCalibration() async { print("[ShimCalibrator] stop") }
}
