import Foundation
import Security

/// Keychain storage for LAN receiver pairing tokens.
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
    /// Keychain service. The `.v1` suffix is the schema version.
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

    // MARK: - Keychain

    static func token(forUID uid: String, service: String = service) -> String? {
        var query = baseQuery(uid: uid, service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                SyncCastLog.log("lan token: keychain read failed for \(uid) (status \(status))")
            }
            return nil
        }
        guard let data = result as? Data,
              let token = String(data: data, encoding: .utf8)
        else {
            SyncCastLog.log("lan token: keychain item for \(uid) was not readable text")
            return nil
        }
        return token
    }

    /// Store (or replace) a receiver's token.
    ///
    /// - Returns: whether the write landed. A failure is reported rather than
    ///   swallowed: a token the user believes they saved and did not is a
    ///   receiver that never connects and never says why.
    @discardableResult
    static func save(_ token: String, forUID uid: String, service: String = service) -> Bool {
        guard let clean = sanitize(token) else { return remove(forUID: uid, service: service) }
        let data = Data(clean.utf8)
        var query = baseQuery(uid: uid, service: service)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else {
            SyncCastLog.log("lan token: keychain update failed for \(uid) (status \(updateStatus))")
            return false
        }
        query[kSecValueData as String] = data
        // The token is only useful while this Mac is unlocked and running, and
        // it must never leave the machine — so no iCloud sync and the
        // strictest accessibility class that still survives a reboot.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            SyncCastLog.log("lan token: keychain write failed for \(uid) (status \(addStatus))")
            return false
        }
        return true
    }

    @discardableResult
    static func remove(forUID uid: String, service: String = service) -> Bool {
        let status = SecItemDelete(baseQuery(uid: uid, service: service) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            SyncCastLog.log("lan token: keychain delete failed for \(uid) (status \(status))")
            return false
        }
        return true
    }

    /// Every stored token, keyed by receiver UID.
    ///
    /// Read once at launch and after each edit; the Router keeps the map in
    /// memory from then on, so the keychain is not touched on the audio path.
    ///
    /// Two passes on purpose: the account names first, then one read per
    /// account. Asking for attributes AND data in a single `kSecMatchLimitAll`
    /// query is accepted by the API and returns nothing on the file-based
    /// keychain, which is a silent "you have no receivers" — the worst
    /// possible failure for a pairing store.
    static func loadAll(service: String = service) -> [String: String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: false,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                SyncCastLog.log("lan token: keychain enumeration failed (status \(status))")
            }
            return [:]
        }
        guard let items = result as? [[String: Any]] else { return [:] }
        var tokens: [String: String] = [:]
        for item in items {
            guard let uid = item[kSecAttrAccount as String] as? String,
                  let token = token(forUID: uid, service: service),
                  let clean = sanitize(token)
            else { continue }
            tokens[uid] = clean
        }
        return tokens
    }

    private static func baseQuery(uid: String, service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: uid,
            kSecAttrSynchronizable as String: false,
        ]
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
