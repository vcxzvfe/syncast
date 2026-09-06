import Foundation
import Security

/// File-backed storage for LAN receiver pairing tokens (0600, app-private).
///
/// # Why not `UserDefaults`
///
/// The token is a shared secret: it is the only thing standing between a
/// receiver on the LAN and anyone else on that LAN. `UserDefaults` is a
/// world-readable plist inside the container, backed up, synced by some setups
/// and trivially dumped with `defaults read` — which is exactly the class of
/// thing this project's own security rules say must not hold credentials. So
/// the token goes in the keychain as a generic password, one item per
/// receiver, and only the LIST of which receivers have one is ever derived
/// from it.
///
/// The service name doubles as the version marker, so a future record shape
/// change gets a new service rather than a migration.
enum LanReceiverTokenStore {
    /// Store name. The `.v1` suffix is the schema version.
    static let service = "syncast.lanReceiverTokens.v1"

    /// Longest token accepted. The daemon generates 32 hex characters; the
    /// cap exists so a paste accident cannot push a megabyte into the
    /// keychain.
    static let maximumTokenLength = 256

    /// Normalise what the user typed. Whitespace around a pasted token is the
    /// normal case, not the exception.
    ///
    /// Returns nil for anything that cannot be a token, so an empty save is a
    /// no-op rather than an item holding "".
    static func sanitize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximumTokenLength else { return nil }
        return trimmed
    }

    /// Whether a token looks like what the daemon prints: hex, even length,
    /// long enough to be worth having. Advisory — a receiver built with a
    /// different generator still works — so this only drives a UI hint.
    static func looksLikeADaemonToken(_ token: String) -> Bool {
        token.count >= 16 && token.allSatisfy(\.isHexDigit)
    }

    /// The 8-hex prefix a receiver advertises in its TXT record. Used to tell
    /// the user "this is the receiver whose log printed 3f2a…" without ever
    /// showing the whole secret.
    static func hint(for token: String) -> String {
        String(token.prefix(8)).lowercased()
    }

    // MARK: - File store

    /// Where the tokens live: one JSON object per store (service name), in the
    /// app's own Application Support directory, mode 0600 in a 0700 folder.
    ///
    /// Why a file and not the keychain any more (2026-09-06): the keychain
    /// item's ACL is bound to the app binary, and every rebuild/reinstall of a
    /// self-signed menubar app is a "different" binary to it. A read that the
    /// ACL refused came back as "no receivers" without a word in the log, and
    /// the only LAN output silently failed to open on every launch. The token
    /// is a LAN pairing secret of the same weight as the daemon's own copy,
    /// which the daemon keeps in a 0600 file — so this side does the same.
    static var directoryOverride: URL?

    static func storeDirectory() -> URL {
        if let directoryOverride { return directoryOverride }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("SyncCast", isDirectory: true)
    }

    static func storeURL(service: String) -> URL {
        let safe = service.replacingOccurrences(of: "/", with: "_")
        return storeDirectory().appendingPathComponent("\(safe).json")
    }

    private static func readStore(service: String) -> [String: String] {
        let url = storeURL(service: service)
        guard let data = try? Data(contentsOf: url) else { return [:] }
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            SyncCastLog.log("lan token: store \(url.lastPathComponent) unreadable; ignoring it")
            return [:]
        }
        var out: [String: String] = [:]
        for (uid, value) in raw {
            guard let token = value as? String, let clean = sanitize(token),
                  !uid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            out[uid] = clean
        }
        return out
    }

    private static func writeStore(_ tokens: [String: String], service: String) -> Bool {
        let directory = storeDirectory()
        let url = storeURL(service: service)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            if tokens.isEmpty {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
                return true
            }
            let data = try JSONSerialization.data(withJSONObject: tokens, options: [.sortedKeys])
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            SyncCastLog.log("lan token: could not write \(url.lastPathComponent): \(error.localizedDescription)")
            return false
        }
    }

    static func token(forUID uid: String, service: String = service) -> String? {
        readStore(service: service)[uid]
    }

    /// Store (or, for an empty/whitespace token, clear) the token for one
    /// receiver. Returns false only when the file could not be written.
    @discardableResult
    static func save(_ token: String, forUID uid: String, service: String = service) -> Bool {
        var tokens = readStore(service: service)
        if let clean = sanitize(token) {
            tokens[uid] = clean
        } else {
            tokens.removeValue(forKey: uid)
        }
        return writeStore(tokens, service: service)
    }

    @discardableResult
    static func remove(forUID uid: String, service: String = service) -> Bool {
        var tokens = readStore(service: service)
        tokens.removeValue(forKey: uid)
        return writeStore(tokens, service: service)
    }

    /// Every stored receiver token. Migrates once from the keychain item the
    /// previous implementation used, WITHOUT ever showing a keychain dialog:
    /// a refused read simply means the user re-enters the token.
    static func loadAll(service: String = service) -> [String: String] {
        var tokens = readStore(service: service)
        if tokens.isEmpty, directoryOverride == nil {
            let migrated = migrateFromKeychain(service: service)
            if !migrated.isEmpty {
                tokens = migrated
                _ = writeStore(tokens, service: service)
                SyncCastLog.log("lan token: migrated \(migrated.count) receiver token(s) from the keychain")
            }
        }
        SyncCastLog.log("lan token: \(tokens.count) receiver token(s) loaded")
        return tokens
    }

    private static func migrateFromKeychain(service: String) -> [String: String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            if status != errSecItemNotFound {
                SyncCastLog.log("lan token: keychain migration skipped (status \(status))")
            }
            return [:]
        }
        var out: [String: String] = [:]
        for item in items {
            guard let uid = item[kSecAttrAccount as String] as? String,
                  let data = item[kSecValueData as String] as? Data,
                  let token = String(data: data, encoding: .utf8),
                  let clean = sanitize(token) else { continue }
            out[uid] = clean
        }
        return out
    }
}

/// Per-receiver playout targets. Not a secret, so plain `UserDefaults`.
enum LanReceiverTargetStore {
    static let defaultsKey = "syncast.lanReceiverTargetMs.v1"

    static func load(defaults: UserDefaults = .standard) -> [String: Int] {
        decode(defaults.dictionary(forKey: defaultsKey))
    }

    static func save(_ targets: [String: Int], defaults: UserDefaults = .standard) {
        let clean = sanitize(targets)
        guard !clean.isEmpty else {
            defaults.removeObject(forKey: defaultsKey)
            return
        }
        defaults.set(clean, forKey: defaultsKey)
    }

    /// Decode from the loosely typed plist a `UserDefaults` dictionary is.
    /// Anything that is not a UID → number pair is dropped rather than
    /// crashing a cast.
    static func decode(_ raw: [String: Any]?) -> [String: Int] {
        guard let raw else { return [:] }
        var out: [String: Int] = [:]
        for (uid, value) in raw {
            let trimmed = uid.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let number = value as? NSNumber else { continue }
            out[trimmed] = number.intValue
        }
        return sanitize(out)
    }

    /// Clamp into the offered range, and drop entries that just say "the
    /// default" — storing those forever would make every launch write a blob
    /// that means nothing.
    static func sanitize(_ targets: [String: Int]) -> [String: Int] {
        var out: [String: Int] = [:]
        for (uid, ms) in targets {
            let trimmed = uid.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let clamped = LanReceiverTargetStore.clamp(ms)
            guard clamped != LanReceiverTargetStore.defaultTargetMs else { continue }
            out[trimmed] = clamped
        }
        return out
    }

    // The range lives in the router package (`LanPcmWire`); these two
    // re-expose it so this file has no import beyond Foundation and the tests
    // read one number rather than two.
    static let defaultTargetMs = 90
    static let rangeMs: ClosedRange<Int> = 30...300
    static let stepMs = 5

    static func clamp(_ ms: Int) -> Int {
        min(rangeMs.upperBound, max(rangeMs.lowerBound, ms))
    }
}
