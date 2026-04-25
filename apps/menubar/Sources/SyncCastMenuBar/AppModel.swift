import Foundation
import Observation
import SyncCastDiscovery
import SyncCastRouter

/// Top-level UI view-model. Owns the `DiscoveryService` and a `Router`,
/// surfaces a snapshot of devices + routing for the SwiftUI tree.
///
/// `@Observable` (Swift 5.9 macros): mutations to any stored property are
/// observed by views automatically.
@Observable
@MainActor
final class AppModel {
    var devices: [Device] = []
    var routing: [String: DeviceRouting] = [:]
    /// The fundamental architectural choice: which audio path is active.
    /// These are mutually exclusive. Switching requires a full pipeline
    /// teardown + rebuild (a few hundred ms of silence on transition,
    /// well under user-perceptible UI latency).
    ///
    /// Why two modes — the latency budgets are incompatible. AirPlay 2's
    /// PTP-anchored playback runs ~1.8 s behind realtime. Local AUHAL
    /// runs ~50 ms. There is no useful middle ground because the only way
    /// to sync them is to delay the local path by 1.8 s, which destroys
    /// the reason to use it. Every commercial multi-room product
    /// (Sonos, Apple Music + AirPlay 2, Roon) makes this same split.
    var mode: Mode = .stereo
    var streamingState: StreamingState = .idle
    var lastError: String?
    /// Screen Recording TCC permission state. We replaced the old
    /// "BlackHole microphone" gate with this.
    var screenRecordingGranted: Bool = false

    enum Mode: String, Sendable, CaseIterable, Identifiable {
        /// Local CoreAudio outputs only, ~50 ms latency, video sync OK.
        /// AirPlay receivers are hidden / unselectable in this mode.
        /// Drives audio through a private CoreAudio Aggregate Device with
        /// kernel-level drift correction so the physical speakers stay
        /// sample-accurately aligned.
        case stereo
        /// All outputs go through OwnTone's player at AirPlay 2's
        /// ~1.8 s latency. Local CoreAudio outputs participate by
        /// receiving PCM from OwnTone's "fifo" output via a sidecar
        /// broadcast → Swift LocalAirPlayBridge. AirPlay 2 receivers
        /// receive the same audio over the network. Everything PTP-
        /// synced. Video sync is impossible in this mode.
        case wholeHome

        public var id: String { rawValue }
        public var displayName: String {
            switch self {
            case .stereo:    return "立体声 (本地, 低延迟)"
            case .wholeHome: return "全屋同步 (AirPlay)"
            }
        }
        public var subtitle: String {
            switch self {
            case .stereo:    return "本地扬声器, ≈50ms 延迟, 适合视频"
            case .wholeHome: return "全设备同步, ≈1.8s 延迟, 仅适合音乐"
            }
        }
    }

    enum StreamingState: String, Sendable {
        case idle, starting, running, error
    }

    var statusIconName: String {
        switch streamingState {
        case .idle:     return "speaker.wave.2"
        case .starting: return "speaker.wave.2.bubble"
        case .running:  return "speaker.wave.3.fill"
        case .error:    return "speaker.slash"
        }
    }

    /// Is at least one local-output device enabled? Used to decide whether
    /// the audio engine should be running.
    var hasEnabledOutputs: Bool {
        routing.values.contains { $0.enabled }
    }

    private let discovery: DiscoveryService
    private let router: Router
    private let sidecarLauncher = SidecarLauncher()
    var sidecarRunning: Bool = false

    /// Debounce guard for `reconcileEngine`. Each call cancels the
    /// previous timer; only the last call within an 80 ms quiet window
    /// actually fires the reconciler. Keeps "user mashes toggle rows" from
    /// generating 30+ reconcile passes in 2 seconds (observed in
    /// launch.log before this guard was added).
    private var reconcileTimer: Task<Void, Never>?

    init() {
        self.discovery = DiscoveryService()
        self.router = Router()
        Task { await self.bootstrap() }
    }

    private func bootstrap() async {
        SyncCastLog.log("bootstrap start")
        // Check Screen Recording permission state. SyncCast captures system
        // audio via ScreenCaptureKit; Screen Recording is the TCC gate.
        screenRecordingGranted = (ScreenRecordingTCC.current == .granted)
        SyncCastLog.log("screen-recording status: \(ScreenRecordingTCC.current.rawValue)")
        // Tahoe sometimes lies: the System Settings switch shows ON but
        // CGPreflightScreenCaptureAccess returns false. Poll every 2s
        // and update the model when the state flips, so the user doesn't
        // have to manually quit-and-reopen.
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self else { return }
                let now = (ScreenRecordingTCC.current == .granted)
                let was = await MainActor.run { self.screenRecordingGranted }
                if now != was {
                    await MainActor.run { self.screenRecordingGranted = now }
                    SyncCastLog.log("screen-recording state changed: \(was) → \(now)")
                    if now {
                        // Just got granted. Trigger reconcile so a previously
                        // queued toggle takes effect without app restart.
                        await MainActor.run { self.reconcileEngine() }
                    }
                }
            }
        }
        // 1. Spawn the bundled sidecar (which in turn spawns OwnTone).
        do {
            let paths = try sidecarLauncher.start()
            sidecarRunning = true
            SyncCastLog.log("[SyncCast] sidecar started, control=\(paths.controlSocket.path)".replacingOccurrences(of: "[SyncCast] ", with: ""))
            // Retry attach with exponential backoff. The PyInstaller
            // onefile binary can need up to a couple of seconds on first
            // run to extract its archive before the Python interpreter
            // gets to asyncio.start_unix_server.
            var lastErr: Error?
            for attempt in 0..<10 {
                do {
                    try await router.attachSidecar(.init(
                        control: paths.controlSocket,
                        audio:   paths.audioSocket
                    ))
                    SyncCastLog.log("[SyncCast] attachSidecar OK on attempt \(attempt + 1)".replacingOccurrences(of: "[SyncCast] ", with: ""))
                    lastErr = nil
                    break
                } catch {
                    lastErr = error
                    SyncCastLog.log("[SyncCast] attachSidecar attempt \(attempt + 1) failed: \(error)".replacingOccurrences(of: "[SyncCast] ", with: ""))
                    try? await Task.sleep(nanoseconds: UInt64(200_000_000) << min(attempt, 4))
                }
            }
            if let e = lastErr { throw e }
        } catch {
            SyncCastLog.log("[SyncCast] sidecar attach gave up: \(error)".replacingOccurrences(of: "[SyncCast] ", with: ""))
            lastError = "sidecar: \(error.localizedDescription)"
        }
        // 2. Start discovery (CoreAudio + Bonjour).
        SyncCastLog.log("[SyncCast] starting discovery".replacingOccurrences(of: "[SyncCast] ", with: ""))
        await discovery.start()
        let stream = await discovery.subscribe()
        Task { [weak self] in
            for await event in stream {
                guard let self else { break }
                await self.applyEvent(event)
            }
        }
        SyncCastLog.log("[SyncCast] bootstrap complete".replacingOccurrences(of: "[SyncCast] ", with: ""))

        // SYNCAST_AUTO_TEST=mbp triggers an automated toggle of the MBP
        // built-in speaker 4 seconds after bootstrap. Used for shell-driven
        // end-to-end audio verification — strictly dev only.
        if let env = ProcessInfo.processInfo.environment["SYNCAST_AUTO_TEST"] {
            // Comma-separated list. e.g.  mbp,xiaomi,display
            // Each token is matched case-insensitively against device.name.
            let targets = env.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard let self else { return }
                await MainActor.run {
                    for target in targets {
                        let match = self.devices.first { d in
                            d.name.localizedCaseInsensitiveContains(target) ||
                            (target == "mbp" && d.name.contains("MacBook Pro扬声器")) ||
                            (target == "display" && d.name.contains("PG27"))
                        }
                        if let dev = match {
                            SyncCastLog.log("AUTO_TEST: toggling \(dev.name) ON")
                            self.toggleDevice(dev.id)
                        } else {
                            SyncCastLog.log("AUTO_TEST: no device matched '\(target)'")
                        }
                    }
                }
            }
        }
    }

    private func applyEvent(_ event: DiscoveryEvent) async {
        await MainActor.run {
            switch event {
            case .appeared(let dev):
                SyncCastLog.log("[SyncCast] device appeared: \(dev.name) (\(dev.transport.rawValue))".replacingOccurrences(of: "[SyncCast] ", with: ""))
                // If a logical device with the same coreAudioUID / host+name
                // already exists under a DIFFERENT id (e.g. discovery layer
                // minted a fresh UUID after a rename or socket flap), migrate
                // its routing entry rather than orphan it. Without this, the
                // routing dict keeps an entry under the OLD id while the row
                // taps drive the NEW id, and the user perceives "click does
                // nothing" because the AUHAL state is keyed off the orphan.
                if let existingIdx = devices.firstIndex(where: { sameLogicalDevice($0, dev) }) {
                    let oldID = devices[existingIdx].id
                    if oldID != dev.id {
                        SyncCastLog.log("device id migration: \(dev.name) \(oldID.prefix(8)) → \(dev.id.prefix(8))")
                        devices[existingIdx] = dev
                        if var oldR = routing.removeValue(forKey: oldID) {
                            oldR.deviceID = dev.id
                            routing[dev.id] = oldR
                        } else if routing[dev.id] == nil {
                            routing[dev.id] = DeviceRouting(deviceID: dev.id, enabled: false)
                        }
                        devices.sort { $0.name < $1.name }
                        detectBlackHole(in: dev)
                        return
                    }
                }
                if !devices.contains(where: { $0.id == dev.id }) {
                    devices.append(dev)
                    devices.sort { $0.name < $1.name }
                }
                if routing[dev.id] == nil {
                    routing[dev.id] = DeviceRouting(deviceID: dev.id, enabled: false)
                }
                detectBlackHole(in: dev)
            case .updated(let dev):
                if let idx = devices.firstIndex(where: { $0.id == dev.id }) {
                    devices[idx] = dev
                } else if let idx = devices.firstIndex(where: { sameLogicalDevice($0, dev) }) {
                    // Same physical device, new SyncCast id. Migrate the
                    // routing slot so user toggles don't drop on the floor.
                    let oldID = devices[idx].id
                    SyncCastLog.log("device id migration on update: \(dev.name) \(oldID.prefix(8)) → \(dev.id.prefix(8))")
                    devices[idx] = dev
                    if var oldR = routing.removeValue(forKey: oldID) {
                        oldR.deviceID = dev.id
                        routing[dev.id] = oldR
                    }
                }
                detectBlackHole(in: dev)
            case .disappeared(let id):
                devices.removeAll { $0.id == id }
            case .error(let msg):
                SyncCastLog.log("[SyncCast] discovery error: \(msg)".replacingOccurrences(of: "[SyncCast] ", with: ""))
                lastError = msg
            }
        }
    }

    /// Two `Device` values describe the same physical/logical device when
    /// their stable transport identity matches: coreAudioUID for local,
    /// host+name for AirPlay. Used by `applyEvent` to detect when discovery
    /// minted a new SyncCast id for a device we've already seen, so we can
    /// migrate the routing entry instead of stranding it under the old id.
    private func sameLogicalDevice(_ a: Device, _ b: Device) -> Bool {
        guard a.transport == b.transport else { return false }
        switch a.transport {
        case .coreAudio:
            if let ua = a.coreAudioUID, let ub = b.coreAudioUID {
                return ua == ub
            }
            return false
        case .airplay2:
            // Bonjour service name is unique per receiver; combined with host
            // it's effectively the receiver's stable identity for our needs.
            // We deliberately do NOT match on id/UUID here — this function
            // exists precisely to bridge the case where the SyncCast id
            // differs.
            return a.name == b.name && (a.host ?? "") == (b.host ?? "")
        }
    }

    // BlackHole detection removed — SCK doesn't need it.
    private func detectBlackHole(in dev: Device) { /* no-op, retained for call-site compat */ }

    /// When the set of enabled devices changes (or whole-house mode flips),
    /// reconcile the audio engine: start it if we have BlackHole + at least
    /// one enabled output, stop it otherwise.
    private func reconcileEngine() {
        // Coalesce rapid-fire callers (toggleDevice / setVolume / toggleMute /
        // permission watcher). 30 ms is short enough that single-tap toggles
        // feel instant but still absorbs the 4-5 redundant calls that one
        // tap can fan out to (Observable invalidations, slider drag bursts).
        // We deliberately keep this short to avoid the user-reported
        // "click did nothing" symptom, which an 80 ms window made worse.
        reconcileTimer?.cancel()
        reconcileTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000)
            if Task.isCancelled { return }
            await self?.reconcileEngineAsync()
        }
    }

    /// Compact one-line dump of the current `routing` dict, with every
    /// device's name + enabled flag. Used in toggleDevice logs so we can
    /// diagnose UI ↔ model desync (user reports "tapped X but Y toggled").
    /// If the log line shows the right id was toggled but the user saw
    /// the wrong row react, the bug is in the SwiftUI layer, not the
    /// model. If the wrong id was toggled, the bug is in MainPopover's
    /// row→id binding.
    private func routingSummary() -> String {
        routing.map { (id, r) -> String in
            let name = devices.first(where: { $0.id == id })?.name ?? "?"
            return "\(name)=\(r.enabled ? "ON" : "off")"
        }
        .sorted()
        .joined(separator: ", ")
    }

    private func reconcileEngineAsync() async {
        SyncCastLog.log("reconcile: scrRec=\(screenRecordingGranted) state=\(streamingState.rawValue) hasEnabled=\(hasEnabledOutputs) mode=\(mode.rawValue)")
        // We DON'T gate on screenRecordingGranted any more.
        // Reason: the only way to make macOS show the user-facing
        // Screen Recording prompt on Tahoe is to actually attempt SCK
        // (SCShareableContent / SCStream.startCapture). If we refuse to
        // try capture until "granted=true", the prompt never appears,
        // and the user is stuck. Instead we let router.start try; if it
        // throws .permissionDenied, we surface the message in lastError.
        // Engine should run when at least one output is enabled. The mode
        // determines WHICH path runs (stereo = local aggregate; wholeHome
        // = SCK → OwnTone → AirPlay receivers + local FIFO bridges), not
        // WHETHER it runs.
        let shouldRun = hasEnabledOutputs
        switch (streamingState, shouldRun) {
        case (.idle, true), (.error, true):
            streamingState = .starting
            lastError = nil
            SyncCastLog.log("reconcile: starting router (SCK capture)")
            do {
                let snapshot = devices
                // Push routing BEFORE start so Router.start's "for dev
                // where routing[dev.id].enabled" loop actually opens
                // AUHAL for the user's selections.
                for (id, r) in routing {
                    await router.setRouting(r)
                    if r.enabled { await router.enable(deviceID: id) }
                }
                // Push AirPlay state BEFORE SCK start. AirPlay activation
                // (OwnTone spawn) is independent of SCK and must not be
                // gated by it. If SCK is slow / failing / waiting on a
                // TCC prompt, AirPlay should still kick off.
                await pushAirplayState()
                try await router.start(devices: snapshot)
                SyncCastLog.log("reconcile: router.start OK")
                // After 1.5s, log the IOProc tick count to confirm CoreAudio
                // is actually pumping data. If still 0 → TCC denied mic.
                Task { [weak self] in
                    for delay in [1, 2, 4, 6] as [UInt64] {
                        try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                        guard let self else { return }
                        let report = await self.router.diagnosticSCKReport()
                        SyncCastLog.log("SCK report @ \(delay)s: \(report)")
                    }
                }
                for (id, r) in routing {
                    if r.enabled { await router.enable(deviceID: id) }
                    else         { await router.disable(deviceID: id) }
                    await router.setRouting(r)
                }
                await pushAirplayState()
                streamingState = .running
                SyncCastLog.log("reconcile: state=running")
            } catch {
                SyncCastLog.log("reconcile: router.start FAILED: \(error)")
                lastError = "engine: \(error.localizedDescription)"
                streamingState = .error
            }
        case (.running, false):
            SyncCastLog.log("reconcile: stopping (no enabled outputs)")
            await router.setActiveAirplayDevices([])
            await router.stop()
            streamingState = .idle
        case (.running, true):
            // ORDER MATTERS. Router holds its own copy of `routing`
            // (Router.routing) which `syncLocalOutputs` reads to decide
            // which AUHALs to open/close. If we call syncLocalOutputs
            // BEFORE pushing the latest routing snapshot, it sees stale
            // enabled-flags and leaves a just-disabled output's AUHAL
            // running — symptom the user reports as "I turned MBP off
            // but it kept playing while only Xiaomi should have been on".
            // Push routing first, THEN reconcile the AUHAL set, THEN
            // push AirPlay state.
            SyncCastLog.log("reconcile: pushing routing updates + syncing local outputs")
            for (_, r) in routing {
                await router.setRouting(r)
            }
            await router.syncLocalOutputs(devices: devices)
            await pushAirplayState()
        default:
            SyncCastLog.log("reconcile: no-op (state=\(streamingState.rawValue) shouldRun=\(shouldRun))")
            break
        }
    }

    /// Sync the enabled AirPlay devices over to the sidecar / OwnTone.
    private func pushAirplayState() async {
        let enabledAirplay = devices.filter {
            $0.transport == .airplay2 && (routing[$0.id]?.enabled ?? false)
        }
        SyncCastLog.log("pushAirplayState: enabledAirplay=\(enabledAirplay.map { $0.name })")
        for dev in enabledAirplay {
            SyncCastLog.log("  registerAirplayDevice: \(dev.name) host=\(dev.host ?? "?") port=\(dev.port ?? 7000)")
            await router.registerAirplayDevice(
                id: dev.id,
                name: dev.name,
                host: dev.host ?? "",
                port: dev.port ?? 7000
            )
            if let r = routing[dev.id] {
                await router.setAirplayVolume(id: dev.id, volume: r.volume)
            }
        }
        SyncCastLog.log("setActiveAirplayDevices: ids=\(enabledAirplay.map { $0.id.prefix(8) })")
        await router.setActiveAirplayDevices(enabledAirplay.map { $0.id })
    }

    // MARK: - Intents

    /// Switch between stereo and whole-home modes. Tears down the current
    /// pipeline (silence for ~200 ms during transition is acceptable),
    /// disables every device that's not selectable in the new mode, then
    /// reconciles the engine so the new mode's path comes up.
    ///
    /// Why disable non-selectable devices automatically: if the user had
    /// MBP扬声器 enabled in stereo mode and switches to whole-home, that
    /// device is still selectable (whole-home covers everything). But if
    /// they had Xiaomi enabled in whole-home and switch to stereo, Xiaomi
    /// is no longer reachable — leaving its routing.enabled=true would
    /// surface as `lastError` on every reconcile. Cleaner to flip it off
    /// at mode-switch time and let the user re-pick the next time they
    /// switch back.
    func setMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        SyncCastLog.log("setMode: \(mode.rawValue) → \(newMode.rawValue)")
        mode = newMode
        // Disable any device that the new mode can't drive.
        for dev in devices {
            if !isSelectableInMode(dev, mode: newMode),
               var r = routing[dev.id], r.enabled {
                r.enabled = false
                routing[dev.id] = r
            }
        }
        reconcileEngine()
    }

    func toggleDevice(_ id: String) {
        var r = routing[id] ?? DeviceRouting(deviceID: id)
        let oldEnabled = r.enabled
        r.enabled.toggle()
        routing[id] = r
        let name = devices.first(where: { $0.id == id })?.name ?? id
        // Emit BOTH the toggled id and the post-toggle full routing so
        // we can prove or disprove the user-reported "click X but Y
        // toggled" symptom from the log alone (no Console.app needed).
        SyncCastLog.log("toggleDevice: \(name) [id=\(id.prefix(8))] \(oldEnabled ? "ON" : "off") → \(r.enabled ? "ON" : "off"). routing: { \(routingSummary()) }")
        reconcileEngine()
    }

    func setVolume(_ value: Float, for id: String) {
        var r = routing[id] ?? DeviceRouting(deviceID: id)
        r.volume = max(0, min(1, value))
        routing[id] = r
        reconcileEngine()
    }

    func toggleMute(_ id: String) {
        var r = routing[id] ?? DeviceRouting(deviceID: id)
        r.muted.toggle()
        routing[id] = r
        reconcileEngine()
    }

    /// Devices the user can plausibly target. Excludes:
    ///   - BlackHole (virtual capture sink — routing audio TO it could
    ///     feedback into our SCK capture path).
    ///   - Our own private aggregate devices (UID prefix
    ///     `io.syncast.aggregate.v1.`) — these are created by the Router
    ///     to drive multi-output sync; user must never see them.
    ///
    /// Notably we DO show user-created aggregate / multi-output devices
    /// from Audio MIDI Setup. Earlier versions filtered these blanket-
    /// style as a feedback safeguard, but with the Router now operating
    /// its own aggregate, blanket-filtering would surprise users who
    /// built their own. Routing into a USER-created aggregate that
    /// happens to include the system input would feedback, so we still
    /// rely on SCK's `excludesCurrentProcessAudio` defense at the
    /// capture layer.
    private func isUserSelectableOutput(_ d: Device) -> Bool {
        if let uid = d.coreAudioUID, uid.contains("BlackHole") { return false }
        // Our own private aggregate (created by Router.reconcileLocalDriver)
        // is invisible-by-construction (kAudioAggregateDeviceIsPrivateKey=1)
        // but as a belt-and-braces filter in case macOS ever surfaces it,
        // hide it by UID prefix.
        if let uid = d.coreAudioUID,
           uid.hasPrefix("io.syncast.aggregate.v1.") {
            return false
        }
        let lower = d.name.lowercased()
        if lower.contains("blackhole") { return false }
        return true
    }

    /// Whether this device is reachable in a given mode.
    /// - .stereo  : only local CoreAudio outputs are usable (low-latency path)
    /// - .wholeHome : every output is usable (AirPlay receivers natively;
    ///   local CoreAudio outputs participate via the FIFO bridge)
    func isSelectableInMode(_ d: Device, mode: Mode) -> Bool {
        guard isUserSelectableOutput(d) else { return false }
        switch mode {
        case .stereo:
            return d.transport == .coreAudio
        case .wholeHome:
            return true
        }
    }

    /// Devices visible in the UI for the CURRENT mode. Filters by both
    /// the global "is targetable at all" check and the mode-specific
    /// reachability.
    var localDevices: [Device] {
        devices.filter {
            $0.transport == .coreAudio && isSelectableInMode($0, mode: mode)
        }
    }
    var airPlayDevices: [Device] {
        devices.filter {
            $0.transport == .airplay2 && isSelectableInMode($0, mode: mode)
        }
    }
    var enabledDeviceCount: Int { routing.values.filter(\.enabled).count }
}
