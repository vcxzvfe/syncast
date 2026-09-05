import Foundation

/// The built-in speaker level as it was *before* auto-connect forced it down.
///
/// A `UserDefaults` record rather than an in-memory field because the two
/// halves happen in different app lifetimes as a matter of course: the force
/// happens when the monitor is unplugged (lid closes, laptop is carried away),
/// the restore happens on the next plug-in, which is routinely a fresh launch
/// from the login item.
struct AutoConnectBuiltInVolumeSnapshot: Codable, Equatable, Sendable {
    /// The CoreAudio UID the scalar was read from. Stored so a snapshot taken
    /// on one machine state is never written back to a different device — Apple
    /// has shipped both `BuiltInSpeakerDevice` and `BuiltInHeadphoneDevice`.
    var uid: String
    /// `kAudioDevicePropertyVolumeScalar`, 0…1, as the slider stood.
    var scalar: Float
    var capturedAt: Date
}

/// Versioned `UserDefaults` persistence for the pre-force built-in level.
///
/// Same shape and the same reasoning as `AutoConnectProfileStore`: one JSON
/// blob under one versioned key, every decode failure collapsing to "no
/// snapshot" rather than to a half-trusted value that would be written into
/// the user's hardware.
enum AutoConnectBuiltInVolumeStore {
    /// Bump the suffix, never the meaning, when the record shape changes.
    static let defaultsKey = "syncast.autoConnect.builtInVolumeBeforeForce.v1"

    static func load(defaults: UserDefaults = .standard) -> AutoConnectBuiltInVolumeSnapshot? {
        decode(defaults.data(forKey: defaultsKey))
    }

    static func save(
        _ snapshot: AutoConnectBuiltInVolumeSnapshot,
        defaults: UserDefaults = .standard
    ) {
        guard let data = encode(snapshot) else {
            SyncCastLog.log("autoconnect: built-in volume snapshot encode failed; not stored")
            return
        }
        defaults.set(data, forKey: defaultsKey)
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }

    static func encode(_ snapshot: AutoConnectBuiltInVolumeSnapshot) -> Data? {
        try? JSONEncoder().encode(snapshot)
    }

    /// Decode + validate. An out-of-range or non-finite scalar is external
    /// data that would go straight into `kAudioDevicePropertyVolumeScalar`, so
    /// it is rejected rather than clamped: a record that nonsensical says the
    /// stored blob is not ours, and guessing at the user's level is worse than
    /// falling back to the "found silent → restore a floor" path.
    static func decode(_ data: Data?) -> AutoConnectBuiltInVolumeSnapshot? {
        guard let data else { return nil }
        guard let snapshot = try? JSONDecoder()
            .decode(AutoConnectBuiltInVolumeSnapshot.self, from: data)
        else {
            SyncCastLog.log("autoconnect: built-in volume snapshot unreadable; ignoring it")
            return nil
        }
        guard !snapshot.uid.isEmpty,
              snapshot.scalar.isFinite,
              (0...1).contains(snapshot.scalar)
        else {
            SyncCastLog.log(
                "autoconnect: built-in volume snapshot out of range "
                + "(uid=\(snapshot.uid) scalar=\(snapshot.scalar)); ignoring it"
            )
            return nil
        }
        return snapshot
    }
}

/// Pure planning helpers that sit between `AutoConnectCoordinator`'s decisions
/// and `AppModel`'s side effects.
///
/// `AppModel+AutoConnect.swift` is an extension on a `@MainActor @Observable`
/// class that owns a router, discovery and a live audio engine, so none of it
/// can be constructed in a test. Every judgement the translation layer makes
/// therefore lives here as a value-in / value-out function, and the extension
/// is left with nothing but "read the world, call this, do what it says".
enum AutoConnectPlan {

    /// Levels at or below this count as silent. A forced 0 % writes exactly
    /// 0.0, but a driver is free to round, and `readHardwareVolume` averages
    /// per-channel elements when there is no master element.
    static let silentScalar: Float = 0.001

    /// The level to hand back when the built-in is found silent and there is
    /// no snapshot to restore. Half the slider: audible, and not startling in
    /// a room where the user has no idea the app touched anything.
    static let recoveryScalar: Float = 0.5

    // MARK: - Deactivation

    /// What the owner should actually do when a rule's trigger goes away.
    struct Deactivation: Equatable {
        /// CoreAudio UIDs to switch off — always a subset of the rule's own
        /// members, never "everything currently enabled".
        var disableUIDs: Set<String>
        var restoreBuiltIn: Bool
        var builtInVolumePercent: Int?
        /// Why the built-in half was dropped, for the log. nil when it stands.
        var skipReason: String?

        var touchesBuiltIn: Bool { restoreBuiltIn || builtInVolumePercent != nil }
    }

    /// Plan a teardown.
    ///
    /// # Only the rule's own members
    ///
    /// The rule fires (built-in + monitor, local stereo). The user then
    /// switches to whole-home and enables the Mac mini and the Xiaomi. Then the
    /// monitor is unplugged. Undoing "everything that is enabled" at that point
    /// switches off two AirPlay receivers the rule never touched and silences a
    /// room the user set up by hand. A rule is only ever entitled to undo what
    /// it did, so the disable set is the rule's members and nothing else — and
    /// AirPlay routing is not in it, because auto-connect never enables AirPlay
    /// receivers in the first place.
    ///
    /// # The built-in half in whole-home
    ///
    /// `restoreBuiltIn` re-points the macOS default output and
    /// `builtInVolumePercent` forces the internal speakers to a level (0 % for
    /// this machine's owner). Both are safety behaviours for "the laptop is
    /// being carried out of the room". In the middle of a whole-home session
    /// they are neither: the audio is going to the house, the default output is
    /// the user's business, and zeroing the internal speakers would silence a
    /// leg the rule never switched on. So both are dropped unless the built-in
    /// is itself one of the rule's members, in which case the rule really is
    /// the reason it is playing and undoing it is fair.
    ///
    /// The mode is never changed by a deactivation in either direction: a rule
    /// that fired in stereo has no business pulling the user out of whole-home.
    static func deactivation(
        memberUIDs: [String],
        restoreBuiltIn: Bool,
        builtInVolumePercent: Int?,
        isWholeHome: Bool,
        builtInUID: String?
    ) -> Deactivation {
        let members = Set(memberUIDs)
        let plan = Deactivation(
            disableUIDs: members,
            restoreBuiltIn: restoreBuiltIn,
            builtInVolumePercent: builtInVolumePercent,
            skipReason: nil
        )
        guard plan.touchesBuiltIn else { return plan }
        guard let builtInUID else {
            return drop(plan, because: "no built-in output found")
        }
        if isWholeHome, !members.contains(builtInUID) {
            return drop(
                plan,
                because: "whole-home session and the built-in is not a rule member"
            )
        }
        return plan
    }

    private static func drop(_ plan: Deactivation, because reason: String) -> Deactivation {
        var dropped = plan
        dropped.restoreBuiltIn = false
        dropped.builtInVolumePercent = nil
        dropped.skipReason = reason
        return dropped
    }

    /// Whether the delayed built-in half of a deactivation should still run.
    ///
    /// It fires 0.8 s after the teardown, and a lot can happen in 0.8 s: a DPMS
    /// blink or a KVM switch brings the trigger straight back, or the user
    /// starts something else. Re-pointing the default output and zeroing the
    /// speakers then would yank audio away from a session that is already
    /// playing, which is exactly the class of bug the delay was introduced to
    /// avoid on the other side.
    static func builtInFallbackStillWanted(
        triggerPresent: Bool,
        isStreaming: Bool
    ) -> Bool {
        !triggerPresent && !isStreaming
    }

    // MARK: - Built-in level around a forced silence

    /// Whether to remember the current built-in level before forcing it down.
    enum Capture: Equatable {
        case skip(reason: String)
        case capture(scalar: Float)
    }

    /// Decide whether this deactivation should take a snapshot.
    ///
    /// An existing snapshot for the same device is never overwritten. Two
    /// unplugs with no plug-in between them would otherwise have the second one
    /// "remember" the 0 % the first one wrote, and the user's real level would
    /// be gone for good.
    static func capture(
        existing: AutoConnectBuiltInVolumeSnapshot?,
        uid: String,
        currentScalar: Float?
    ) -> Capture {
        if let existing, existing.uid == uid {
            return .skip(reason: "snapshot already held")
        }
        guard let currentScalar else {
            return .skip(reason: "level unreadable")
        }
        guard currentScalar > silentScalar else {
            return .skip(reason: "already silent; nothing worth restoring")
        }
        return .capture(scalar: currentScalar)
    }

    /// Whether to write a level back into the built-in speakers before the
    /// rule's members are enabled.
    enum Restore: Equatable {
        case none(reason: String)
        case write(scalar: Float, clearSnapshot: Bool, reason: String)
    }

    /// Decide what an activation owes the built-in speakers.
    ///
    /// # Why this has to run before the members are enabled
    ///
    /// Forcing the built-in to 0 % is a one-way door without it. Direct Stereo
    /// treats the hardware as the authority: as soon as the built-in is enabled
    /// as a member, `refreshDirectStereoVolumeState` reads its scalar and
    /// `applyDirectStereoVolumeSnapshot` mirrors it into `routing[*].volume` as
    /// though the user had chosen it. A built-in still parked at the forced 0 %
    /// is therefore adopted as the user's level, and every replug from then on
    /// comes back silent with a slider that agrees. Writing the remembered
    /// level first means the snapshot reads the restored value.
    ///
    /// The floor case covers the histories that never produced a snapshot — the
    /// feature was enabled while the speakers were already at 0, the defaults
    /// were cleared, an older build forced silence before snapshots existed.
    /// Coming back audible-but-quiet is recoverable; coming back silent with no
    /// visible cause is the bug being fixed.
    static func restore(
        memberUIDs: [String],
        builtInUID: String?,
        snapshot: AutoConnectBuiltInVolumeSnapshot?,
        currentScalar: Float?
    ) -> Restore {
        guard let builtInUID else {
            return .none(reason: "no built-in output found")
        }
        guard memberUIDs.contains(builtInUID) else {
            // The rule does not drive the built-in this episode, so its level
            // is the user's business. A snapshot from an earlier rule shape is
            // deliberately kept, not cleared: the next activation that does
            // include the built-in is still owed it.
            return .none(reason: "built-in is not a rule member")
        }
        if let snapshot, snapshot.uid == builtInUID {
            guard snapshot.scalar > silentScalar else {
                return .write(
                    scalar: recoveryScalar,
                    clearSnapshot: true,
                    reason: "stored snapshot was itself silent; using the floor"
                )
            }
            return .write(
                scalar: snapshot.scalar,
                clearSnapshot: true,
                reason: "restoring the level from before the forced silence"
            )
        }
        guard let currentScalar else {
            return .none(reason: "level unreadable")
        }
        guard currentScalar <= silentScalar else {
            return .none(reason: "built-in is already audible")
        }
        return .write(
            scalar: recoveryScalar,
            clearSnapshot: false,
            reason: "built-in found silent with no snapshot; restoring the floor"
        )
    }
}
