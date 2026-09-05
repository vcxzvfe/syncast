import Foundation
import SyncCastRouter

/// One remembered channel assignment, plus the name to show while its device
/// is away.
///
/// Keyed by output UID for the same reason `DeviceStereoImageProfile` is: the
/// setting describes a *cabinet* — "this speaker sits on the left of the desk
/// and should carry the left channel" — so it belongs to the physical output
/// and has to come back on every connect. `Device.id` is re-minted every
/// process and display names are not unique, so neither can carry it.
///
/// Unlike the equalizer and the imager, this store is NOT CoreAudio-only: a
/// LAN receiver's `lan:<instance name>` UID is a legal key here, because the
/// sender applies the matrix before packetising and a receiver is exactly the
/// kind of output someone wants on one channel.
struct DeviceChannelMatrixProfile: Codable, Sendable, Equatable, Identifiable {
    var uid: String
    var displayName: String?
    var settings: ChannelMatrixSettings

    var id: String { uid }

    init(uid: String, displayName: String? = nil, settings: ChannelMatrixSettings) {
        self.uid = uid
        self.displayName = displayName
        self.settings = settings
    }

    func name(fallback: String? = nil) -> String {
        displayName ?? fallback ?? uid
    }
}

/// Versioned `UserDefaults` persistence for per-device channel assignments.
///
/// JSON under one versioned key, separate from the equalizer's and the
/// imager's: the three features are edited and reset independently, and
/// folding them into one record would make "reset the EQ" a reason to rewrite
/// the channel blob.
///
/// Everything except `load`/`save` is pure, so the malformed-data paths are
/// unit-testable without touching the user's defaults.
enum DeviceChannelMatrixStore {
    /// Bump the suffix, never the meaning, when the record shape changes.
    static let defaultsKey = "syncast.deviceChannelMatrix.v1"

    static func load(defaults: UserDefaults = .standard) -> [String: DeviceChannelMatrixProfile] {
        decode(defaults.data(forKey: defaultsKey))
    }

    static func save(
        _ profiles: [String: DeviceChannelMatrixProfile],
        defaults: UserDefaults = .standard
    ) {
        let sanitized = sanitize(Array(profiles.values))
        guard !sanitized.isEmpty else {
            defaults.removeObject(forKey: defaultsKey)
            return
        }
        guard let data = encode(sanitized) else {
            SyncCastLog.log("channel matrix: encode failed; keeping previous stored settings")
            return
        }
        defaults.set(data, forKey: defaultsKey)
    }

    static func encode(_ profiles: [DeviceChannelMatrixProfile]) -> Data? {
        do {
            // Sorted so the stored blob is stable across launches; a plist
            // that churns on every save is noise in backups and in diffs.
            return try JSONEncoder().encode(profiles.sorted { $0.uid < $1.uid })
        } catch {
            SyncCastLog.log("channel matrix: encode error \(error)")
            return nil
        }
    }

    /// Decode + validate. This is external data that has been through
    /// `UserDefaults`, so every failure mode is explicit: absent, unreadable,
    /// and structurally valid-but-nonsensical all collapse to "no settings"
    /// rather than to a half-applied matrix. The clamping in
    /// `ChannelMatrixSettings.sanitized()` is load-bearing: a NaN coefficient
    /// reaching the render thread would turn that speaker into permanent
    /// silence or noise.
    static func decode(_ data: Data?) -> [String: DeviceChannelMatrixProfile] {
        guard let data else { return [:] }
        do {
            let decoded = try JSONDecoder().decode([DeviceChannelMatrixProfile].self, from: data)
            let sanitized = sanitize(decoded)
            if sanitized.count != decoded.count {
                SyncCastLog.log(
                    "channel matrix: dropped \(decoded.count - sanitized.count)"
                        + " malformed setting(s) on load"
                )
            }
            return Dictionary(uniqueKeysWithValues: sanitized.map { ($0.uid, $0) })
        } catch {
            SyncCastLog.log("channel matrix: stored settings unreadable (\(error)); ignoring them")
            return [:]
        }
    }

    /// Drop entries with no UID, clamp everything into range, snap to the UI
    /// grid, drop entries that say nothing, and drop duplicate UIDs (two
    /// records for one speaker would make "which one wins" a coin toss).
    ///
    /// "Says nothing" here means 立体声, and unlike the other two stores there
    /// is no bypass to keep alive behind it: a channel assignment has no A/B
    /// switch, because 立体声 IS the A.
    static func sanitize(
        _ profiles: [DeviceChannelMatrixProfile]
    ) -> [DeviceChannelMatrixProfile] {
        var seen = Set<String>()
        var out: [DeviceChannelMatrixProfile] = []
        for profile in profiles {
            let uid = profile.uid.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !uid.isEmpty, seen.insert(uid).inserted else { continue }
            var normalized = profile
            normalized.uid = uid
            normalized.settings = normalize(profile.settings)
            guard normalized.settings.hasUserSetting else { continue }
            out.append(normalized)
        }
        return out
    }

    /// Clamp into the router's range, then snap to the UI's grid so a value
    /// read back from JSON always lands exactly on a slider detent.
    static func normalize(_ settings: ChannelMatrixSettings) -> ChannelMatrixSettings {
        var clean = settings.sanitized()
        // Only the custom coefficients are on a grid; a preset's matrix is
        // exact constants and must not be rounded into something that is
        // merely close to the identity.
        guard clean.preset == .custom else { return clean }
        clean.leftToLeftDb = ChannelMatrixLimits.snapToStep(clean.leftToLeftDb)
        clean.rightToLeftDb = ChannelMatrixLimits.snapToStep(clean.rightToLeftDb)
        clean.leftToRightDb = ChannelMatrixLimits.snapToStep(clean.leftToRightDb)
        clean.rightToRightDb = ChannelMatrixLimits.snapToStep(clean.rightToRightDb)
        // Snapping can push a value a step outside its range, so the router's
        // own validation runs again on the way out.
        return clean.sanitized()
    }
}
