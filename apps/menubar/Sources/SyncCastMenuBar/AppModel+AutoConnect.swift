import Foundation
import SyncCastDiscovery
import SyncCastRouter

/// Auto-connect: the glue between `AutoConnectCoordinator`'s decisions and the
/// intents `AppModel` already exposes (`setMode`, `setDeviceEnabled`,
/// `reconcileEngine`).
///
/// Nothing here decides anything. The coordinator decides; this file snapshots
/// the world for it, translates one action into existing intents, and logs
/// every step so a wrong route on real hardware can be read out of
/// `~/Library/Logs/SyncCast/launch.log` without reproducing it.
extension AppModel {

    // MARK: - Tunables

    /// How long to wait after tearing the engine down before pointing macOS at
    /// the built-in speakers. `reconcileEngine` is debounced by 30 ms and
    /// `DirectStereoOutput.stop()` then restores whatever the default output
    /// was BEFORE SyncCast took over — which, on a disconnect, is the monitor
    /// that just left. Writing our own default first would simply be undone.
    static let autoConnectDeactivateSettleSeconds: Double = 0.8

    /// Grace period after launch before the first evaluation. Discovery needs
    /// to have reported the devices that are already plugged in; the
    /// coordinator's own debounce then adds its 1.5 s on top.
    static let autoConnectLaunchSettleSeconds: Double = 3.0

    /// Delay before re-evaluating after wake. Mirrors `handleWake`'s own 1.5 s
    /// `coreaudiod` settle plus a margin for the device list to come back.
    static let autoConnectWakeSettleSeconds: Double = 3.0

    /// How long to wait before re-attempting an activation the app refused to
    /// apply. The only known cause is `setMode` single-flighting a transition
    /// that is already running, and that transition is a `router.stop()` plus a
    /// reconcile — comfortably inside a second.
    static let autoConnectActivationRetrySeconds: Double = 1.0

    /// Debug hatch: comma-separated CoreAudio UIDs to hide from the
    /// coordinator, so the disconnect branch can be exercised on hardware
    /// without physically unplugging anything.
    ///
    ///     SYNCAST_AUTOCONNECT_SIMULATE_ABSENT=00000000-0000-0000-0000-000000000001
    ///
    /// Only the auto-connect view of the device list is affected — discovery,
    /// the popover and the engine still see the device — so this simulates
    /// "the rule thinks it is gone", not "the device is gone".
    ///
    /// Read once at first use: the environment cannot change under a running
    /// process, and this is consulted on every evaluation.
    static let autoConnectSimulatedAbsentUIDs: Set<String> = {
        guard let raw = ProcessInfo.processInfo
            .environment["SYNCAST_AUTOCONNECT_SIMULATE_ABSENT"]
        else { return [] }
        return Set(
            raw.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        )
    }()

    // MARK: - Rule access

    /// v1 edits a single rule. The store is an array so a later revision can
    /// add more without a migration; `first` is the one the UI shows.
    var autoConnectProfile: AutoConnectProfile? { autoConnectProfiles.first }

    /// Local outputs that make sense as a trigger: everything except the
    /// built-in speakers, which are always present and would arm the rule
    /// permanently.
    var autoConnectTriggerCandidates: [Device] {
        localDevices.filter { device in
            guard let uid = device.coreAudioUID else { return false }
            return uid != AutoConnect.builtInSpeakerUID
                && !uid.hasPrefix(AutoConnect.builtInUIDPrefix)
        }
    }

    /// Local outputs the user currently has switched on, as devices.
    var autoConnectEnabledLocalDevices: [Device] {
        localDevices.filter { routing[$0.id]?.enabled == true }
    }

    /// Whether the rule's trigger device is connected right now.
    var autoConnectTriggerPresent: Bool {
        guard let profile = autoConnectProfile else { return false }
        return autoConnectPresentUIDs().contains(profile.triggerUID)
    }

    /// One-line 「当 X 出现 → 开启 A + B」 summary for the popover.
    var autoConnectSummary: String? {
        guard let profile = autoConnectProfile else { return nil }
        let members = profile.memberUIDs
            .map { autoConnectDisplayName(for: $0, in: profile) }
            .joined(separator: " + ")
        let trigger = autoConnectDisplayName(for: profile.triggerUID, in: profile)
        return "当 \(trigger) 出现 → 开启 \(members)"
    }

    func autoConnectDisplayName(for uid: String, in profile: AutoConnectProfile) -> String {
        if let live = devices.first(where: { $0.coreAudioUID == uid })?.name {
            return live
        }
        return profile.displayName(for: uid)
    }

    // MARK: - Rule editing

    /// 「用当前选择创建规则」: the enabled local outputs become the members and
    /// the picked device becomes the trigger.
    ///
    /// Refuses rather than half-creates when the selection cannot produce a
    /// usable rule — a rule that can never fire is worse than no rule, because
    /// the user believes automation is in place.
    func autoConnectCreateProfile(triggerUID: String) {
        let members = autoConnectEnabledLocalDevices.compactMap(\.coreAudioUID)
        guard !triggerUID.isEmpty, !members.isEmpty else {
            SyncCastLog.log(
                "autoconnect: refusing to create rule (trigger=\(triggerUID.isEmpty ? "none" : triggerUID) members=\(members.count))"
            )
            lastError = "自动连接：先选好要开的设备，再创建规则"
            return
        }
        var names: [String: String] = [:]
        for uid in Set(members + [triggerUID]) {
            if let name = devices.first(where: { $0.coreAudioUID == uid })?.name {
                names[uid] = name
            }
        }
        let profile = AutoConnectProfile(
            enabled: true,
            triggerUID: triggerUID,
            memberUIDs: members,
            onDisconnect: .off,
            displayNames: names
        )
        autoConnectReplaceProfiles([profile], reason: "created")
        // The rule is created FROM the current state, so it is already
        // satisfied. Evaluating now claims the episode instead of re-applying
        // what is already true.
        autoConnectEvaluate(reason: "rule created")
    }

    func autoConnectDeleteProfile() {
        guard let profile = autoConnectProfile else { return }
        autoConnectCoordinator.forgetProfile(profile.id)
        autoConnectReplaceProfiles([], reason: "deleted")
    }

    func autoConnectSetEnabled(_ enabled: Bool) {
        guard var profile = autoConnectProfile, profile.enabled != enabled else { return }
        profile.enabled = enabled
        if !enabled {
            // Drop the episode as well as flipping the flag, so a rule that
            // had already fired cannot answer a later unplug with a stop and a
            // volume change the user has just switched off.
            autoConnectCoordinator.forgetProfile(profile.id)
        }
        autoConnectReplaceProfiles([profile], reason: "enabled=\(enabled)")
        if enabled {
            // Turning the switch on is an explicit "apply this now" — the same
            // intent as the 重新应用规则 button.
            autoConnectReapplyNow()
        }
    }

    func autoConnectSetRestoreBuiltIn(_ restore: Bool) {
        guard var profile = autoConnectProfile else { return }
        profile.onDisconnect = .init(
            restoreBuiltIn: restore,
            builtInVolumePercent: profile.onDisconnect.builtInVolumePercent
        )
        autoConnectReplaceProfiles([profile], reason: "restoreBuiltIn=\(restore)")
    }

    /// nil means "leave the built-in level alone", which is the default for a
    /// new rule. This machine's owner sets 0.
    func autoConnectSetBuiltInVolumePercent(_ percent: Int?) {
        guard var profile = autoConnectProfile else { return }
        profile.onDisconnect = .init(
            restoreBuiltIn: profile.onDisconnect.restoreBuiltIn,
            builtInVolumePercent: percent
        )
        autoConnectReplaceProfiles([profile], reason: "builtInVolume=\(percent.map(String.init) ?? "off")")
    }

    /// 「重新应用规则」: forget that the user overrode us, then evaluate.
    func autoConnectReapplyNow() {
        autoConnectCoordinator.resetSuppression()
        SyncCastLog.log("autoconnect: manual re-apply requested")
        autoConnectEvaluate(reason: "manual re-apply")
    }

    private func autoConnectReplaceProfiles(
        _ profiles: [AutoConnectProfile],
        reason: String
    ) {
        autoConnectProfiles = AutoConnectProfileStore.sanitize(profiles)
        AutoConnectProfileStore.save(autoConnectProfiles)
        SyncCastLog.log(
            "autoconnect: rules \(reason) (count=\(autoConnectProfiles.count))"
        )
    }

    // MARK: - Triggers into the coordinator

    /// Called once bootstrap has started discovery. The monitor may already be
    /// plugged in from a previous session, in which case SyncCast should come
    /// up playing without the user touching anything.
    func autoConnectBootstrap() {
        SyncCastLog.log(
            "autoconnect: \(autoConnectProfiles.count) rule(s) loaded"
            + (AppModel.autoConnectSimulatedAbsentUIDs.isEmpty
               ? ""
               : "; simulating absent \(AppModel.autoConnectSimulatedAbsentUIDs.sorted().joined(separator: ","))")
        )
        autoConnectScheduleRecheck(
            after: AppModel.autoConnectLaunchSettleSeconds, reason: "launch"
        )
    }

    /// The device list changed. Cheap: the coordinator's debounce decides
    /// whether this edge is worth believing.
    func autoConnectNoteDeviceChange() {
        autoConnectEvaluate(reason: "device change")
    }

    /// The user changed the selection or the mode themselves. Suppresses the
    /// rule for the rest of this trigger-presence episode.
    func autoConnectNoteUserIntent(_ reason: String) {
        guard !autoConnectApplying, !autoConnectProfiles.isEmpty else { return }
        autoConnectCoordinator.noteUserOverride()
        SyncCastLog.log("autoconnect: user override (\(reason)); rule stands down this episode")
    }

    func autoConnectNoteWake() {
        autoConnectScheduleRecheck(
            after: AppModel.autoConnectWakeSettleSeconds, reason: "wake"
        )
    }

    // MARK: - Evaluation

    func autoConnectScheduleRecheck(after seconds: Double, reason: String) {
        autoConnectRecheckTask?.cancel()
        autoConnectRecheckTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            if Task.isCancelled { return }
            self?.autoConnectEvaluate(reason: reason)
        }
    }

    /// Ask the coordinator what to do and do it. At most one action per call;
    /// an action schedules a prompt re-evaluation so a departure followed by an
    /// arrival still resolves.
    func autoConnectEvaluate(reason: String) {
        guard !autoConnectProfiles.isEmpty else { return }
        // Re-entrancy: our own `setDeviceEnabled` calls fan out to discovery
        // and volume re-seeding, which would call straight back in here.
        guard !autoConnectApplying else { return }

        let decision = autoConnectCoordinator.evaluate(
            AutoConnectCoordinator.Input(
                profiles: autoConnectProfiles,
                presentUIDs: autoConnectPresentUIDs(),
                enabledUIDs: autoConnectEnabledUIDs(),
                isStreaming: streamingState == .running,
                isStereoMode: mode == .stereo,
                now: Date()
            )
        )

        switch decision.action {
        case .none:
            break
        case .activate(let profileID, let memberUIDs):
            SyncCastLog.log(
                "autoconnect: activate rule \(profileID.uuidString.prefix(8)) "
                + "members=[\(memberUIDs.joined(separator: ","))] (\(reason))"
            )
            if autoConnectApplyActivation(memberUIDs: memberUIDs) {
                autoConnectScheduleRecheck(after: 0.2, reason: "post-activate")
            } else {
                autoConnectHandleActivationFailure(profileID: profileID)
            }
            return
        case .claimSatisfied(let profileID, let memberUIDs):
            // Nothing to start: the audio path is already what the rule would
            // have built. The episode is claimed by the coordinator; all this
            // owes the user is the built-in level a previous disconnect may
            // have forced down, which no `.activate` will ever come along to
            // hand back on this path.
            SyncCastLog.log(
                "autoconnect: rule \(profileID.uuidString.prefix(8)) already satisfied; "
                + "claiming the episode without touching the audio path (\(reason))"
            )
            autoConnectRestoreBuiltInLevel(memberUIDs: memberUIDs)
            return
        case .deactivate(let profileID, let memberUIDs, let restoreBuiltIn, let volumePercent):
            SyncCastLog.log(
                "autoconnect: deactivate rule \(profileID.uuidString.prefix(8)) "
                + "members=[\(memberUIDs.joined(separator: ","))] "
                + "restoreBuiltIn=\(restoreBuiltIn) "
                + "volume=\(volumePercent.map { "\($0)%" } ?? "unchanged") (\(reason))"
            )
            autoConnectApplyDeactivation(
                profileID: profileID,
                memberUIDs: memberUIDs,
                restoreBuiltIn: restoreBuiltIn,
                volumePercent: volumePercent
            )
            autoConnectScheduleRecheck(after: 0.2, reason: "post-deactivate")
            return
        }

        if let after = decision.recheckAfter {
            // +50 ms so the retry lands after the debounce deadline rather
            // than exactly on it, where a coarse clock could miss by a hair
            // and cost another full round trip.
            autoConnectScheduleRecheck(after: after + 0.05, reason: "settling \(reason)")
        }
    }

    /// CoreAudio UIDs the rule engine considers present.
    ///
    /// Deliberately `localDevices` rather than raw `devices`: SyncCast's own
    /// aggregates and BlackHole appear and disappear as the engine starts and
    /// stops, and feeding those edges to the debounce would keep the present
    /// set permanently unsettled.
    func autoConnectPresentUIDs() -> Set<String> {
        let simulatedAbsent = AppModel.autoConnectSimulatedAbsentUIDs
        return Set(localDevices.compactMap(\.coreAudioUID))
            .subtracting(simulatedAbsent)
    }

    func autoConnectEnabledUIDs() -> Set<String> {
        Set(autoConnectEnabledLocalDevices.compactMap(\.coreAudioUID))
    }

    // MARK: - Applying actions

    /// - Returns: false when the app refused the switch to local Stereo, in
    ///   which case NOTHING else was touched and the caller must arrange a
    ///   retry. Enabling the members anyway would leave them switched on in
    ///   whole-home, which is the wrong mode for every one of them.
    private func autoConnectApplyActivation(memberUIDs: [String]) -> Bool {
        autoConnectApplying = true
        defer { autoConnectApplying = false }
        if mode != .stereo {
            setMode(.stereo)
            // `setMode` is single-flight: it drops the call and returns
            // silently when a previous transition is still stopping the
            // engine. `mode` is the only signal that it did.
            guard mode == .stereo else {
                SyncCastLog.log(
                    "autoconnect: setMode(.stereo) was dropped (mode=\(mode.rawValue)); "
                    + "leaving the selection untouched"
                )
                return false
            }
        }
        // Before the members go on, never after: the Direct Stereo snapshot
        // that runs on enabling reads the hardware as the authority.
        autoConnectRestoreBuiltInLevel(memberUIDs: memberUIDs)
        let wanted = Set(memberUIDs)
        for device in localDevices {
            guard let uid = device.coreAudioUID else { continue }
            let shouldEnable = wanted.contains(uid)
            let isEnabled = routing[device.id]?.enabled == true
            guard shouldEnable != isEnabled else { continue }
            setDeviceEnabled(shouldEnable, for: device.id)
        }
        reconcileEngine()
        return true
    }

    /// Retry, or give up loudly. Never silently.
    private func autoConnectHandleActivationFailure(profileID: UUID) {
        guard autoConnectCoordinator.markActivationFailed(profileID) else {
            SyncCastLog.log(
                "autoconnect: rule \(profileID.uuidString.prefix(8)) could not be applied "
                + "after \(AutoConnectCoordinator.maxActivationAttempts) attempts; "
                + "standing down until the trigger is unplugged and reconnected"
            )
            lastError = "自动连接：切换到本地 Stereo 失败，本次不再重试"
            return
        }
        SyncCastLog.log(
            "autoconnect: retrying rule \(profileID.uuidString.prefix(8)) in "
            + "\(AppModel.autoConnectActivationRetrySeconds)s"
        )
        autoConnectScheduleRecheck(
            after: AppModel.autoConnectActivationRetrySeconds, reason: "activation retry"
        )
    }

    /// Hand the built-in speakers back the level a previous disconnect forced
    /// down, if this activation is the one that owes it.
    ///
    /// All the judgement is in `AutoConnectPlan.restore`; this reads the world
    /// and executes the verdict.
    func autoConnectRestoreBuiltInLevel(memberUIDs: [String]) {
        let builtInUID = AutoConnect.builtInOutputUID(in: devices)
        let snapshot = AutoConnectBuiltInVolumeStore.load()
        let current = builtInUID.flatMap { AggregateDevice.readHardwareVolume(uid: $0) }
        switch AutoConnectPlan.restore(
            memberUIDs: memberUIDs,
            builtInUID: builtInUID,
            snapshot: snapshot,
            currentScalar: current
        ) {
        case .none(let reason):
            SyncCastLog.log("autoconnect: built-in level left alone — \(reason)")
        case .write(let scalar, let clearSnapshot, let reason):
            guard let builtInUID else { return }
            let ok = AggregateDevice.applyHardwareVolume(uid: builtInUID, volume: scalar)
            SyncCastLog.log(
                "autoconnect: built-in level → \(String(format: "%.2f", scalar)) "
                + "ok=\(ok) — \(reason)"
            )
            if clearSnapshot {
                AutoConnectBuiltInVolumeStore.clear()
            }
        }
    }

    /// Switch the rule's own members off, then (optionally, and after a settle
    /// delay) hand the system back to the built-in speakers at a fixed level.
    ///
    /// The scope of the teardown and the whole-home carve-out are both decided
    /// by `AutoConnectPlan.deactivation` — read that for the reasoning. The
    /// built-in half runs after a delay because it has to win against
    /// `DirectStereoOutput.stop()`, which restores the PREVIOUS default output
    /// — the monitor that just left.
    private func autoConnectApplyDeactivation(
        profileID: UUID,
        memberUIDs: [String],
        restoreBuiltIn: Bool,
        volumePercent: Int?
    ) {
        let builtInUID = AutoConnect.builtInOutputUID(in: devices)
        let plan = AutoConnectPlan.deactivation(
            memberUIDs: memberUIDs,
            restoreBuiltIn: restoreBuiltIn,
            builtInVolumePercent: volumePercent,
            isWholeHome: mode == .wholeHome,
            builtInUID: builtInUID
        )
        autoConnectApplyMemberTeardown(plan.disableUIDs)

        guard plan.touchesBuiltIn, let builtInUID else {
            if let reason = plan.skipReason {
                SyncCastLog.log("autoconnect: built-in fallback skipped — \(reason)")
            }
            return
        }
        // The trigger this teardown answers, captured now: by the time the
        // follow-up wakes the rule may have been deleted out from under it.
        let triggerUID = autoConnectProfiles.first { $0.id == profileID }?.triggerUID
        autoConnectDeactivateTask?.cancel()
        autoConnectDeactivateTask = Task { @MainActor [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(AppModel.autoConnectDeactivateSettleSeconds * 1_000_000_000)
            )
            guard !Task.isCancelled, let self else { return }
            self.autoConnectApplyBuiltInFallback(
                plan: plan, builtInUID: builtInUID, triggerUID: triggerUID
            )
        }
    }

    /// Switch off exactly the rule's members, and only local outputs.
    ///
    /// `devices` filtered by transport rather than `localDevices`, which also
    /// filters by "selectable in the current mode" — a member that has become
    /// unselectable is precisely one that still needs switching off.
    private func autoConnectApplyMemberTeardown(_ disableUIDs: Set<String>) {
        autoConnectApplying = true
        defer { autoConnectApplying = false }
        for device in devices where device.transport == .coreAudio {
            guard let uid = device.coreAudioUID,
                  disableUIDs.contains(uid),
                  routing[device.id]?.enabled == true
            else { continue }
            setDeviceEnabled(false, for: device.id)
        }
        reconcileEngine()
    }

    /// The delayed half: point macOS back at the built-in speakers and force
    /// their level, having first checked that the world still wants it.
    private func autoConnectApplyBuiltInFallback(
        plan: AutoConnectPlan.Deactivation,
        builtInUID: String,
        triggerUID: String?
    ) {
        let triggerPresent = triggerUID.map { autoConnectPresentUIDs().contains($0) } ?? false
        let isStreaming = streamingState == .running
        guard AutoConnectPlan.builtInFallbackStillWanted(
            triggerPresent: triggerPresent, isStreaming: isStreaming
        ) else {
            SyncCastLog.log(
                "autoconnect: built-in fallback stood down "
                + "(trigger back=\(triggerPresent) streaming=\(isStreaming))"
            )
            return
        }
        if plan.restoreBuiltIn {
            let ok = SystemDefaultOutput.setDefaultOutput(uid: builtInUID)
            SyncCastLog.log("autoconnect: default output → \(builtInUID) ok=\(ok)")
        }
        guard let percent = plan.builtInVolumePercent else { return }
        autoConnectRememberBuiltInLevel(uid: builtInUID)
        // Linear scalar on purpose: this is the macOS slider position, so
        // 0 % is genuinely silent. See DisconnectAction.builtInVolumePercent.
        let ok = AggregateDevice.applyHardwareVolume(
            uid: builtInUID,
            volume: AutoConnect.hardwareScalar(forPercent: percent)
        )
        SyncCastLog.log("autoconnect: built-in volume → \(percent)% ok=\(ok)")
    }

    /// Remember the level we are about to overwrite, so the next activation
    /// can give it back. See `AutoConnectPlan.capture`.
    private func autoConnectRememberBuiltInLevel(uid: String) {
        let current = AggregateDevice.readHardwareVolume(uid: uid)
        switch AutoConnectPlan.capture(
            existing: AutoConnectBuiltInVolumeStore.load(),
            uid: uid,
            currentScalar: current
        ) {
        case .skip(let reason):
            SyncCastLog.log("autoconnect: not snapshotting the built-in level — \(reason)")
        case .capture(let scalar):
            AutoConnectBuiltInVolumeStore.save(
                AutoConnectBuiltInVolumeSnapshot(
                    uid: uid, scalar: scalar, capturedAt: Date()
                )
            )
            SyncCastLog.log(
                "autoconnect: remembered built-in level \(String(format: "%.2f", scalar)) "
                + "before forcing it down"
            )
        }
    }
}
