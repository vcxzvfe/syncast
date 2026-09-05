import Foundation
import SyncCastRouter

/// One remembered stereo-image setting, plus the name to show while its device
/// is away.
///
/// Keyed by CoreAudio UID for the same reason `DeviceEqualizerProfile` is: the
/// setting describes a *cabinet* — how far apart its drivers are, how far away
/// the listener sits — so it belongs to the physical output and has to come
/// back on every connect. `Device.id` is re-minted every process and display
/// names are not unique, so neither can carry it.
///
/// AirPlay receivers have no CoreAudio UID and are deliberately not offered
/// this control (see `Router.applyStereoImages`), so this store is
/// CoreAudio-only by construction.
struct DeviceStereoImageProfile: Codable, Sendable, Equatable, Identifiable {
    var uid: String
    var displayName: String?
    var settings: StereoImageSettings

    var id: String { uid }

    init(uid: String, displayName: String? = nil, settings: StereoImageSettings) {
        self.uid = uid
        self.displayName = displayName
        self.settings = settings
    }

    func name(fallback: String? = nil) -> String {
        displayName ?? fallback ?? uid
    }
}

/// Versioned `UserDefaults` persistence for per-device stereo-image settings.
///
/// JSON under one versioned key, separate from `syncast.deviceEqualizer.v1`:
/// the two features are edited, reset and bypassed independently, and folding
/// them into one record would make "reset the EQ" a reason to rewrite the
/// imaging blob.
///
/// Everything except `load`/`save` is pure, so the malformed-data paths are
/// unit-testable without touching the user's defaults.
enum DeviceStereoImageStore {
    /// Bump the suffix, never the meaning, when the record shape changes.
    static let defaultsKey = "syncast.deviceStereoImage.v1"

    static func load(defaults: UserDefaults = .standard) -> [String: DeviceStereoImageProfile] {
        decode(defaults.data(forKey: defaultsKey))
    }

    static func save(
        _ profiles: [String: DeviceStereoImageProfile],
        defaults: UserDefaults = .standard
    ) {
        let sanitized = sanitize(Array(profiles.values))
        guard !sanitized.isEmpty else {
            defaults.removeObject(forKey: defaultsKey)
            return
        }
        guard let data = encode(sanitized) else {
            SyncCastLog.log("stereo image: encode failed; keeping previous stored settings")
            return
        }
        defaults.set(data, forKey: defaultsKey)
    }

    static func encode(_ profiles: [DeviceStereoImageProfile]) -> Data? {
        do {
            // Sorted so the stored blob is stable across launches; a plist
            // that churns on every save is noise in backups and in diffs.
            return try JSONEncoder().encode(profiles.sorted { $0.uid < $1.uid })
        } catch {
            SyncCastLog.log("stereo image: encode error \(error)")
            return nil
        }
    }

    /// Decode + validate. This is external data that has been through
    /// `UserDefaults`, so every failure mode is explicit: absent, unreadable,
    /// and structurally valid-but-nonsensical all collapse to "no settings"
    /// rather than to a half-applied filter. The clamping in
    /// `StereoImageSettings.sanitized()` is load-bearing: a NaN corner or an
    /// out-of-range feedback coefficient reaching the render thread would be
    /// permanent noise — or, in a recursive structure, a runaway.
    static func decode(_ data: Data?) -> [String: DeviceStereoImageProfile] {
        guard let data else { return [:] }
        do {
            let decoded = try JSONDecoder().decode([DeviceStereoImageProfile].self, from: data)
            let sanitized = sanitize(decoded)
            if sanitized.count != decoded.count {
                SyncCastLog.log(
                    "stereo image: dropped \(decoded.count - sanitized.count)"
                        + " malformed setting(s) on load"
                )
            }
            return Dictionary(uniqueKeysWithValues: sanitized.map { ($0.uid, $0) })
        } catch {
            SyncCastLog.log("stereo image: stored settings unreadable (\(error)); ignoring them")
            return [:]
        }
    }

    /// Drop entries with no UID, clamp everything into range, snap to the UI
    /// grid, drop entries that say nothing, and drop duplicate UIDs (two
    /// records for one speaker would make "which one wins" a coin toss).
    static func sanitize(_ profiles: [DeviceStereoImageProfile]) -> [DeviceStereoImageProfile] {
        var seen = Set<String>()
        var out: [DeviceStereoImageProfile] = []
        for profile in profiles {
            let uid = profile.uid.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !uid.isEmpty, seen.insert(uid).inserted else { continue }
            var normalized = profile
            normalized.uid = uid
            normalized.settings = normalize(profile.settings)
            // A stored record that cannot change anything is dead weight; a
            // BYPASSED record that holds a setting is not, because bypass is
            // the A/B switch and losing the setting behind it defeats the
            // point of having one.
            guard normalized.settings.hasUserSetting else { continue }
            out.append(normalized)
        }
        return out
    }

    /// Clamp into the router's ranges, then snap to the UI's grids so a value
    /// read back from JSON always lands exactly on a slider detent.
    static func normalize(_ settings: StereoImageSettings) -> StereoImageSettings {
        var clean = settings.sanitized()
        clean.width.width = StereoImageLimits.snap(
            clean.width.width, step: StereoImageLimits.widthStep
        )
        clean.width.cornerHz = StereoImageLimits.snap(
            clean.width.cornerHz, step: StereoImageLimits.widthCornerStepHz
        )
        clean.width.midTrimDb = StereoImageLimits.snap(
            clean.width.midTrimDb, step: StereoImageLimits.midTrimStepDb
        )
        clean.crosstalk.attenuationDb = StereoImageLimits.snap(
            clean.crosstalk.attenuationDb, step: StereoImageLimits.attenuationStepDb
        )
        clean.crosstalk.strength = StereoImageLimits.snap(
            clean.crosstalk.strength, step: StereoImageLimits.strengthStep
        )
        clean.crosstalk.spanMeters = StereoImageLimits.snap(
            clean.crosstalk.spanMeters, step: StereoImageLimits.spanStepMeters
        )
        clean.crosstalk.distanceMeters = StereoImageLimits.snap(
            clean.crosstalk.distanceMeters, step: StereoImageLimits.distanceStepMeters
        )
        clean.crosstalk.lowHz = StereoImageLimits.snap(
            clean.crosstalk.lowHz, step: StereoImageLimits.crosstalkBandStepHz
        )
        clean.crosstalk.highHz = StereoImageLimits.snap(
            clean.crosstalk.highHz, step: StereoImageLimits.crosstalkBandStepHz
        )
        // Snapping can push a value a step outside its range (or invert the
        // band), so the router's own validation runs again on the way out.
        return clean.sanitized()
    }
}
