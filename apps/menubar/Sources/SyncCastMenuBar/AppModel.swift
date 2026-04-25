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
    var wholeHouseEnabled: Bool = false
    var streamingState: StreamingState = .idle
    var lastError: String?
    /// Screen Recording TCC permission state. We replaced the old
    /// "BlackHole microphone" gate with this.
    var screenRecordingGranted: Bool = false

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
        if let target = ProcessInfo.processInfo.environment["SYNCAST_AUTO_TEST"] {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard let self else { return }
                await MainActor.run {
                    let match = self.devices.first { d in
                        d.name.localizedCaseInsensitiveContains(target) ||
                        (target == "mbp" && d.name.contains("MacBook Pro扬声器"))
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

    private func applyEvent(_ event: DiscoveryEvent) async {
        await MainActor.run {
            switch event {
            case .appeared(let dev):
                SyncCastLog.log("[SyncCast] device appeared: \(dev.name) (\(dev.transport.rawValue))".replacingOccurrences(of: "[SyncCast] ", with: ""))
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

    // BlackHole detection removed — SCK doesn't need it.
    private func detectBlackHole(in dev: Device) { /* no-op, retained for call-site compat */ }

    /// When the set of enabled devices changes (or whole-house mode flips),
    /// reconcile the audio engine: start it if we have BlackHole + at least
    /// one enabled output, stop it otherwise.
    private func reconcileEngine() {
        Task { await self.reconcileEngineAsync() }
    }

    private func reconcileEngineAsync() async {
        SyncCastLog.log("reconcile: scrRec=\(screenRecordingGranted) state=\(streamingState.rawValue) hasEnabled=\(hasEnabledOutputs) wholeHouse=\(wholeHouseEnabled)")
        // We DON'T gate on screenRecordingGranted any more.
        // Reason: the only way to make macOS show the user-facing
        // Screen Recording prompt on Tahoe is to actually attempt SCK
        // (SCShareableContent / SCStream.startCapture). If we refuse to
        // try capture until "granted=true", the prompt never appears,
        // and the user is stuck. Instead we let router.start try; if it
        // throws .permissionDenied, we surface the message in lastError.
        let shouldRun = hasEnabledOutputs || wholeHouseEnabled
        switch (streamingState, shouldRun) {
        case (.idle, true), (.error, true):
            streamingState = .starting
            lastError = nil
            SyncCastLog.log("reconcile: starting router (SCK capture)")
            do {
                let snapshot = devices
                // Push routing BEFORE start so Router.start's "for dev
                // where routing[dev.id].enabled" loop actually opens
                // AUHAL for the user's selections. Without this push,
                // Router.start would see an empty routing dict and skip
                // every device — causing the engine to capture audio
                // but never render it to any output.
                for (id, r) in routing {
                    await router.setRouting(r)
                    if r.enabled { await router.enable(deviceID: id) }
                }
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
            SyncCastLog.log("reconcile: pushing routing updates + syncing local outputs")
            await router.syncLocalOutputs(devices: devices)
            for (_, r) in routing {
                await router.setRouting(r)
            }
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
        for dev in enabledAirplay {
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
        await router.setActiveAirplayDevices(enabledAirplay.map { $0.id })
    }

    // MARK: - Intents

    func toggleWholeHouse() {
        wholeHouseEnabled.toggle()
        if wholeHouseEnabled {
            for dev in devices {
                var r = routing[dev.id] ?? DeviceRouting(deviceID: dev.id)
                r.enabled = true
                routing[dev.id] = r
            }
        }
        reconcileEngine()
    }

    func toggleDevice(_ id: String) {
        var r = routing[id] ?? DeviceRouting(deviceID: id)
        r.enabled.toggle()
        routing[id] = r
        let name = devices.first(where: { $0.id == id })?.name ?? id
        SyncCastLog.log("toggleDevice: \(name) → enabled=\(r.enabled)")
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

    /// Devices the user can plausibly target. Excludes the BlackHole
    /// capture device (it's the *source*, not an output) and any virtual
    /// aggregate / multi-output devices the system already exposes.
    private func isUserSelectableOutput(_ d: Device) -> Bool {
        // BlackHole is a virtual sink; never list it as a target. SCK
        // captures system audio without needing BlackHole installed, but
        // the user may still have it from before — hide it.
        if let uid = d.coreAudioUID, uid.contains("BlackHole") { return false }
        let lower = d.name.lowercased()
        if lower.contains("blackhole") { return false }
        if lower.contains("aggregate") { return false }
        if lower.contains("multi-output") || lower.contains("multioutput") { return false }
        if d.name.contains("多输出") { return false }
        return true
    }

    var localDevices: [Device] {
        devices.filter { $0.transport == .coreAudio && isUserSelectableOutput($0) }
    }
    var airPlayDevices: [Device] {
        devices.filter { $0.transport == .airplay2 && isUserSelectableOutput($0) }
    }
    var enabledDeviceCount: Int { routing.values.filter(\.enabled).count }
}
