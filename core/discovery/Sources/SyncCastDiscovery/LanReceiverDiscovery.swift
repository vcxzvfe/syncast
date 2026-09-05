import Foundation
import Network

/// Discovers SyncCast receiver daemons via Bonjour `_synccast-pcm._udp`.
///
/// Deliberately much smaller than `AirPlayDiscovery`: there is one service
/// type rather than two to merge, the instance name IS the stable identity (a
/// receiver is started with `--name`, and the daemon refuses to advertise
/// without one), and there is no self-advertisement to filter out — this Mac
/// is the sender and never publishes the service.
///
/// The same serial-queue confinement rule applies: `NWBrowser`'s callback can
/// fire from libdispatch on any thread, and every mutation of `seen` /
/// `continuation` happens on `queue`.
public final class LanReceiverDiscovery: @unchecked Sendable {

    /// The service the receiver daemon advertises.
    public static let serviceType = "_synccast-pcm._udp"

    /// TXT keys the daemon publishes. Everything here is advisory: a receiver
    /// that omits them still shows up, because the instance name alone is
    /// enough to reach it and the link's `hello_ack` reports the truth anyway.
    static let versionTXTKey = "v"
    static let nameTXTKey = "name"
    static let tokenHintTXTKey = "token"
    static let rateTXTKey = "rate"

    /// Protocol version this build speaks. A receiver advertising anything
    /// else is listed with its version in the model field rather than hidden,
    /// so a user who upgraded one side can see why the other will not connect.
    public static let supportedVersion = "1"

    /// Same rationale as `AirPlayDiscovery.rescanRemovalGraceSeconds`: a
    /// freshly restarted browser's first callback is routinely incomplete, and
    /// treating "absent" as "gone" there would tear down a playing link.
    public static let rescanRemovalGraceSeconds: Double = 6.0

    private var browser: NWBrowser?
    private var latestResults: Set<NWBrowser.Result> = []
    private var removalGate = RescanRemovalGate()
    private var continuation: AsyncStream<DiscoveryEvent>.Continuation?
    /// Keyed by the Bonjour instance name.
    private var seen: [String: Device] = [:]
    private let idMap = StableIDMap()
    private let queue = DispatchQueue(label: "io.syncast.discovery.lan")

    public init() {}

    public func events() -> AsyncStream<DiscoveryEvent> {
        AsyncStream { continuation in
            self.continuation = continuation
            self.start()
            continuation.onTermination = { @Sendable _ in self.stop() }
        }
    }

    /// Tear down and restart the browser, forcing a fresh round of queries.
    /// A no-op before `events()` has been called — there is no subscriber to
    /// deliver to, and a browser nobody consumes only burns radio time.
    public func rescan() {
        queue.async { [weak self] in
            guard let self, self.continuation != nil else { return }
            self.stop()
            self.removalGate.suppressRemovals(
                until: Date().addingTimeInterval(Self.rescanRemovalGraceSeconds)
            )
            self.start()
        }
    }

    private func start() {
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(
            type: Self.serviceType, domain: nil
        )
        let browser = NWBrowser(for: descriptor, using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.queue.async { self?.handleResults(results) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            guard case .failed(let error) = state else { return }
            self?.queue.async {
                self?.continuation?.yield(.error("\(Self.serviceType) browse: \(error)"))
            }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    private func stop() {
        browser?.cancel()
        browser = nil
        // `latestResults` is deliberately kept: `rescan()` restarts the
        // browser and relies on the previous set surviving until fresh
        // callbacks land, exactly as `seen` is kept.
    }

    private func handleResults(_ results: Set<NWBrowser.Result>) {
        latestResults = results
        var merged: [String: Device] = [:]
        for result in results {
            guard case let .service(instanceName, _, domain, _) = result.endpoint else {
                continue
            }
            let trimmed = instanceName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let txt = Self.txtDictionary(from: result.metadata)
            let device = Self.makeDevice(
                instanceName: trimmed,
                domain: domain,
                txt: txt,
                id: idMap.id(for: "lan:\(trimmed)")
            )
            merged[trimmed] = device
        }

        for (key, device) in merged {
            if let previous = seen[key] {
                if previous != device {
                    seen[key] = device
                    continuation?.yield(.updated(device))
                }
            } else {
                seen[key] = device
                continuation?.yield(.appeared(device))
            }
        }
        apply(removalGate.observe(keys: Set(merged.keys), now: Date()))
    }

    /// Build the `Device` for one browse result. Pure and `static` so the TXT
    /// handling — which is external data — is unit-testable without a browser.
    static func makeDevice(
        instanceName: String,
        domain: String?,
        txt: [String: String],
        id: String
    ) -> Device {
        // The friendly name is advisory; the instance name is the identity.
        // An empty or whitespace-only `name=` falls back rather than producing
        // a blank row.
        let advertised = txt[nameTXTKey]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = (advertised?.isEmpty == false ? advertised! : instanceName)
        let version = txt[versionTXTKey]?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Version mismatch is surfaced, not hidden: a receiver the user just
        // upgraded must not simply vanish from the list.
        let model = (version == nil || version == supportedVersion)
            ? "SyncCast receiver"
            : "SyncCast receiver (protocol v\(version!))"
        let rate = txt[rateTXTKey].flatMap(Double.init)
        return Device(
            id: id,
            transport: .lanReceiver,
            name: displayName,
            model: model,
            host: nil,
            port: nil,
            coreAudioUID: nil,
            isOutputCapable: true,
            // The receiver reports its real answer in `hello_ack.hw_volume`;
            // until it has, the optimistic default keeps the UI from showing a
            // "software volume" warning that may be wrong.
            supportsHardwareVolume: true,
            nominalSampleRate: rate ?? 48_000,
            airplayDeviceID: nil,
            isLocalMachineReceiver: false,
            lanServiceName: instanceName,
            lanServiceDomain: domain,
            lanTokenHint: sanitizedTokenHint(txt[tokenHintTXTKey])
        )
    }

    /// Accept a token hint only if it looks like the 8 hex characters the
    /// protocol specifies. Anything else is dropped rather than rendered — the
    /// hint goes straight into the UI, and an unvalidated TXT value from an
    /// unauthenticated LAN service is not something to draw on screen.
    static func sanitizedTokenHint(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.count == 8, trimmed.allSatisfy({ $0.isHexDigit }) else { return nil }
        return trimmed
    }

    private func apply(_ action: RescanRemovalGate.Action) {
        switch action {
        case .alreadyScheduled:
            break
        case .deferBy(let seconds):
            queue.asyncAfter(deadline: .now() + max(0, seconds)) { [weak self] in
                guard let self else { return }
                self.apply(self.removalGate.recheckFired(now: Date()))
            }
        case .emitNow:
            emitRemovals(keptKeys: removalGate.lastBrowserKeys)
        }
    }

    private func emitRemovals(keptKeys: Set<String>) {
        for (key, device) in seen where !keptKeys.contains(key) {
            seen.removeValue(forKey: key)
            continuation?.yield(.disappeared(deviceID: device.id))
        }
    }

    private static func txtDictionary(
        from metadata: NWBrowser.Result.Metadata
    ) -> [String: String] {
        if case let .bonjour(record) = metadata { return record.dictionary }
        return [:]
    }
}
