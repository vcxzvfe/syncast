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
    /// Maps SyncCast device ID → coreAudio UID for every device the
    /// active aggregate covers. Used by replan() to apply per-device
    /// hardware volume — routing is keyed by SyncCast ID, but the
    /// hardware-volume API needs the underlying device's UID.
    private var aggregateUIDByDeviceID: [String: String] = [:]
    /// Cached stream-format diagnostic from the most recent aggregate
    /// build. Surfaced by `diagnosticSCKReport()` so field logs show the
    /// actual channel layout of the kernel-level fan-out — invaluable
    /// for diagnosing the "only one speaker plays" symptom (which is
    /// almost always a channel-count mismatch between AUHAL stream
    /// format and the aggregate's exposed stream layout).
    private var aggregateStreamDiagnostic: AggregateDevice.StreamDiagnostic?
    private var routing: [String: DeviceRouting] = [:]
    private var measuredAirplayLatencyMs: Int = 1800
    /// Per-session set of subdevice UIDs we've already logged the
    /// "hardware volume rejected" warning for. Each UID logs ONCE,
    /// then goes silent — many DP / HDMI displays expose no writable
    /// VolumeScalar on any element, so without this gate the log
    /// would emit on every single replan (every slider drag) and
    /// drown out every other diagnostic. The diagnostic report can
    /// inspect `aggregateHwVolumeRejectionCounts` to surface the
    /// total rejection count per UID without spamming stderr.
    private var loggedHwVolumeRejectionUIDs: Set<String> = []
    /// Total number of rejected hardware-volume writes per UID this
    /// session. Incremented on every rejection regardless of whether
    /// we logged. Surfaced through `diagnosticSCKReport()` so a
    /// support ticket can show "we tried 47 times, never accepted".
    private var aggregateHwVolumeRejectionCounts: [String: Int] = [:]
    /// Per-session set of subdevice UIDs whose hardware volume is
    /// known unsupported (a write attempt returned false at least
    /// once). Future replans skip the call into CoreAudio entirely
    /// and go straight to the software-gain fallback. Cleared on
    /// teardown so re-plug or device hot-swap gets a fresh probe.
    private var aggregateHwVolumeUnsupportedUIDs: Set<String> = []
    private var ipc: IpcClient?
    private var audioWriter: AudioSocketWriter?
    /// Per-device connection state, keyed by SyncCast device ID. Updated
    /// in the sidecar-notification handler on every `event.device_state`
    /// arrival (see `attachSidecar`). Surfaced to the UI via
    /// `connectionState(deviceID:)` + `connectionStatesSnapshot()`.
    ///
    /// Why the actor owns this rather than AppModel: AppModel runs on
    /// the MainActor, so funnelling per-event notifications all the way
    /// up to the UI thread for every device-state event would generate
    /// dozens of MainActor hops per session start (the sidecar emits
    /// connecting+connected+occasional failed for every device). The
    /// actor keeps the latest cache and AppModel polls every second
    /// (see `AppModel.subscribeConnectionStates`). v1 is intentionally
    /// poll-based — pushing every event to MainActor can be added later
    /// when we have a need (e.g. instant-failure UI animation).
    private var connectionStates: [String: DeviceConnectionState] = [:]
    /// Per-device "last_error" string from the most recent failed
    /// event. Surfaced in the UI as a one-line under-row message.
    /// Nil for any device whose state is not currently `.failed`.
    private var connectionFailureReasons: [String: String] = [:]
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
            // re-plan, and per-device connection-state events to drive
            // the UI sync dots. Other events are observed by the UI
            // layer via a separate subscription mechanism (TODO P3).
            if method == "event.measured_latency",
               let measured = params["measured_ms"] as? Int {
                Task { await self.updateAirplayLatency(measured) }
            }
            if method == "event.device_state",
               let deviceID = params["device_id"] as? String,
               let stateStr = params["state"] as? String {
                let reason = params["last_error"] as? String
                Task { await self.recordConnectionState(
                    deviceID: deviceID, stateStr: stateStr, reason: reason,
                ) }
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
            // Mode-gated local driver setup. In stereo mode the SCK ring
            // feeds AUHALs on enabled physical devices directly (low-latency
            // path). In whole_home mode local audio flows via the bridge
            // chain: SCK → audioWriter → sidecar → OwnTone → fifo
            // broadcaster → LocalAirPlayBridge → AUHAL. The two paths MUST
            // NOT both render to the same physical device — that produces
            // double-audio at different latencies (garbled). Bridges are
            // brought up by `startWholeHome(devices:)`, which the AppModel
            // calls right after `start` resolves.
            if mode == .stereo {
                reconcileLocalDriver(devices: devices)
            } else {
                // Whole_home: ensure no stale aggregate AUHAL is left over
                // from a previous mode. tearDownLocalDriver is idempotent
                // (no-op if localOutputs is already empty + aggregate is nil).
                tearDownLocalDriver()
            }
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
            awInfo = " airplayWriter=pkts:\(aw.packetsSent) underrun:\(aw.underrunPackets) partial:\(aw.partialSends) bytes:\(aw.bytesSent) err:\(aw.lastSendError.isEmpty ? "none" : aw.lastSendError)"
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
        // Aggregate stream-format diagnostic (Strategy 2 fix): surfaces
        // the actual channel layout so field logs make the "only one
        // speaker plays" bug unambiguous. Format:
        //   streamChannelCount=streams=1 ch=[2] total=2 master=2  (good)
        //   streamChannelCount=streams=1 ch=[4] total=4 master=2  (was bug)
        let streamInfo: String
        if let diag = aggregateStreamDiagnostic {
            streamInfo = " streamChannelCount=\(diag.summary)"
        } else {
            streamInfo = ""
        }
        // Whole-home bridges (Strategy 1): one line per active bridge
        // with packet + render counters. Empty when not in wholeHome
        // mode or no bridges are active.
        var bridgeInfo = ""
        for (id, b) in localBridges {
            bridgeInfo += " bridge[\(id.prefix(6))]=pkts:\(b.packetsReceived) ticks:\(b.renderTickCount) peak:\(String(format: "%.4f", b.lastRenderPeak)) err:\(b.lastError.isEmpty ? "none" : b.lastError)"
        }
        // Per-subdevice hardware-volume rejection counters. Surfaced
        // here because the stderr log emits ONCE per UID per session;
        // a support ticket needs to see total rejection counts for
        // any device routed through software-gain fallback (typical:
        // DP / HDMI displays).
        var hwVolInfo = ""
        for (uid, count) in aggregateHwVolumeRejectionCounts {
            hwVolInfo += " hwVolRejected[\(uid.prefix(6))]=\(count)"
        }
        return "seen=\(s.debugBuffersSeen) written=\(s.debugBuffersWritten) ticks=\(s.tickCount) peak=\(String(format: "%.4f", s.debugLastPeak))/\(String(format: "%.4f", s.debugMaxPeak)) readback=\(String(format: "%.4f", s.debugReadbackPeak))@\(s.debugReadbackPos) last=\(s.debugLastReason)\(driverInfo)\(streamInfo)\(renderInfo)\(awInfo)\(bridgeInfo)\(hwVolInfo)"
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
    /// local state with the result. The two paths are mutually
    /// exclusive — in stereo mode only the SCK→AUHAL aggregate runs;
    /// in whole_home mode only LocalAirPlayBridge instances run.
    /// Allowing both to render to the same physical device produces
    /// double-audio at different latencies (garbled). To make the
    /// invariant impossible to violate, this function fully tears down
    /// whichever path belongs to the OPPOSITE mode before the new mode
    /// can come up via `start(devices:)` / `startWholeHome(devices:)`.
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
        // Mode change accepted by sidecar. Local cleanup — drop the
        // OPPOSITE mode's audio path so the two never render to the
        // same physical device simultaneously.
        switch newMode {
        case .stereo:
            // Going to stereo: kill every bridge. They're useless
            // without the sidecar broadcaster on the other end, and
            // leaving them running while the SCK→aggregate path is
            // about to come up would double-play.
            for (_, b) in localBridges { b.stop() }
            localBridges.removeAll()
        case .wholeHome:
            // Going to whole_home: tear down the SCK→aggregate path.
            // Otherwise reconcileEngineAsync's running-true→wholeHome
            // arm could leave the aggregate AUHAL rendering at the
            // same time the bridges spin up (Symptom 2 in the field
            // report — `driver=wholeHome(2)` AND `render[agg:…]`
            // ticking concurrently).
            tearDownLocalDriver()
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

        // Diagnose the aggregate's actual output-stream layout BEFORE
        // opening AUHAL. This reads kAudioDevicePropertyStreamConfiguration
        // and lets us correlate AUHAL's mChannelsPerFrame=2 against the
        // aggregate's real channel count. If they mismatch (e.g. 4 ch
        // because the kernel exposed both subdevices' channels via one
        // stream), only the first 2 channels get audio and the second
        // physical speaker is silent — the user-reported bug.
        let diag = agg.diagnoseStreamConfig()
        // stderr — Router has no SyncCastLog dependency.
        FileHandle.standardError.write(Data(
            "[Router] aggregate stream diag: \(diag.summary) outputCh=\(agg.outputChannelCount)\n".utf8
        ))
        aggregateStreamDiagnostic = diag

        // AUHAL is configured for the aggregate's REAL channel count.
        // If approach (A) succeeded in narrowing every stream to 2-ch,
        // outputChannelCount == 2 and render() emits a clean stereo pair.
        // If (A) was rejected and outputChannelCount is wider (typically
        // 2*subdeviceCount), render() splats the source stereo into
        // every channel pair so all subdevices play.
        let out = LocalOutput(
            deviceID: agg.deviceID, deviceUID: agg.aggregateUID,
            ring: sckCapture.ringBuffer,
            sampleRate: sckCapture.sampleRate,
            channelCount: sckCapture.channelCount,
            outputChannelCount: agg.outputChannelCount
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
            // Build the SyncCast-id → UID map needed by replan() to
            // apply per-device hardware volume.
            var idToUID: [String: String] = [:]
            for e in enabled { idToUID[e.deviceID] = e.uid }
            aggregateUIDByDeviceID = idToUID
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
        aggregateUIDByDeviceID.removeAll()
        aggregateStreamDiagnostic = nil
        // Per-session caches that only make sense for the now-defunct
        // aggregate. A re-plug of a device gets a fresh probe; the
        // count of past rejections doesn't survive teardown either,
        // so the diagnostic report reflects only the current session's
        // active aggregate.
        loggedHwVolumeRejectionUIDs.removeAll()
        aggregateHwVolumeRejectionCounts.removeAll()
        aggregateHwVolumeUnsupportedUIDs.removeAll()
    }

    /// Record a per-device connection-state event from the sidecar.
    /// Called from the IPC notification handler closure (off-actor)
    /// via a `Task { await ... }` hop, so it lands inside the actor.
    ///
    /// Translates the sidecar's wire `state` string into a
    /// `DeviceConnectionState`. The legacy `streaming` and `added`
    /// states are mapped to `.unknown` so they don't override a fresh
    /// `connecting` / `connected` flag — the UI cares about the
    /// receiver-wiring lifecycle, not the internal stream lifecycle.
    public func recordConnectionState(
        deviceID: String, stateStr: String, reason: String?,
    ) {
        let state: DeviceConnectionState
        switch stateStr {
        case "connecting", "connected", "failed", "disconnected":
            state = .fromWire(stateStr)
        default:
            // legacy / informational states (added, streaming): leave
            // any prior wiring-state untouched and ignore this event.
            return
        }
        connectionStates[deviceID] = state
        if state == .failed, let reason = reason {
            connectionFailureReasons[deviceID] = reason
        } else if state != .failed {
            connectionFailureReasons.removeValue(forKey: deviceID)
        }
    }

    /// Query the most recent connection state for a single device.
    /// Returns `.unknown` if no event has been received for it yet.
    public func connectionState(deviceID: String) -> DeviceConnectionState {
        connectionStates[deviceID] ?? .unknown
    }

    /// Snapshot the entire connection-state map (states + failure
    /// reasons) for the UI poll loop. Returned as plain Sendable
    /// dictionaries so MainActor consumers can copy them off-actor.
    public func connectionStatesSnapshot() -> (
        states: [String: DeviceConnectionState],
        reasons: [String: String]
    ) {
        (connectionStates, connectionFailureReasons)
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
        // Mode-specific empty-list handling.
        //
        // .stereo:    no AirPlay devices means we don't need OwnTone running
        //             at all — stop the stream and the writer.
        // .wholeHome: even with ZERO AirPlay receivers selected, OwnTone's
        //             player must keep running so its `fifo` output writes
        //             PCM into output.fifo for the local LocalAirPlayBridge
        //             instances. Stopping the stream here would silence
        //             every local speaker — observed user-reported bug:
        //             "在全屋模式下只选 MBP+显示器也没声音".
        if ids.isEmpty {
            if mode == .wholeHome {
                // Tell sidecar "no AirPlay receivers selected" but keep
                // the stream itself active. start_stream now accepts an
                // empty device_ids list in whole-home mode and disables
                // every AirPlay output while leaving fifo + audio reader
                // running.
                let anchor = Clock.nowNs() + UInt64(measuredAirplayLatencyMs) * 1_000_000
                _ = try? await ipc.call("stream.start", params: [
                    "device_ids": ids,
                    "anchor_time_ns": Int(anchor),
                    "sample_rate": 48_000,
                    "channels": 2,
                    "format": "pcm_s16le",
                ])
                do {
                    try audioWriter?.start()
                } catch {
                    lastError = "audioWriter.start failed: \(error)"
                }
                return
            }
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

        // In aggregate mode, also apply per-device HARDWARE volume on
        // the underlying physical DACs. The single AUHAL atop the
        // aggregate cannot natively do this — it sees one stream and
        // applies gain uniformly to every subdevice. Hardware volume
        // bypasses the AUHAL entirely … but only on devices whose
        // CoreAudio driver actually exposes
        // `kAudioDevicePropertyVolumeScalar` as writable.
        //
        // DP / HDMI display speakers (the user's PG27UCDM is the
        // canonical example) DO NOT — there's no hardware path to
        // control their output level, the user must use the OSD.
        // For those, we fall back to per-channel-pair software gain
        // applied at the AUHAL render layer: the splat already writes
        // the source stereo into every output pair, so attenuating
        // just the display's pair (e.g. channels 2..3 with master at
        // channels 0..1) gives the user a working slider without
        // touching the master's volume. This is digital attenuation,
        // so very low values lose effective bit depth — that's the
        // documented quality trade-off the user implicitly accepts
        // by using a monitor speaker.
        if let agg = aggregateDevice,
           let aggOut = localOutputs[agg.aggregateUID] {
            for (devID, uid) in aggregateUIDByDeviceID {
                let r = routing[devID] ?? DeviceRouting(deviceID: devID)
                let target = r.muted ? Float(0) : r.volume
                applyAggregateSubdeviceVolume(
                    aggregate: agg,
                    aggregateOutput: aggOut,
                    deviceID: devID,
                    uid: uid,
                    target: target
                )
            }
        }
    }

    /// Apply the user's slider value to one subdevice of the active
    /// aggregate. Tries hardware volume first; on rejection (or on a
    /// device that's known unsupported from a prior probe) routes
    /// through the per-channel-pair software gain on the aggregate's
    /// AUHAL.
    ///
    /// The "known unsupported" cache short-circuits the slow CoreAudio
    /// probe loop on every replan — without it, every slider drag
    /// would re-walk 32 elements for the display before falling back,
    /// which is a several-ms-per-frame UI hitch.
    private func applyAggregateSubdeviceVolume(
        aggregate: AggregateDevice,
        aggregateOutput: LocalOutput,
        deviceID: String,
        uid: String,
        target: Float
    ) {
        // Fast-path: we already know this device's hardware volume
        // is unsupported. Skip the CoreAudio call entirely.
        let knownUnsupported =
            aggregateHwVolumeUnsupportedUIDs.contains(uid) ||
            AggregateDevice.isHardwareVolumeKnownUnsupported(uid: uid)
        let hwOk: Bool
        if knownUnsupported {
            hwOk = false
        } else {
            hwOk = aggregate.setSubdeviceVolume(uid: uid, volume: target)
        }
        if hwOk {
            // Hardware accepted. If we previously installed a
            // software-gain fallback for this pair (e.g. the device
            // was unsupported and is now back, after re-plug), reset
            // the pair to 1.0 so we don't double-attenuate.
            if let pair = aggregate.subdeviceChannelOffset(uid: uid)
                .map({ $0 / max(1, aggregateOutput.channelCount) }) {
                aggregateOutput.setSoftwareGain(pair: pair, gain: 1.0)
            }
            return
        }
        // Hardware rejected. Increment the diagnostic counter on every
        // rejection; emit the stderr line ONCE per UID per session.
        aggregateHwVolumeRejectionCounts[uid, default: 0] += 1
        aggregateHwVolumeUnsupportedUIDs.insert(uid)
        if !loggedHwVolumeRejectionUIDs.contains(uid) {
            loggedHwVolumeRejectionUIDs.insert(uid)
            FileHandle.standardError.write(Data(
                ("[Router] hardware volume unsupported for \(uid.prefix(20)) — falling back to software gain (this device's level must be controlled via its OSD or via SyncCast's per-device slider; further rejections silenced)\n").utf8
            ))
        }
        // Route the slider value into the AUHAL's per-pair gain. The
        // channel-pair index is the subdevice's first output channel
        // divided by the source channel count (typically 2). If the
        // aggregate's stream layout doesn't match our model (e.g. one
        // wide stream where we expected per-subdevice pairs), the
        // setSoftwareGain call no-ops on out-of-range pair indices.
        guard let firstChannel = aggregate.subdeviceChannelOffset(uid: uid) else {
            return
        }
        let pair = firstChannel / max(1, aggregateOutput.channelCount)
        aggregateOutput.setSoftwareGain(pair: pair, gain: target)
        _ = deviceID  // intentionally unused — kept in signature for future per-device diagnostics
    }
}
