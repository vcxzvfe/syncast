import Foundation
import SyncCastDiscovery

/// A user-defined "when this output shows up, switch these on" rule.
///
/// # Why UIDs and nothing else
///
/// This is a laptop that moves. At home it meets one DisplayPort monitor, in
/// the office a different one, and the office display must NEVER trigger the
/// home rule. `Device.id` is re-minted every process (see `StableIDMap`) and
/// display *names* are not unique — two ASUS panels can both report the same
/// product string. The only identity that is both stable across relaunches and
/// specific to the panel the user actually pointed at is the CoreAudio device
/// UID, so trigger and members are stored as UIDs and matched by equality.
/// Names are cached alongside them purely so the UI can say "等待 ExternalDisplay"
/// while the device is absent.
struct AutoConnectProfile: Codable, Identifiable, Hashable, Sendable {

    /// What to do when the trigger device goes away again.
    struct DisconnectAction: Codable, Hashable, Sendable {
        /// Point the macOS default output back at the built-in speakers.
        ///
        /// `DirectStereoOutput.stop()` restores whatever the default output
        /// was BEFORE SyncCast took over — which, in the case this feature
        /// exists for, is the monitor that was just unplugged. Restoring the
        /// built-in explicitly is therefore not redundant with the teardown.
        var restoreBuiltIn: Bool

        /// Hardware level to force on the built-in speakers after restoring
        /// them, or nil to leave the level alone (the default for new rules).
        ///
        /// Interpreted as the macOS output-slider POSITION — the value is
        /// written straight to `kAudioDevicePropertyVolumeScalar` as
        /// `percent / 100`. It is deliberately NOT run through `VolumeCurve`,
        /// whose 0 % is -30 dB rather than silence: the entire point of the
        /// setting is "unplugging in a café must not make the laptop audible",
        /// and -30 dB is quiet but not silent.
        var builtInVolumePercent: Int?
        /// Leaving mode "keep playing on the laptop": instead of switching
        /// the rule's members off and handing the output back to macOS, keep
        /// SyncCast running with the built-in speakers as its only output.
        /// Optional so rules stored before it existed decode as nil (= off).
        var keepBuiltInViaSyncCast: Bool?
        /// System volume (the SyncCast sink's slider position, 0–100) to set
        /// when leaving in keep mode — typically 0, so the laptop is silent
        /// until the user turns it up. Nil leaves the volume alone.
        var systemVolumePercent: Int?

        static let off = DisconnectAction(restoreBuiltIn: false, builtInVolumePercent: nil)

        init(restoreBuiltIn: Bool, builtInVolumePercent: Int?,
             keepBuiltInViaSyncCast: Bool? = nil, systemVolumePercent: Int? = nil) {
            self.restoreBuiltIn = restoreBuiltIn
            self.builtInVolumePercent = builtInVolumePercent.map(AutoConnect.clampPercent)
            self.keepBuiltInViaSyncCast = keepBuiltInViaSyncCast
            self.systemVolumePercent = systemVolumePercent.map(AutoConnect.clampPercent)
        }

        var keepsBuiltIn: Bool { keepBuiltInViaSyncCast == true }
    }

    var id: UUID
    /// Master switch for this rule. A disabled rule is remembered but inert.
    var enabled: Bool
    /// CoreAudio UID whose PRESENCE arms the rule (e.g. the home monitor).
    var triggerUID: String
    /// CoreAudio UIDs to switch on, in the user's order. Normally contains
    /// `triggerUID` plus the built-in speakers, but the rule does not require
    /// it: "monitor appears → play on the desk speakers only" is legal.
    var memberUIDs: [String]
    var onDisconnect: DisconnectAction
    /// System volume (slider position, 0–100) to set once the rule has
    /// brought its outputs up on arrival. Nil leaves the volume alone.
    var arriveSystemVolumePercent: Int?
    /// UID → last known display name, for the UI while a device is absent.
    /// Purely cosmetic; never used for matching.
    var displayNames: [String: String]

    init(
        id: UUID = UUID(),
        enabled: Bool = true,
        triggerUID: String,
        memberUIDs: [String],
        onDisconnect: DisconnectAction = .off,
        arriveSystemVolumePercent: Int? = nil,
        displayNames: [String: String] = [:]
    ) {
        self.id = id
        self.enabled = enabled
        self.triggerUID = triggerUID
        self.memberUIDs = AutoConnect.dedupePreservingOrder(memberUIDs)
        self.onDisconnect = onDisconnect
        self.arriveSystemVolumePercent = arriveSystemVolumePercent.map(AutoConnect.clampPercent)
        self.displayNames = displayNames
    }

    /// Every UID that has to be present before the rule may fire.
    var requiredUIDs: Set<String> {
        Set(memberUIDs.filter { !AutoConnect.isOptionalMember($0) }).union([triggerUID])
    }

    func displayName(for uid: String) -> String {
        displayNames[uid] ?? uid
    }

    var triggerDisplayName: String { displayName(for: triggerUID) }

    /// A rule with no trigger or no members can never do anything useful and
    /// is rejected at both the creation and the load boundary.
    var isWellFormed: Bool {
        !triggerUID.isEmpty && !memberUIDs.isEmpty
    }
}

/// Shared constants and small pure helpers for the auto-connect feature.
enum AutoConnect {
    /// The stable UID Apple gives the internal speakers.
    ///
    /// Unlike an external display's UID (a per-panel UUID such as
    /// `00000000-0000-0000-0000-000000000001`), this one is a fixed string
    /// and is the same on every Mac, which is why it can be a constant.
    static let builtInSpeakerUID = "BuiltInSpeakerDevice"

    /// Prefix every internal Apple audio device UID starts with, used as the
    /// second-choice match when the exact UID above is not present (Apple has
    /// changed it before: `BuiltInSpeakerDevice`, `BuiltInHeadphoneDevice`).
    static let builtInUIDPrefix = "BuiltIn"

    /// The key a device is stored under in a rule: its CoreAudio UID, or for a
    /// LAN receiver its `lan:<service>` UID (the same key every per-device
    /// store uses). AirPlay receivers cannot be rule members: whole-home is a
    /// different mode and the rule always lands in local Stereo.
    static func memberKey(for device: Device) -> String? {
        switch device.transport {
        case .coreAudio: return device.coreAudioUID
        case .lanReceiver: return Device.lanReceiverUID(serviceName: device.lanServiceName)
        case .airplay2: return nil
        }
    }

    /// A member whose absence must not hold the rule back. A LAN receiver is
    /// another machine that may be asleep or off: the rule still brings up the
    /// local outputs, and switches the receiver on too when it is there.
    static func isOptionalMember(_ key: String) -> Bool {
        Device.lanServiceName(fromUID: key) != nil
    }

    static let percentRange: ClosedRange<Int> = 0...100

    static func clampPercent(_ percent: Int) -> Int {
        min(percentRange.upperBound, max(percentRange.lowerBound, percent))
    }

    /// Hardware scalar for a stored percent. Linear on purpose — see
    /// `DisconnectAction.builtInVolumePercent`.
    static func hardwareScalar(forPercent percent: Int) -> Float {
        Float(clampPercent(percent)) / 100
    }

    static func dedupePreservingOrder(_ uids: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for uid in uids where !uid.isEmpty {
            if seen.insert(uid).inserted { out.append(uid) }
        }
        return out
    }

    /// Which of the currently known outputs is "the built-in speakers".
    ///
    /// `Device` carries no transport-type flag, so this is a UID test with a
    /// name test as the last resort. Exact UID first so a Mac with both
    /// internal speakers and internal headphones connected picks the speakers.
    static func builtInOutputUID(in devices: [Device]) -> String? {
        let localUIDs = devices
            .filter { $0.transport == .coreAudio }
            .compactMap(\.coreAudioUID)
        if let exact = localUIDs.first(where: { $0 == builtInSpeakerUID }) {
            return exact
        }
        if let prefixed = localUIDs.first(where: { $0.hasPrefix(builtInUIDPrefix) }) {
            return prefixed
        }
        return devices.first { device in
            guard device.transport == .coreAudio, device.coreAudioUID != nil else {
                return false
            }
            let lower = device.name.lowercased()
            return lower.contains("built-in") || lower.contains("macbook")
        }?.coreAudioUID
    }
}

/// Versioned `UserDefaults` persistence for auto-connect rules.
///
/// Stored as JSON under one versioned key rather than as a plist array of
/// primitives: the rule is a nested record, and a future v2 wants to be able
/// to read (or deliberately ignore) v1 without guessing at a flat layout.
///
/// Everything except `load`/`save` is pure so the malformed-data paths are
/// unit-testable without touching the user's defaults.
enum AutoConnectProfileStore {
    /// Bump the suffix, never the meaning, when the record shape changes.
    static let defaultsKey = "syncast.autoConnect.profiles.v1"

    static func load(defaults: UserDefaults = .standard) -> [AutoConnectProfile] {
        decode(defaults.data(forKey: defaultsKey))
    }

    static func save(_ profiles: [AutoConnectProfile], defaults: UserDefaults = .standard) {
        let sanitized = sanitize(profiles)
        guard !sanitized.isEmpty else {
            defaults.removeObject(forKey: defaultsKey)
            return
        }
        guard let data = encode(sanitized) else {
            SyncCastLog.log("autoconnect: encode failed; keeping previous stored rules")
            return
        }
        defaults.set(data, forKey: defaultsKey)
    }

    static func encode(_ profiles: [AutoConnectProfile]) -> Data? {
        do {
            return try JSONEncoder().encode(profiles)
        } catch {
            SyncCastLog.log("autoconnect: encode error \(error)")
            return nil
        }
    }

    /// Decode + validate. External data, so every failure mode is explicit:
    /// absent, unreadable, and structurally valid-but-nonsensical all collapse
    /// to "no rules" rather than to a half-applied rule that would move the
    /// user's audio somewhere they never asked for.
    static func decode(_ data: Data?) -> [AutoConnectProfile] {
        guard let data else { return [] }
        do {
            let decoded = try JSONDecoder().decode([AutoConnectProfile].self, from: data)
            let sanitized = sanitize(decoded)
            if sanitized.count != decoded.count {
                SyncCastLog.log(
                    "autoconnect: dropped \(decoded.count - sanitized.count) malformed rule(s) on load"
                )
            }
            return sanitized
        } catch {
            SyncCastLog.log("autoconnect: stored rules unreadable (\(error)); ignoring them")
            return []
        }
    }

    /// Drop rules that cannot fire, dedupe members, clamp percents, and drop
    /// duplicate ids (two rules sharing an id would confuse the coordinator's
    /// per-rule episode bookkeeping).
    static func sanitize(_ profiles: [AutoConnectProfile]) -> [AutoConnectProfile] {
        var seenIDs = Set<UUID>()
        var out: [AutoConnectProfile] = []
        for profile in profiles {
            var normalized = profile
            normalized.memberUIDs = AutoConnect.dedupePreservingOrder(profile.memberUIDs)
            normalized.onDisconnect = AutoConnectProfile.DisconnectAction(
                restoreBuiltIn: profile.onDisconnect.restoreBuiltIn,
                builtInVolumePercent: profile.onDisconnect.builtInVolumePercent,
                keepBuiltInViaSyncCast: profile.onDisconnect.keepBuiltInViaSyncCast,
                systemVolumePercent: profile.onDisconnect.systemVolumePercent
            )
            normalized.arriveSystemVolumePercent = profile.arriveSystemVolumePercent
                .map(AutoConnect.clampPercent)
            guard normalized.isWellFormed, seenIDs.insert(normalized.id).inserted else {
                continue
            }
            out.append(normalized)
        }
        return out
    }
}
