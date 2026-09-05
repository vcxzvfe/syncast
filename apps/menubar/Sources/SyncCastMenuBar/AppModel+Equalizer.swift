import Foundation
import SyncCastRouter

/// Per-output tone control: read, edit, remember, push.
///
/// The user's request was "针对各个设备的调音器 … 长期记忆在这个设备上，每次连接
/// 都默认这样". Two rules follow from that and shape everything here:
///
/// 1. **Keyed by CoreAudio UID.** A curve belongs to the speaker, not to the
///    session. See `DeviceEqualizerProfile`.
/// 2. **The Router holds the whole map, not one-shot edits.** Re-applying is
///    then the Router's job on every driver reconcile (`applyEqualizers`),
///    which is what makes "每次连接都默认这样" true for a re-plug, a re-enable,
///    or an aggregate rebuild — none of which the menubar reliably sees.
@MainActor
extension AppModel {

    /// Settle time before a curve edit reaches the Router. Short: the push is
    /// an actor hop plus a memcpy, and the audible ramp is the bank's own
    /// 20 ms crossfade, so there is nothing to protect the audio path from —
    /// this only keeps a continuous drag from queueing a hop per frame.
    static let equalizerCommitDebounceNanos: UInt64 = 50_000_000

    // MARK: - Availability

    /// Whether the current audio path renders the samples itself, and can
    /// therefore equalise them.
    ///
    /// - Local Stereo on the **system-sink** or **capture** legs: yes. The
    ///   samples pass through `LocalOutput.render()`.
    /// - Local Stereo on **Direct Stereo**: no. The HAL renders straight into
    ///   the public aggregate; we never touch a buffer.
    /// - **Whole-home**: no. Audio flows OwnTone → `LocalAirPlayBridge`, a
    ///   different render path that this feature deliberately does not touch.
    var equalizerIsSupportedOnCurrentPath: Bool {
        mode == .stereo && AppModel.selectedStereoOutputPath != .direct
    }

    /// Whether THIS row should offer an EQ button.
    func equalizerIsAvailable(for deviceID: String) -> Bool {
        guard equalizerIsSupportedOnCurrentPath else { return false }
        guard routing[deviceID]?.enabled ?? false else { return false }
        return coreAudioUID(forDeviceID: deviceID) != nil
    }

    /// One line explaining why an existing curve is not being applied right
    /// now, or nil when it is. Only ever shown on a row that HAS a curve —
    /// silently ignoring a saved setting is the behaviour that reads as a bug.
    func equalizerInactiveHint(for deviceID: String) -> String? {
        guard let uid = coreAudioUID(forDeviceID: deviceID),
              deviceEqualizers[uid]?.settings.hasUserCurve == true
        else {
            return nil
        }
        if mode != .stereo {
            return "调音器在「AirPlay 全屋」模式下不生效 · equalizer is Local Stereo only"
        }
        if AppModel.selectedStereoOutputPath == .direct {
            return "调音器在 Direct Stereo 路径下不生效（音频不经过本程序）"
                + " · not applied on the Direct Stereo path"
        }
        return nil
    }

    /// CoreAudio UID for a row, or nil for an AirPlay receiver / a device that
    /// discovery has already dropped.
    func coreAudioUID(forDeviceID deviceID: String) -> String? {
        guard let device = devices.first(where: { $0.id == deviceID }),
              device.transport == .coreAudio
        else {
            return nil
        }
        return device.coreAudioUID
    }

    // MARK: - Reading

    /// The curve to show in the editor. A device with nothing stored gets the
    /// ten-band graphic layout at 0 dB, so the editor always has sliders to
    /// draw and the "band index" the mutators take is always meaningful.
    func equalizerSettings(for deviceID: String) -> EqualizerSettings {
        guard let uid = coreAudioUID(forDeviceID: deviceID) else {
            return .graphicFlat
        }
        return equalizerSettings(forUID: uid)
    }

    func equalizerSettings(forUID uid: String) -> EqualizerSettings {
        guard let stored = deviceEqualizers[uid]?.settings, !stored.bands.isEmpty else {
            return .graphicFlat
        }
        return stored
    }

    /// True when the user has dialled something in for this device, whether or
    /// not it is currently bypassed. Gates the row's "EQ" badge.
    func hasEqualizerCurve(for deviceID: String) -> Bool {
        guard let uid = coreAudioUID(forDeviceID: deviceID) else { return false }
        return deviceEqualizers[uid]?.settings.hasUserCurve ?? false
    }

    func equalizerIsBypassed(for deviceID: String) -> Bool {
        equalizerSettings(for: deviceID).bypassed
    }

    /// Short summary for the row, e.g. "低音 −6.0 dB" style is too clever —
    /// this reports the extreme band so the user can see at a glance that a
    /// curve is loaded and roughly how strong it is.
    func equalizerSummary(for deviceID: String) -> String? {
        guard hasEqualizerCurve(for: deviceID) else { return nil }
        let settings = equalizerSettings(for: deviceID)
        let strongest = settings.bands
            .max { abs($0.gainDb) < abs($1.gainDb) }
        var parts: [String] = []
        if let strongest, abs(strongest.gainDb) >= EqualizerLimits.gainStepDb {
            parts.append(
                "\(AppModel.equalizerFrequencyLabel(strongest.frequency))"
                    + " \(AppModel.equalizerGainLabel(strongest.gainDb))"
            )
        }
        if abs(settings.trimDb) >= EqualizerLimits.gainStepDb {
            parts.append("总量 \(AppModel.equalizerGainLabel(settings.trimDb))")
        }
        if settings.bypassed { parts.append("已旁路") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Whether this output's chain is currently hitting the limiter.
    ///
    /// In aggregate mode the counter belongs to the single AUHAL on top of the
    /// aggregate, so every member device reports the same figure — the UI says
    /// "输出链" rather than claiming a per-speaker number we do not have.
    func equalizerIsClipping(for deviceID: String) -> Bool {
        guard let uid = coreAudioUID(forDeviceID: deviceID) else { return false }
        return (equalizerClipCounts[uid] ?? 0) > 0
    }

    // MARK: - Labels

    static func equalizerFrequencyLabel(_ hz: Double) -> String {
        if hz >= 1_000 {
            let k = hz / 1_000
            return k == k.rounded()
                ? String(format: "%.0fk", k)
                : String(format: "%.1fk", k)
        }
        return hz == hz.rounded()
            ? String(format: "%.0f", hz)
            : String(format: "%.1f", hz)
    }

    static func equalizerGainLabel(_ db: Double) -> String {
        let snapped = EqualizerLimits.snapToStep(db)
        if abs(snapped) < EqualizerLimits.gainStepDb / 2 { return "0.0" }
        // U+2212 MINUS SIGN, matching the delay-trim row's hint.
        let sign = snapped > 0 ? "+" : "−"
        return String(format: "%@%.1f", sign, abs(snapped))
    }

    // MARK: - Editing

    /// Move one band. `bandIndex` indexes `equalizerSettings(for:).bands`.
    func setEqualizerBandGain(_ db: Double, bandIndex: Int, for deviceID: String) {
        updateEqualizer(for: deviceID) { settings in
            guard settings.bands.indices.contains(bandIndex) else { return }
            settings.bands[bandIndex].gainDb =
                EqualizerLimits.snapToStep(EqualizerLimits.clampBandGainDb(db))
        }
    }

    /// Move the pre-gain.
    func setEqualizerTrim(_ db: Double, for deviceID: String) {
        updateEqualizer(for: deviceID) { settings in
            settings.trimDb = EqualizerLimits.snapToStep(EqualizerLimits.clampTrimDb(db))
        }
    }

    /// A/B switch. The curve is remembered while bypassed — losing it would
    /// defeat the point of having the switch.
    func setEqualizerBypassed(_ bypassed: Bool, for deviceID: String) {
        updateEqualizer(for: deviceID) { settings in
            settings.bypassed = bypassed
        }
    }

    /// Back to flat: every band at 0 dB, no trim, not bypassed. This DELETES
    /// the stored record, which is what makes an untouched speaker leave no
    /// trace in the defaults plist.
    func resetEqualizer(for deviceID: String) {
        updateEqualizer(for: deviceID) { settings in
            settings = .graphicFlat
        }
    }

    /// The single mutation path: resolve the UID, apply the edit, normalise,
    /// store or delete, persist, and queue the debounced push.
    private func updateEqualizer(
        for deviceID: String,
        _ transform: (inout EqualizerSettings) -> Void
    ) {
        guard let uid = coreAudioUID(forDeviceID: deviceID) else {
            // A device with no CoreAudio UID cannot be keyed, and this feature
            // is CoreAudio-only, so there is nothing to edit. The UI never
            // offers the control on such a row; this is the backstop.
            SyncCastLog.log("equalizer: ignoring edit for un-keyable device \(deviceID)")
            return
        }
        var settings = equalizerSettings(forUID: uid)
        transform(&settings)
        let normalized = DeviceEqualizerStore.normalize(settings)
        let name = devices.first { $0.id == deviceID }?.name

        if normalized.hasUserCurve {
            deviceEqualizers[uid] = DeviceEqualizerProfile(
                uid: uid, displayName: name, settings: normalized
            )
        } else if deviceEqualizers.removeValue(forKey: uid) == nil {
            // Nothing stored and nothing to store: the edit was a no-op (e.g.
            // Reset on an untouched row). Skip the write and the push.
            return
        }
        DeviceEqualizerStore.save(deviceEqualizers)
        scheduleEqualizerCommit()
    }

    // MARK: - Pushing to the Router

    /// Debounced full-map push. Cancels any push still waiting, so a drag
    /// collapses to one.
    func scheduleEqualizerCommit() {
        equalizerCommitTask?.cancel()
        equalizerCommitTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: AppModel.equalizerCommitDebounceNanos)
            guard !Task.isCancelled, let self else { return }
            await self.pushDeviceEqualizers()
        }
    }

    /// Push the whole UID → curve map. Called on every engine start and
    /// reconcile as well as after an edit: the Router treats an unchanged map
    /// as a no-op, so re-pushing costs nothing and guarantees a freshly opened
    /// AUHAL is never left flat.
    func pushDeviceEqualizers() async {
        let map = deviceEqualizers.mapValues(\.settings)
        await router.setEqualizers(map)
    }

    /// Sample the Router's limiter counters. Called from the same 1 Hz poll as
    /// the connection states; skipped entirely when nothing is stored, so a
    /// user who never opens the EQ pays no actor hop for it.
    func refreshEqualizerClipCounts() async {
        guard !deviceEqualizers.isEmpty, streamingState == .running else {
            if !equalizerClipCounts.isEmpty { equalizerClipCounts = [:] }
            return
        }
        let counts = await router.equalizerClipCounts()
        if counts != equalizerClipCounts { equalizerClipCounts = counts }
    }
}
