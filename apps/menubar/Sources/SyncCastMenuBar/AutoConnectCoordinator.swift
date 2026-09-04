import Foundation

/// Pure decision engine for auto-connect rules.
///
/// # Why this is its own value type
///
/// Every interesting branch here is a race with hardware the tests cannot
/// touch: a DisplayPort audio device appears and disappears several times
/// while the monitor wakes, the user overrides a rule mid-episode, the trigger
/// leaves while the engine is still starting. Leaving that logic inside
/// `AppModel` would make it reachable only by physically unplugging a monitor,
/// which is exactly how this class of bug survives.
///
/// So the coordinator takes a snapshot of the world (which UIDs are present,
/// what is enabled, whether the engine runs, what time it is) and returns one
/// action. It owns no clock, no CoreAudio, and no `AppModel`.
///
/// # The two invariants it exists to hold
///
/// 1. **Fire once per trigger-presence episode.** An episode starts when the
///    trigger UID becomes present and ends when it goes away. Re-firing inside
///    an episode would let the rule stamp on a selection the user made after
///    it had already done its job.
/// 2. **Never fight the user.** Any manual selection/mode change while the
///    trigger is present suppresses the rule for the rest of that episode.
///    Getting it back is either unplugging and replugging, or the explicit
///    「重新应用规则」 button (`resetSuppression`).
struct AutoConnectCoordinator {

    /// What the owner should do right now.
    enum Action: Equatable {
        case none
        /// Switch to local Stereo and enable exactly these UIDs.
        case activate(profileID: UUID, memberUIDs: [String])
        /// The trigger for an activated rule is gone: stop, and optionally put
        /// the built-in speakers back as the default output at a fixed level.
        case deactivate(
            profileID: UUID,
            restoreBuiltIn: Bool,
            builtInVolumePercent: Int?
        )
    }

    /// An action plus, when the decision was postponed by the debounce, how
    /// long the owner should wait before asking again.
    ///
    /// The recheck hint is part of the return value rather than a callback
    /// because the debounce is the whole reason this type is testable: a
    /// device list that flaps produces `.none` + a deadline, and the test can
    /// advance its own clock instead of sleeping.
    struct Decision: Equatable {
        var action: Action
        var recheckAfter: TimeInterval?

        static let idle = Decision(action: .none, recheckAfter: nil)
    }

    /// One snapshot of the world.
    struct Input {
        var profiles: [AutoConnectProfile]
        /// CoreAudio UIDs discovery reports as present right now.
        var presentUIDs: Set<String>
        /// CoreAudio UIDs the routing table currently has switched on.
        var enabledUIDs: Set<String>
        /// Whether the engine is actually running (starting does not count:
        /// a rule that fires against a half-built engine would be re-applied
        /// on top of itself).
        var isStreaming: Bool
        /// True when the app is in local Stereo. A rule that has to change
        /// the mode first is not "already satisfied" however the UIDs look.
        var isStereoMode: Bool
        var now: Date

        init(
            profiles: [AutoConnectProfile],
            presentUIDs: Set<String>,
            enabledUIDs: Set<String>,
            isStreaming: Bool,
            isStereoMode: Bool,
            now: Date
        ) {
            self.profiles = profiles
            self.presentUIDs = presentUIDs
            self.enabledUIDs = enabledUIDs
            self.isStreaming = isStreaming
            self.isStereoMode = isStereoMode
            self.now = now
        }
    }

    /// Per-rule bookkeeping for the current trigger-presence episode.
    struct EpisodeState: Equatable {
        var triggerPresent = false
        /// The rule has already had its one shot this episode.
        var activated = false
        /// The user overrode us this episode; stay out of the way.
        var suppressed = false
    }

    /// How long the present-set has to hold still before it is believed.
    ///
    /// Measured requirement, not a guess: a DisplayPort monitor coming out of
    /// DPMS sleep drops and re-adds its audio device several times inside
    /// about a second (the same behaviour `RescanRemovalGate` was written for
    /// on the Bonjour side, and the reason `AppModel.handleWake` waits 1.5 s
    /// for `coreaudiod`). Acting on the first edge would start and stop the
    /// engine two or three times per wake.
    static let debounceSeconds: TimeInterval = 1.5

    private let debounce: TimeInterval

    /// The present-set the coordinator currently believes.
    private(set) var stableUIDs: Set<String> = []
    /// A different present-set that has not held still long enough yet.
    private(set) var pendingUIDs: Set<String>?
    private(set) var pendingSince: Date?
    private(set) var episodes: [UUID: EpisodeState] = [:]

    init(debounce: TimeInterval = AutoConnectCoordinator.debounceSeconds) {
        self.debounce = debounce
    }

    // MARK: - User intent

    /// The user changed the selection, the mode, or stopped the engine.
    ///
    /// Suppresses every rule whose trigger is currently present. Rules whose
    /// trigger is absent are untouched: the user cannot be overriding a rule
    /// that has not run and cannot run.
    mutating func noteUserOverride() {
        for (id, state) in episodes where state.triggerPresent && !state.suppressed {
            var next = state
            next.suppressed = true
            episodes[id] = next
        }
    }

    /// 「重新应用规则」: forget both the once-per-episode flag and the
    /// suppression, so the next `evaluate` re-applies whatever matches.
    mutating func resetSuppression() {
        for (id, state) in episodes {
            var next = state
            next.suppressed = false
            next.activated = false
            episodes[id] = next
        }
    }

    /// Forget a rule entirely (deleted in the UI).
    mutating func forgetProfile(_ id: UUID) {
        episodes.removeValue(forKey: id)
    }

    // MARK: - Decision

    /// One step of the machine.
    ///
    /// Returns at most one action. The owner is expected to apply it and then
    /// call `evaluate` again — a departure and an arrival in the same tick are
    /// reported one at a time on purpose, because applying a departure tears
    /// the engine down and the arrival has to be planned against the result.
    mutating func evaluate(_ input: Input) -> Decision {
        if let wait = settlePresence(input) { return wait }
        pruneEpisodes(keeping: input.profiles)

        // Departures first, and one per call: a departure tears the engine
        // down, so pairing it with an activation in the same tick would race
        // the teardown. The owner re-evaluates after applying anyway.
        if let decision = departureDecision(input) { return decision }
        return arrivalDecision(input)
    }

    /// Debounce the present-set. Returns a postponed decision while the set is
    /// still moving, nil once `stableUIDs` reflects reality.
    private mutating func settlePresence(_ input: Input) -> Decision? {
        guard input.presentUIDs != stableUIDs else {
            pendingUIDs = nil
            pendingSince = nil
            return nil
        }
        if pendingUIDs != input.presentUIDs {
            pendingUIDs = input.presentUIDs
            pendingSince = input.now
        }
        let since = pendingSince ?? input.now
        let elapsed = input.now.timeIntervalSince(since)
        guard elapsed >= debounce else {
            return Decision(action: .none, recheckAfter: debounce - elapsed)
        }
        stableUIDs = input.presentUIDs
        pendingUIDs = nil
        pendingSince = nil
        return nil
    }

    /// Drop episode state for rules that no longer exist, so a deleted-and-
    /// recreated rule does not inherit a stale `suppressed`.
    private mutating func pruneEpisodes(keeping profiles: [AutoConnectProfile]) {
        let live = Set(profiles.map(\.id))
        episodes = episodes.filter { live.contains($0.key) }
    }

    /// Close out any episode whose trigger has left, emitting at most one
    /// `.deactivate`.
    ///
    /// Disabled rules still get their episode closed (so re-enabling one does
    /// not inherit `activated: true`) but never emit an action.
    private mutating func departureDecision(_ input: Input) -> Decision? {
        for profile in input.profiles {
            let state = episodes[profile.id] ?? EpisodeState()
            guard state.triggerPresent, !stableUIDs.contains(profile.triggerUID) else {
                continue
            }
            // Episode closed either way. A rule that never fired this episode
            // has nothing to undo, so it closes silently and the loop moves on
            // to the next departing rule.
            episodes[profile.id] = EpisodeState()
            // A rule switched off after it fired stays switched off: the user
            // turning the feature off must not be answered later by the loudest
            // thing it can do. `enabled` is checked here as well as at the
            // owner's `forgetProfile` call because this is the choke point that
            // actually emits the action.
            guard state.activated, profile.enabled else { continue }
            // Deliberately fires even when the user overrode us afterwards.
            // The disconnect action is a safety behaviour ("do not let the
            // laptop blast in public"), not a routing preference, and the
            // rule demonstrably took effect this episode.
            return Decision(
                action: .deactivate(
                    profileID: profile.id,
                    restoreBuiltIn: profile.onDisconnect.restoreBuiltIn,
                    builtInVolumePercent: profile.onDisconnect.builtInVolumePercent
                ),
                recheckAfter: nil
            )
        }
        return nil
    }

    /// Open episodes for arriving triggers and fire at most one `.activate`.
    ///
    /// First matching rule wins for the whole episode: every other rule that
    /// could also have fired is marked as spent rather than left pending, or
    /// the next call would apply rule 2 straight on top of rule 1 and the
    /// user's outputs would flip once per evaluation.
    private mutating func arrivalDecision(_ input: Input) -> Decision {
        var result = Decision.idle
        var winnerChosen = false
        for profile in input.profiles {
            var state = episodes[profile.id] ?? EpisodeState()
            let present = stableUIDs.contains(profile.triggerUID)
            if present && !state.triggerPresent {
                state = EpisodeState(triggerPresent: true, activated: false, suppressed: false)
            }
            episodes[profile.id] = state

            guard present,
                  profile.enabled,
                  !state.activated,
                  !state.suppressed,
                  profile.requiredUIDs.isSubset(of: stableUIDs)
            else { continue }

            state.activated = true
            episodes[profile.id] = state
            guard !winnerChosen else { continue }
            winnerChosen = true

            // Already exactly right: claim the episode without touching the
            // audio path, so a launch into the correct state is silent and a
            // later manual change is still treated as the user's.
            let satisfied = input.isStereoMode
                && input.isStreaming
                && input.enabledUIDs == Set(profile.memberUIDs)
            if satisfied { continue }
            result = Decision(
                action: .activate(profileID: profile.id, memberUIDs: profile.memberUIDs),
                recheckAfter: nil
            )
        }
        return result
    }
}
