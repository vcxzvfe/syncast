import Foundation

/// Aggregates discovery from all transports into a single event stream.
///
/// Owns one `CoreAudioDiscovery` and one `AirPlayDiscovery`, merges their
/// streams, and exposes a unified `Device` registry keyed by the stable
/// SyncCast device ID.
public actor DiscoveryService {
    private let coreAudio: CoreAudioDiscovery
    private let airplay: AirPlayDiscovery
    private var registry: [String: Device] = [:]
    private var subscribers: [UUID: AsyncStream<DiscoveryEvent>.Continuation] = [:]
    private var pumpTask: Task<Void, Never>?

    public init(
        coreAudio: CoreAudioDiscovery = .init(),
        airplay: AirPlayDiscovery = .init()
    ) {
        self.coreAudio = coreAudio
        self.airplay = airplay
    }

    public func start() {
        guard pumpTask == nil else { return }
        pumpTask = Task { [coreAudio, airplay] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await event in coreAudio.events() {
                        await self.ingest(event)
                    }
                }
                group.addTask {
                    for await event in airplay.events() {
                        await self.ingest(event)
                    }
                }
            }
        }
    }

    public func stop() {
        pumpTask?.cancel()
        pumpTask = nil
        for (_, c) in subscribers { c.finish() }
        subscribers.removeAll()
    }

    public func snapshot() -> [Device] {
        Array(registry.values).sorted { $0.name < $1.name }
    }

    public func subscribe() -> AsyncStream<DiscoveryEvent> {
        AsyncStream { continuation in
            let token = UUID()
            self.addSubscriber(token: token, continuation: continuation)
            // Replay current registry to new subscriber.
            for dev in registry.values {
                continuation.yield(.appeared(dev))
            }
            continuation.onTermination = { @Sendable _ in
                Task { await self.removeSubscriber(token: token) }
            }
        }
    }

    private func addSubscriber(token: UUID, continuation: AsyncStream<DiscoveryEvent>.Continuation) {
        subscribers[token] = continuation
    }

    private func removeSubscriber(token: UUID) {
        subscribers.removeValue(forKey: token)
    }

    private func ingest(_ event: DiscoveryEvent) {
        switch event {
        case .appeared(let dev):
            registry[dev.id] = dev
        case .updated(let dev):
            registry[dev.id] = dev
        case .disappeared(let id):
            registry.removeValue(forKey: id)
        case .error:
            break
        }
        for (_, c) in subscribers { c.yield(event) }
    }
}
