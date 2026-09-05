import Foundation
import SyncCastDiscovery

/// AirPlay pairing plumbing.
///
/// Everything here is deliberately short-lived on the wire. The sidecar owns
/// the long human-scale window (the user has to read a full-screen PIN off the
/// receiving Mac and type it back), and reports progress by notification, so
/// none of these calls can wedge the IPC connection — which is shared with
/// `stream.stop` and `mode.set` and therefore must never block.
extension Router {
    /// Ceiling for a pairing RPC. Every pairing method returns in
    /// milliseconds by contract; if one does not, something is wrong and the
    /// UI must find out rather than hanging.
    public static let pairingRpcTimeout: TimeInterval = 5

    public enum PairingError: Error, CustomStringConvertible {
        case sidecarUnavailable
        case timedOut(String)
        case rejected(String)

        public var description: String {
            switch self {
            case .sidecarUnavailable:
                return "the audio helper is not running"
            case .timedOut(let method):
                return "\(method) did not answer in time"
            case .rejected(let detail):
                return detail
            }
        }
    }

    /// Stable key under which a receiver's pairing state is tracked, shared
    /// verbatim with the sidecar's `Device.pairing_key`. For AirPlay receivers
    /// this is `ap:<normalized-deviceid>`; the fallback to the per-launch id
    /// exists only so a device with no stable identity still gets a key rather
    /// than crashing the lookup.
    public static func pairingKey(for device: Device) -> String {
        if let key = device.persistenceKey { return key }
        // Fallback for a device with no stable persistence key. It MUST match
        // the sidecar's `Device.pairing_key`, which uses `name:<name>` when an
        // AirPlay receiver advertises no Bonjour `deviceid`. Falling back to the
        // per-launch `device.id` instead (the old behaviour) keyed the two
        // sides differently, so the UI's `pairingState(for:)` lookup missed and
        // `beginPairing` could not resolve the output. coreAudio always has a
        // persistenceKey, so this branch only affects deviceid-less AirPlay
        // receivers (the real targets, Mac mini / Xiaomi, both advertise one).
        switch device.transport {
        case .airplay2:
            return "name:\(device.name)"
        case .coreAudio, .lanReceiver:
            // Neither reaches here in practice: a CoreAudio device always has
            // a UID and a LAN receiver always has a Bonjour instance name, so
            // `persistenceKey` answered above. A LAN receiver also has nothing
            // to do with AirPlay pairing — its own shared token is a different
            // mechanism entirely (see `LanReceiverLink`) — so the per-launch id
            // is the right inert answer rather than a `name:` key the sidecar
            // would then try to match against an OwnTone output.
            return device.id
        }
    }

    public func pairingState(forKey key: String) -> PairingState {
        pairingStatesStorage[key] ?? .notRequired
    }

    public func pairingStatesSnapshot() -> [String: PairingState] {
        pairingStatesStorage
    }

    public func pairingError(forKey key: String) -> String? {
        pairingErrorsStorage[key]
    }

    func recordPairingState(deviceKey: String, stateStr: String, reason: String?) {
        let state = PairingState.fromWire(stateStr)
        pairingStatesStorage[deviceKey] = state
        if let reason, !reason.isEmpty, state == .failed {
            pairingErrorsStorage[deviceKey] = reason
        } else if state == .paired || state == .notRequired {
            pairingErrorsStorage.removeValue(forKey: deviceKey)
        }
    }

    /// Forget a cached terminal outcome (`failed` / `timedOut` / `cancelled`)
    /// for one receiver, so a NEW attempt does not inherit the old one's.
    ///
    /// The UI polls `pairingStatesSnapshot()` once a second. Without this, the
    /// cached failure from the previous attempt kept being re-applied to the
    /// fresh sheet on every tick, bouncing the user back to the failure screen
    /// about a second after they pressed "Try again" — so a receiver that
    /// failed once could not practically be paired at all.
    ///
    /// Resets to `.required` rather than removing the entry: the receiver
    /// demonstrably still needs pairing (that is why we are here), and
    /// dropping the key would report `.notRequired` and take the "Pair"
    /// affordance out of the device list until the sidecar spoke again.
    public func resetPairingState(deviceKey: String) {
        pairingStatesStorage[deviceKey] = .required
        pairingErrorsStorage.removeValue(forKey: deviceKey)
    }

    /// Ask the receiver to display its PIN. Returns the state the sidecar
    /// entered; progress after that arrives via `event.pairing_state`.
    @discardableResult
    public func beginPairing(deviceKey: String) async throws -> PairingState {
        let result = try await pairingCall(
            "pairing.begin", params: ["device_key": deviceKey]
        )
        let state = (result as? [String: Any])?["state"] as? String ?? "failed"
        recordPairingState(deviceKey: deviceKey, stateStr: state, reason: nil)
        return PairingState.fromWire(state)
    }

    /// Outcome of handing a PIN over. `reason` is a fixed, secret-free string
    /// chosen by the sidecar — never an upstream exception's text.
    public struct PINSubmission: Sendable, Equatable {
        public let accepted: Bool
        public let state: PairingState
        public let reason: String?
    }

    /// Hand the four digits the user read off the receiver's screen to the
    /// sidecar. The PIN is never logged here and never placed in a URL.
    @discardableResult
    public func submitPairingPIN(
        deviceKey: String, pin: String
    ) async throws -> PINSubmission {
        let result = try await pairingCall(
            "pairing.submit_pin", params: ["device_key": deviceKey, "pin": pin]
        )
        let dict = result as? [String: Any]
        let state = PairingState.fromWire(dict?["state"] as? String ?? "failed")
        // A rejection has several distinct causes — a malformed PIN, and no
        // attempt in flight because the window already closed — and the two
        // demand different things of the user. Carrying the sidecar's reason
        // through is what stops the UI from telling someone their correct
        // four digits are "not four digits".
        return PINSubmission(
            accepted: dict?["accepted"] as? Bool ?? false,
            state: state,
            reason: dict?["reason"] as? String
        )
    }

    @discardableResult
    public func cancelPairing(deviceKey: String) async throws -> Bool {
        let result = try await pairingCall(
            "pairing.cancel", params: ["device_key": deviceKey]
        )
        let cancelled = (result as? [String: Any])?["cancelled"] as? Bool ?? false
        // Only record it when something was actually cancelled. Recording
        // unconditionally marks a receiver nobody ever tried to pair as
        // "pairing did not finish", for the rest of the session, purely
        // because the user backed out of the explanation sheet.
        if cancelled {
            recordPairingState(deviceKey: deviceKey, stateStr: "cancelled", reason: nil)
        }
        return cancelled
    }

    /// Refresh pairing state from the sidecar (used on bootstrap, where no
    /// notification has arrived yet).
    public func refreshPairingState(deviceKey: String) async throws -> PairingState {
        let result = try await pairingCall(
            "pairing.status", params: ["device_key": deviceKey]
        )
        let dict = result as? [String: Any]
        let state = dict?["state"] as? String ?? "not_required"
        let lastError = dict?["last_error"] as? String
        recordPairingState(deviceKey: deviceKey, stateStr: state, reason: lastError)
        return PairingState.fromWire(state)
    }

    /// Bounded JSON-RPC call. `IpcClient.call` has no timeout of its own, and
    /// a pairing UI that hangs forever on a wedged sidecar is worse than one
    /// that reports a failure the user can retry.
    ///
    /// The bound only works because `IpcClient.call` honours cancellation: a
    /// task group must await every child before it can return, so racing a
    /// timeout against a child that ignores `cancelAll()` produces exactly
    /// the hang this wrapper exists to prevent.
    private func pairingCall(
        _ method: String,
        params: [String: Any]
    ) async throws -> Any {
        guard let ipc else { throw PairingError.sidecarUnavailable }
        let timeout = Self.pairingRpcTimeout
        return try await withThrowingTaskGroup(of: Any.self) { group in
            group.addTask { try await ipc.call(method, params: params) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw PairingError.timedOut(method)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw PairingError.timedOut(method)
            }
            return first
        }
    }
}
