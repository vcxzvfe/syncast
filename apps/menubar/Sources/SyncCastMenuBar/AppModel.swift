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

    private let discovery: DiscoveryService
    private let router: Router

    init() {
        self.discovery = DiscoveryService()
        self.router = Router()
        Task { await self.bootstrap() }
    }

    private func bootstrap() async {
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
            case .updated(let dev):
                if let idx = devices.firstIndex(where: { $0.id == dev.id }) {
                    devices[idx] = dev
                }
            case .disappeared(let id):
                devices.removeAll { $0.id == id }
            case .error(let msg):
                lastError = msg
            }
        }
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
    }

    func toggleDevice(_ id: String) {
        var r = routing[id] ?? DeviceRouting(deviceID: id)
        r.enabled.toggle()
        routing[id] = r
    }

    func setVolume(_ value: Float, for id: String) {
        var r = routing[id] ?? DeviceRouting(deviceID: id)
        r.volume = max(0, min(1, value))
        routing[id] = r
    }

    func toggleMute(_ id: String) {
        var r = routing[id] ?? DeviceRouting(deviceID: id)
        r.muted.toggle()
        routing[id] = r
    }

    var localDevices: [Device] { devices.filter { $0.transport == .coreAudio } }
    var airPlayDevices: [Device] { devices.filter { $0.transport == .airplay2 } }
    var enabledDeviceCount: Int { routing.values.filter(\.enabled).count }
}
