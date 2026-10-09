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
//   3. When the panel answers again, the display goes back to `.ddc`. Its
//      software attenuation is HELD until the panel acknowledges the first
//      write (`sinkDDCIntentLanded`). Dropping to unity earlier would play at
//      the panel's old level for one I2C round trip, and after a long
//      fallback that level can be far louder than the current system volume.
//   4. A hand-back whose write is never acknowledged returns to software gain
//      after `SinkDDCRecoveryPolicy.firstWriteTimeoutSeconds`, so a held
//      attenuation cannot outlive the attempt.

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
        guard !stuck.isEmpty || !sinkDDCAwaitingFirstWrite.isEmpty else { return }
        if !stuck.isEmpty {
            RouterLog.write(
                "[Router] system sink: DDC is not carrying \(Self.shortUIDs(stuck)); software gain holds the level (it cannot go above the panel's own) — re-probing in the background\n"
            )
        }
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
        sinkDDCAwaitingFirstWrite.removeAll()
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
            // While a hand-back is pending the loop only has to outlast its
            // timeout, so it ticks at that pace instead of the probe backoff.
            let delay = sinkDDCAwaitingFirstWrite.isEmpty
                ? SinkDDCRecoveryPolicy.delaySeconds(attempt: attempt)
                : SinkDDCRecoveryPolicy.firstWriteTimeoutSeconds
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, sinkDDCRecoveryGeneration == generation,
                  systemSinkPathIsLive
            else {
                return
            }
            expireStaleSinkDDCHandBacks()
            let stuck = sinkDDCRecoveryCandidates()
            if stuck.isEmpty {
                if sinkDDCAwaitingFirstWrite.isEmpty { return }
                continue
            }
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

    /// A hand-back whose first write was never acknowledged goes back to
    /// software gain; the loop will try the panel again later.
    private func expireStaleSinkDDCHandBacks() {
        let now = ContinuousClock.now
        let timeout = Duration.milliseconds(
            Int(SinkDDCRecoveryPolicy.firstWriteTimeoutSeconds * 1000)
        )
        let expired = sinkDDCAwaitingFirstWrite
            .filter { now - $0.value >= timeout }
            .map(\.key)
        guard !expired.isEmpty else { return }
        for uid in expired {
            sinkDDCAwaitingFirstWrite.removeValue(forKey: uid)
            sinkVolumeBackends[uid] = .softwareGain
        }
        RouterLog.write(
            "[Router] system sink: the panel never acknowledged the hand-back write for \(Self.shortUIDs(expired)); staying on software gain\n"
        )
        applySystemSinkVolumes()
    }

    /// The DDC controller demoted a panel that was carrying a sink output.
    func sinkDDCDemoted(uid: String) {
        guard systemSinkPathIsLive, sinkVolumeBackends[uid] == .ddc else { return }
        sinkDDCAwaitingFirstWrite.removeValue(forKey: uid)
        sinkVolumeBackends[uid] = .softwareGain
        applySystemSinkVolumes()
    }

    /// A panel acknowledged a write. Releases the held attenuation of a
    /// hand-back; the re-apply this triggers writes the panel once more (the
    /// same level, harmless), and that second acknowledgement finds nothing
    /// waiting, so it stops there.
    func sinkDDCIntentLanded(uid: String) {
        guard sinkDDCAwaitingFirstWrite.removeValue(forKey: uid) != nil,
              systemSinkPathIsLive
        else {
            return
        }
        applySystemSinkVolumes()
    }

    private static func shortUIDs(_ uids: [String]) -> String {
        uids.map { String($0.prefix(20)) }.sorted().joined(separator: ",")
    }
}
