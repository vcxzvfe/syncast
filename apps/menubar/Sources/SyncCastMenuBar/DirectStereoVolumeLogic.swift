import Foundation

/// Direction of a media-volume-key step.
enum DirectStereoVolumeStepDirection: Equatable {
    case up
    case down
}

/// Pure decision logic for Direct Stereo media-volume-key handling.
///
/// Kept free of CoreAudio / AppKit so the group-volume semantics are unit
/// testable: the old implementation picked the FIRST device that exposed a
/// hardware volume as the "reference", then wrote that single absolute value
/// to every enabled output — which destroyed the user's per-device balance
/// (e.g. MacBook Pro speakers tuned quieter than the desk monitor). The
/// functions here encode the replacement rules:
///
///   - volume keys step each device RELATIVE to its own current volume,
///   - the mute key acts on the group ("any audible → mute all").
enum DirectStereoVolumeLogic {
    /// 1/16 per key press — matches macOS's own 16-segment volume OSD.
    static let volumeStep: Float = 1.0 / 16.0

    /// One balance-preserving step from `current`, clamped to 0...1.
    /// Every device steps from its OWN volume; the inter-device offsets
    /// the user dialed in survive any number of key presses.
    static func steppedVolume(
        from current: Float,
        direction: DirectStereoVolumeStepDirection
    ) -> Float {
        let delta: Float = direction == .up ? volumeStep : -volumeStep
        return min(1, max(0, current + delta))
    }

    /// Whether a step in `direction` should also clear the muted flag.
    /// Volume-up implies "I want to hear something" (macOS behaves the
    /// same way on single devices); volume-down leaves mute untouched.
    static func unmutesOnStep(
        _ direction: DirectStereoVolumeStepDirection
    ) -> Bool {
        direction == .up
    }

    /// Group decision for the mute key. Returns the muted state to apply
    /// to EVERY enabled device: if any device is currently audible the
    /// key mutes the whole group; only when everything is already muted
    /// does it unmute the whole group.
    static func groupMuteTarget(currentlyMuted: [Bool]) -> Bool {
        currentlyMuted.contains(false)
    }

    /// One covered Direct Stereo output as seen by the snapshot gate:
    /// BOTH the SyncCast device id and the CoreAudio UID. A struct (not
    /// an "id|uid" string join) so ids containing the separator can never
    /// collide two distinct sets into one fingerprint.
    struct CoveredDeviceKey: Hashable {
        let id: String
        let uid: String
    }

    /// Smallest hardware volume delta worth mirroring into routing —
    /// below this, an observed value is our own write echoing back
    /// through driver quantization.
    static let externalVolumeDelta: Float = 0.004

    /// Hardware scalar values at or below this count as "parked at zero
    /// by a mute", not as a user-chosen level (covers drivers that
    /// quantize 0 to e.g. 1/256).
    static let mutedZeroEchoEpsilon: Float = 0.01

    /// What an observed hardware volume/mute report should change on the
    /// route. `nil` fields mean "leave as is".
    struct ExternalHardwareChangeDecision: Equatable {
        let volume: Float?
        let muted: Bool?

        var changesAnything: Bool { volume != nil || muted != nil }
    }

    /// Pure mirror-hardware-into-route decision, shared by the hardware
    /// observer callback and the snapshot path.
    ///
    /// The mute-echo rule (Codex P1): while the route is muted and the
    /// report does not unmute it, an observed volume ≈ 0 is the expected
    /// artifact of a mute — either our own emulated-mute write (scalar
    /// driven to 0 because the device has no writable Mute) or a driver
    /// that zeroes the scalar while muted — and must NOT overwrite the
    /// saved `route.volume`, or unmute "restores" silence. A NON-zero
    /// external volume during mute (user dragging System Settings) still
    /// updates the level while `muted` stays put, so no state is lost.
    /// An explicit external unmute applies as observed, including a
    /// genuine zero level.
    static func externalHardwareChange(
        routeVolume: Float,
        routeMuted: Bool,
        observedVolume: Float?,
        observedMuted: Bool?
    ) -> ExternalHardwareChangeDecision {
        let stillMuted = observedMuted ?? routeMuted
        var volume: Float? = nil
        if let observed = observedVolume,
           abs(routeVolume - observed) > externalVolumeDelta {
            let isMutedZeroEcho = routeMuted
                && stillMuted
                && observed <= mutedZeroEchoEpsilon
            if !isMutedZeroEcho {
                volume = observed
            }
        }
        let muted: Bool? = (observedMuted != nil && observedMuted != routeMuted)
            ? observedMuted
            : nil
        return ExternalHardwareChangeDecision(volume: volume, muted: muted)
    }

    /// Pure state machine gating media volume keys on the enter-running
    /// hardware snapshot (Codex P2).
    ///
    /// Direct Stereo entering running flips the event-tap eligibility on
    /// immediately, but `refreshDirectStereoVolumeState`'s async snapshot
    /// (capability probe + hardware volume/mute reads) is still in flight.
    /// A key pressed inside that window would step from the PERSISTED
    /// routing values and write them to hardware — jumping every output to
    /// a stale slider level, the exact scenario the startup snapshot
    /// exists to prevent. The gate keeps the tap consuming (no macOS
    /// "forbidden" OSD flicker) but drops the actions until either the
    /// snapshot lands or a fallback timeout fires, so a failed/cancelled
    /// snapshot can never leave the keys permanently dead.
    ///
    /// Episodes: every closed→waiting transition increments `episode`,
    /// and a fallback timer only opens the gate for the episode it was
    /// armed for — a timer surviving a quick leave/re-enter of running
    /// cannot open the NEXT episode early.
    enum SnapshotGate {
        enum Phase: Equatable, Sendable {
            /// Not eligible (direct stereo not running). Keys ineligible
            /// anyway; gate must re-arm on the next eligible entry.
            case closed
            /// Eligible, enter-running snapshot still in flight: drop keys.
            case waiting
            /// Snapshot landed (or fallback fired): keys flow.
            case open
        }

        struct State: Equatable, Sendable {
            var phase: Phase = .closed
            /// Monotonic count of closed→waiting transitions; pairs each
            /// armed fallback timer with the episode it belongs to.
            var episode: UInt64 = 0

            var allowsKeys: Bool { phase == .open }
        }

        /// Direct stereo became (or re-confirmed) eligible. Only a closed
        /// gate starts a new waiting episode — eligible→eligible didSet
        /// re-entries (mode reassignment, reconcile-triggered refreshes)
        /// must NOT re-close an open gate, or keys would go dead mid-run.
        static func becameEligible(
            _ state: State
        ) -> (state: State, shouldArmFallback: Bool) {
            guard state.phase == .closed else { return (state, false) }
            return (
                State(phase: .waiting, episode: state.episode &+ 1),
                true
            )
        }

        /// The enter-running snapshot settled (applied, or skipped because
        /// no targets are covered). Opens a waiting gate; a snapshot
        /// landing after the gate closed (left running mid-flight) must
        /// not reopen it.
        static func snapshotSettled(_ state: State) -> State {
            guard state.phase == .waiting else { return state }
            return State(phase: .open, episode: state.episode)
        }

        /// Fallback timeout fired for `episode`. Opens the gate only if
        /// that exact episode is still waiting — keys must never stay
        /// permanently dead on a stalled/failed snapshot, but a stale
        /// timer from a previous episode must not open a fresh one.
        static func fallbackFired(
            _ state: State, episode: UInt64
        ) -> State {
            guard state.phase == .waiting, state.episode == episode else {
                return state
            }
            return State(phase: .open, episode: state.episode)
        }

        /// Left direct-stereo-running: reset so the next entry re-arms.
        static func becameIneligible(_ state: State) -> State {
            State(phase: .closed, episode: state.episode)
        }
    }

    /// Fingerprint of the covered set, used to skip redundant hardware
    /// snapshots on reconcile passes.
    ///
    /// Must include the SyncCast device id, not just the CoreAudio UID:
    /// discovery can republish the SAME UID under a NEW device id mid-run
    /// (routing migration keeps playback), and the backend-capability map
    /// plus the hardware-volume observer are keyed by device id. A
    /// UID-only fingerprint skipped the refresh on id migration and left
    /// both pinned to the dead id — the new row lost its "volume
    /// uncontrollable" hint and external hardware volume changes were
    /// dropped.
    static func coveredSetFingerprint(
        idUIDPairs: [(id: String, uid: String)]
    ) -> Set<CoveredDeviceKey> {
        Set(idUIDPairs.map { CoveredDeviceKey(id: $0.id, uid: $0.uid) })
    }
}
