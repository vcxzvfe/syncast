import Foundation
import CoreAudio
import SyncCastDiscovery

/// Helper struct used inside Router.reconcileLocalDriver to carry the
/// (id, uid, name) triple for each enabled local CoreAudio output. Defined
/// at file scope so it can cross from the reconcile entry point into the
/// per-mode helpers without an extra indirection.
private struct EnabledLocalOutput {
    let deviceID: String
    let uid: String
    let name: String
}

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

    /// Top-level data-plane mode.
    ///
    /// - ``stereo``     — legacy: SCK-captured PCM is fed through the
    ///                    sidecar to AirPlay 2 receivers, while local
    ///                    CoreAudio outputs render from the same SCK
    ///                    ring directly. Two clocks: SCK for local,
    ///                    AirPlay's RTSP anchor for remote.
    /// - ``wholeHome``  — Strategy 1: bundled OwnTone produces ONE
    ///                    player-clock stream that fans out to AirPlay
    ///                    receivers (via OwnTone's existing AirPlay
    ///                    output) AND to local CoreAudio devices via
    ///                    `LocalAirPlayBridge` instances reading the
    ///                    sidecar's fifo broadcast socket. Single
    ///                    clock everywhere.
    public enum Mode: String, Sendable {
        case stereo
        case wholeHome = "whole_home"
    }

    public private(set) var state: RouterState = .idle
    public private(set) var lastError: String?
    public private(set) var mode: Mode = .stereo

    private let sckCapture: SCKCapture
    private let scheduler: Scheduler
    /// Open AUHAL outputs. Keyed differently depending on driver mode:
    ///   - In `.individual` mode: keyed by SyncCast device ID — one
    ///     LocalOutput per enabled physical device.
    ///   - In `.aggregate` mode: a single entry keyed by the aggregate
    ///     device's UID. The kernel-side aggregate fans out audio to all
    ///     constituent physical devices with sample-accurate drift
    ///     correction; that's why we only need one AUHAL on top of it.
    private var localOutputs: [String: LocalOutput] = [:]
    /// Active synchronized aggregate, when 2+ local outputs are enabled.
    /// `nil` in idle mode, in single-output mode, or after a transition
    /// teardown. The teardown order is strict — see Router.stop().
    private var aggregateDevice: AggregateDevice?
    /// Set of physical device UIDs the active aggregate currently fans
    /// audio out to. Used to decide if a routing change requires destroy +
    /// recreate (different set) or is a no-op (same set).
    private var aggregateCoveredUIDs: Set<String> = []
    private var routing: [String: DeviceRouting] = [:]
    private var measuredAirplayLatencyMs: Int = 1800
    private var ipc: IpcClient?
    private var audioWriter: AudioSocketWriter?
    /// Whole-home AirPlay mode bridges, keyed by SyncCast device ID.
    /// Each entry owns one Unix-socket connection to the sidecar's
    /// broadcast listener and one AUHAL on a physical CoreAudio device.
    /// Empty in stereo mode and after teardown. Fully replaces the
    /// `localOutputs` set while in whole-home mode — the two are never
    /// active at the same time on the same physical device.
    private var localBridges: [String: LocalAirPlayBridge] = [:]
    /// Cached path returned by `local_fifo.path` IPC — fetched once on
    /// the first whole-home transition and reused for all bridges.
    private var localFifoSocketPath: URL?

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
        // Reap any private aggregate devices left behind by a prior crash
        // BEFORE we ever try to create one in this run. Header docs say
        // private aggregates auto-clean on process exit, but coreaudiod
        // has been observed to leak them after SIGKILL or fast user
        // switching. Sweep is keyed by the AggregateDevice.uidPrefix.
        let reaped = AggregateDevice.sweepOrphans()
        if reaped > 0 {
            // Logged as a warning so we notice in the field if SIGKILL
            // crashes start happening.
            print("[Router] swept \(reaped) orphan aggregate device(s) at init")
        }
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
            // Single entry point for opening local outputs. Picks individual
            // AUHALs vs synchronized aggregate based on the enabled-output
            // count (see reconcileLocalDriver). Used by both initial start
            // and live retag via syncLocalOutputs.
            reconcileLocalDriver(devices: devices)
            replan()
            state = .running
        } catch {
            state = .error
            lastError = "\(error)"
            tearDownLocalDriver()
            sckCapture.stop()
            throw error
        }
    }

    public func stop() async {
        state = .stopping
        // 0. Tear down whole-home bridges first (if any). They hold
        //    Unix sockets pointing at the sidecar and AUHALs on
        //    physical devices; both need to release before the rest of
        //    the local driver shutdown sequence.
        for (_, b) in localBridges { b.stop() }
        localBridges.removeAll()
        // 1. Stop the audio writer's send loop, but DO NOT nil it. The
        //    instance holds the ring + socket-path; .start() can reconnect
        //    cleanly on the next reconcile. Nilling this and `ipc` below
        //    is what made "toggle Xiaomi off then back on → silent
        //    forever" — subsequent setActiveAirplayDevices saw `ipc==nil`
        //    and silently returned without re-arming the AirPlay stream.
        audioWriter?.stop()
        // 2. Tell the sidecar to stop its current stream session, but
        //    KEEP the IPC connection open. The sidecar's `_on_client`
        //    finally was previously hardened to NOT shutdown OwnTone on
        //    disconnect, so this socket stays valid; closing it here
        //    forces a reconnect-from-scratch path that doesn't exist
        //    (attachSidecar is bootstrap-only).
        if let ipc = ipc {
            _ = try? await ipc.call("stream.stop", params: [:])
        }
        // 3. Tear down local AUHALs and the synchronized aggregate (if any).
        //    Strict order: stop AUHAL → Uninit + Dispose → destroy
        //    aggregate. Reversing this deadlocks coreaudiod on some macOS
        //    versions (per AggregateDevice.swift docstring + BlackHole
        //    issue tracker).
        tearDownLocalDriver()
        // 4. Stop the SCK capture stream. SCKCapture.stop() launches an
        //    unstructured Task to await the SCStream.stopCapture; that
        //    task finishes asynchronously but won't be re-entered here.
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
            // Aggregate driver mode keys its single LocalOutput by the
            // aggregate's UID, which starts with our well-known prefix.
            // Show "agg" + a short tail rather than the noisy prefix.
            let label: String
            if id.hasPrefix(AggregateDevice.uidPrefix) {
                label = "agg:\(id.suffix(6))"
            } else {
                label = String(id.prefix(6))
            }
            renderInfo += " render[\(label)]=ticks:\(out.renderTickCount) peak:\(String(format: "%.4f", out.lastRenderPeak))"
        }
        var awInfo = ""
        if let aw = audioWriter {
            awInfo = " airplayWriter=pkts:\(aw.packetsSent) bytes:\(aw.bytesSent) err:\(aw.lastSendError.isEmpty ? "none" : aw.lastSendError)"
        }
        // Driver mode: most useful in field reports — tells us instantly
        // if the kernel-level synchronized aggregate is engaged or not.
        let driverInfo: String
        if mode == .wholeHome {
            driverInfo = " driver=wholeHome(\(localBridges.count))"
        } else if aggregateDevice != nil {
            driverInfo = " driver=aggregate(\(aggregateCoveredUIDs.count))"
        } else if !localOutputs.isEmpty {
            driverInfo = " driver=individual(\(localOutputs.count))"
        } else {
            driverInfo = " driver=idle"
        }
        // Whole-home bridges: one diagnostic line per active bridge with
        // its packet/render counters. Empty string if there are none.
        var bridgeInfo = ""
        for (id, b) in localBridges {
            bridgeInfo += " bridge[\(id.prefix(6))]=pkts:\(b.packetsReceived) ticks:\(b.renderTickCount) peak:\(String(format: "%.4f", b.lastRenderPeak)) err:\(b.lastError.isEmpty ? "none" : b.lastError)"
        }
        return "seen=\(s.debugBuffersSeen) written=\(s.debugBuffersWritten) ticks=\(s.tickCount) peak=\(String(format: "%.4f", s.debugLastPeak))/\(String(format: "%.4f", s.debugMaxPeak)) readback=\(String(format: "%.4f", s.debugReadbackPeak))@\(s.debugReadbackPos) last=\(s.debugLastReason)\(driverInfo)\(renderInfo)\(awInfo)\(bridgeInfo)"
    }

    /// Reconcile the open AUHAL set against the current routing snapshot.
    /// Called whenever the user toggles a local device while the engine
    /// is already running.
    public func syncLocalOutputs(devices: [Device]) async {
        reconcileLocalDriver(devices: devices)
        replan()
    }

    // MARK: - Whole-home AirPlay mode (Strategy 1)
    //
    // Two public entry points the menubar app drives:
    //
    //   setMode(_:)         — round-trip the mode change with the
    //                          sidecar via `mode.set`. Tearing down
    //                          existing local bridges happens here so
    //                          the SCK driver path is clean before any
    //                          subsequent stereo `start(devices:)`.
    //
    //   startWholeHome(devices:) — for each enabled local CoreAudio
    //                          device in `devices`, open one
    //                          LocalAirPlayBridge against the sidecar's
    //                          broadcast socket.
    //
    // The two are separate because the menubar may want to set the mode
    // FIRST (so OwnTone has time to spin up) and bring the bridges up
    // only after the user has chosen which devices participate.

    /// Tell the sidecar to switch data planes, and synchronize our
    /// local state with the result. In stereo→whole_home, this is a
    /// prerequisite for `startWholeHome`. In whole_home→stereo, this
    /// also tears down any active bridges so the next stereo start has
    /// a clean slate.
    public func setMode(_ newMode: Mode) async {
        guard let ipc else {
            lastError = "ipc not attached, cannot set mode"
            return
        }
        do {
            _ = try await ipc.call("mode.set", params: ["mode": newMode.rawValue])
        } catch {
            lastError = "mode.set(\(newMode.rawValue)): \(error)"
            return
        }
        // Mode change accepted by sidecar. Local cleanup:
        if newMode == .stereo {
            // Drop every bridge — they're useless without the sidecar
            // broadcaster on the other end. Local outputs (LocalOutput
            // /aggregate) are NOT touched here; if the user restarts
            // stereo streaming via `start(devices:)` they'll be opened
            // by reconcileLocalDriver.
            for (_, b) in localBridges { b.stop() }
            localBridges.removeAll()
        }
        // Stash the new mode AFTER the IPC succeeds so a failed call
        // doesn't lie about our state.
        self.mode = newMode
    }

    /// Open `LocalAirPlayBridge` instances for every enabled local
    /// CoreAudio device in `devices`. The bridge connects to the
    /// sidecar's broadcast socket and renders OwnTone's player-clock
    /// PCM through AUHAL on the device.
    ///
    /// Preconditions:
    ///   * `setMode(.wholeHome)` has already returned successfully.
    ///   * The IPC connection is up (otherwise we cannot resolve the
    ///     broadcast socket path).
    ///
    /// Idempotent: re-calling with the same `devices` is a no-op for
    /// existing bridges. Devices not enabled or not local-CoreAudio are
    /// skipped silently. Devices that USED to have a bridge but are no
    /// longer enabled get their bridge stopped + removed.
    public func startWholeHome(devices: [Device]) async {
        guard mode == .wholeHome else {
            lastError = "startWholeHome called outside whole_home mode"
            return
        }
        guard let ipc else {
            lastError = "ipc not attached, cannot start whole_home"
            return
        }
        // Resolve the broadcast socket path once per session.
        if localFifoSocketPath == nil {
            do {
                let any = try await ipc.call("local_fifo.path", params: [:])
                if let dict = any as? [String: Any],
                   let pathStr = dict["socket_path"] as? String {
                    localFifoSocketPath = URL(fileURLWithPath: pathStr)
                } else {
                    lastError = "local_fifo.path returned malformed result"
                    return
                }
            } catch {
                lastError = "local_fifo.path failed: \(error)"
                return
            }
        }
        guard let socketURL = localFifoSocketPath else { return }

        // Build the target set of (deviceID, uid) tuples from `devices`,
        // honouring the same "enabled and local-coreaudio" predicate as
        // reconcileLocalDriver. We deliberately do NOT filter out our
        // own private aggregates here — in whole-home mode we don't use
        // them, but if the user has a third-party aggregate they want
        // to drive, that's fine.
        struct Target { let deviceID: String; let uid: String; let name: String }
        let targets: [Target] = devices.compactMap { dev in
            guard dev.transport == .coreAudio else { return nil }
            guard routing[dev.id]?.enabled ?? false else { return nil }
            guard let uid = dev.coreAudioUID else { return nil }
            // Skip our own private aggregates — they're an artifact of
            // stereo mode's reconciliation and would re-open the SCK
            // driver path, defeating the purpose.
            if uid.hasPrefix(AggregateDevice.uidPrefix) { return nil }
            // Same blackhole filter as stereo mode — never route audio
            // back into the loopback source.
            if dev.name.lowercased().contains("blackhole") { return nil }
            return Target(deviceID: dev.id, uid: uid, name: dev.name)
        }
        let targetIDs = Set(targets.map { $0.deviceID })

        // Tear down bridges that are no longer in the target set.
        for (id, b) in localBridges where !targetIDs.contains(id) {
            b.stop()
            localBridges.removeValue(forKey: id)
        }

        // Bring up bridges for new targets.
        for t in targets {
            if localBridges[t.deviceID] != nil { continue }
            // Resolve UID → AudioObjectID. Failure here is per-device,
            // not fatal for the whole call — log and skip.
            let coreAudioID: AudioObjectID
            do {
                coreAudioID = try Capture.deviceID(forUID: t.uid)
            } catch {
                lastError = "bridge: device \(t.name) not found: \(error)"
                continue
            }
            guard coreAudioID != 0 else {
                lastError = "bridge: device \(t.name) resolved to id 0"
                continue
            }
            let bridge = LocalAirPlayBridge(
                deviceID: coreAudioID,
                deviceUID: t.uid,
                socketPath: socketURL
            )
            do {
                try bridge.start()
                localBridges[t.deviceID] = bridge
            } catch {
                lastError = "bridge \(t.name) start failed: \(error)"
            }
        }
    }

    // MARK: - Local driver reconciliation
    //
    // The core decision: how do we drive the user's enabled CoreAudio
    // outputs? Two modes:
    //
    //   .individual  — count == 1. Open one AUHAL on the physical device.
    //                  No aggregate; no SRC; lowest possible latency.
    //
    //   .aggregate   — count >= 2. Create a private CoreAudio Aggregate
    //                  Device with all enabled outputs as subdevices, drift
    //                  correction enabled on all non-master subdevices, and
    //                  open ONE AUHAL on the aggregate. The kernel handles
    //                  per-device sync with continuous SRC tuning. This is
    //                  the only way to get sub-sample-accurate alignment
    //                  between independent physical outputs (e.g. MBP
    //                  built-in speaker + a DisplayPort monitor).
    //
    // count == 0 ⇒ tear everything down; the engine itself will be stopped
    // by the AppModel reconciler one rung up.
    //
    // Transitions are "tear down then build up" rather than "patch the
    // existing driver in place" — patching adds complexity for marginal
    // benefit (a few ms of silence during transition, well under the
    // user-perceptible threshold for a UI toggle).
    private func reconcileLocalDriver(devices: [Device]) {
        // Index name lookups so master picker can score by device name.
        var nameByUID: [String: String] = [:]
        for dev in devices {
            if let u = dev.coreAudioUID { nameByUID[u] = dev.name }
        }

        // Compute the target enabled set: every CoreAudio device that the
        // user has toggled on, minus a few classes that are unsafe to
        // route into:
        //   - BlackHole (it's a virtual sink that may be the system source
        //     for SCK capture; routing audio TO it could feedback)
        //   - any of OUR previously-spawned aggregates (UID prefix match)
        //
        // We deliberately DO NOT exclude user-created aggregates from
        // Audio MIDI Setup any more. With our own private aggregate now
        // a first-class concept, blanket-filtering aggregates would
        // surprise users who set one up themselves.
        let enabled: [EnabledLocalOutput] = devices.compactMap { dev in
            guard dev.transport == .coreAudio else { return nil }
            guard routing[dev.id]?.enabled ?? false else { return nil }
            guard let uid = dev.coreAudioUID else { return nil }
            if uid.hasPrefix(AggregateDevice.uidPrefix) { return nil }
            let lower = dev.name.lowercased()
            if lower.contains("blackhole") { return nil }
            return EnabledLocalOutput(deviceID: dev.id, uid: uid, name: dev.name)
        }
        let targetUIDs = Set(enabled.map { $0.uid })

        switch enabled.count {
        case 0:
            tearDownLocalDriver()
        case 1:
            // Switch to individual mode if we aren't already covering
            // exactly this single device.
            let only = enabled[0]
            let alreadyCorrect =
                aggregateDevice == nil &&
                localOutputs.count == 1 &&
                localOutputs.keys.first == only.deviceID
            if !alreadyCorrect {
                tearDownLocalDriver()
                openIndividualAUHAL(deviceID: only.deviceID, uid: only.uid, name: only.name)
            }
        default:
            // Switch to aggregate mode if we aren't already covering
            // exactly this set.
            let alreadyCorrect =
                aggregateDevice != nil &&
                aggregateCoveredUIDs == targetUIDs
            if !alreadyCorrect {
                tearDownLocalDriver()
                openAggregateAUHAL(enabled: enabled, nameByUID: nameByUID)
            }
        }
    }

    private func openIndividualAUHAL(deviceID: String, uid: String, name: String) {
        guard let coreAudioID = try? Capture.deviceID(forUID: uid),
              coreAudioID != 0 else {
            lastError = "device \(name) not found in CoreAudio"
            return
        }
        let out = LocalOutput(
            deviceID: coreAudioID, deviceUID: uid,
            ring: sckCapture.ringBuffer,
            sampleRate: sckCapture.sampleRate,
            channelCount: sckCapture.channelCount
        )
        do {
            try out.start()
            localOutputs[deviceID] = out
        } catch {
            lastError = "open \(name) failed: \(error)"
        }
    }

    private func openAggregateAUHAL(
        enabled: [EnabledLocalOutput],
        nameByUID: [String: String]
    ) {
        let candidateUIDs = Set(enabled.map { $0.uid })
        guard let masterUID = AggregateDevice.pickMaster(
            candidateUIDs: candidateUIDs, deviceNames: nameByUID
        ) else {
            lastError = "could not pick master device for aggregate"
            return
        }
        let slaveUIDs = enabled.map { $0.uid }.filter { $0 != masterUID }

        let agg: AggregateDevice
        do {
            agg = try AggregateDevice(masterUID: masterUID, slaveUIDs: slaveUIDs)
        } catch {
            lastError = "aggregate create failed: \(error). Falling back to first-only."
            // Recovery: drive only the master device individually so we
            // still produce SOME audio. Drift between physical speakers
            // returns, but silence is worse.
            if let master = enabled.first(where: { $0.uid == masterUID }) {
                openIndividualAUHAL(deviceID: master.deviceID, uid: master.uid, name: master.name)
            }
            return
        }

        let out = LocalOutput(
            deviceID: agg.deviceID, deviceUID: agg.aggregateUID,
            ring: sckCapture.ringBuffer,
            sampleRate: sckCapture.sampleRate,
            channelCount: sckCapture.channelCount
        )
        do {
            try out.start()
            // Verify drift correction got applied (Apple Silicon has been
            // observed to silently downgrade quality under low-power).
            // This is read-only; doesn't fix it, but logs let us notice.
            let drift = agg.verifyDriftCorrection()
            let off = drift.filter { $0.key != masterUID && !$0.value.enabled }
            if !off.isEmpty {
                lastError = "aggregate built but drift OFF for: \(off.keys.joined(separator: ","))"
            }
            aggregateDevice = agg
            aggregateCoveredUIDs = candidateUIDs
            // Key the AUHAL by the aggregate UID so diagnostic dumps and
            // setRouting iteration can find it without confusing it with
            // a per-device entry.
            localOutputs[agg.aggregateUID] = out
        } catch {
            lastError = "AUHAL on aggregate failed: \(error)"
            agg.destroy()
        }
    }

    /// Strict teardown order: stop every AUHAL first (synchronously waits
    /// for the in-flight render block to drain), then destroy the
    /// aggregate. Reversing this deadlocks coreaudiod on some macOS
    /// versions — observed in BlackHole's issue tracker and confirmed by
    /// our own crash report at the toggle-off path.
    private func tearDownLocalDriver() {
        for (_, out) in localOutputs { out.stop() }
        localOutputs.removeAll()
        if let agg = aggregateDevice {
            agg.destroy()
            aggregateDevice = nil
        }
        aggregateCoveredUIDs = []
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
