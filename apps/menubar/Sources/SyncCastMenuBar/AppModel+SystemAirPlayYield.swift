import Foundation
import SyncCastRouter

/// Following the sidecar out of whole-home when macOS's own AirPlay sender
/// takes the PTP ports.
///
/// The sidecar has already killed OwnTone by the time this runs (it has to
/// free UDP 319/320 within ~600 ms of macOS activating the endpoint, far
/// faster than this once-a-second poll). Whole-home cannot run without
/// OwnTone, so all that is left here is to bring the UI and the engine onto
/// the Stereo path, which keeps the local speakers and LAN receivers playing,
/// and to say why.
extension AppModel {
    /// How long the hand-over line stays in the status strip.
    static let systemAirPlayNoticeSeconds: TimeInterval = 120

    /// How long a hand-over waits before the mode switch. Picking an AirPlay
    /// speaker in Control Center moves the system default output AND
    /// activates the endpoint; the activation reaches us within milliseconds,
    /// the default-output change only through `pollSystemSinkStatus` on a
    /// later tick. Switching to Stereo before that poll has seen it would
    /// start the Stereo sink and take the output back from the speaker the
    /// user just picked. OwnTone is already gone, so waiting costs nothing
    /// the user can hear beyond what the hand-over itself costs.
    static let systemAirPlayYieldSettleSeconds: TimeInterval = 1.5

    func refreshSystemAirPlayYield(now: Date = Date()) async {
        expireSystemAirPlayNoticeIfDue(now: now)
        guard let latest = await router.latestSystemAirPlayYield(),
              latest.sequence > lastHandledSystemAirPlayYieldSequence else { return }
        guard let firstSeen = systemAirPlayYieldFirstSeen,
              firstSeen.sequence == latest.sequence else {
            systemAirPlayYieldFirstSeen = (latest.sequence, now)
            return
        }
        guard now.timeIntervalSince(firstSeen.at) >= Self.systemAirPlayYieldSettleSeconds else {
            return
        }
        // `setMode` drops calls while a transition is in flight. Leave the
        // event unhandled and retry on the next tick rather than lose it:
        // staying in whole-home would respawn OwnTone and take the ports
        // back from Music on the next reconcile.
        if mode == .wholeHome, isModeTransitioning { return }
        lastHandledSystemAirPlayYieldSequence = latest.sequence
        systemAirPlayYieldFirstSeen = nil
        handleSystemAirPlayYield(latest)
    }

    func handleSystemAirPlayYield(_ event: SystemAirPlayYield) {
        let leavingWholeHome = mode == .wholeHome
        SyncCastLog.log(
            "system AirPlay hand-over #\(event.sequence): trigger=\(event.trigger.rawValue) "
                + "endpoint=\(event.endpoint ?? "?") sidecarMode=\(event.previousMode ?? "?") "
                + "uiMode=\(mode.rawValue) outputMovedAway=\(systemSinkPausedByDisplacement)"
        )
        systemAirPlayNotice = Self.systemAirPlayNoticeText(
            for: event, leftWholeHome: leavingWholeHome
        )
        systemAirPlayNoticeExpiresAt = Date().addingTimeInterval(Self.systemAirPlayNoticeSeconds)
        guard leavingWholeHome else { return }
        systemAirPlayYieldApplying = true
        defer { systemAirPlayYieldApplying = false }
        setMode(.stereo)
    }

    nonisolated static func systemAirPlayNoticeText(
        for event: SystemAirPlayYield, leftWholeHome: Bool
    ) -> String {
        let zhTarget = event.endpoint.map { "「\($0)」" } ?? "音箱"
        let enTarget = event.endpoint.map { "“\($0)”" } ?? "a speaker"
        var zh = "系统开始隔空播放到\(zhTarget)，"
        var en = "macOS started AirPlay to \(enTarget)"
        if leftWholeHome {
            zh += "SyncCast 已退出全屋、切到立体声"
            en += "; SyncCast switched to Stereo"
        } else {
            zh += "SyncCast 已让出"
            en += "; SyncCast stepped aside"
        }
        if event.trigger == .ptpConflict {
            // Late hand-over: that one session never re-adds its clock peer.
            zh += "；若仍无声，请重新选一次该音箱"
            en += ". If silent, pick the speaker again"
        }
        return "\(zh) · \(en)"
    }

    func clearSystemAirPlayNotice() {
        systemAirPlayNotice = nil
        systemAirPlayNoticeExpiresAt = nil
    }

    func expireSystemAirPlayNoticeIfDue(now: Date = Date()) {
        if let until = systemAirPlayNoticeExpiresAt, now >= until {
            clearSystemAirPlayNotice()
        }
    }
}
