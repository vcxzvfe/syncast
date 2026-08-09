import Foundation
import SyncCastDiscovery

/// Persistence for the local output devices the unified clock domain renders
/// to, plus the resolution rules that let the selection survive a change of
/// location.
///
/// The problem this exists to solve: this is a laptop. In the office it is
/// plugged into one display, at home into a different one. The user's choice
/// therefore has to be stored as a set of CoreAudio UIDs (never names, never
/// indices), kept intact when a device is absent, and quietly narrowed to
/// whatever is actually connected right now. A device that vanishes must not
/// be forgotten — it comes back when the user does.
///
/// The resolution logic is pure and unit tested; only `load`/`save` touch
/// `UserDefaults`.
public enum WholeHomeMemberStore {
    public static let defaultsKey = "syncast.wholeHome.localMemberUIDs"

    /// One row of the member picker.
    public struct Entry: Identifiable, Hashable, Sendable {
        public let uid: String
        /// Display name when the device is present; nil when it is not, in
        /// which case the UI shows the remembered UID greyed out.
        public let name: String?
        public let isConnected: Bool
        public let isSelected: Bool

        public var id: String { uid }
    }

    public static func load(defaults: UserDefaults = .standard) -> [String] {
        (defaults.array(forKey: defaultsKey) as? [String]) ?? []
    }

    public static func save(_ uids: [String], defaults: UserDefaults = .standard) {
        defaults.set(uids, forKey: defaultsKey)
    }

    /// The subset of `selectedUIDs` that maps to a device present right now,
    /// in the user's stored order.
    ///
    /// Absent UIDs are skipped, NOT dropped from storage — see the type
    /// documentation.
    public static func presentUIDs(
        selectedUIDs: [String],
        available devices: [Device]
    ) -> [String] {
        let present = Set(devices.compactMap(\.coreAudioUID))
        return selectedUIDs.filter { present.contains($0) }
    }

    /// Rows for the picker: every currently connected local output, plus any
    /// remembered-but-absent selection so the user can see (and un-pick) it.
    public static func entries(
        selectedUIDs: [String],
        available devices: [Device]
    ) -> [Entry] {
        let selected = Set(selectedUIDs)
        var nameByUID: [String: String] = [:]
        var order: [String] = []
        for device in devices {
            guard device.transport == .coreAudio,
                  let uid = device.coreAudioUID,
                  nameByUID[uid] == nil
            else { continue }
            nameByUID[uid] = device.name
            order.append(uid)
        }
        var rows = order.map { uid in
            Entry(
                uid: uid,
                name: nameByUID[uid],
                isConnected: true,
                isSelected: selected.contains(uid)
            )
        }
        for uid in selectedUIDs where nameByUID[uid] == nil {
            rows.append(Entry(uid: uid, name: nil, isConnected: false, isSelected: true))
        }
        return rows
    }

    /// Add or remove one UID, preserving the user's ordering for everything
    /// else. Selecting appends, which makes the first-picked device the
    /// aggregate's preferred master candidate.
    public static func toggling(
        _ uid: String,
        in selectedUIDs: [String]
    ) -> [String] {
        if selectedUIDs.contains(uid) {
            return selectedUIDs.filter { $0 != uid }
        }
        return selectedUIDs + [uid]
    }

    /// Fallback used when the stored selection resolves to nothing: the
    /// current system default output, if it is a usable local output.
    ///
    /// This is what stops "I moved to a different desk" from turning into
    /// "SyncCast has no sound and no way to get it back".
    public static func fallbackSelection(
        available devices: [Device],
        systemDefaultUID: String?
    ) -> [String] {
        if let systemDefaultUID,
           devices.contains(where: { $0.coreAudioUID == systemDefaultUID }) {
            return [systemDefaultUID]
        }
        return []
    }
}
