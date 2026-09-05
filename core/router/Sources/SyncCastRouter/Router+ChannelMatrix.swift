import Foundation

/// Per-device channel assignment ("声道分配").
///
/// A 2×2 gain matrix per physical output, keyed by CoreAudio UID and applied
/// inside the same render callbacks as the equalizer and the stereo imager,
/// one stage later on the signal (see `ChannelMatrixBank`). The Router keeps
/// the whole map rather than pushing one-shot edits so that a device which is
/// re-plugged, re-enabled, or lands in a rebuilt aggregate picks its
/// assignment straight back up: `applyChannelMatrices()` runs on every driver
/// reconcile and every replan, and is a no-op when nothing moved.
///
/// SCOPE — every leg whose samples this process renders, which is one leg WIDER
/// than the stereo imager's:
///
///   * Local Stereo on the system-sink / ScreenCaptureKit legs
///     (`localOutputs`), individual or aggregate — one pair per physical
///     device.
///   * The LAN receiver legs (`lanReceiverOutputs`), whose producer applies the
///     matrix before packetising, because the receiver plays what it is sent.
///   * Whole-home local outputs (`localBridges`) — same UID key, so a speaker
///     assigned to the left channel in Stereo stays assigned in whole-home.
///
/// It does NOT cover the whole-home AirPlay leg: OwnTone's fan-out sends ONE
/// stream to every receiver, so a matrix applied upstream would put the same
/// channel assignment on the whole house. Nor Direct Stereo, where the HAL
/// renders straight into the public aggregate and we never see the samples.
extension Router {

    /// Replace the whole UID → matrix map. The menubar owns the persisted
    /// store and pushes it in full, which keeps "the user reset a device to
    /// 立体声" and "the user changed it" on the same path.
    public func setChannelMatrices(_ settingsByUID: [String: ChannelMatrixSettings]) {
        var sanitized: [String: ChannelMatrixSettings] = [:]
        for (uid, settings) in settingsByUID where !uid.isEmpty {
            let clean = settings.sanitized()
            // Storing 立体声 would make `applyChannelMatrices` push identical
            // no-ops forever; absent already means 立体声.
            guard clean.hasUserSetting else { continue }
            sanitized[uid] = clean
        }
        guard sanitized != channelMatrixSettingsByUID else { return }
        channelMatrixSettingsByUID = sanitized
        applyChannelMatrices()
    }

    /// Set (or clear, with `.stereo`) one device's assignment.
    public func setChannelMatrix(uid: String, settings: ChannelMatrixSettings) {
        guard !uid.isEmpty else { return }
        var next = channelMatrixSettingsByUID
        let clean = settings.sanitized()
        if clean.hasUserSetting {
            next[uid] = clean
        } else {
            next.removeValue(forKey: uid)
        }
        setChannelMatrices(next)
    }

    /// The assignments the Router currently holds. Mostly for tests and
    /// reports.
    public func channelMatrices() -> [String: ChannelMatrixSettings] {
        channelMatrixSettingsByUID
    }

    /// CoreAudio UIDs (plus LAN receiver UIDs) whose samples this process
    /// renders itself, and which can therefore be re-assigned. Empty on Direct
    /// Stereo — the same question the UI asks before offering the control.
    public func channelMatrixableOutputUIDs() -> [String] {
        if mode == .wholeHome {
            return localBridges.values.map(\.deviceUID)
        }
        return localPairTargets().map(\.uid)
    }

    /// Per-device limiter counts, keyed by UID. Non-zero means that device's
    /// matrix is summing or boosting the signal past full scale.
    public func channelMatrixClipCounts() -> [String: Int64] {
        var result: [String: Int64] = [:]
        for target in localPairTargets() {
            result[target.uid] = target.output.channelMatrixClipCount
        }
        for bridge in localBridges.values {
            result[bridge.deviceUID] = bridge.channelMatrixClipCount
        }
        return result
    }

    /// Push the stored assignments onto the live outputs. Idempotent — a pair
    /// already holding a matrix takes `LocalOutput.setChannelMatrix`'s no-op
    /// path — so this rides along with every reconcile and replan rather than
    /// needing its own trigger.
    func applyChannelMatrices() {
        for target in localPairTargets() {
            target.output.setChannelMatrix(
                pair: target.pair,
                settings: channelMatrixSettingsByUID[target.uid] ?? .stereo
            )
        }
        for bridge in localBridges.values {
            bridge.setChannelMatrix(channelMatrixSettingsByUID[bridge.deviceUID] ?? .stereo)
        }
    }
}
