import Foundation
import CoreAudio
import os

// DDC/CI volume backend for Direct Stereo.
//
// Direct Stereo has no render callback (apps render straight into the
// public aggregate), so software gain is impossible and per-device volume
// must reach real hardware. HDMI/DisplayPort monitors (e.g. ASUS ExternalDisplay)
// expose no writable CoreAudio VolumeScalar — their speaker level lives in
// the panel's scaler, reachable only over the DDC/CI I2C channel
// (see DDCTransport.swift for the private-API notice).
//
// Fail-closed posture: every step — arm64/symbols, display matching,
// VCP read — must positively succeed before a UID is considered
// DDC-controllable. Anything else reports unsupported and the Router keeps
// today's behavior (rejection diagnostics, OSD-only volume).

/// Which backend can honor a Direct Stereo volume intent for one device.
/// Part of the Router public API contract consumed by the menubar app.
public enum DirectStereoVolumeBackend: String, Sendable {
    case coreAudioHardware
    case ddc
    case none
}

// MARK: - Pure readback/backend classification (unit-checkable)

/// Single backend classification shared by the Router's capability
/// snapshot AND its volume readback, so reads always follow the backend
/// that owns the device's WRITES.
///
/// Some HDMI/DP devices expose a CoreAudio VolumeScalar that is READABLE
/// but not settable — a stale mirror that never tracks the panel's real
/// speaker level. Classification therefore keys on write capability only:
/// returning that mirror for a `.ddc` device would feed the stale value
/// back into routing, and the next media key / slider step would re-apply
/// the wrong level.
public enum DirectStereoVolumeReadback {
    /// - Parameters:
    ///   - coreAudioVolumeSettable: verdict of the read-only settability
    ///     probe (`AggregateDevice.probeHardwareVolumeWritable`).
    ///   - coreAudioPreviouslyRejected: an actual CoreAudio level write
    ///     was refused earlier (the Router's rejection bookkeeping) — the
    ///     settability claim is distrusted from then on.
    ///   - ddcKnownSupported: a DDC probe positively established control.
    public static func backend(
        coreAudioVolumeSettable: Bool,
        coreAudioPreviouslyRejected: Bool,
        ddcKnownSupported: Bool
    ) -> DirectStereoVolumeBackend {
        if coreAudioVolumeSettable, !coreAudioPreviouslyRejected {
            return .coreAudioHardware
        }
        if ddcKnownSupported {
            return .ddc
        }
        return .none
    }
}

// MARK: - Pure 0...1 <-> VCP scale conversion (unit-checkable)

public enum DDCVolumeScale {
    /// Map a 0...1 scalar onto the display's 0...max VCP range,
    /// round-to-nearest. max == 0 (degenerate display report) maps to 0.
    public static func toVCPValue(normalized: Float, max: UInt16) -> UInt16 {
        guard max > 0, normalized.isFinite else { return 0 }
        let clamped = Swift.max(Float(0), Swift.min(Float(1), normalized))
        return UInt16((clamped * Float(max)).rounded())
    }

    /// Map a VCP current/max pair back to 0...1. nil when max == 0,
    /// so a nonsensical display report can't masquerade as "volume 0".
    public static func toNormalized(current: UInt16, max: UInt16) -> Float? {
        guard max > 0 else { return nil }
        return Swift.max(Float(0), Swift.min(Float(1), Float(current) / Float(max)))
    }
}

// MARK: - Pure two-layer volume cache decision (unit-checkable)

/// Two-layer volume cache for one DDC-controlled display.
///
/// `userVolume` is the clamped level the user asked for — it survives a
/// mute, so snapshot reads (`Router.readDirectStereoVolume`) and a later
/// unmute restore the user's level instead of the 0 an emulated mute wrote
/// to the panel. `outputLevel` is what is actually on VCP 0x62 right now
/// (0 while an emulated mute holds on displays without VCP 0x8D).
public struct DDCVolumeLevels: Equatable, Sendable {
    public let userVolume: Float
    public let outputLevel: Float

    public init(userVolume: Float, outputLevel: Float) {
        self.userVolume = userVolume
        self.outputLevel = outputLevel
    }

    /// Pure apply plan for one volume/mute intent. Displays with a native
    /// mute VCP keep 0x62 at the user level even while muted; displays
    /// without one get mute emulated as outputLevel = 0, but the user
    /// volume layer is preserved either way.
    public static func planned(
        volume: Float,
        muted: Bool,
        supportsMuteVCP: Bool
    ) -> DDCVolumeLevels {
        let clamped = Swift.max(Float(0), Swift.min(Float(1), volume))
        let output = (muted && !supportsMuteVCP) ? Float(0) : clamped
        return DDCVolumeLevels(userVolume: clamped, outputLevel: output)
    }
}

// MARK: - Pure display <-> audio-device matching decision (unit-checkable)

public enum DDCDisplayMatching {
    /// Decide which external DDC display (by index into
    /// `displayProductNames`) backs the CoreAudio output device named
    /// `audioDeviceName`. Conservative, fail closed:
    ///
    /// 1. Exact product-name match (case-insensitive, trimmed). Exactly
    ///    one display must match — duplicates are ambiguous -> nil.
    /// 2. Otherwise, only when there is exactly ONE external DDC display
    ///    AND the audio device's transport is HDMI/DisplayPort, assume
    ///    that display is the audio sink.
    /// 3. Anything else -> nil (unsupported).
    public static func matchIndex(
        audioDeviceName: String?,
        isHDMIOrDisplayPortTransport: Bool,
        displayProductNames: [String]
    ) -> Int? {
        if let audioDeviceName {
            let needle = normalized(audioDeviceName)
            if !needle.isEmpty {
                let hits = displayProductNames.indices.filter {
                    normalized(displayProductNames[$0]) == needle
                }
                if hits.count == 1 {
                    return hits[0]
                }
                if hits.count > 1 {
                    return nil
                }
            }
        }
        if displayProductNames.count == 1, isHDMIOrDisplayPortTransport {
            return 0
        }
        return nil
    }

    private static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

// MARK: - Controller

/// Process-wide DDC volume controller.
///
/// Threading model: DDC/CI I2C is slow (each transaction is 10s of ms with
/// sleeps and retries), so ALL IO runs on a private serial queue and never
/// inside the Router actor. Callers interact through non-blocking methods:
/// capability lookups read a lock-protected cache, and apply intents are
/// coalesced per UID (only the latest pending volume/mute survives while a
/// transaction is in flight — slider drags don't queue up a backlog).
///
/// @unchecked Sendable: all mutable state is guarded by `stateLock`; the
/// IOAVService channels are only used on `queue`.
public final class DDCDisplayVolumeController: @unchecked Sendable {
    public static let shared = DDCDisplayVolumeController()

    private struct Intent {
        let volume: Float
        let muted: Bool
    }

    private struct Binding {
        let channel: DDCI2CChannel
        let displayName: String
        let maxValue: UInt16
        let supportsMuteVCP: Bool
        /// Two-layer cache (user intent vs. actual 0x62 level) so an
        /// emulated mute can't clobber the user's volume — see
        /// `DDCVolumeLevels`.
        var levels: DDCVolumeLevels
    }

    private enum Capability {
        case probing
        case supported(Binding)
        case unsupported
    }

    /// Consecutive failed apply transactions before a UID is demoted to
    /// unsupported (display unplugged, scaler stopped responding, ...).
    /// Transient single-transaction I2C hiccups survive thanks to retries
    /// inside DDCI2CChannel plus this outer tolerance.
    private static let maxConsecutiveFailures = 3

    /// Cooldown between background self-heal kicks (supported-binding
    /// revalidation on explicit refresh, post-demotion auto re-probe on a
    /// rejected write) for one UID. Reconcile bursts and media-key
    /// autorepeat collapse to at most one I2C-touching kick per window,
    /// so self-heal can never become a probe storm.
    private static let selfHealCooldownSeconds: Double = 3.0

    private let queue = DispatchQueue(
        label: "io.syncast.ddc-volume",
        qos: .userInitiated
    )
    private let stateLock = OSAllocatedUnfairLock()
    private var capabilities: [String: Capability] = [:]
    private var pending: [String: Intent] = [:]
    private var drainingUIDs: Set<String> = []
    private var consecutiveFailures: [String: Int] = [:]
    private var completedWrites = 0
    private var failedWrites = 0
    private var loggedUnsupportedUIDs: Set<String> = []
    private var lastRevalidationKick: [String: DispatchTime] = [:]
    private var lastAutoReprobeKick: [String: DispatchTime] = [:]
    /// See `setOnPendingIntentDropped`. Guarded by `stateLock`; always
    /// invoked OUTSIDE the lock (on the DDC queue).
    private var onPendingIntentDropped: (@Sendable (String) -> Void)?

    public init() {}

    /// Observer for intents that were ACCEPTED by `enqueueApply` (probe
    /// still in flight, or binding later demoted) and then dropped when
    /// the UID's verdict landed on unsupported.
    ///
    /// Why this exists (Codex P2): the probing-state enqueue deliberately
    /// returns true — the first key press/slider drag on a fresh display
    /// must not misreport "unsupported" before the probe finishes. But
    /// that optimistic accept means the Router records the intent as
    /// carried; if the probe then concludes unsupported the queued intent
    /// vanishes with no rejection diagnostics — "UI moved, hardware
    /// didn't, nothing logged". This callback closes the gap: the Router
    /// registers a handler that retroactively books the rejection.
    ///
    /// Threading: fired on the DDC serial queue, never under `stateLock`.
    /// The handler must hop to its own isolation (the Router wraps the
    /// call in a `Task` into the actor, same pattern as
    /// `capture.onUnexpectedStop`).
    public func setOnPendingIntentDropped(
        _ handler: (@Sendable (String) -> Void)?
    ) {
        stateLock.withLock { onPendingIntentDropped = handler }
    }

    // MARK: Non-blocking API (safe to call from the Router actor)

    /// Kick capability probes for any UID not yet classified. Returns
    /// immediately; probe IO happens on the DDC queue. Call when Direct
    /// Stereo (re)starts so capability snapshots are warm before the
    /// first slider drag.
    public func probeCapabilities(uids: [String]) {
        kickProbes(uids: uids, includeUnsupported: false)
    }

    /// Like `probeCapabilities`, but also re-probes UIDs previously marked
    /// unsupported AND revalidates known-supported bindings. Display
    /// sleep/replug tears down the DCPAVServiceProxy node, so both a
    /// cached "unsupported" verdict (or a demotion after stale write
    /// failures) and a cached "supported" binding can go stale; the Router
    /// calls this on every Direct Stereo reconcile (user toggles, wake
    /// rebuilds) so DDC recovers without a process restart. Supported
    /// bindings are revalidated with one cheap VCP read — they keep their
    /// `.supported` verdict while the check is in flight, so the
    /// capability snapshot never flaps.
    public func refreshCapabilities(uids: [String]) {
        kickProbes(uids: uids, includeUnsupported: true)
    }

    private enum ProbeKick {
        case probe
        case revalidate
        case none
    }

    private func kickProbes(uids: [String], includeUnsupported: Bool) {
        guard DDCDisplayEnumerator.isSupported else { return }
        for uid in uids {
            let kick: ProbeKick = stateLock.withLock {
                switch capabilities[uid] {
                case nil:
                    break
                case .unsupported where includeUnsupported:
                    consecutiveFailures[uid] = 0
                case .supported where includeUnsupported:
                    // Display sleep/replug can kill the cached
                    // DCPAVServiceProxy handle behind a binding that still
                    // looks supported. Explicit refreshes (wake/reconcile)
                    // revalidate it instead of skipping, debounced by the
                    // self-heal cooldown so a reconcile burst costs at
                    // most one I2C read per UID.
                    guard passedCooldownLocked(&lastRevalidationKick, uid: uid)
                    else { return .none }
                    return .revalidate
                default:
                    return .none
                }
                capabilities[uid] = .probing
                return .probe
            }
            switch kick {
            case .probe:
                queue.async { [weak self] in self?.probe(uid: uid) }
            case .revalidate:
                queue.async { [weak self] in self?.revalidate(uid: uid) }
            case .none:
                break
            }
        }
    }

    /// Must be called inside `stateLock`. Fires at most once per
    /// `selfHealCooldownSeconds` per UID and records the kick time when
    /// it does.
    private func passedCooldownLocked(
        _ lastKick: inout [String: DispatchTime],
        uid: String
    ) -> Bool {
        let now = DispatchTime.now()
        if let last = lastKick[uid],
           now < last + Self.selfHealCooldownSeconds {
            return false
        }
        lastKick[uid] = now
        return true
    }

    /// True iff a probe positively established DDC control for this UID.
    public func isKnownSupported(uid: String) -> Bool {
        stateLock.withLock {
            if case .supported = capabilities[uid] { return true }
            return false
        }
    }

    /// True iff a probe (or repeated write failures) established that DDC
    /// cannot control this UID.
    public func isKnownUnsupported(uid: String) -> Bool {
        stateLock.withLock {
            if case .unsupported = capabilities[uid] { return true }
            return false
        }
    }

    /// Accept a volume/mute intent for async DDC application.
    ///
    /// Returns true when the intent was accepted: the UID is known
    /// DDC-controllable, or its probe is still pending (the intent applies
    /// as soon as the probe succeeds, and is dropped if it fails). Returns
    /// false — fail closed — once the UID is known unsupported, so the
    /// Router can record its rejection diagnostics exactly like before.
    @discardableResult
    public func enqueueApply(uid: String, volume: Float, muted: Bool) -> Bool {
        guard DDCDisplayEnumerator.isSupported else { return false }
        let intent = Intent(volume: volume, muted: muted)
        enum Action { case rejected, rejectedKickingReprobe, probe, drain, coalesced }
        let action: Action = stateLock.withLock {
            switch capabilities[uid] {
            case .unsupported:
                // Self-heal for media-key-only usage: a UID demoted after
                // stale-handle write failures (display sleep/replug) would
                // otherwise stay dead until a Direct Stereo reconcile runs
                // refreshCapabilities. Kick a cooldown-limited re-probe off
                // this rejected write so the NEXT intent (media keys
                // autorepeat within moments) lands on a recovered binding.
                // Write-triggered rather than timer-based: it cannot loop
                // unattended, and the cooldown caps it at one probe per
                // window even while a volume key is held down. The
                // triggering intent itself stays rejected — the fail-closed
                // contract (and the Router's rejection diagnostics) is
                // unchanged.
                guard passedCooldownLocked(&lastAutoReprobeKick, uid: uid)
                else { return .rejected }
                consecutiveFailures[uid] = 0
                capabilities[uid] = .probing
                return .rejectedKickingReprobe
            case .supported:
                pending[uid] = intent
                if drainingUIDs.contains(uid) { return .coalesced }
                drainingUIDs.insert(uid)
                return .drain
            case .probing:
                pending[uid] = intent
                return .coalesced
            case nil:
                pending[uid] = intent
                capabilities[uid] = .probing
                return .probe
            }
        }
        switch action {
        case .rejected:
            return false
        case .rejectedKickingReprobe:
            queue.async { [weak self] in self?.probe(uid: uid) }
            return false
        case .probe:
            queue.async { [weak self] in self?.probe(uid: uid) }
            return true
        case .drain:
            queue.async { [weak self] in self?.drain(uid: uid) }
            return true
        case .coalesced:
            return true
        }
    }

    /// Last known 0...1 USER volume for a DDC-controlled UID: the value
    /// read at probe time, updated after each applied write. nil when the
    /// UID is not DDC-controlled.
    ///
    /// This deliberately reports the user-intent layer, NOT the panel's
    /// actual 0x62 level: while an emulated mute holds (displays without
    /// VCP 0x8D), 0x62 is 0, and reporting that 0 here would let a snapshot
    /// write it back as route.volume — unmute would then "restore" silence.
    public func cachedNormalizedVolume(uid: String) -> Float? {
        stateLock.withLock {
            if case .supported(let binding) = capabilities[uid] {
                return binding.levels.userVolume
            }
            return nil
        }
    }

    // MARK: Bounded-wait API (safe to await from the Router actor)

    /// Upper bound for `waitForSettledCapabilities` so an actor caller can
    /// never hang on a wedged I2C transaction. A full probe (enumeration +
    /// up to two VCP reads with retries) lands well under this in practice.
    public static let settleTimeoutSeconds: Double = 2.0

    /// Wait — bounded by `timeoutSeconds` — until every UID in `uids` has
    /// a settled capability verdict (supported/unsupported, i.e. no longer
    /// probing). Returns immediately when nothing is in flight; on timeout
    /// it simply returns with the verdicts still unsettled, and callers
    /// keep their fail-closed "unknown = none" classification.
    ///
    /// Bridges the DDC serial queue with a checked continuation: a sentinel
    /// block behind the in-flight probe resumes the waiter as soon as the
    /// queue drains; a timeout fallback resumes it at the deadline if the
    /// queue is stuck. Holds no locks or actor state across the suspension.
    public func waitForSettledCapabilities(
        uids: [String],
        timeoutSeconds: Double = DDCDisplayVolumeController.settleTimeoutSeconds
    ) async {
        let deadline = DispatchTime.now() + timeoutSeconds
        while hasProbeInFlight(uids: uids), DispatchTime.now() < deadline {
            await waitForQueueDrain(deadline: deadline)
            // A probe marks itself .probing under the lock a beat before
            // its block lands on the queue; if the sentinel slipped into
            // that gap the verdict is still unsettled here — yield briefly
            // instead of spinning, then re-check until the deadline.
            if hasProbeInFlight(uids: uids) {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
    }

    private func hasProbeInFlight(uids: [String]) -> Bool {
        stateLock.withLock {
            uids.contains { uid in
                if case .probing = capabilities[uid] { return true }
                return false
            }
        }
    }

    /// Suspend until the DDC serial queue drains past a sentinel block or
    /// `deadline` passes, whichever comes first. The continuation is
    /// resumed exactly once (lock-guarded) no matter which side wins.
    private func waitForQueueDrain(deadline: DispatchTime) async {
        let resumed = OSAllocatedUnfairLock(initialState: false)
        await withCheckedContinuation { (
            continuation: CheckedContinuation<Void, Never>
        ) in
            let resumeOnce = {
                let shouldResume = resumed.withLock { state -> Bool in
                    if state { return false }
                    state = true
                    return true
                }
                if shouldResume { continuation.resume() }
            }
            queue.async { resumeOnce() }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: deadline
            ) { resumeOnce() }
        }
    }

    /// Compact suffix for Router.diagnosticCaptureReport(), e.g.
    /// " ddc=1 ddcWrites=12 ddcErr=0". Empty when DDC never engaged.
    public func diagnosticSuffix() -> String {
        stateLock.withLock {
            let supported = capabilities.values.filter {
                if case .supported = $0 { return true }
                return false
            }.count
            guard supported > 0 || completedWrites > 0 || failedWrites > 0 else {
                return ""
            }
            return " ddc=\(supported) ddcWrites=\(completedWrites) ddcErr=\(failedWrites)"
        }
    }

    // MARK: Queue-side IO

    private func probe(uid: String) {
        let binding = Self.probeBinding(uid: uid)
        let verdict: (
            hasPending: Bool,
            droppedHandler: (@Sendable (String) -> Void)?
        ) = stateLock.withLock {
            if let binding {
                capabilities[uid] = .supported(binding)
                consecutiveFailures[uid] = 0
                // A recovered display may legitimately demote again on the
                // next sleep/replug — let that episode log once too.
                loggedUnsupportedUIDs.remove(uid)
            } else {
                capabilities[uid] = .unsupported
                // The probing-state enqueue accepted this intent; the
                // verdict came back unsupported, so it is dropped here —
                // report it so the Router can book the rejection the
                // optimistic accept masked (Codex P2).
                if pending.removeValue(forKey: uid) != nil {
                    return (false, onPendingIntentDropped)
                }
            }
            guard binding != nil, pending[uid] != nil else {
                return (false, nil)
            }
            guard !drainingUIDs.contains(uid) else { return (false, nil) }
            drainingUIDs.insert(uid)
            return (true, nil)
        }
        verdict.droppedHandler?(uid)
        if verdict.hasPending {
            drain(uid: uid)
        }
    }

    /// Queue-side lightweight revalidation of a still-`supported` binding,
    /// used by the explicit refresh path (wake/reconcile). One cheap VCP
    /// 0x62 read over the cached channel proves the DCPAVServiceProxy
    /// handle survived display sleep/replug. On failure, a full re-probe
    /// either rebinds the display (fresh service handle; the two-layer
    /// user-volume cache is preserved — the panel may have reset its own
    /// level during sleep, but the user's intent did not change) or
    /// demotes the UID so the rejection diagnostics and write-triggered
    /// self-heal take over. The verdict stays `.supported` while the check
    /// is in flight, so capability snapshots never flap.
    private func revalidate(uid: String) {
        let current: Binding? = stateLock.withLock {
            if case .supported(let binding) = capabilities[uid] {
                return binding
            }
            return nil
        }
        guard let current else { return }
        guard current.channel.readVCP(DDCAudioVCP.speakerVolume) == nil else {
            return // Handle still live — binding stays as-is.
        }
        let fresh = Self.probeBinding(uid: uid)
        let droppedHandler: (@Sendable (String) -> Void)? = stateLock.withLock {
            guard case .supported(let stale) = capabilities[uid] else {
                return nil
            }
            if let fresh {
                var rebound = fresh
                rebound.levels = stale.levels
                capabilities[uid] = .supported(rebound)
                consecutiveFailures[uid] = 0
                return nil
            }
            capabilities[uid] = .unsupported
            logDemotionOnce(uid: uid, displayName: stale.displayName)
            // An intent accepted while the binding still looked supported
            // dies with the demotion — report it (Codex P2).
            if pending.removeValue(forKey: uid) != nil {
                return onPendingIntentDropped
            }
            return nil
        }
        droppedHandler?(uid)
    }

    /// Full fail-closed probe chain: CoreAudio identity -> conservative
    /// display match -> VCP 0x62 readable. Runs on the DDC queue (CoreAudio
    /// property reads are thread-safe and cheap; the I2C read is the slow
    /// part).
    private static func probeBinding(uid: String) -> Binding? {
        guard let deviceID = try? Capture.deviceID(forUID: uid) else {
            return nil
        }
        let displays = DDCDisplayEnumerator.externalDisplays()
        guard !displays.isEmpty else { return nil }
        guard let index = DDCDisplayMatching.matchIndex(
            audioDeviceName: readDeviceName(deviceID),
            isHDMIOrDisplayPortTransport: isHDMIOrDisplayPort(deviceID),
            displayProductNames: displays.map(\.productName)
        ) else {
            return nil
        }
        let display = displays[index]
        guard let volume = display.channel.readVCP(DDCAudioVCP.speakerVolume),
              let normalized = DDCVolumeScale.toNormalized(
                  current: volume.current, max: volume.max
              ) else {
            return nil
        }
        let supportsMute =
            display.channel.readVCP(DDCAudioVCP.mute) != nil
        return Binding(
            channel: display.channel,
            displayName: display.productName,
            maxValue: volume.max,
            supportsMuteVCP: supportsMute,
            levels: DDCVolumeLevels(
                userVolume: normalized, outputLevel: normalized
            )
        )
    }

    private func drain(uid: String) {
        while true {
            let work: (Binding, Intent)? = stateLock.withLock {
                guard case .supported(let binding) = capabilities[uid],
                      let intent = pending.removeValue(forKey: uid) else {
                    drainingUIDs.remove(uid)
                    return nil
                }
                return (binding, intent)
            }
            guard let (binding, intent) = work else { return }
            let outcome = Self.apply(binding: binding, intent: intent)
            let droppedHandler: (@Sendable (String) -> Void)? = stateLock.withLock {
                if outcome.ok {
                    completedWrites += 1
                    consecutiveFailures[uid] = 0
                    if case .supported(var updated) = capabilities[uid] {
                        updated.levels = outcome.levels
                        capabilities[uid] = .supported(updated)
                    }
                    return nil
                }
                failedWrites += 1
                let failures = (consecutiveFailures[uid] ?? 0) + 1
                consecutiveFailures[uid] = failures
                guard failures >= Self.maxConsecutiveFailures else {
                    return nil
                }
                capabilities[uid] = .unsupported
                logDemotionOnce(uid: uid, displayName: binding.displayName)
                // A NEWER intent may have been accepted (coalesced) while
                // this failing transaction was in flight; the demotion
                // discards it — report it (Codex P2).
                if pending.removeValue(forKey: uid) != nil {
                    return onPendingIntentDropped
                }
                return nil
            }
            droppedHandler?(uid)
        }
    }

    /// One coalesced intent -> I2C transaction(s). Native mute uses VCP
    /// 0x8D and keeps 0x62 at the user's level so unmute restores cleanly.
    /// Displays without 0x8D get mute emulated as 0x62 = 0; unmute rewrites
    /// the intent volume (intents always carry both fields, so emulation
    /// needs no extra state). The returned levels keep the user-intent
    /// volume separate from the written 0x62 level — see DDCVolumeLevels.
    private static func apply(
        binding: Binding,
        intent: Intent
    ) -> (ok: Bool, levels: DDCVolumeLevels) {
        let levels = DDCVolumeLevels.planned(
            volume: intent.volume,
            muted: intent.muted,
            supportsMuteVCP: binding.supportsMuteVCP
        )
        let vcpValue = DDCVolumeScale.toVCPValue(
            normalized: levels.outputLevel, max: binding.maxValue
        )
        var ok = true
        if binding.supportsMuteVCP, intent.muted {
            // Mute first so the level write below is inaudible.
            ok = binding.channel.writeVCP(
                DDCAudioVCP.mute, value: DDCAudioVCP.muteOn
            ) && ok
        }
        ok = binding.channel.writeVCP(
            DDCAudioVCP.speakerVolume, value: vcpValue
        ) && ok
        if binding.supportsMuteVCP, !intent.muted {
            // Unmute last so the level is already correct when sound returns.
            ok = binding.channel.writeVCP(
                DDCAudioVCP.mute, value: DDCAudioVCP.muteOff
            ) && ok
        }
        return (ok, levels)
    }

    /// Must be called inside `stateLock`.
    private func logDemotionOnce(uid: String, displayName: String) {
        guard !loggedUnsupportedUIDs.contains(uid) else { return }
        loggedUnsupportedUIDs.insert(uid)
        FileHandle.standardError.write(Data(
            ("[DDC] display \"\(displayName)\" stopped acknowledging DDC volume writes for \(uid.prefix(20)) — demoting to unsupported (further failures silenced)\n").utf8
        ))
    }

    // MARK: CoreAudio identity helpers

    private static func readDeviceName(_ id: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, ptr)
        }
        guard status == noErr else { return nil }
        return value as String?
    }

    private static func isHDMIOrDisplayPort(_ id: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
            id, &address, 0, nil, &size, &value
        ) == noErr else {
            return false
        }
        return value == kAudioDeviceTransportTypeHDMI
            || value == kAudioDeviceTransportTypeDisplayPort
    }
}
