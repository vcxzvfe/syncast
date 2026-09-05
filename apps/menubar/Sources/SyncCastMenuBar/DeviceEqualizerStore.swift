import Foundation
import SyncCastRouter

/// One remembered tone curve, plus the name to show while its device is away.
///
/// # Why the CoreAudio UID and nothing else
///
/// The user's ask was "长期记忆在这个设备上，每次连接都默认这样" — the curve
/// belongs to the *speaker*, not to this session. `Device.id` is re-minted
/// every process (see `StableIDMap`), and display names are not unique: two
/// ASUS panels report the same product string, and the office monitor must
/// never inherit the home monitor's bass cut. The CoreAudio device UID is the
/// only identity that is both stable across relaunches and specific to the
/// physical output, so it is the key, exactly as `AutoConnectProfile` keys its
/// triggers. `displayName` is cached alongside purely so the UI can label a
/// remembered curve for a device that is not plugged in.
///
/// AirPlay receivers have no CoreAudio UID and are not equalised (their audio
/// never passes through our render callback), so this store is CoreAudio-only
/// by construction.
struct DeviceEqualizerProfile: Codable, Sendable, Equatable, Identifiable {
    var uid: String
    var displayName: String?
    var settings: EqualizerSettings

    var id: String { uid }

    init(uid: String, displayName: String? = nil, settings: EqualizerSettings) {
        self.uid = uid
        self.displayName = displayName
        self.settings = settings
    }

    func name(fallback: String? = nil) -> String {
        displayName ?? fallback ?? uid
    }
}

/// Versioned `UserDefaults` persistence for per-device equalizer curves.
///
/// JSON under one versioned key, for the same reason `AutoConnectProfileStore`
/// does it: the record is nested (a curve holds a band list), and a future v2
/// wants to be able to read — or deliberately ignore — v1 rather than guess at
/// a flat plist layout.
///
/// Everything except `load`/`save` is pure, so the malformed-data paths are
/// unit-testable without touching the user's defaults.
enum DeviceEqualizerStore {
    /// Bump the suffix, never the meaning, when the record shape changes.
    static let defaultsKey = "syncast.deviceEqualizer.v1"

    static func load(defaults: UserDefaults = .standard) -> [String: DeviceEqualizerProfile] {
        decode(defaults.data(forKey: defaultsKey))
    }

    static func save(
        _ profiles: [String: DeviceEqualizerProfile],
        defaults: UserDefaults = .standard
    ) {
        let sanitized = sanitize(Array(profiles.values))
        guard !sanitized.isEmpty else {
            defaults.removeObject(forKey: defaultsKey)
            return
        }
        guard let data = encode(sanitized) else {
            SyncCastLog.log("equalizer: encode failed; keeping previous stored curves")
            return
        }
        defaults.set(data, forKey: defaultsKey)
    }

    static func encode(_ profiles: [DeviceEqualizerProfile]) -> Data? {
        do {
            // Sorted so the stored blob is stable across launches; a plist
            // that churns on every save is noise in backups and in diffs.
            return try JSONEncoder().encode(profiles.sorted { $0.uid < $1.uid })
        } catch {
            SyncCastLog.log("equalizer: encode error \(error)")
            return nil
        }
    }

    /// Decode + validate. This is external data that has been through
    /// `UserDefaults`, so every failure mode is explicit: absent, unreadable,
    /// and structurally valid-but-nonsensical all collapse to "no curves"
    /// rather than to a half-applied filter. A NaN band gain reaching the
    /// render thread would be permanent noise on that speaker, so the
    /// clamping in `EqualizerSettings.sanitized()` is load-bearing, not
    /// defensive decoration.
    static func decode(_ data: Data?) -> [String: DeviceEqualizerProfile] {
        guard let data else { return [:] }
        do {
            let decoded = try JSONDecoder().decode([DeviceEqualizerProfile].self, from: data)
            let sanitized = sanitize(decoded)
            if sanitized.count != decoded.count {
                SyncCastLog.log(
                    "equalizer: dropped \(decoded.count - sanitized.count) malformed curve(s) on load"
                )
            }
            return Dictionary(uniqueKeysWithValues: sanitized.map { ($0.uid, $0) })
        } catch {
            SyncCastLog.log("equalizer: stored curves unreadable (\(error)); ignoring them")
            return [:]
        }
    }

    /// Drop entries with no UID, clamp every gain into range, snap to the UI
    /// step, drop entries whose curve says nothing, and drop duplicate UIDs
    /// (two records for one speaker would make "which one wins" a coin toss).
    static func sanitize(_ profiles: [DeviceEqualizerProfile]) -> [DeviceEqualizerProfile] {
        var seen = Set<String>()
        var out: [DeviceEqualizerProfile] = []
        for profile in profiles {
            let uid = profile.uid.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !uid.isEmpty, seen.insert(uid).inserted else { continue }
            var normalized = profile
            normalized.uid = uid
            normalized.settings = normalize(profile.settings)
            // A stored record that cannot change anything is dead weight; a
            // bypassed record that HOLDS a curve is not, because bypass is the
            // A/B switch and losing the curve behind it defeats the point.
            guard normalized.settings.hasUserCurve else { continue }
            out.append(normalized)
        }
        return out
    }

    /// Clamp into the router's ranges, then snap to the UI's 0.5 dB grid so a
    /// value read back from JSON always lands exactly on a slider detent.
    static func normalize(_ settings: EqualizerSettings) -> EqualizerSettings {
        var clean = settings.sanitized()
        clean.trimDb = EqualizerLimits.snapToStep(clean.trimDb)
        for index in clean.bands.indices {
            clean.bands[index].gainDb = EqualizerLimits.snapToStep(clean.bands[index].gainDb)
        }
        return clean
    }
}
