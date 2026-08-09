import Foundation
import Network

/// Discovers AirPlay 2 receivers via Bonjour (`_airplay._tcp`).
///
/// We use Apple's `NWBrowser` (Network framework) rather than legacy
/// `NetServiceBrowser`. The TXT record carries useful capability bits
/// (features, model, deviceid) that the router uses later.
public final class AirPlayDiscovery: @unchecked Sendable {
    /// TXT key carrying the receiver's stable AirPlay identity (a MAC-shaped
    /// string). Verified present on every `_airplay._tcp` endpoint on the
    /// local network during recon.
    static let deviceIDTXTKey = "deviceid"

    private let serviceType = "_airplay._tcp"
    private var browser: NWBrowser?
    private var continuation: AsyncStream<DiscoveryEvent>.Continuation?
    /// Keyed by the stable registry key (`id:<deviceid>` when the TXT record
    /// carries one, `name:<instance>` otherwise) — NOT by the raw instance
    /// name. See `handleResults`.
    private var seen: [String: Device] = [:]
    private let idMap = StableIDMap()
    /// Serial queue used to confine all access to `seen` and
    /// `continuation`. NWBrowser's `browseResultsChangedHandler` can fire
    /// concurrently from libdispatch — without this serialization we got
    /// EXC_BAD_ACCESS in Dictionary.makeIterator() when two threads
    /// touched `seen` at once.
    private let queue = DispatchQueue(label: "io.syncast.discovery.airplay")

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
            // Hop onto our serial queue so the Dictionary mutations
            // inside handleResults are never racy against another
            // invocation from libdispatch.
            self?.queue.async { self?.handleResults(results) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let err):
                self?.queue.async { self?.continuation?.yield(.error("airplay browse: \(err)")) }
            default:
                break
            }
        }
        // Pin the browser's own callback queue to ours so even Apple's
        // own internal dispatch path is serial relative to us.
        browser.start(queue: queue)
        self.browser = browser
    }

    private func stop() {
        browser?.cancel()
        browser = nil
    }

    private func handleResults(_ results: Set<NWBrowser.Result>) {
        // A single receiver can produce SEVERAL browse results — this Mac
        // advertises on both loopback and Wi-Fi, so it shows up twice. They
        // are merged here by registry key; keying on the raw instance name
        // instead made the two records fight over one slot and emit a
        // `.updated` storm, which in turn bumped the AirPlay timing epoch and
        // invalidated the calibration cache over and over.
        var merged: [String: Device] = [:]
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint else { continue }
            let txt = txtDictionary(from: result.metadata)
            let model = txt["model"]
            let host = hostString(for: result.endpoint)
            let port = portFromTXT(txt) ?? 7000
            let deviceID = Device.normalizedAirplayDeviceID(txt[Self.deviceIDTXTKey])
            // Only the local machine advertises on the loopback interface.
            // This is the self-identification signal: no name matching, no
            // model matching, no subnet assumptions.
            let onLoopback = result.interfaces.contains { $0.type == .loopback }
            // Registry key preference: the stable AirPlay deviceid, falling
            // back to the instance name when the TXT record omitted it.
            let key = deviceID.map { "id:\($0)" } ?? "name:\(name)"
            let stableID = idMap.id(for: "ap:\(key)")
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
                nominalSampleRate: 44_100,
                airplayDeviceID: deviceID,
                isLocalMachineReceiver: onLoopback
                    || (merged[key]?.isLocalMachineReceiver ?? false)
            )
            merged[key] = device
        }

        for (key, device) in merged {
            if let prev = seen[key] {
                if prev != device {
                    seen[key] = device
                    continuation?.yield(.updated(device))
                }
            } else {
                seen[key] = device
                continuation?.yield(.appeared(device))
            }
        }
        for (key, dev) in seen where merged[key] == nil {
            seen.removeValue(forKey: key)
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
        // KNOWN LIMITATION: for a Bonjour endpoint this yields the escaped
        // service instance string (e.g. `<AirPlay\032receiver\032B>._airplay.
        // _tcp.local.`), not a hostname or IP. Nothing in the current
        // pipeline dials it — OwnTone rediscovers receivers itself and the
        // unified-clock-domain path reaches this Mac over loopback — so it is
        // left as-is rather than widening this change. Do not build a direct
        // connection on this value without resolving the endpoint first.
        return String(describing: endpoint)
    }

    private func portFromTXT(_ txt: [String: String]) -> Int? {
        if let raw = txt["port"], let v = Int(raw) { return v }
        return nil
    }
}
