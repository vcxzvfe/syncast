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

    private let sckCapture: SCKCapture
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
        if #available(macOS 13.0, *) {
            self.sckCapture = SCKCapture(sampleRate: sampleRate, channelCount: channelCount)
        } else {
            // We require macOS 14 anyway; this branch never executes.
            fatalError("SyncCast requires macOS 13+")
        }
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
        let writer = AudioSocketWriter(ring: sckCapture.ringBuffer, socketPath: sockets.audio)
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

    public func start(devices: [Device]) async throws {
        state = .starting
        do {
            try await sckCapture.start()
            // Open AUHAL for every enabled local CoreAudio output. SCK
            // captures system audio at the OS level — we don't need to
            // skip a "capture device" the way we did with BlackHole.
            // Still skip aggregates and the system multi-output to avoid
            // routing audio into a sink that itself includes one of our
            // outputs (potential feedback / double-play).
            for dev in devices where dev.transport == .coreAudio && (routing[dev.id]?.enabled ?? false) {
                guard let uid = dev.coreAudioUID else { continue }
                let lower = dev.name.lowercased()
                if lower.contains("blackhole") || lower.contains("aggregate") ||
                   lower.contains("multi-output") || dev.name.contains("多输出") {
                    continue
                }
                let coreAudioID = (try? Capture.deviceID(forUID: uid)) ?? 0
                if coreAudioID == 0 { continue }
                let out = LocalOutput(
                    deviceID: coreAudioID,
                    deviceUID: uid,
                    ring: sckCapture.ringBuffer,
                    sampleRate: sckCapture.sampleRate,
                    channelCount: sckCapture.channelCount
                )
                try out.start()
                localOutputs[dev.id] = out
            }
            replan()
            state = .running
        } catch {
            state = .error
            lastError = "\(error)"
            for (_, out) in localOutputs { out.stop() }
            localOutputs.removeAll()
            sckCapture.stop()
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
        sckCapture.stop()
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

    /// Diagnostic: how many SCK audio sample buffers have been processed?
    /// Zero after a few seconds with system audio playing ⇒ Screen Recording
    /// permission denied or SCK stream silently failed.
    public func diagnosticTickCount() -> UInt64 {
        sckCapture.tickCount
    }

    /// Returns a one-line diagnostic snapshot of the SCK capture pipeline.
    public func diagnosticSCKReport() -> String {
        let s = sckCapture
        var renderInfo = ""
        for (id, out) in localOutputs {
            renderInfo += " render[\(id.prefix(6))]=ticks:\(out.renderTickCount) peak:\(String(format: "%.4f", out.lastRenderPeak))"
        }
        var awInfo = ""
        if let aw = audioWriter {
            awInfo = " airplayWriter=pkts:\(aw.packetsSent) bytes:\(aw.bytesSent) err:\(aw.lastSendError.isEmpty ? "none" : aw.lastSendError)"
        }
        return "seen=\(s.debugBuffersSeen) written=\(s.debugBuffersWritten) ticks=\(s.tickCount) peak=\(String(format: "%.4f", s.debugLastPeak))/\(String(format: "%.4f", s.debugMaxPeak)) readback=\(String(format: "%.4f", s.debugReadbackPeak))@\(s.debugReadbackPos) last=\(s.debugLastReason)\(renderInfo)\(awInfo)"
    }

    /// Reconcile the open AUHAL set against the current routing snapshot.
    /// Called whenever the user toggles a local device while the engine
    /// is already running — ensures LocalOutput is created for newly-
    /// enabled devices and torn down for newly-disabled ones.
    public func syncLocalOutputs(devices: [Device]) async {
        // Open AUHAL for newly-enabled local devices.
        for dev in devices where dev.transport == .coreAudio && (routing[dev.id]?.enabled ?? false) {
            if localOutputs[dev.id] != nil { continue }
            guard let uid = dev.coreAudioUID else { continue }
            let lower = dev.name.lowercased()
            if lower.contains("blackhole") || lower.contains("aggregate") ||
               lower.contains("multi-output") || dev.name.contains("多输出") {
                continue
            }
            let coreAudioID = (try? Capture.deviceID(forUID: uid)) ?? 0
            if coreAudioID == 0 { continue }
            let out = LocalOutput(
                deviceID: coreAudioID,
                deviceUID: uid,
                ring: sckCapture.ringBuffer,
                sampleRate: sckCapture.sampleRate,
                channelCount: sckCapture.channelCount
            )
            do {
                try out.start()
                localOutputs[dev.id] = out
            } catch {
                lastError = "open output \(dev.name) failed: \(error)"
            }
        }
        // Close AUHAL for newly-disabled local devices.
        for (id, out) in localOutputs {
            if !(routing[id]?.enabled ?? false) {
                out.stop()
                localOutputs.removeValue(forKey: id)
            }
        }
        replan()
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
        guard let ipc else {
            lastError = "ipc not attached, cannot register \(name)"
            return
        }
        do {
            _ = try await ipc.call("device.add", params: [
                "device_id": id,
                "transport": "airplay2",
                "host": host,
                "port": port,
                "name": name,
            ])
        } catch let IpcClient.IpcError.rpcError(code, message) {
            // -32602 INVALID_PARAMS / "device_id already exists" is benign
            if code != -32602 {
                lastError = "device.add(\(name)): \(code) \(message)"
            }
        } catch {
            lastError = "device.add(\(name)): \(error)"
        }
    }

    /// Set per-device volume for an AirPlay device on the sidecar.
    public func setAirplayVolume(id: String, volume: Float) async {
        guard let ipc else { return }
        do {
            _ = try await ipc.call("device.set_volume", params: [
                "device_id": id,
                "volume": Double(volume),
            ])
        } catch {
            lastError = "set_volume(\(id.prefix(8))): \(error)"
        }
    }

    /// Enabled AirPlay device IDs that should be in the active stream.
    /// Calling this with an empty list stops the AirPlay stream.
    public func setActiveAirplayDevices(_ ids: [String]) async {
        guard let ipc else {
            lastError = "ipc not attached, cannot start AirPlay stream"
            return
        }
        if ids.isEmpty {
            _ = try? await ipc.call("stream.stop", params: [:])
            audioWriter?.stop()
            return
        }
        let anchor = Clock.nowNs() + UInt64(measuredAirplayLatencyMs) * 1_000_000
        do {
            _ = try await ipc.call("stream.start", params: [
                "device_ids": ids,
                "anchor_time_ns": Int(anchor),
                "sample_rate": 48_000,
                "channels": 2,
                "format": "pcm_s16le",
            ])
        } catch {
            lastError = "stream.start failed: \(error)"
            return
        }
        do {
            try audioWriter?.start()
        } catch {
            lastError = "audioWriter.start failed: \(error)"
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
