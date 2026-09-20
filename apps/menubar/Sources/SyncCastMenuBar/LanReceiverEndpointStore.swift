import Foundation
import SyncCastRouter

/// The literal address each paired receiver was last reached on, so a
/// connection does not depend on mDNS resolving the service name. Local
/// preferences only; never logged with the token, never leaves the machine.
enum LanReceiverEndpointStore {
    static let defaultsKey = "syncast.lanReceiverLastEndpoint.v1"

    static func load(defaults: UserDefaults = .standard) -> [String: LanReceiverLastEndpoint] {
        guard let data = defaults.data(forKey: defaultsKey) else { return [:] }
        do {
            return try JSONDecoder().decode([String: LanReceiverLastEndpoint].self, from: data)
                .filter { !$0.key.isEmpty && !$0.value.host.isEmpty && $0.value.port != 0 }
        } catch {
            SyncCastLog.log("lan endpoint store: unreadable, starting empty: \(error)")
            return [:]
        }
    }

    static func save(_ endpoints: [String: LanReceiverLastEndpoint], defaults: UserDefaults = .standard) {
        guard !endpoints.isEmpty else { defaults.removeObject(forKey: defaultsKey); return }
        do {
            defaults.set(try StableJSON.encoder.encode(endpoints), forKey: defaultsKey)
        } catch {
            SyncCastLog.log("lan endpoint store: could not encode: \(error)")
        }
    }
}
