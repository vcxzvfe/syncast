import Foundation
import SyncCastDiscovery
import SyncCastRouter

/// Per-output channel assignment ("声道分配"): read, edit, remember, push.
///
/// The same two rules as the equalizer and the stereo imager, for the same
/// reasons:
///
/// 1. **Keyed by output UID.** The assignment describes where a cabinet sits,
///    not a session. See `DeviceChannelMatrixProfile`.
/// 2. **The Router holds the whole map, not one-shot edits.** Re-applying is
///    then the Router's job on every driver reconcile
///    (`applyChannelMatrices`), which covers a re-plug, a re-enable and an
///    aggregate rebuild — none of which the menubar reliably sees.
///
/// One thing IS different: the UID space is wider. A LAN receiver has no
/// CoreAudio UID, but the sender applies the matrix before packetising, so a
/// receiver is a perfectly good target and is keyed by its `lan:` UID.
@MainActor
extension AppModel {

    /// Settle time before an edit reaches the Router. Matches the other two
    /// panels': the push is an actor hop plus a memcpy, and the audible ramp
    /// is the bank's own 20 ms coefficient ramp.
    static let channelMatrixCommitDebounceNanos: UInt64 = 50_000_000

    // MARK: - Identity

    /// The UID this device's channel assignment is stored under, or nil for a
    /// device that has no stable one (an AirPlay receiver, which is not
    /// offered the control at all).
    func channelMatrixUID(forDeviceID deviceID: String) -> String? {
        guard let device = devices.first(where: { $0.id == deviceID }) else { return nil }
        switch device.transport {
        case .coreAudio:
            return device.coreAudioUID
        case .lanReceiver:
            return Device.lanReceiverUID(serviceName: device.lanServiceName)
        case .airplay2:
            // OwnTone's fan-out sends one stream to every receiver, so a
            // per-receiver assignment is not something the architecture can
            // express. Better no control than one that silently reassigns the
            // whole house.
            return nil
        }
    }

    // MARK: - Availability

    /// Whether the current audio path renders these samples itself, and can
    /// therefore reassign them.
    var channelMatrixIsSupportedOnCurrentPath: Bool {
        equalizerIsSupportedOnCurrentPath
    }

    /// Whether THIS row should offer a 声道 button.
    func channelMatrixIsAvailable(for deviceID: String) -> Bool {
        guard channelMatrixIsSupportedOnCurrentPath else { return false }
        guard routing[deviceID]?.enabled ?? false else { return false }
        return channelMatrixUID(forDeviceID: deviceID) != nil
    }

    /// One line explaining why an existing assignment is not being applied
    /// right now, or nil when it is. Only ever shown on a row that HAS one —
    /// silently ignoring a saved setting is the behaviour that reads as a bug.
    func channelMatrixInactiveHint(for deviceID: String) -> String? {
        guard let uid = channelMatrixUID(forDeviceID: deviceID),
              deviceChannelMatrices[uid]?.settings.hasUserSetting == true
        else {
            return nil
        }
        if mode == .stereo, AppModel.selectedStereoOutputPath == .direct {
            return "声道分配在 Direct Stereo 路径下不生效（音频不经过本程序）"
                + " · not applied on the Direct Stereo path"
        }
        return nil
    }

    // MARK: - Reading

    /// The setting to show in the editor. A device with nothing stored gets
    /// 立体声, so the panel always has values to draw.
    func channelMatrixSettings(for deviceID: String) -> ChannelMatrixSettings {
        guard let uid = channelMatrixUID(forDeviceID: deviceID) else { return .stereo }
        return deviceChannelMatrices[uid]?.settings ?? .stereo
    }

    /// True when the user has picked something other than 立体声.
    func hasChannelMatrixSetting(for deviceID: String) -> Bool {
        guard let uid = channelMatrixUID(forDeviceID: deviceID) else { return false }
        return deviceChannelMatrices[uid]?.settings.hasUserSetting ?? false
    }

    /// Short summary for the row, so a collapsed panel still says what is on.
    func channelMatrixSummary(for deviceID: String) -> String? {
        guard hasChannelMatrixSetting(for: deviceID) else { return nil }
        return AppModel.channelMatrixSummary(of: channelMatrixSettings(for: deviceID))
    }

    /// Pure form, so the tests get the same string without a device lookup.
    static func channelMatrixSummary(of settings: ChannelMatrixSettings) -> String? {
        guard settings.hasUserSetting else { return nil }
        switch settings.preset {
        case .stereo:
            return nil
        case .left, .right, .mono:
            return channelMatrixPresetLabel(settings.preset)
        case .custom:
            // Four numbers would not fit the row, so the summary reports the
            // one thing a glance needs: that it is hand-tuned, and how loud
            // the loudest path is.
            let peak = settings.matrix.worstCaseGain
            return "自定义 · \(channelMatrixDecibelLabel(ChannelMatrixLimits.decibels(forAmplitude: peak))) 峰值"
        }
    }

    /// Whether this output's chain is currently hitting the matrix limiter.
    ///
    /// In aggregate mode the counter belongs to the single AUHAL on top of the
    /// aggregate, so every member device reports the same figure — the UI says
    /// "输出链" rather than claiming a per-speaker number we do not have.
    func channelMatrixIsClipping(for deviceID: String) -> Bool {
        guard let uid = channelMatrixUID(forDeviceID: deviceID) else { return false }
        return (channelMatrixClipCounts[uid] ?? 0) > 0
    }

    // MARK: - Labels

    static func channelMatrixPresetLabel(_ preset: ChannelMatrixPreset) -> String {
        switch preset {
        case .stereo: return "立体声"
        case .left: return "左"
        case .right: return "右"
        case .mono: return "单声道"
        case .custom: return "自定义"
        }
    }

    static func channelMatrixDecibelLabel(_ db: Double) -> String {
        guard db > ChannelMatrixLimits.silentDb else { return "−∞" }
        // U+2212 MINUS SIGN, matching the equalizer's and the delay row's.
        let sign = db > 0 ? "+" : (db < 0 ? "−" : "")
        return String(format: "%@%.1f dB", sign, abs(db))
    }

    // MARK: - Editing

    func setChannelMatrixPreset(_ preset: ChannelMatrixPreset, for deviceID: String) {
        updateChannelMatrix(for: deviceID) { settings in
            if preset == .custom {
                // Seed the four sliders from whatever the user was hearing, so
                // opening the custom editor is a continuation rather than a
                // jump to silence.
                settings = .custom(seededFrom: settings.preset)
            } else {
                settings.preset = preset
            }
        }
    }

    func setChannelMatrixCoefficient(
        _ db: Double,
        path: ChannelMatrixPath,
        for deviceID: String
    ) {
        updateChannelMatrix(for: deviceID) { settings in
            // Touching a coefficient means the user is hand-tuning; the preset
            // follows rather than fighting them.
            if settings.preset != .custom { settings = .custom(seededFrom: settings.preset) }
            let snapped = ChannelMatrixLimits.snapToStep(ChannelMatrixLimits.clampDb(db))
            switch path {
            case .leftToLeft: settings.leftToLeftDb = snapped
            case .rightToLeft: settings.rightToLeftDb = snapped
            case .leftToRight: settings.leftToRightDb = snapped
            case .rightToRight: settings.rightToRightDb = snapped
            }
        }
    }

    func resetChannelMatrix(for deviceID: String) {
        updateChannelMatrix(for: deviceID) { $0 = .stereo }
    }

    /// The single mutation path: resolve the UID, apply the edit, normalise,
    /// store or delete, persist, and queue the debounced push.
    private func updateChannelMatrix(
        for deviceID: String,
        _ transform: (inout ChannelMatrixSettings) -> Void
    ) {
        guard let uid = channelMatrixUID(forDeviceID: deviceID) else {
            // The UI never offers the control on such a row; this is the
            // backstop, and it says so rather than failing silently.
            SyncCastLog.log("channel matrix: ignoring edit for un-keyable device \(deviceID)")
            return
        }
        var settings = deviceChannelMatrices[uid]?.settings ?? .stereo
        transform(&settings)
        let normalized = DeviceChannelMatrixStore.normalize(settings)
        let name = devices.first { $0.id == deviceID }?.name

        if normalized.hasUserSetting {
            deviceChannelMatrices[uid] = DeviceChannelMatrixProfile(
                uid: uid, displayName: name, settings: normalized
            )
        } else if deviceChannelMatrices.removeValue(forKey: uid) == nil {
            // Nothing stored and nothing to store: the edit was a no-op (e.g.
            // 立体声 on an untouched row). Skip the write and the push.
            return
        }
        DeviceChannelMatrixStore.save(deviceChannelMatrices)
        scheduleChannelMatrixCommit()
    }

    // MARK: - Pushing to the Router

    /// Debounced full-map push. Cancels any push still waiting, so a drag
    /// collapses to one.
    func scheduleChannelMatrixCommit() {
        channelMatrixCommitTask?.cancel()
        channelMatrixCommitTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: AppModel.channelMatrixCommitDebounceNanos)
            guard !Task.isCancelled, let self else { return }
            await self.pushDeviceChannelMatrices()
        }
    }

    /// Push the whole UID → matrix map. Whole-map, for the same reason the
    /// other two are: "the user reset this device" and "the user changed it"
    /// then travel the same path.
    func pushDeviceChannelMatrices() async {
        let map = deviceChannelMatrices.mapValues(\.settings)
        await router.setChannelMatrices(map)
    }

    func refreshChannelMatrixClipCounts() async {
        guard !deviceChannelMatrices.isEmpty, streamingState == .running else {
            if !channelMatrixClipCounts.isEmpty { channelMatrixClipCounts = [:] }
            return
        }
        let counts = await router.channelMatrixClipCounts()
        if counts != channelMatrixClipCounts { channelMatrixClipCounts = counts }
    }
}

/// Which cell of the 2×2 matrix an editor control is bound to.
enum ChannelMatrixPath: String, CaseIterable, Sendable {
    case leftToLeft
    case rightToLeft
    case leftToRight
    case rightToRight

    var label: String {
        switch self {
        case .leftToLeft: return "L → 左"
        case .rightToLeft: return "R → 左"
        case .leftToRight: return "L → 右"
        case .rightToRight: return "R → 右"
        }
    }

    func decibels(in settings: ChannelMatrixSettings) -> Double {
        switch self {
        case .leftToLeft: return settings.leftToLeftDb
        case .rightToLeft: return settings.rightToLeftDb
        case .leftToRight: return settings.leftToRightDb
        case .rightToRight: return settings.rightToRightDb
        }
    }
}
