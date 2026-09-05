import Foundation
import SyncCastRouter

/// Per-device delay compensation for the local Stereo paths: read, edit,
/// remember, push.
///
/// The problem it solves is one the machine cannot see. A display's panel
/// applies its own audio processing after the HAL has handed the samples over,
/// costing tens of milliseconds that `kAudioDevicePropertyLatency` never
/// mentions, so the display and the built-in speakers play the same stream a
/// noticeable distance apart. The Router seeds each device from the latency it
/// DOES report; this control is the signed remainder, measured by the only
/// instrument that can see it — the listener.
///
/// Two rules shape everything here, both borrowed from the equalizer because
/// the requirement is the same ("remember it on this device, apply it every
/// time it connects"):
///
/// 1. **Keyed by CoreAudio UID.** The value belongs to the speaker, not to the
///    session. See `LocalDelayTrimProfile`.
/// 2. **The Router holds the whole map, not one-shot edits.** Re-applying is
///    then the Router's job on every driver reconcile and replan, which is
///    what makes the setting survive a re-plug, a re-enable, or an aggregate
///    rebuild — none of which the menubar reliably sees.
@MainActor
extension AppModel {

    /// Settle time before an edit reaches the Router. Short: the push is an
    /// actor hop plus a memcpy, and the audible ramp is the render thread's
    /// own 20 ms crossfade, so this only keeps a continuous drag from queueing
    /// a hop per pixel.
    ///
    /// Deliberately NOT the whole-home trim's 200 ms: that one is long because
    /// each commit costs an AirPlay receiver a ~0.4 s relatch. Nothing here
    /// relatches anything.
    static let localDelayTrimCommitDebounceNanos: UInt64 = 50_000_000

    // MARK: - Availability

    /// Whether the current audio path renders the samples itself, and can
    /// therefore delay them.
    ///
    /// - Local Stereo on the **system-sink** or **capture** legs: yes. The
    ///   samples pass through `LocalOutput.render()`.
    /// - Local Stereo on **Direct Stereo**: no. The HAL renders straight into
    ///   the public aggregate; we never touch a buffer.
    /// - **Whole-home**: no. That path has its own per-output trim on the
    ///   device row, which is a different correction on a different leg.
    var localDelayTrimIsSupportedOnCurrentPath: Bool {
        mode == .stereo && AppModel.selectedStereoOutputPath != .direct
    }

    /// Whether THIS row should offer the control.
    ///
    /// Enabled outputs only: a disabled device is not a member of the set the
    /// Router normalises, so its slider would move nothing. The value is kept
    /// (it is keyed by UID in the defaults) and comes back with the device.
    func localDelayTrimIsAvailable(for deviceID: String) -> Bool {
        guard localDelayTrimIsSupportedOnCurrentPath else { return false }
        guard routing[deviceID]?.enabled ?? false else { return false }
        return coreAudioUID(forDeviceID: deviceID) != nil
    }

    /// One line explaining why a stored value is not being applied right now,
    /// or nil when it is. Only ever shown on a row that HAS one — silently
    /// ignoring a saved setting is the behaviour that reads as a bug.
    func localDelayTrimInactiveHint(for deviceID: String) -> String? {
        guard let uid = coreAudioUID(forDeviceID: deviceID),
              (localDelayTrims[uid]?.delayMs ?? 0) != 0
        else {
            return nil
        }
        if mode != .stereo {
            return "本机延迟补偿在「AirPlay 全屋」模式下不生效（该模式用设备行的延迟微调）"
                + " · local delay is Stereo only"
        }
        if AppModel.selectedStereoOutputPath == .direct {
            return "本机延迟补偿在 Direct Stereo 路径下不生效（音频不经过本程序）"
                + " · not applied on the Direct Stereo path"
        }
        return nil
    }

    // MARK: - Reading

    /// The value dialled in for a device, in milliseconds. Signed: positive
    /// means "make this one sound later".
    func localDelayTrimMs(for deviceID: String) -> Int {
        guard let uid = coreAudioUID(forDeviceID: deviceID) else { return 0 }
        return localDelayTrims[uid]?.delayMs ?? 0
    }

    func hasLocalDelayTrim(for deviceID: String) -> Bool {
        localDelayTrimMs(for: deviceID) != 0
    }

    /// Label beside the control. States the correction, never a distance the
    /// user is supposed to measure: 1 ms of hold is worth ~34 cm of extra path
    /// length, which is what makes the number intuitive at all.
    static func localDelayTrimLabel(_ ms: Int) -> String {
        guard ms != 0 else { return "0 ms" }
        // U+2212 MINUS SIGN, matching the whole-home trim row.
        let sign = ms > 0 ? "+" : "−"
        return "\(sign)\(abs(ms)) ms"
    }

    /// The one-line hint under the control. Says which way the sign goes,
    /// because "I set −5 and that speaker did not move" is the normalisation
    /// working correctly and looks like a bug without this sentence.
    static var localDelayTrimHint: String {
        let cm = Int((DeviceDelayTrim.speedOfSoundMPerS / 10).rounded())
        return "正值 = 让这台晚出声（相对最早的那台）· 1 ms ≈ \(cm) cm"
    }

    // MARK: - Editing

    /// Set one device's trim.
    ///
    /// - Parameter persist: false while a slider is being dragged — the value
    ///   is live (and pushed, debounced) but not yet written to the defaults,
    ///   so a drag costs one write on release rather than one per pixel. The
    ///   in-memory value is what gets pushed either way, so "live" and "saved"
    ///   never disagree about what is playing.
    func setLocalDelayTrim(_ ms: Int, for deviceID: String, persist: Bool = true) {
        guard let uid = coreAudioUID(forDeviceID: deviceID) else {
            // The UI never offers the control on a row with no CoreAudio UID
            // (an AirPlay receiver never reaches our render callback); this is
            // the backstop, and it says so rather than failing silently.
            SyncCastLog.log("localDelay: ignoring edit for un-keyable device \(deviceID)")
            return
        }
        let clamped = LocalDelayTrim.clamp(ms)
        let current = localDelayTrims[uid]?.delayMs ?? 0
        let name = devices.first { $0.id == deviceID }?.name
        if clamped == current {
            // Nothing moved. Still honour a persist request, because a drag
            // that ends where it started must not leave the release write
            // pending forever.
            if persist { LocalDelayTrimStore.save(localDelayTrims) }
            return
        }
        if clamped == 0 {
            localDelayTrims.removeValue(forKey: uid)
        } else {
            localDelayTrims[uid] = LocalDelayTrimProfile(
                uid: uid, displayName: name, delayMs: clamped
            )
        }
        if persist { LocalDelayTrimStore.save(localDelayTrims) }
        scheduleLocalDelayTrimCommit()
    }

    /// Nudge by a signed delta (the ± buttons / arrow keys).
    func nudgeLocalDelayTrim(_ deltaMs: Int, for deviceID: String) {
        setLocalDelayTrim(localDelayTrimMs(for: deviceID) + deltaMs, for: deviceID)
    }

    func resetLocalDelayTrim(for deviceID: String) {
        setLocalDelayTrim(0, for: deviceID)
    }

    // MARK: - Pushing to the Router

    /// Debounced full-map push. Cancels any push still waiting, so a drag
    /// collapses to one.
    func scheduleLocalDelayTrimCommit() {
        localDelayTrimCommitTask?.cancel()
        localDelayTrimCommitTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: AppModel.localDelayTrimCommitDebounceNanos)
            guard !Task.isCancelled, let self else { return }
            await self.pushLocalDelayTrims()
        }
    }

    /// Push the whole UID → milliseconds map. Called on every engine start and
    /// stereo reconcile as well as after an edit: the Router treats an
    /// unchanged map as a no-op, so re-pushing costs nothing and guarantees a
    /// freshly opened AUHAL is never left at zero.
    func pushLocalDelayTrims() async {
        let map = localDelayTrims.mapValues(\.delayMs)
        await router.setLocalDelayTrims(map)
    }
}
