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

    func logPeriodicHealthIfDue() async {
        guard streamingState == .running else {
            // Reset so the first line after a start is a fresh interval rather
            // than whatever was left over from the previous session.
            healthLogTicks = 0
            return
        }
        healthLogTicks += 1
        guard healthLogTicks >= AppModel.healthLogIntervalSeconds else { return }
        healthLogTicks = 0
        let report = await router.diagnosticCaptureReport()
        SyncCastLog.log("health @ \(AppModel.healthLogIntervalSeconds)s: \(report)")
    }
}
