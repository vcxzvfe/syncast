import Foundation
import SyncCastDiscovery

/// The Scheduler is the brain of SyncCast's sync model.
///
/// Strategy ("pad-the-fast-path", per `docs/research/sync-brief.md`):
/// 1. Pick the slowest declared end-to-end delivery latency across all enabled
///    devices — typically the AirPlay 2 path, ~1.8s. Call this `T_master`.
/// 2. Each device's playback offset is `T_master − L_i + manualTrim_i`,
///    where `L_i` is that device's own latency.
/// 3. Capture frames at wall-clock t. Their target playback wall-clock is
///    `t + T_master`. Each consumer reads from the ring buffer at the offset
///    that yields its required pre-roll.
///
/// Drift (sample-rate slippage between AirPlay master and Mac local clock) is
/// handled by an outer slow PI loop that nudges the local AUHAL's read cursor
/// by ±1 sample once every ~30s.
public final class Scheduler {
    public struct DeviceLatency: Sendable, Hashable {
        public let deviceID: String
        public let transport: Transport
        public let measuredMs: Int      // most recent measured/declared latency
        public init(deviceID: String, transport: Transport, measuredMs: Int) {
            self.deviceID = deviceID
            self.transport = transport
            self.measuredMs = measuredMs
        }
    }

    public struct DevicePlan: Sendable, Hashable {
        public let deviceID: String
        public let transport: Transport
        /// Frames the consumer must lag behind the write cursor when reading.
        public let readBackoffFrames: Int
        public init(deviceID: String, transport: Transport, readBackoffFrames: Int) {
            self.deviceID = deviceID
            self.transport = transport
            self.readBackoffFrames = readBackoffFrames
        }
    }

    public let sampleRate: Double

    public init(sampleRate: Double = 48_000) {
        self.sampleRate = sampleRate
    }

    /// Compute per-device read-cursor offsets given current latencies.
    public func plan(
        latencies: [DeviceLatency],
        manualTrimMs: [String: Int] = [:],
        safetyMarginMs: Int = 50
    ) -> [DevicePlan] {
        guard !latencies.isEmpty else { return [] }
        let master = latencies.map(\.measuredMs).max()! + safetyMarginMs
        return latencies.map { dev in
            let trim = manualTrimMs[dev.deviceID] ?? 0
            let backoffMs = max(0, master - dev.measuredMs + trim)
            let backoffFrames = Int((Double(backoffMs) / 1000.0) * sampleRate)
            return DevicePlan(
                deviceID: dev.deviceID,
                transport: dev.transport,
                readBackoffFrames: backoffFrames
            )
        }
    }
}
