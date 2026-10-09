import Foundation

// DDC self-healing on the system-sink path.
//
// # The failure this exists for
//
// A display's speaker level rides on DDC/CI VCP 0x62. When the panel stops
// answering (the DCPAVServiceProxy handle goes stale across display sleep or
// replug, or the panel is not ready yet in the first seconds after it
// reappears), the sink path falls back to software gain for that display.
// Before this file, that fallback was permanent for the rest of the session:
// the cached `.softwareGain` verdict was never revisited, so nothing ever
// wrote VCP 0x62 again.
//
// Software gain can only attenuate below the panel's own level, and the panel
// stays wherever it was when DDC was lost. Turning the system volume down
// still works, but turning it back up stops at that frozen panel level.
// Measured on real hardware: the system volume and the built-in speakers at
// 100 % while the panel read back 90, and the display spent roughly half of
// its sink-path time over three weeks on software gain, often from the first
// seconds after it reappeared until the end of the session.
//
// # What happens now
//
//   1. Losing DDC moves the display onto software gain at once
//      (`sinkDDCDemoted`), not on the next volume change, because the write
//      that failed never reached the panel.
//   2. While any display that DDC could carry is on software gain, a
//      background loop re-probes it on a backoff (`SinkDDCRecoveryPolicy`).
//   3. When the panel answers again, the display goes back to `.ddc`, but
//      keeps being attenuated in software, as during the fallback, until the
//      panel acknowledges the CURRENT volume/mute intent
//      (`sinkDDCIntentLanded`). Dropping to unity earlier would play at the
//      panel's old level for one I2C round trip, and after a long fallback
//      that level can be far louder than the current system volume. The
//      software gain is recomputed on every apply during the wait, so a mute
//      or a lower volume still lands at once, and an acknowledgement of an
//      intent the user has since changed releases nothing.
//   4. A hand-back the panel does not acknowledge within
//      `SinkDDCRecoveryPolicy.firstWriteTimeoutSeconds` returns to software
//      gain. Each hand-back carries its own deadline timer, independent of the
//      re-probe loop's backoff.

/// Pure timing for the sink path's DDC re-probe loop (unit-checkable).
public enum SinkDDCRecoveryPolicy {
    /// Fast early retries cover the panel that simply was not ready yet when
    /// it reappeared; after that, one probe a minute while the fallback lasts.
    /// A probe is one display enumeration plus one or two VCP reads.
    public static let backoffSeconds: [Double] = [1, 2, 4, 8, 15, 30]
    public static let steadySeconds: Double = 60

    /// How long a hand-back may wait for its first panel acknowledgement.
    public static let firstWriteTimeoutSeconds: Double = 3

    public static func delaySeconds(attempt: Int) -> Double {
        guard attempt >= 0, attempt < backoffSeconds.count else {
            return steadySeconds
        }
        return backoffSeconds[attempt]
    }
}

/// One display's pending software-gain → DDC hand-back.
struct SinkDDCHandBack {
    struct Target: Equatable {
        let volume: Float
        let muted: Bool
    }
    let started: ContinuousClock.Instant
    /// The intent most recently sent to the panel; only its acknowledgement
    /// releases the software gain.
    var target: Target?
}

extension Router {

    /// Sink outputs on software gain that a DDC panel could carry.
    func sinkDDCRecoveryCandidates() -> [String] {
        sinkOutputUIDs().filter { uid in
            guard sinkVolumeBackends[uid] == .softwareGain else { return false }
            if let cached = sinkDDCCandidateCache[uid] { return cached }
            let candidate = DDCDisplayVolumeController.isDDCCandidate(uid: uid)
            sinkDDCCandidateCache[uid] = candidate
            return candidate
        }
    }

    /// Start the re-probe loop when a display is stuck on software gain or a
    /// hand-back is still waiting for its first write. Cheap when neither
    /// holds, so it runs after every apply.
    func scheduleSinkDDCRecoveryIfNeeded() {
        guard sinkDDCRecoveryTask == nil, systemSinkPathIsLive else { return }
        let stuck = sinkDDCRecoveryCandidates()
        guard !stuck.isEmpty else { return }
        RouterLog.write(
            "[Router] system sink: DDC is not carrying \(Self.shortUIDs(stuck)); software gain holds the level (it cannot go above the panel's own) — re-probing in the background\n"
        )
        sinkDDCRecoveryGeneration += 1
        let generation = sinkDDCRecoveryGeneration
        sinkDDCRecoveryTask = Task { [weak self] in
            await self?.runSinkDDCRecovery(generation: generation)
        }
    }

    func resetSinkDDCRecovery() {
        sinkDDCRecoveryTask?.cancel()
        sinkDDCRecoveryTask = nil
        sinkDDCRecoveryGeneration += 1
        sinkAppliedBackends.removeAll()
        sinkDDCHandBacks.removeAll()
        sinkDDCCandidateCache.removeAll()
    }

    private func runSinkDDCRecovery(generation: Int) async {
        defer {
            if sinkDDCRecoveryGeneration == generation {
                sinkDDCRecoveryTask = nil
            }
        }
        var attempt = 0
        while !Task.isCancelled {
            let delay = SinkDDCRecoveryPolicy.delaySeconds(attempt: attempt)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, sinkDDCRecoveryGeneration == generation,
                  systemSinkPathIsLive
            else {
                return
            }
            let stuck = sinkDDCRecoveryCandidates()
            if stuck.isEmpty { return }
            attempt += 1
            let ddc = DDCDisplayVolumeController.shared
            ddc.refreshCapabilities(uids: stuck)
            await ddc.waitForSettledCapabilities(uids: stuck)
            guard !Task.isCancelled, sinkDDCRecoveryGeneration == generation,
                  systemSinkPathIsLive
            else {
                return
            }
            var recovered: [String] = []
            for uid in stuck where sinkVolumeBackends[uid] == .softwareGain {
                guard classifySinkVolumeBackend(uid: uid) == .ddc else { continue }
                sinkVolumeBackends[uid] = .ddc
                recovered.append(uid)
            }
            guard !recovered.isEmpty else { continue }
            RouterLog.write(
                "[Router] system sink: DDC answers again for \(Self.shortUIDs(recovered)) after \(attempt) re-probe(s); handing the level back to the panel\n"
            )
            applySystemSinkVolumes()
        }
    }

    /// Start a hand-back and arm its own deadline.
    func beginSinkDDCHandBack(uid: String) {
        let handBack = SinkDDCHandBack(started: ContinuousClock.now, target: nil)
        sinkDDCHandBacks[uid] = handBack
        let started = handBack.started
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(
                SinkDDCRecoveryPolicy.firstWriteTimeoutSeconds * 1_000_000_000
            ))
            await self?.expireSinkDDCHandBack(uid: uid, started: started)
        }
    }

    /// A hand-back the panel never acknowledged goes back to software gain;
    /// the re-probe loop will try the panel again later. `started` ties the
    /// timer to the hand-back that armed it, so a later hand-back of the same
    /// display is never expired early.
    private func expireSinkDDCHandBack(uid: String, started: ContinuousClock.Instant) {
        guard sinkDDCHandBacks[uid]?.started == started else { return }
        sinkDDCHandBacks.removeValue(forKey: uid)
        guard systemSinkPathIsLive else { return }
        sinkVolumeBackends[uid] = .softwareGain
        let expired = [uid]
        RouterLog.write(
            "[Router] system sink: the panel never acknowledged the hand-back write for \(Self.shortUIDs(expired)); staying on software gain\n"
        )
        applySystemSinkVolumes()
    }

    /// The DDC controller demoted a panel that was carrying a sink output.
    func sinkDDCDemoted(uid: String) {
        guard systemSinkPathIsLive, sinkVolumeBackends[uid] == .ddc else { return }
        sinkDDCHandBacks.removeValue(forKey: uid)
        sinkVolumeBackends[uid] = .softwareGain
        applySystemSinkVolumes()
    }

    /// A panel acknowledged a write. Releases a hand-back's software gain
    /// only when what the panel now holds is the intent most recently sent,
    /// matched by enqueue sequence, not by value; an acknowledgement of an
    /// older intent (the user moved the volume or muted while it was in
    /// flight) releases nothing, and the newer write's own acknowledgement
    /// will. The re-apply this triggers writes the panel
    /// once more (the same level, harmless); that acknowledgement finds no
    /// hand-back, so it stops there.
    func sinkDDCIntentLanded(uid: String) {
        guard systemSinkPathIsLive,
              let handBack = sinkDDCHandBacks[uid],
              let target = handBack.target,
              let applied = DDCDisplayVolumeController.shared.appliedIntent(uid: uid),
              applied.sequence == DDCDisplayVolumeController.shared
                  .latestEnqueuedSequence(uid: uid),
              SinkDDCHandBack.Target(volume: applied.volume, muted: applied.muted) == target
        else {
            return
        }
        sinkDDCHandBacks.removeValue(forKey: uid)
        applySystemSinkVolumes()
    }

    private static func shortUIDs(_ uids: [String]) -> String {
        uids.map { String($0.prefix(20)) }.sorted().joined(separator: ",")
    }
}
