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
    var blackHoleAvailable: Bool = false
    var blackHoleUID: String?

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
        // 1. Spawn the bundled sidecar (which in turn spawns OwnTone).
        do {
            let paths = try sidecarLauncher.start()
            sidecarRunning = true
            // Give the sidecar a moment to bind its sockets before the
            // Router tries to connect.
            try? await Task.sleep(nanoseconds: 500_000_000)
            try await router.attachSidecar(.init(
                control: paths.controlSocket,
                audio:   paths.audioSocket
            ))
        } catch {
            lastError = "sidecar: \(error.localizedDescription)"
        }
        // 2. Start discovery (CoreAudio + Bonjour).
        await discovery.start()
        let stream = await discovery.subscribe()
        Task { [weak self] in
            for await event in stream {
                guard let self else { break }
                await self.applyEvent(event)
            }
        }
    }

    private func applyEvent(_ event: DiscoveryEvent) async {
        await MainActor.run {
            switch event {
            case .appeared(let dev):
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
                lastError = msg
            }
        }
    }

    /// BlackHole exposes itself as a CoreAudio device whose UID contains
    /// "BlackHole". We pick the first one we see and remember it. Users
    /// with multiple BlackHole channel counts (2ch / 16ch / 64ch) get the
    /// 2ch one because that's what we asked for in bootstrap.sh.
    private func detectBlackHole(in dev: Device) {
        guard dev.transport == .coreAudio,
              let uid = dev.coreAudioUID,
              uid.contains("BlackHole") else { return }
        if blackHoleUID == nil {
            blackHoleUID = uid
            blackHoleAvailable = true
        }
    }

    /// When the set of enabled devices changes (or whole-house mode flips),
    /// reconcile the audio engine: start it if we have BlackHole + at least
    /// one enabled output, stop it otherwise.
    private func reconcileEngine() {
        Task { await self.reconcileEngineAsync() }
    }

    private func reconcileEngineAsync() async {
        guard blackHoleAvailable, let uid = blackHoleUID else {
            if streamingState == .running {
                await router.stop()
                streamingState = .idle
            }
            return
        }
        let shouldRun = hasEnabledOutputs || wholeHouseEnabled
        switch (streamingState, shouldRun) {
        case (.idle, true), (.error, true):
            streamingState = .starting
            do {
                let snapshot = devices
                try await router.start(blackHoleUID: uid, devices: snapshot)
                for (id, r) in routing {
                    if r.enabled { await router.enable(deviceID: id) }
                    else         { await router.disable(deviceID: id) }
                    await router.setRouting(r)
                }
                streamingState = .running
            } catch {
                lastError = "\(error)"
                streamingState = .error
            }
        case (.running, false):
            await router.stop()
            streamingState = .idle
        case (.running, true):
            // Push current routing to the running engine.
            for (_, r) in routing {
                await router.setRouting(r)
            }
        default:
            break
        }
    }

    // MARK: - Intents

    func toggleWholeHouse() {
        wholeHouseEnabled.toggle()
        if wholeHouseEnabled {
            // Enable every output that's not the BlackHole capture itself.
            for dev in devices where dev.coreAudioUID != blackHoleUID {
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
        if let uid = d.coreAudioUID, uid == blackHoleUID { return false }
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
