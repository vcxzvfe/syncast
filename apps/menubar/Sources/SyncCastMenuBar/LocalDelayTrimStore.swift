import Foundation
import SyncCastRouter

/// One remembered local-Stereo delay, plus the name to show while its device
/// is away.
///
/// # Why the CoreAudio UID, and why a store of its own
///
/// The value belongs to the *speaker*: a display whose panel adds 30 ms of its
/// own processing adds it every time it is plugged in, so the setting is keyed
/// by CoreAudio device UID exactly as `DeviceEqualizerProfile` is. `Device.id`
/// is re-minted every process and display names are not unique, so neither can
/// carry a setting across a relaunch.
///
/// This is deliberately NOT `AppModel.deviceTrimDefaultsKey`
/// (`syncast.deviceDelayTrimMs`), which holds the whole-home listening-position
/// trim. Same unit, different correction:
///
///   * the whole-home trim answers "how far is this speaker from the chair",
///     is applied on the OwnTone / bridge legs, and is keyed by
///     `Device.persistenceKey` so it can also cover AirPlay receivers;
///   * this one answers "how much latency does this device add that it never
///     declared", is applied inside the local render callback, and is
///     CoreAudio-only because nothing else passes through that callback.
///
/// Sharing one number would make each mode silently retune the other, and the
/// whole-home range (±200 ms) is twice what the local ring budgets for.
struct LocalDelayTrimProfile: Codable, Sendable, Equatable, Identifiable {
    var uid: String
    var displayName: String?
    /// Signed milliseconds. Positive = hold this device back.
    var delayMs: Int

    var id: String { uid }

    init(uid: String, displayName: String? = nil, delayMs: Int) {
        self.uid = uid
        self.displayName = displayName
        self.delayMs = delayMs
    }

    func name(fallback: String? = nil) -> String {
        displayName ?? fallback ?? uid
    }
}

/// Versioned `UserDefaults` persistence for the local-Stereo delay trims.
///
/// JSON under one versioned key, for the same reason `DeviceEqualizerStore`
/// does it: the record is a small struct rather than a scalar, and a future v2
/// should be able to read — or deliberately ignore — v1 instead of guessing at
/// a flat plist layout.
///
/// Everything except `load`/`save` is pure, so the malformed-data paths are
/// unit-testable without touching the user's defaults.
enum LocalDelayTrimStore {
    /// Bump the suffix, never the meaning, when the record shape changes.
    static let defaultsKey = "syncast.localDelayTrimMs.v1"

    static func load(defaults: UserDefaults = .standard) -> [String: LocalDelayTrimProfile] {
        decode(defaults.data(forKey: defaultsKey))
    }

    static func save(
        _ profiles: [String: LocalDelayTrimProfile],
        defaults: UserDefaults = .standard
    ) {
        let sanitized = sanitize(Array(profiles.values))
        guard !sanitized.isEmpty else {
            defaults.removeObject(forKey: defaultsKey)
            return
        }
        guard let data = encode(sanitized) else {
            SyncCastLog.log("localDelay: encode failed; keeping previously stored trims")
            return
        }
        defaults.set(data, forKey: defaultsKey)
    }

    static func encode(_ profiles: [LocalDelayTrimProfile]) -> Data? {
        do {
            // Sorted so the stored blob is stable across launches; a plist that
            // churns on every save is noise in backups and in diffs.
            return try JSONEncoder().encode(profiles.sorted { $0.uid < $1.uid })
        } catch {
            SyncCastLog.log("localDelay: encode error \(error)")
            return nil
        }
    }

    /// Decode + validate. This is external data that has been through
    /// `UserDefaults`, so every failure mode is explicit: absent, unreadable,
    /// and structurally valid-but-nonsensical all collapse to "no trims"
    /// rather than to a half-applied delay. An out-of-range value reaching the
    /// render thread would be silence on that speaker (the read cursor parked
    /// behind the ring), so the clamp is load-bearing, not decoration.
    static func decode(_ data: Data?) -> [String: LocalDelayTrimProfile] {
        guard let data else { return [:] }
        do {
            let decoded = try JSONDecoder().decode([LocalDelayTrimProfile].self, from: data)
            let sanitized = sanitize(decoded)
            if sanitized.count != decoded.count {
                SyncCastLog.log(
                    "localDelay: dropped \(decoded.count - sanitized.count) malformed trim(s) on load"
                )
            }
            return Dictionary(uniqueKeysWithValues: sanitized.map { ($0.uid, $0) })
        } catch {
            SyncCastLog.log("localDelay: stored trims unreadable (\(error)); ignoring them")
            return [:]
        }
    }

    /// Drop entries with no UID, clamp into the router's range, drop the ones
    /// that say nothing (0 ms is the default and needs no record), and drop
    /// duplicate UIDs — two records for one speaker would make "which one
    /// wins" a coin toss.
    static func sanitize(_ profiles: [LocalDelayTrimProfile]) -> [LocalDelayTrimProfile] {
        var seen = Set<String>()
        var out: [LocalDelayTrimProfile] = []
        for profile in profiles {
            let uid = profile.uid.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !uid.isEmpty, seen.insert(uid).inserted else { continue }
            var normalized = profile
            normalized.uid = uid
            normalized.delayMs = LocalDelayTrim.clamp(profile.delayMs)
            guard normalized.delayMs != 0 else { continue }
            out.append(normalized)
        }
        return out
    }
}
