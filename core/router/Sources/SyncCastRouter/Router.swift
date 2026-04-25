import Foundation
import CoreAudio
import SyncCastDiscovery

/// The Router is the top-level coordinator: it owns the capture, the ring
/// buffer, the local outputs, and the IPC client to the sidecar. The view
/// layer talks to this actor; CoreAudio threads talk to its members directly.
public actor Router {
    public enum RouterState: String, Sendable {
        case idle
        case starting
        case running
        case stopping
        case error
    }

    public private(set) var state: RouterState = .idle
    public private(set) var lastError: String?

    private let capture: Capture
    private let scheduler: Scheduler
    private var localOutputs: [String: LocalOutput] = [:]   // SyncCast device ID → AUHAL
    private var routing: [String: DeviceRouting] = [:]
    private var measuredAirplayLatencyMs: Int = 1800
    private var ipc: IpcClient?

    public init(sampleRate: Double = 48_000, channelCount: Int = 2) {
        self.capture = Capture(sampleRate: sampleRate, channelCount: channelCount)
        self.scheduler = Scheduler(sampleRate: sampleRate)
    }

    public func setRouting(_ r: DeviceRouting) {
        routing[r.deviceID] = r
        replan()
    }

    public func disable(deviceID: String) {
        var r = routing[deviceID] ?? DeviceRouting(deviceID: deviceID)
        r.enabled = false
        routing[deviceID] = r
        replan()
    }

    public func enable(deviceID: String) {
        var r = routing[deviceID] ?? DeviceRouting(deviceID: deviceID)
        r.enabled = true
        routing[deviceID] = r
        replan()
    }

    public func start(blackHoleUID: String, devices: [Device]) async throws {
        state = .starting
        do {
            try capture.start(uid: blackHoleUID)
            for dev in devices where dev.transport == .coreAudio && (routing[dev.id]?.enabled ?? true) {
                guard let uid = dev.coreAudioUID else { continue }
                let coreAudioID = (try? Capture.deviceID(forUID: uid)) ?? 0
                if coreAudioID == 0 { continue }
                let out = LocalOutput(
                    deviceID: coreAudioID,
                    deviceUID: uid,
                    ring: capture.ringBuffer,
                    sampleRate: capture.sampleRate,
                    channelCount: capture.channelCount
                )
                try out.start()
                localOutputs[dev.id] = out
            }
            replan()
            state = .running
        } catch {
            state = .error
            lastError = "\(error)"
            throw error
        }
    }

    public func stop() async {
        state = .stopping
        for (_, out) in localOutputs { out.stop() }
        localOutputs.removeAll()
        capture.stop()
        state = .idle
    }

    public func updateAirplayLatency(_ measuredMs: Int) {
        if abs(measuredMs - measuredAirplayLatencyMs) > 20 {
            measuredAirplayLatencyMs = measuredMs
            replan()
        }
    }

    private func replan() {
        var latencies: [Scheduler.DeviceLatency] = []
        for (id, _) in localOutputs {
            latencies.append(.init(deviceID: id, transport: .coreAudio, measuredMs: 12))
        }
        for (id, r) in routing where r.enabled && localOutputs[id] == nil {
            latencies.append(.init(deviceID: id, transport: .airplay2, measuredMs: measuredAirplayLatencyMs))
        }
        let trims = Dictionary(uniqueKeysWithValues: routing.compactMapValues { $0.manualDelayMs }
            .map { ($0.key, $0.value) })
        let plans = scheduler.plan(latencies: latencies, manualTrimMs: trims)
        for plan in plans {
            guard let out = localOutputs[plan.deviceID] else { continue }
            let r = routing[plan.deviceID] ?? DeviceRouting(deviceID: plan.deviceID)
            out.setRouting(
                readBackoffFrames: plan.readBackoffFrames,
                gain: r.volume,
                muted: r.muted
            )
        }
    }
}
