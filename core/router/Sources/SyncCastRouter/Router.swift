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
    private var audioWriter: AudioSocketWriter?

    /// Sockets used to talk to the Python sidecar. May be nil in unit tests
    /// or when running without AirPlay support.
    public struct SidecarSockets: Sendable {
        public let control: URL
        public let audio: URL
        public init(control: URL, audio: URL) {
            self.control = control
            self.audio = audio
        }
    }

    public init(sampleRate: Double = 48_000, channelCount: Int = 2) {
        self.capture = Capture(sampleRate: sampleRate, channelCount: channelCount)
        self.scheduler = Scheduler(sampleRate: sampleRate)
    }

    public func attachSidecar(_ sockets: SidecarSockets) async throws {
        let client = IpcClient(socketPath: sockets.control)
        try await client.connect { method, params in
            // Notifications from sidecar: parse device latency events to
            // re-plan. Other events are observed by the UI layer via a
            // separate subscription mechanism (TODO P3).
            if method == "event.measured_latency",
               let measured = params["measured_ms"] as? Int {
                Task { await self.updateAirplayLatency(measured) }
            }
        }
        _ = try await client.call("sidecar.hello", params: ["v": 1, "router_pid": ProcessInfo.processInfo.processIdentifier])
        self.ipc = client
        let writer = AudioSocketWriter(ring: capture.ringBuffer, socketPath: sockets.audio)
        self.audioWriter = writer
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
        audioWriter?.stop()
        audioWriter = nil
        if let ipc = ipc {
            _ = try? await ipc.call("stream.stop", params: [:])
            await ipc.close()
        }
        ipc = nil
        for (_, out) in localOutputs { out.stop() }
        localOutputs.removeAll()
        capture.stop()
        state = .idle
    }

    /// Notify the sidecar to begin streaming, then start the audio-socket
    /// writer that pumps PCM into the sidecar.
    public func beginAirplayStream(deviceIDs: [String]) async throws {
        guard let ipc, let audioWriter else {
            throw NSError(domain: "SyncCastRouter", code: 100, userInfo: [
                NSLocalizedDescriptionKey: "sidecar not attached"
            ])
        }
        let anchorNs = Clock.nowNs() + UInt64(measuredAirplayLatencyMs) * 1_000_000
        _ = try await ipc.call("stream.start", params: [
            "device_ids": deviceIDs,
            "anchor_time_ns": Int(anchorNs),
            "sample_rate": 48_000,
            "channels": 2,
            "format": "pcm_s16le",
        ])
        try audioWriter.start()
    }

    public func updateAirplayLatency(_ measuredMs: Int) {
        if abs(measuredMs - measuredAirplayLatencyMs) > 20 {
            measuredAirplayLatencyMs = measuredMs
            replan()
        }
    }

    /// Tell the sidecar about an AirPlay 2 device. Idempotent — re-adding
    /// the same device is a no-op on the sidecar side (returns
    /// `device_id already exists`, which we swallow).
    public func registerAirplayDevice(id: String, name: String, host: String, port: Int) async {
        guard let ipc else { return }
        do {
            _ = try await ipc.call("device.add", params: [
                "device_id": id,
                "transport": "airplay2",
                "host": host,
                "port": port,
                "name": name,
            ])
        } catch {
            // INVALID_PARAMS = already exists. Ignore.
        }
    }

    /// Set per-device volume for an AirPlay device on the sidecar.
    public func setAirplayVolume(id: String, volume: Float) async {
        guard let ipc else { return }
        _ = try? await ipc.call("device.set_volume", params: [
            "device_id": id,
            "volume": Double(volume),
        ])
    }

    /// Enabled AirPlay device IDs that should be in the active stream.
    /// Calling this with an empty list stops the AirPlay stream.
    public func setActiveAirplayDevices(_ ids: [String]) async {
        guard let ipc else { return }
        if ids.isEmpty {
            _ = try? await ipc.call("stream.stop", params: [:])
            audioWriter?.stop()
            return
        }
        // Anchor time = "now + master delay" so OwnTone can align.
        let anchor = Clock.nowNs() + UInt64(measuredAirplayLatencyMs) * 1_000_000
        do {
            _ = try await ipc.call("stream.start", params: [
                "device_ids": ids,
                "anchor_time_ns": Int(anchor),
                "sample_rate": 48_000,
                "channels": 2,
                "format": "pcm_s16le",
            ])
            try audioWriter?.start()
        } catch {
            lastError = "stream.start: \(error)"
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
