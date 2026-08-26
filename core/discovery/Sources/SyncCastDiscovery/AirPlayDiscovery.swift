import Foundation
import Network

/// Discovers AirPlay receivers via Bonjour, browsing BOTH `_airplay._tcp`
/// and `_raop._tcp`.
///
/// Browsing only `_airplay._tcp` loses receivers that are online and fully
/// usable: a Xiaomi Sound was observed advertising `_raop._tcp` alone (its
/// `_airplay._tcp` record comes and goes, apparently with standby), which
/// made it vanish from the device list even though OwnTone — which browses
/// both types — could still drive it. Whatever a receiver advertises, if it
/// speaks either protocol we can reach it, so both are browsed and merged.
///
/// We use Apple's `NWBrowser` (Network framework) rather than legacy
/// `NetServiceBrowser`. The TXT record carries useful capability bits
/// (features, model, deviceid) that the router uses later.
public final class AirPlayDiscovery: @unchecked Sendable {
    /// TXT key carrying the receiver's stable AirPlay identity (a MAC-shaped
    /// string). Verified present on every `_airplay._tcp` endpoint on the
    /// local network during recon.
    static let deviceIDTXTKey = "deviceid"

    /// How long after a manual `rescan()` we refuse to emit `.disappeared`.
    ///
    /// A freshly started `NWBrowser` delivers its first
    /// `browseResultsChangedHandler` callback with whatever it has resolved
    /// so far — frequently an empty or partial set. `handleResults` treats
    /// "absent from this callback" as gone, so without this window the very
    /// act of refreshing would report every currently-playing receiver as
    /// disappeared, and the app would tear down its routing and rebuild the
    /// output. The window only suppresses removals; `.appeared`/`.updated`
    /// flow through immediately, which is the whole point of refreshing.
    ///
    /// Suppressed removals are DEFERRED, not dropped: `handleResults` records
    /// the keys the browser last reported and re-runs the removal pass once
    /// the window closes. Dropping them was unsound because `NWBrowser` only
    /// calls `browseResultsChangedHandler` when the result set CHANGES — a
    /// receiver powered off inside the window produced exactly one callback,
    /// and if nothing else on the network moved there was never another one to
    /// notice it had gone.
    ///
    /// NOT calibrated against real mDNS timing yet — see the latency line
    /// the app logs after each rescan.
    public static let rescanRemovalGraceSeconds: Double = 6.0

    /// AirPlay 2 service. Carries the richer TXT record (`deviceid`, `model`,
    /// `features`), so its version of a receiver wins during the merge.
    static let airplayServiceType = "_airplay._tcp"
    /// Legacy RAOP service. Its instance name is `<MAC>@<Display Name>`; the
    /// MAC half normalises to the same value as the AirPlay TXT `deviceid`
    /// (`Device.normalizedAirplayDeviceID` strips separators and uppercases),
    /// which is what lets one receiver seen on both services collapse onto a
    /// single registry key instead of appearing twice.
    static let raopServiceType = "_raop._tcp"

    /// Merge order, not browse order: later entries overwrite earlier ones, so
    /// `_airplay._tcp` is last and its richer record wins for receivers that
    /// advertise both.
    private static let mergeOrder = [raopServiceType, airplayServiceType]

    private var browsers: [String: NWBrowser] = [:]
    /// Most recent browse result set per service type. Each browser reports
    /// independently, so the diff has to run against the UNION — a callback
    /// from one browser must not read as "everything the other browser found
    /// is gone".
    private var latestResults: [String: Set<NWBrowser.Result>] = [:]
    /// Post-rescan removal bookkeeping. Armed by `rescan()`, consulted by
    /// `handleResults`. Confined to `queue` like everything else here; see
    /// `RescanRemovalGate` for why the logic lives in a pure value type.
    private var removalGate = RescanRemovalGate()
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

    /// Tear down and restart the Bonjour browser, forcing a fresh round of
    /// queries instead of waiting for the receiver's next announcement.
    ///
    /// Safe to call at any time: `stop()` only cancels the browser and
    /// leaves the continuation and the `seen` registry intact, so the
    /// replacement browser reports into the same stream and only genuine
    /// deltas surface. We deliberately do NOT clear `seen` — that would
    /// replay the whole table as disappeared+appeared, minting new device
    /// ids and bumping the AirPlay timing epoch for no reason.
    ///
    /// A no-op before `events()` has been called: there is no subscriber to
    /// deliver to, and spinning up a browser whose results nobody consumes
    /// would only burn radio time.
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
        for type in Self.mergeOrder {
            let params = NWParameters()
            params.includePeerToPeer = false
            let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(
                type: type, domain: nil
            )
            let browser = NWBrowser(for: descriptor, using: params)
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                // Hop onto our serial queue so the Dictionary mutations
                // inside handleResults are never racy against another
                // invocation from libdispatch — or against the other
                // browser's callback.
                self?.queue.async { self?.handleResults(results, from: type) }
            }
            browser.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed(let err):
                    self?.queue.async {
                        self?.continuation?.yield(.error("\(type) browse: \(err)"))
                    }
                default:
                    break
                }
            }
            // Pin the browser's own callback queue to ours so even Apple's
            // own internal dispatch path is serial relative to us.
            browser.start(queue: queue)
            browsers[type] = browser
        }
    }

    private func stop() {
        for browser in browsers.values { browser.cancel() }
        browsers.removeAll()
        // Deliberately NOT clearing `latestResults`: `rescan()` restarts the
        // browsers and relies on the previous union surviving until fresh
        // callbacks land, mirroring why `seen` is kept (see `rescan()`).
    }

    private func handleResults(
        _ results: Set<NWBrowser.Result>, from serviceType: String
    ) {
        latestResults[serviceType] = results
        mergeAndDiff()
    }

    private func mergeAndDiff() {
        // A single receiver can produce SEVERAL browse results — this Mac
        // advertises on both loopback and Wi-Fi, so it shows up twice, and a
        // receiver advertising both service types contributes one result per
        // type. They are merged here by registry key; keying on the raw
        // instance name instead made the records fight over one slot and emit
        // a `.updated` storm, which in turn bumped the AirPlay timing epoch
        // and invalidated the calibration cache over and over.
        var merged: [String: Device] = [:]
        for serviceType in Self.mergeOrder {
            for result in latestResults[serviceType] ?? [] {
            guard case let .service(instanceName, _, _, _) = result.endpoint
            else { continue }
            let txt = txtDictionary(from: result.metadata)
            let model = txt["model"]
            let host = hostString(for: result.endpoint)
            let port = portFromTXT(txt) ?? 7000
            // RAOP folds the identity into the instance name (`<MAC>@<Name>`)
            // instead of a `deviceid` TXT key, so split it out — both to get a
            // display name free of the MAC and to produce the same normalised
            // id the AirPlay record yields, which is what merges the two.
            let (name, deviceID) = serviceType == Self.raopServiceType
                ? Self.raopIdentity(instanceName: instanceName)
                : (
                    instanceName,
                    Device.normalizedAirplayDeviceID(txt[Self.deviceIDTXTKey])
                )
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
                // Sticky across callbacks, not just across the results in
                // THIS callback. A browser — especially a freshly restarted
                // one after `rescan()` — routinely delivers a partial set, and
                // this Mac's own receiver arriving with only its Wi-Fi record
                // would otherwise flip the flag false, emit `.updated`, and
                // make our own AirPlay Receiver appear as a selectable
                // whole-home target (a row whose toggle does nothing, because
                // `pushAirplayState` still refuses to register it).
                isLocalMachineReceiver: onLoopback
                    || (merged[key]?.isLocalMachineReceiver ?? false)
                    || (seen[key]?.isLocalMachineReceiver ?? false)
            )
            merged[key] = device
            }
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
        // Removal pass. Deferred for a short window after a manual rescan,
        // because a just-restarted browser's first callbacks are routinely
        // incomplete and every "missing" receiver here would be torn out of
        // the routing table.
        apply(removalGate.observe(keys: Set(merged.keys), now: Date()))
    }

    /// Carry out whatever `RescanRemovalGate` decided. Must run on `queue`;
    /// the deferred re-check hops back onto it, so `seen`, the gate and the
    /// continuation all stay confined to the one serial queue.
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

    /// Report every registered receiver absent from `keptKeys` as gone.
    /// Idempotent, so a deferred pass that races an ordinary callback which
    /// already ran the diff simply finds nothing left to remove.
    private func emitRemovals(keptKeys: Set<String>) {
        for (key, dev) in seen where !keptKeys.contains(key) {
            seen.removeValue(forKey: key)
            continuation?.yield(.disappeared(deviceID: dev.id))
        }
    }

    /// Split a RAOP instance name into (display name, normalised device id).
    ///
    /// RAOP advertises as `<MAC>@<Display Name>` — e.g.
    /// `02AB00CD00EF@<AirPlay receiver B>`. The MAC half normalises to exactly
    /// what `_airplay._tcp`'s `deviceid` TXT key yields for the same receiver,
    /// so both records land on one registry key and the receiver appears once.
    ///
    /// Anything that does not match that shape (no `@`, or a prefix that is not
    /// hex) is passed through as a plain name with no id — better a duplicate
    /// row than a wrong merge onto another receiver's key.
    static func raopIdentity(instanceName: String) -> (name: String, deviceID: String?) {
        guard let at = instanceName.firstIndex(of: "@") else {
            return (instanceName, nil)
        }
        let prefix = String(instanceName[instanceName.startIndex..<at])
        let rest = String(instanceName[instanceName.index(after: at)...])
        guard !rest.isEmpty,
              let deviceID = Device.normalizedAirplayDeviceID(prefix)
        else { return (instanceName, nil) }
        return (rest, deviceID)
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
