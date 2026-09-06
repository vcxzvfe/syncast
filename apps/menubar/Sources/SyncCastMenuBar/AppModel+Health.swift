import Foundation

/// Periodic health logging.
///
/// The startup burst (`capture report @ 1/2/4/6s`) proves the engine came up.
/// It cannot prove the engine STAYS up, which is exactly the claim the low
/// ring floor needs: "no resyncs and no underruns in N minutes". So the 1 Hz
/// poller drops one diagnostic line every `healthLogIntervalSeconds` while the
/// engine is running, and the line carries `LocalOutput`'s glitch counters
/// (`resync` / `underrun` / `minWater`) beside the tick count. Counters that
/// do not move across a run ARE the evidence; a headless run is read by
/// diffing two of these lines.
@MainActor
extension AppModel {
    /// Seconds between periodic health lines. 30 s keeps a multi-hour session's
    /// log readable while still bounding how long a dropout can hide.
    static let healthLogIntervalSeconds = 30

    /// Consecutive seconds of "sink running, capture silent" before the hint
    /// is raised. Two blocks of a tap are 21 ms; four seconds is not a hiccup.
    static let captureStarvationSeconds = 4
    static let captureStarvationMessage =
        "未捕获到系统音频：请在 系统设置 → 隐私与安全性 → 屏幕与系统音频录制 中允许 SyncCast，然后重新勾选输出 · system audio capture is silent — allow SyncCast under Screen & System Audio Recording"

    func logPeriodicHealthIfDue() async {
        guard streamingState == .running else {
            // Reset so the first line after a start is a fresh interval rather
            // than whatever was left over from the previous session.
            healthLogTicks = 0
            captureProbeStalledSeconds = 0
            captureProbeLastTicks = 0
            if captureStarvationHint != nil { captureStarvationHint = nil }
            return
        }
        await probeCaptureStarvation()
        healthLogTicks += 1
        guard healthLogTicks >= AppModel.healthLogIntervalSeconds else { return }
        healthLogTicks = 0
        let report = await router.diagnosticCaptureReport()
        SyncCastLog.log("health @ \(AppModel.healthLogIntervalSeconds)s: \(report)")
    }

    /// The one failure macOS reports with silence: a Process Tap whose
    /// "System Audio Recording" permission was refused is created, never
    /// errors, and never fires. Detect it as "the sink device is running IO for
    /// some app, but our capture tick count has not moved for N seconds".
    private func probeCaptureStarvation() async {
        let health = await router.captureHealth()
        guard health.sinkPathActive else {
            captureProbeStalledSeconds = 0
            if captureStarvationHint != nil { captureStarvationHint = nil }
            captureProbeLastTicks = health.captureTicks
            return
        }
        let advanced = health.captureTicks != captureProbeLastTicks
        captureProbeLastTicks = health.captureTicks
        if advanced || health.sinkIsRunningSomewhere != true {
            captureProbeStalledSeconds = 0
            if captureStarvationHint != nil {
                captureStarvationHint = nil
                SyncCastLog.log("capture probe: capture is delivering again")
            }
            return
        }
        captureProbeStalledSeconds += 1
        if captureProbeStalledSeconds == AppModel.captureStarvationSeconds {
            SyncCastLog.log(
                "capture probe: sink has been running for \(captureProbeStalledSeconds)s with zero capture callbacks — System Audio Recording permission is most likely refused"
            )
            captureStarvationHint = AppModel.captureStarvationMessage
        }
    }
}
