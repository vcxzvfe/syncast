import Foundation
import SyncCastRouter

/// Per-output stereo imaging: read, edit, remember, push.
///
/// Same two rules as the per-device equalizer, and for the same reasons:
///
/// 1. **Keyed by CoreAudio UID.** The setting describes a cabinet and a seat
///    in front of it, not a session. See `DeviceStereoImageProfile`.
/// 2. **The Router holds the whole map, not one-shot edits.** Re-applying is
///    then the Router's job on every driver reconcile (`applyStereoImages`),
///    which covers a re-plug, a re-enable, and an aggregate rebuild — none of
///    which the menubar reliably sees.
///
/// Unlike the equalizer there is no group target: crosstalk cancellation is a
/// statement about one listener's geometry in front of one cabinet, so there
/// is nothing sensible to apply to every AirPlay receiver at once.
@MainActor
extension AppModel {

    /// Settle time before an edit reaches the Router. Matches the equalizer's:
    /// the push is an actor hop plus a memcpy, and the audible ramp is the
    /// processor's own 20 ms crossfade.
    static let stereoImageCommitDebounceNanos: UInt64 = 50_000_000

    // MARK: - Availability

    /// Whether the current audio path renders a local output's samples itself,
    /// and can therefore image them. Identical to the equalizer's answer —
    /// both run in the same two render callbacks — but named separately so the
    /// two can diverge without a silent surprise.
    var stereoImageIsSupportedOnCurrentPath: Bool {
        equalizerIsSupportedOnCurrentPath
    }

    /// Whether THIS row should offer a stereo-image button.
    func stereoImageIsAvailable(for deviceID: String) -> Bool {
        guard stereoImageIsSupportedOnCurrentPath else { return false }
        guard routing[deviceID]?.enabled ?? false else { return false }
        return coreAudioUID(forDeviceID: deviceID) != nil
    }

    /// One line explaining why an existing setting is not being applied right
    /// now, or nil when it is. Only ever shown on a row that HAS a setting —
    /// silently ignoring a saved setting is the behaviour that reads as a bug.
    func stereoImageInactiveHint(for deviceID: String) -> String? {
        guard let uid = coreAudioUID(forDeviceID: deviceID),
              deviceStereoImages[uid]?.settings.hasUserSetting == true
        else {
            return nil
        }
        if mode == .stereo, AppModel.selectedStereoOutputPath == .direct {
            return "声场处理在 Direct Stereo 路径下不生效（音频不经过本程序）"
                + " · not applied on the Direct Stereo path"
        }
        return nil
    }

    // MARK: - Reading

    /// The setting to show in the editor. A device with nothing stored gets
    /// the neutral defaults, so the panel always has values to draw.
    func stereoImageSettings(for deviceID: String) -> StereoImageSettings {
        guard let uid = coreAudioUID(forDeviceID: deviceID) else { return .neutral }
        return deviceStereoImages[uid]?.settings ?? .neutral
    }

    /// True when the user has dialled something in for this device, whether or
    /// not it is currently bypassed. Gates the row's badge.
    func hasStereoImageSetting(for deviceID: String) -> Bool {
        guard let uid = coreAudioUID(forDeviceID: deviceID) else { return false }
        return deviceStereoImages[uid]?.settings.hasUserSetting ?? false
    }

    func stereoImageIsBypassed(for deviceID: String) -> Bool {
        stereoImageSettings(for: deviceID).bypassed
    }

    /// Short summary for the row, so a collapsed panel still says what is on.
    func stereoImageSummary(for deviceID: String) -> String? {
        guard hasStereoImageSetting(for: deviceID) else { return nil }
        return AppModel.stereoImageSummary(of: stereoImageSettings(for: deviceID))
    }

    /// Pure form, so the tests get the same string without a device lookup.
    static func stereoImageSummary(of settings: StereoImageSettings) -> String? {
        var parts: [String] = []
        if !settings.width.isNeutral {
            parts.append("宽度 \(stereoImageWidthLabel(settings.width.width))")
        }
        if !settings.crosstalk.isNeutral {
            parts.append("串扰 \(stereoImagePercentLabel(settings.crosstalk.strength))")
        }
        if settings.bypassed { parts.append("已旁路") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Whether this output's chain is currently hitting the imager's limiter.
    ///
    /// In aggregate mode the counter belongs to the single AUHAL on top of the
    /// aggregate, so every member device reports the same figure — the UI says
    /// "输出链" rather than claiming a per-speaker number we do not have.
    func stereoImageIsClipping(for deviceID: String) -> Bool {
        guard let uid = coreAudioUID(forDeviceID: deviceID) else { return false }
        return (stereoImageClipCounts[uid] ?? 0) > 0
    }

    // MARK: - Labels

    static func stereoImageWidthLabel(_ width: Double) -> String {
        String(format: "%.2f×", width)
    }

    static func stereoImagePercentLabel(_ fraction: Double) -> String {
        String(format: "%.0f%%", (fraction * 100).rounded())
    }

    static func stereoImageDecibelLabel(_ db: Double) -> String {
        // U+2212 MINUS SIGN, matching the equalizer's and the delay row's.
        let sign = db > 0 ? "+" : (db < 0 ? "−" : "")
        return String(format: "%@%.1f dB", sign, abs(db))
    }

    static func stereoImageCentimetreLabel(_ metres: Double) -> String {
        String(format: "%.0f cm", (metres * 100).rounded())
    }

    static func stereoImageHertzLabel(_ hz: Double) -> String {
        hz >= 1_000
            ? String(format: "%.1f kHz", hz / 1_000)
            : String(format: "%.0f Hz", hz)
    }

    /// The read-only "计算延迟" line: τ in microseconds, with the sample count
    /// it works out to at the rate the outputs are opened at.
    ///
    /// Shown because it is the one number in the crosstalk panel the user does
    /// not set directly — it falls out of the two geometry sliders — and
    /// because seeing it move is what makes those sliders legible.
    static func stereoImageDelayLabel(
        _ crosstalk: StereoCrosstalkSettings,
        sampleRate: Double = 48_000
    ) -> String {
        let micros = crosstalk.delaySeconds * 1_000_000
        let samples = crosstalk.delaySamples(sampleRate: sampleRate)
        return String(format: "计算延迟 %.0f µs（%.1f 采样 @48 kHz）", micros, samples)
    }

    /// The honest warning that goes with the crosstalk stage: the recursion
    /// boosts what is common to both channels near `1/(2τ)`, and that is what
    /// drives the limiter.
    static func stereoImageColourationLabel(_ crosstalk: StereoCrosstalkSettings) -> String? {
        guard !crosstalk.isNeutral else { return nil }
        let peak = crosstalk.peakColourationDb
        guard peak >= 1 else { return nil }
        return String(
            format: "中置内容在 %.1f kHz 附近最多 +%.1f dB",
            crosstalk.peakColourationHz / 1_000, peak
        )
    }

    // MARK: - Editing

    func setStereoImageBypassed(_ bypassed: Bool, for deviceID: String) {
        updateStereoImage(for: deviceID) { $0.bypassed = bypassed }
    }

    func setStereoWidthEnabled(_ enabled: Bool, for deviceID: String) {
        updateStereoImage(for: deviceID) { settings in
            settings.width.enabled = enabled
            // Turning the stage on at exactly 1.0 would be a visible switch
            // that does nothing, so an untouched width comes up at the default.
            if enabled, abs(settings.width.width - 1) < StereoImageLimits.widthEpsilon {
                settings.width.width = StereoImageLimits.defaultWidth
            }
        }
    }

    func setStereoWidth(_ width: Double, for deviceID: String) {
        updateStereoImage(for: deviceID) { settings in
            settings.width.width = StereoImageLimits.snap(
                StereoImageLimits.clamp(width, to: StereoImageLimits.widthRange),
                step: StereoImageLimits.widthStep
            )
        }
    }

    func setStereoWidthCorner(_ hz: Double, for deviceID: String) {
        updateStereoImage(for: deviceID) { settings in
            settings.width.cornerHz = StereoImageLimits.snap(
                StereoImageLimits.clamp(hz, to: StereoImageLimits.widthCornerRangeHz),
                step: StereoImageLimits.widthCornerStepHz
            )
        }
    }

    func setStereoMidTrim(_ db: Double, for deviceID: String) {
        updateStereoImage(for: deviceID) { settings in
            settings.width.midTrimDb = StereoImageLimits.snap(
                StereoImageLimits.clampMidTrimDb(db),
                step: StereoImageLimits.midTrimStepDb
            )
        }
    }

    func setStereoCrosstalkEnabled(_ enabled: Bool, for deviceID: String) {
        updateStereoImage(for: deviceID) { settings in
            settings.crosstalk.enabled = enabled
            // Same rule as the width toggle: a stage switched on at zero
            // strength is a control that visibly does nothing.
            if enabled, settings.crosstalk.strength <= StereoImageLimits.strengthEpsilon {
                settings.crosstalk.strength = StereoImageLimits.defaultStrength
            }
        }
    }

    func setStereoCrosstalkAttenuation(_ db: Double, for deviceID: String) {
        updateStereoImage(for: deviceID) { settings in
            settings.crosstalk.attenuationDb = StereoImageLimits.snap(
                StereoImageLimits.clampAttenuationDb(db),
                step: StereoImageLimits.attenuationStepDb
            )
        }
    }

    func setStereoCrosstalkStrength(_ fraction: Double, for deviceID: String) {
        updateStereoImage(for: deviceID) { settings in
            settings.crosstalk.strength = StereoImageLimits.snap(
                StereoImageLimits.clamp(fraction, to: StereoImageLimits.strengthRange),
                step: StereoImageLimits.strengthStep
            )
        }
    }

    func setStereoCrosstalkSpan(_ metres: Double, for deviceID: String) {
        updateStereoImage(for: deviceID) { settings in
            settings.crosstalk.spanMeters = StereoImageLimits.snap(
                StereoImageLimits.clamp(metres, to: StereoImageLimits.spanRangeMeters),
                step: StereoImageLimits.spanStepMeters
            )
        }
    }

    func setStereoCrosstalkDistance(_ metres: Double, for deviceID: String) {
        updateStereoImage(for: deviceID) { settings in
            settings.crosstalk.distanceMeters = StereoImageLimits.snap(
                StereoImageLimits.clamp(metres, to: StereoImageLimits.distanceRangeMeters),
                step: StereoImageLimits.distanceStepMeters
            )
        }
    }

    func setStereoCrosstalkLow(_ hz: Double, for deviceID: String) {
        updateStereoImage(for: deviceID) { settings in
            settings.crosstalk.lowHz = StereoImageLimits.snap(
                StereoImageLimits.clamp(hz, to: StereoImageLimits.crosstalkLowRangeHz),
                step: StereoImageLimits.crosstalkBandStepHz
            )
        }
    }

    func setStereoCrosstalkHigh(_ hz: Double, for deviceID: String) {
        updateStereoImage(for: deviceID) { settings in
            settings.crosstalk.highHz = StereoImageLimits.snap(
                StereoImageLimits.clamp(hz, to: StereoImageLimits.crosstalkHighRangeHz),
                step: StereoImageLimits.crosstalkBandStepHz
            )
        }
    }

    /// Back to neutral: both stages off, every value at its default. This
    /// DELETES the stored record, which is what makes an untouched speaker
    /// leave no trace in the defaults plist.
    func resetStereoImage(for deviceID: String) {
        updateStereoImage(for: deviceID) { $0 = .neutral }
    }

    /// The single mutation path: resolve the UID, apply the edit, normalise,
    /// store or delete, persist, and queue the debounced push.
    private func updateStereoImage(
        for deviceID: String,
        _ transform: (inout StereoImageSettings) -> Void
    ) {
        guard let uid = coreAudioUID(forDeviceID: deviceID) else {
            // The UI never offers the control on such a row; this is the
            // backstop, and it says so rather than failing silently.
            SyncCastLog.log("stereo image: ignoring edit for un-keyable device \(deviceID)")
            return
        }
        var settings = deviceStereoImages[uid]?.settings ?? .neutral
        transform(&settings)
        let normalized = DeviceStereoImageStore.normalize(settings)
        let name = devices.first { $0.id == deviceID }?.name

        if normalized.hasUserSetting {
            deviceStereoImages[uid] = DeviceStereoImageProfile(
                uid: uid, displayName: name, settings: normalized
            )
        } else if deviceStereoImages.removeValue(forKey: uid) == nil {
            // Nothing stored and nothing to store: the edit was a no-op (e.g.
            // Reset on an untouched row). Skip the write and the push.
            return
        }
        DeviceStereoImageStore.save(deviceStereoImages)
        scheduleStereoImageCommit()
    }

    // MARK: - Pushing to the Router

    /// Debounced full-map push. Cancels any push still waiting, so a drag
    /// collapses to one.
    func scheduleStereoImageCommit() {
        stereoImageCommitTask?.cancel()
        stereoImageCommitTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: AppModel.stereoImageCommitDebounceNanos)
            guard !Task.isCancelled, let self else { return }
            await self.pushDeviceStereoImages()
        }
    }

    /// Push the whole UID → setting map. Called on every engine start and
    /// reconcile as well as after an edit: the Router treats an unchanged map
    /// as a no-op, so re-pushing costs nothing and guarantees a freshly opened
    /// AUHAL is never left neutral.
    func pushDeviceStereoImages() async {
        let map = deviceStereoImages.mapValues(\.settings)
        await router.setStereoImages(map)
    }

    /// Sample the Router's limiter counters, from the same 1 Hz poll as the
    /// equalizer's. Skipped entirely when nothing is stored, so a user who
    /// never opens the panel pays no actor hop for it.
    func refreshStereoImageClipCounts() async {
        guard !deviceStereoImages.isEmpty, streamingState == .running else {
            if !stereoImageClipCounts.isEmpty { stereoImageClipCounts = [:] }
            return
        }
        let counts = await router.stereoImageClipCounts()
        if counts != stereoImageClipCounts { stereoImageClipCounts = counts }
    }
}
