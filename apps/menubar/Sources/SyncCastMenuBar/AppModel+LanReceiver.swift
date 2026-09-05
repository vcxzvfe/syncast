import Foundation
import SyncCastDiscovery
import SyncCastRouter

/// LAN receiver legs: which rows exist, what they need before they can play,
/// and what the link is doing right now.
///
/// The receiver is an output, not an AirPlay target: it is selectable in local
/// Stereo only, it never participates in whole-home, and its shared token is
/// its own mechanism with nothing to do with AirPlay pairing.
@MainActor
extension AppModel {

    // MARK: - The row set

    /// Receivers to show in the popover's LAN section.
    var lanReceiverDevices: [Device] {
        devices.filter {
            $0.transport == .lanReceiver && isSelectableInMode($0, mode: mode)
        }
    }

    /// Whether the current path can drive a receiver at all.
    ///
    /// Direct Stereo has no capture ring — the HAL renders straight into a
    /// public aggregate and this process never sees the samples — so there is
    /// nothing to packetise. The row says so rather than offering a toggle
    /// that would do nothing.
    var lanReceiversAreSupportedOnCurrentPath: Bool {
        mode == .stereo && AppModel.selectedStereoOutputPath != .direct
    }

    /// One line explaining why receivers cannot be used right now, or nil when
    /// they can.
    func lanReceiverUnsupportedHint() -> String? {
        guard !lanReceiverDevices.isEmpty else { return nil }
        if mode == .wholeHome {
            return "LAN 接收端只在「立体声」模式可用 · LAN receivers work in Stereo mode only"
        }
        if AppModel.selectedStereoOutputPath == .direct {
            return "LAN 接收端需要采集环形缓冲；Direct Stereo 路径没有"
                + " · needs the capture ring, which the Direct Stereo path does not have"
        }
        return nil
    }

    /// The UID a receiver's token, target and render settings are stored
    /// under.
    func lanReceiverUID(forDeviceID deviceID: String) -> String? {
        guard let device = devices.first(where: { $0.id == deviceID }),
              device.transport == .lanReceiver
        else { return nil }
        return Device.lanReceiverUID(serviceName: device.lanServiceName)
    }

    // MARK: - Token

    func hasLanToken(for deviceID: String) -> Bool {
        guard let uid = lanReceiverUID(forDeviceID: deviceID) else { return false }
        return lanReceiverTokens[uid] != nil
    }

    /// The 8-hex hint the receiver advertised, for the "which token is this"
    /// line next to the entry field.
    func lanTokenHint(for deviceID: String) -> String? {
        devices.first(where: { $0.id == deviceID })?.lanTokenHint
    }

    /// Whether the stored token's own prefix matches what the receiver
    /// advertises. `nil` when either side is missing — an unknown answer is not
    /// a wrong one, and a receiver that publishes no hint is still usable.
    func lanTokenMatchesHint(for deviceID: String) -> Bool? {
        guard let uid = lanReceiverUID(forDeviceID: deviceID),
              let token = lanReceiverTokens[uid],
              let hint = lanTokenHint(for: deviceID)
        else { return nil }
        return LanReceiverTokenStore.hint(for: token) == hint
    }

    /// Store a token and re-push. An empty string clears it, which is how a
    /// user who typed the wrong one starts over.
    func setLanToken(_ raw: String, for deviceID: String) {
        guard let uid = lanReceiverUID(forDeviceID: deviceID) else {
            SyncCastLog.log("lan token: ignoring token for un-keyable device \(deviceID)")
            return
        }
        if let clean = LanReceiverTokenStore.sanitize(raw) {
            guard LanReceiverTokenStore.save(clean, forUID: uid) else {
                lanTokenSaveError = "无法保存到钥匙串 · could not write to the keychain"
                return
            }
            lanReceiverTokens[uid] = clean
        } else {
            LanReceiverTokenStore.remove(forUID: uid)
            lanReceiverTokens.removeValue(forKey: uid)
        }
        lanTokenSaveError = nil
        // The token is never logged, here or anywhere else.
        SyncCastLog.log("lan token: stored for \(uid)")
        Task { await pushLanReceiverConfiguration() }
        reconcileEngine()
    }

    /// Open the token window for one receiver, creating it on first use.
    ///
    /// The window is created here rather than at launch because most people
    /// will never own a receiver, and an `NSWindow` nobody opens is waste.
    func presentLanTokenWindow(for deviceID: String) {
        lanTokenEditorDeviceID = deviceID
        lanTokenSaveError = nil
        let controller = lanTokenWindowController ?? LanTokenWindowController(model: self)
        lanTokenWindowController = controller
        controller.present()
    }

    // MARK: - Target latency

    func lanTargetMs(for deviceID: String) -> Int {
        guard let uid = lanReceiverUID(forDeviceID: deviceID) else {
            return LanReceiverTargetStore.defaultTargetMs
        }
        return lanReceiverTargets[uid] ?? LanReceiverTargetStore.defaultTargetMs
    }

    func setLanTargetMs(_ ms: Int, for deviceID: String, persist: Bool) {
        guard let uid = lanReceiverUID(forDeviceID: deviceID) else { return }
        let clamped = LanReceiverTargetStore.clamp(ms)
        if clamped == LanReceiverTargetStore.defaultTargetMs {
            lanReceiverTargets.removeValue(forKey: uid)
        } else {
            lanReceiverTargets[uid] = clamped
        }
        guard persist else { return }
        LanReceiverTargetStore.save(lanReceiverTargets)
        Task { await pushLanReceiverConfiguration() }
    }

    // MARK: - Link status

    func lanStatus(for deviceID: String) -> LanReceiverStatus? {
        lanReceiverStatuses[deviceID]
    }

    /// The one-line link readout: RTT, offset, buffer and the three fault
    /// counters. nil while the link has said nothing yet.
    func lanLinkSummary(for deviceID: String) -> String? {
        guard let status = lanStatus(for: deviceID) else { return nil }
        let link = status.link
        guard link.isConnected || link.lastError != nil else { return nil }
        if let error = link.lastError, !link.isAudioReady {
            return error
        }
        var parts: [String] = []
        if let rtt = link.roundTripMs {
            parts.append(String(format: "RTT %.1f ms", rtt))
        }
        if let offset = link.offsetMs {
            parts.append(String(format: "偏移 %.0f ms", offset))
        }
        if let stats = link.stats {
            parts.append(String(format: "缓冲 %.0f ms", stats.bufferMs))
            parts.append("迟到 \(stats.late)")
            parts.append("丢包 \(stats.lost)")
            parts.append("欠载 \(stats.underrun)")
        } else if let buffer = link.receiverBufferMs {
            parts.append("缓冲 \(buffer) ms")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Whether the receiver is carrying the master level in its own hardware
    /// volume, as it reported in `hello_ack`.
    func lanHardwareVolumeNote(for deviceID: String) -> String? {
        guard let status = lanStatus(for: deviceID),
              let hardware = status.link.hasHardwareVolume
        else { return nil }
        return hardware
            ? "系统音量走接收端硬件音量 · system volume drives the receiver's own volume control"
            : "接收端无硬件音量，使用软件增益 · receiver has no hardware volume, using software gain"
    }

    /// End-to-end lag while a receiver is live, stated honestly.
    var lanTotalLagHint: String? {
        guard let lag = lanTotalLagMs else { return nil }
        return String(
            format: "全部输出对齐到约 %.0f ms 音画延迟（不含采集级）· all outputs aligned to ~%.0f ms",
            lag, lag
        )
    }

    // MARK: - Pushing to the Router

    /// Push the token and target maps. Called on launch, after an edit, and
    /// from the engine reconcile.
    func pushLanReceiverConfiguration() async {
        await router.setLanReceiverTokens(lanReceiverTokens)
        await router.setLanReceiverTargets(lanReceiverTargets)
    }

    /// Sample the live link state. Runs on the same 1 Hz poll as the
    /// connection states.
    func refreshLanReceiverStatuses() async {
        guard streamingState == .running, lanReceiversAreSupportedOnCurrentPath else {
            if !lanReceiverStatuses.isEmpty { lanReceiverStatuses = [:] }
            if lanTotalLagMs != nil { lanTotalLagMs = nil }
            return
        }
        let statuses = await router.lanReceiverStatuses()
        if statuses != lanReceiverStatuses { lanReceiverStatuses = statuses }
        let lag = await router.lanTotalLagMs()
        if lag != lanTotalLagMs { lanTotalLagMs = lag }
    }
}
