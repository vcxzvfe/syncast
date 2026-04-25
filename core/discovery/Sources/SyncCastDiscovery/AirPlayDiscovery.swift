import Foundation
import Network

/// Discovers AirPlay 2 receivers via Bonjour (`_airplay._tcp`).
///
/// We use Apple's `NWBrowser` (Network framework) rather than legacy
/// `NetServiceBrowser`. The TXT record carries useful capability bits
/// (features, model, deviceid) that the router uses later.
public final class AirPlayDiscovery: @unchecked Sendable {
    private let serviceType = "_airplay._tcp"
    private var browser: NWBrowser?
    private var continuation: AsyncStream<DiscoveryEvent>.Continuation?
    private var seen: [String: Device] = [:]
    private let idMap = StableIDMap()

    public init() {}

    public func events() -> AsyncStream<DiscoveryEvent> {
        AsyncStream { continuation in
            self.continuation = continuation
            self.start()
            continuation.onTermination = { @Sendable _ in self.stop() }
        }
    }

    private func start() {
        let params = NWParameters()
        params.includePeerToPeer = false
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(
            type: serviceType, domain: nil
        )
        let browser = NWBrowser(for: descriptor, using: params)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.handleResults(results)
        }
        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let err):
                self?.continuation?.yield(.error("airplay browse: \(err)"))
            default:
                break
            }
        }
        browser.start(queue: .global(qos: .utility))
        self.browser = browser
    }

    private func stop() {
        browser?.cancel()
        browser = nil
    }

    private func handleResults(_ results: Set<NWBrowser.Result>) {
        var nowSeen = Set<String>()
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint else { continue }
            nowSeen.insert(name)
            let txt = txtDictionary(from: result.metadata)
            let model = txt["model"]
            let host = hostString(for: result.endpoint)
            let port = portFromTXT(txt) ?? 7000
            let stableID = idMap.id(for: "ap:\(name)")
            let device = Device(
                id: stableID,
                transport: .airplay2,
                name: name,
                model: model,
                host: host,
                port: port,
                coreAudioUID: nil,
                isOutputCapable: true,
                supportsHardwareVolume: true,
                nominalSampleRate: 44_100
            )
            if let prev = seen[name] {
                if prev != device {
                    seen[name] = device
                    continuation?.yield(.updated(device))
                }
            } else {
                seen[name] = device
                continuation?.yield(.appeared(device))
            }
        }
        for (name, dev) in seen where !nowSeen.contains(name) {
            seen.removeValue(forKey: name)
            continuation?.yield(.disappeared(deviceID: dev.id))
        }
    }

    private func txtDictionary(from metadata: NWBrowser.Result.Metadata) -> [String: String] {
        if case let .bonjour(record) = metadata {
            return record.dictionary
        }
        return [:]
    }

    private func hostString(for endpoint: NWEndpoint) -> String? {
        // The endpoint resolves at connection time. The router resolves it via
        // `NWConnection`; here we expose a best-effort textual form.
        return String(describing: endpoint)
    }

    private func portFromTXT(_ txt: [String: String]) -> Int? {
        if let raw = txt["port"], let v = Int(raw) { return v }
        return nil
    }
}
