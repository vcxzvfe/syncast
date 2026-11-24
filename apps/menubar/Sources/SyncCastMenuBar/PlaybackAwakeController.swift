import CoreAudio
import Foundation
import SyncCastRouter

/// Runs `PlaybackAwakePolicy` against the real machine: once a second while
/// the rule's display is present, measure what is going out of it and hold or
/// drop the display-sleep assertion.
///
/// # Where the level comes from
///
/// CoreAudio's per-process output list says who is rendering to the display.
///
/// - SyncCast itself (every SyncCast route that plays locally): the router
///   is already capturing what the apps play, and its ring is read here, no
///   extra tap. The router also says whether it lets that audio out on the
///   display (the display's row, the system volume it owns).
/// - Other processes (SyncCast idle with the display as the default output,
///   Direct Stereo, an app with its own device picker): a meter-only Process
///   Tap on exactly those processes is started, and stopped again shortly
///   after they stop rendering.
///
/// Nothing is started just because the display is connected: the per-process
/// check costs only property reads, and the loop does not run at all while
/// the display is absent or the rule has the feature off. The property reads
/// run off the main thread, because coreaudiod can stall them during
/// hot-plug and wake.
///
/// # Why the meter tap cannot latch
///
/// A tap aggregate is INPUT IO in this process. The gate is "a process other
/// than SyncCast is running OUTPUT to the display", which the meter tap never
/// makes true by itself.
@MainActor
final class PlaybackAwakeController {

    struct Settings: Equatable, Sendable {
        /// CoreAudio UID of the display whose audio must not be cut.
        var displayUID: String
        var releaseAfterSeconds: TimeInterval
    }

    typealias RouterSourceProvider = @Sendable (String) async -> Router.PlaybackMeterSource?

    static let tickSeconds: Double = 1
    /// Longest stretch of audio one measurement reads (2 s at 48 kHz). Ticks
    /// are a second apart; a late one reads at most this much.
    static let maxMeasureFrames = 96_000
    /// How long the meter tap outlives the last outside renderer. Players
    /// close and reopen their stream between tracks; this keeps one tap
    /// across that instead of a create/destroy per track.
    static let meterTapLingerSeconds: TimeInterval = 15
    /// Outside processes are rendering but the meter tap has delivered
    /// nothing for this long: it is dead (stale after wake, or the system
    /// audio recording permission is missing). Rebuild it.
    static let meterTapStallSeconds: TimeInterval = 10
    static let meterTapQuickRetrySeconds: TimeInterval = 5
    /// After this many dead taps in a row, back off and tell the user.
    static let meterTapStrikesBeforeBackoff = 3
    static let meterTapBackoffSeconds: TimeInterval = 300
    static let meterTapRingFrames = 1 << 17
    /// Retry spacing when powerd refused to create or release the assertion.
    static let assertionRetrySeconds: TimeInterval = 30
    static let releaseRetryAttempts = 12
    static let summaryIntervalSeconds: TimeInterval = 60

    /// Called with the new state whenever the assertion is taken or dropped.
    var onHoldingChanged: ((Bool) -> Void)?
    /// True while outside renderers cannot be measured (see
    /// `meterTapStallSeconds`); the UI points the user at the permission.
    var onMeterProblemChanged: ((Bool) -> Void)?

    private let blocker: DisplaySleepBlocker
    private let routerSource: RouterSourceProvider
    private let ownPID = getpid()
    private let clockOrigin = ContinuousClock.now

    private var settings: Settings?
    private var policy = PlaybackAwakePolicy()
    private var loop: Task<Void, Never>?
    /// Bumped whenever a loop starts or winds down. Work that was in flight
    /// across a suspension point checks it before acting, so a tick or a tap
    /// start that outlived its loop cannot take the assertion or start a tap.
    private var generation = 0
    private var refreshGeneration = 0
    private var holdRetryAt: TimeInterval = 0

    private let routerProbe = RingLevelProbe()
    private let meterProbe = RingLevelProbe()
    private var meterTap: MeterTap?
    private var meterTapStarting = false
    private var meterTapRetryAt: TimeInterval = 0
    private var meterTapIdleSince: TimeInterval?
    private var meterTapStrikes = 0
    private var meterProblem = false

    private var summary = LevelSummary()

    init(blocker: DisplaySleepBlocker, routerSource: @escaping RouterSourceProvider) {
        self.blocker = blocker
        self.routerSource = routerSource
    }

    var isHolding: Bool { blocker.isHolding }

    /// New rule settings (nil: no rule, or the rule has the feature off).
    /// Also re-checks whether the display is present.
    func update(settings newSettings: Settings?, reason: String) {
        if newSettings != settings {
            let displayChanged = newSettings?.displayUID != settings?.displayUID
            settings = newSettings
            policy.config.releaseAfterSeconds = newSettings?.releaseAfterSeconds
                ?? PlaybackAwakeDefaults.releaseSeconds
            SyncCastLog.log(
                "[awake] settings (\(reason)): "
                + (newSettings.map {
                    "on for \($0.displayUID.prefix(8))…, release after \(Int($0.releaseAfterSeconds)) s"
                } ?? "off")
            )
            // A different display is a different episode: whatever was being
            // held was held for the old one.
            if displayChanged, loop != nil || blocker.isHolding {
                finishIneligible(reason: "display changed")
            }
        }
        refresh(reason: reason)
    }

    /// Start or stop the loop to match "feature on and display present".
    /// Cheap; call it on every device-list change.
    func refresh(reason: String) {
        refreshGeneration += 1
        let token = refreshGeneration
        guard let uid = settings?.displayUID else {
            if loop != nil || blocker.isHolding { finishIneligible(reason: "feature off") }
            return
        }
        Task { @MainActor [weak self] in
            let present = await Task.detached(priority: .utility) {
                PlaybackOutputProbe.isPresent(uid: uid)
            }.value
            guard let self, token == self.refreshGeneration,
                  self.settings?.displayUID == uid else { return }
            if present, self.loop == nil {
                SyncCastLog.log("[awake] watching (\(reason))")
                self.startLoop()
            } else if !present, self.loop != nil {
                self.finishIneligible(reason: "display gone")
            }
        }
    }

    // MARK: - Loop

    private func startLoop() {
        generation += 1
        let gen = generation
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.generation == gen else { return }
                guard await self.tick(generation: gen) else { return }
                try? await Task.sleep(nanoseconds: UInt64(Self.tickSeconds * 1_000_000_000))
            }
        }
    }

    private func isCurrent(_ gen: Int) -> Bool {
        !Task.isCancelled && generation == gen && loop != nil
    }

    private func now() -> TimeInterval {
        let elapsed = ContinuousClock.now - clockOrigin
        return Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
    }

    /// One measurement. Returns false when the loop should end.
    private func tick(generation gen: Int) async -> Bool {
        guard let settings else {
            finishIneligible(reason: "feature off")
            return false
        }
        let uid = settings.displayUID
        let pid = ownPID
        let snapshot = await Task.detached(priority: .utility) {
            PlaybackOutputProbe.snapshot(displayUID: uid, ownPID: pid)
        }.value
        guard isCurrent(gen) else { return false }
        guard snapshot.displayPresent else {
            finishIneligible(reason: "display gone")
            return false
        }

        var sources: [PlaybackLevel.Source] = []
        var labels: [String] = []
        if snapshot.feed.bySyncCast {
            let source = await routerSource(uid)
            guard isCurrent(gen) else { return false }
            if let source {
                // The router's own row and master, AND the display's own
                // controls: a display muted in macOS plays nothing however
                // loud the capture is.
                let audible = source.audibleOnOutput && PlaybackLevel.deviceLetsAudioOut(
                    muted: snapshot.displayMuted, scalar: snapshot.displayScalar
                )
                if let peak = routerProbe.measure(ring: source.ring, maxFrames: Self.maxMeasureFrames) {
                    sources.append(.init(peak: peak, audible: audible))
                }
                labels.append(audible ? "router" : "router (silenced on the display)")
            } else {
                routerProbe.reset()
            }
        } else {
            routerProbe.reset()
        }

        let t = now()
        manageMeterTap(processes: snapshot.feed.otherProcesses, now: t, generation: gen)
        if snapshot.feed.byOthers, let tap = meterTap {
            if let peak = meterProbe.measure(ring: tap.capture.ringBuffer, maxFrames: Self.maxMeasureFrames) {
                sources.append(.init(
                    peak: peak,
                    audible: PlaybackLevel.deviceLetsAudioOut(
                        muted: snapshot.displayMuted, scalar: snapshot.displayScalar
                    )
                ))
            }
            labels.append("process tap ×\(tap.processes.count)")
        } else {
            meterProbe.reset()
        }

        let level = PlaybackLevel.effectiveDbfs(sources)
        let transition = policy.step(.init(now: t, eligible: true, levelDbfs: level))
        apply(transition, level: level, labels: labels, now: t)
        reconcileBlocker(now: t)
        noteSummary(level: level, fed: snapshot.feed.bySyncCast || snapshot.feed.byOthers, now: t)
        return true
    }

    private func apply(
        _ transition: PlaybackAwakePolicy.Transition?,
        level: Double?,
        labels: [String],
        now t: TimeInterval
    ) {
        switch transition {
        case .hold:
            let ok = blocker.hold()
            if !ok { holdRetryAt = t + Self.assertionRetrySeconds }
            SyncCastLog.log(
                "[awake] holding the display awake (\(Self.format(level)) via \(labels.joined(separator: " + ")))"
                + (ok ? "" : " — assertion REFUSED, retrying every \(Int(Self.assertionRetrySeconds)) s")
            )
            onHoldingChanged?(blocker.isHolding)
        case .release(let reason):
            let ok = blocker.release()
            SyncCastLog.log(
                "[awake] released (\(reason.rawValue)"
                + (reason == .quiet
                   ? ", nothing ≥ \(Int(policy.config.sustainDbfs)) dBFS for \(Int(policy.config.releaseAfterSeconds)) s"
                   : "")
                + ")" + (ok ? "" : " — release FAILED, retrying")
            )
            onHoldingChanged?(blocker.isHolding)
        case nil:
            break
        }
    }

    /// Make the blocker agree with the policy when an earlier create or
    /// release did not take.
    private func reconcileBlocker(now t: TimeInterval) {
        if policy.holding, !blocker.isHolding, t >= holdRetryAt {
            if blocker.hold() {
                SyncCastLog.log("[awake] assertion taken on retry")
                onHoldingChanged?(true)
            } else {
                holdRetryAt = t + Self.assertionRetrySeconds
            }
        } else if !policy.holding, blocker.isHolding {
            if blocker.release() { onHoldingChanged?(false) }
        }
    }

    private func finishIneligible(reason: String) {
        generation += 1
        loop?.cancel()
        loop = nil
        if let transition = policy.step(.init(now: now(), eligible: false, levelDbfs: nil)) {
            apply(transition, level: nil, labels: [], now: now())
        }
        if blocker.isHolding, !blocker.release() {
            scheduleReleaseRetry()
        }
        onHoldingChanged?(blocker.isHolding)
        stopMeterTap(reason: reason)
        meterTapStrikes = 0
        meterTapRetryAt = 0
        setMeterProblem(false)
        routerProbe.reset()
        meterProbe.reset()
        summary = LevelSummary()
        SyncCastLog.log("[awake] not watching (\(reason))")
    }

    /// No loop is left to retry a release that failed on the way out.
    private func scheduleReleaseRetry() {
        Task { @MainActor [weak self] in
            for _ in 0..<Self.releaseRetryAttempts {
                try? await Task.sleep(nanoseconds: UInt64(Self.assertionRetrySeconds * 1_000_000_000))
                guard let self else { return }
                // A new loop owns the blocker again; it reconciles itself.
                guard self.loop == nil, self.blocker.isHolding else { return }
                if self.blocker.release() {
                    self.onHoldingChanged?(false)
                    return
                }
            }
        }
    }

    // MARK: - Meter-only tap

    private struct MeterTap {
        /// A `TapCapture`, held through the protocol so this type does not
        /// need the macOS 14.2 availability gate.
        let capture: any SystemAudioCapture
        let processes: [UInt32]
        var lastWritePosition: Int64
        var lastAdvanceAt: TimeInterval
    }

    private func manageMeterTap(processes: [UInt32], now t: TimeInterval, generation gen: Int) {
        guard !processes.isEmpty else {
            guard meterTap != nil else {
                meterTapIdleSince = nil
                return
            }
            if let since = meterTapIdleSince {
                if t - since >= Self.meterTapLingerSeconds {
                    stopMeterTap(reason: "no outside renderer for \(Int(Self.meterTapLingerSeconds)) s")
                }
            } else {
                meterTapIdleSince = t
            }
            return
        }
        meterTapIdleSince = nil

        if var tap = meterTap {
            if tap.processes != processes {
                stopMeterTap(reason: "outside renderers changed")
            } else {
                let position = tap.capture.ringBuffer.writePosition
                if position > tap.lastWritePosition {
                    tap.lastWritePosition = position
                    tap.lastAdvanceAt = t
                    meterTap = tap
                    if meterTapStrikes > 0 { meterTapStrikes = 0 }
                    setMeterProblem(false)
                    return
                }
                guard t - tap.lastAdvanceAt >= Self.meterTapStallSeconds else { return }
                stopMeterTap(
                    reason: "delivered nothing for \(Int(Self.meterTapStallSeconds)) s while \(processes.count) process(es) render"
                )
                noteMeterTapStrike(now: t)
                return
            }
        }
        guard !meterTapStarting, t >= meterTapRetryAt else { return }
        startMeterTap(processes: processes, now: t, generation: gen)
    }

    private func noteMeterTapStrike(now t: TimeInterval) {
        meterTapStrikes += 1
        if meterTapStrikes >= Self.meterTapStrikesBeforeBackoff {
            meterTapRetryAt = t + Self.meterTapBackoffSeconds
            setMeterProblem(true)
            SyncCastLog.log(
                "[awake] meter tap failed \(meterTapStrikes)× in a row; next try in \(Int(Self.meterTapBackoffSeconds)) s"
                + " (is System Audio Recording allowed for SyncCast?)"
            )
        } else {
            meterTapRetryAt = t + Self.meterTapQuickRetrySeconds
        }
    }

    private func startMeterTap(processes: [UInt32], now t: TimeInterval, generation gen: Int) {
        guard #available(macOS 14.2, *) else {
            meterTapRetryAt = .infinity
            setMeterProblem(true)
            SyncCastLog.log("[awake] meter tap needs macOS 14.2; outside renderers are not metered")
            return
        }
        let capture: any SystemAudioCapture = TapCapture(
            channelCount: 2,
            ringCapacityFrames: Self.meterTapRingFrames,
            includedProcesses: processes.map { AudioObjectID($0) },
            allowsAnySampleRate: true
        )
        meterTapStarting = true
        Task { @MainActor [weak self] in
            do {
                try await capture.start()
            } catch {
                guard let self else { return }
                self.meterTapStarting = false
                guard self.generation == gen else { return }
                SyncCastLog.log("[awake] meter tap failed to start: \(error)")
                self.noteMeterTapStrike(now: self.now())
                return
            }
            guard let self else {
                Self.stopInBackground(capture)
                return
            }
            self.meterTapStarting = false
            // The loop may have wound down (display gone, feature off) while
            // the tap was coming up; a tap nobody reads must not keep running.
            guard self.generation == gen, self.loop != nil, self.settings != nil else {
                Self.stopInBackground(capture)
                return
            }
            self.meterTap = MeterTap(
                capture: capture,
                processes: processes,
                lastWritePosition: capture.ringBuffer.writePosition,
                lastAdvanceAt: self.now()
            )
            self.meterProbe.reset()
            SyncCastLog.log("[awake] meter tap on for \(processes.count) outside process(es)")
        }
    }

    private func stopMeterTap(reason: String) {
        meterTapIdleSince = nil
        guard let tap = meterTap else { return }
        meterTap = nil
        meterProbe.reset()
        Self.stopInBackground(tap.capture)
        SyncCastLog.log("[awake] meter tap off (\(reason))")
    }

    /// `AudioDeviceStop` / destroy can block on a wedged coreaudiod; never on
    /// the main thread.
    private nonisolated static func stopInBackground(_ capture: any SystemAudioCapture) {
        DispatchQueue.global(qos: .utility).async { capture.stop() }
    }

    private func setMeterProblem(_ problem: Bool) {
        guard problem != meterProblem else { return }
        meterProblem = problem
        onMeterProblemChanged?(problem)
    }

    // MARK: - Logging

    /// One line a minute while anything audible was measured or the display
    /// is being held, so thresholds can be checked against real listening
    /// instead of guessed.
    private struct LevelSummary {
        var startedAt: TimeInterval?
        var seconds = 0
        var fedSeconds = 0
        var armSeconds = 0
        var sustainSeconds = 0
        var maxDb = -Double.infinity
        var quietestAudibleDb = Double.infinity
    }

    private func noteSummary(level: Double?, fed: Bool, now t: TimeInterval) {
        if summary.startedAt == nil { summary.startedAt = t }
        summary.seconds += 1
        if fed { summary.fedSeconds += 1 }
        if let level {
            if level >= policy.config.armDbfs { summary.armSeconds += 1 }
            if level >= policy.config.sustainDbfs { summary.sustainSeconds += 1 }
            summary.maxDb = max(summary.maxDb, level)
            if level > -.infinity { summary.quietestAudibleDb = min(summary.quietestAudibleDb, level) }
        }
        guard let started = summary.startedAt, t - started >= Self.summaryIntervalSeconds else { return }
        // Skip minutes of pure silence: on the sink path SyncCast feeds the
        // display around the clock, and "nothing played" is not worth a line.
        if summary.maxDb.isFinite || blocker.isHolding {
            SyncCastLog.log(
                "[awake] last \(Int((t - started).rounded())) s (\(summary.seconds) ticks): fed \(summary.fedSeconds)"
                + ", ≥\(Int(policy.config.armDbfs)) dBFS \(summary.armSeconds)"
                + ", ≥\(Int(policy.config.sustainDbfs)) dBFS \(summary.sustainSeconds)"
                + ", max \(Self.format(summary.maxDb))"
                + ", quietest non-zero \(Self.format(summary.quietestAudibleDb.isFinite ? summary.quietestAudibleDb : nil))"
                + ", holding=\(blocker.isHolding ? "yes" : "no")"
            )
        }
        summary = LevelSummary()
    }

    private static func format(_ db: Double?) -> String {
        guard let db else { return "no audio" }
        guard db.isFinite else { return "digital silence" }
        return String(format: "%.1f dBFS", db)
    }
}
