import Foundation
import os.lock

/// **v4 continuous calibration** — periodically drives the on-demand
/// `ActiveCalibrator` and applies drift corrections to
/// `airplayDelayMs`. Replaces `PassiveCalibrator`'s background loop:
/// GCC-PHAT against shared music can't distinguish per-device taus
/// (single-peak detection collapses everything onto the loudest
/// speaker) and produced ±100 ms run-to-run noise.
///
/// Loop contract:
///   * Sleep `measurementIntervalSeconds` (sliced into 500 ms chunks
///     for prompt `stop()` cancellation).
///   * Invoke `runner` (the on-demand calibrator entry point).
///   * If `aggregateConfidence < confidenceFloor`: skip apply, emit
///     Sample, count toward consecutive-failure streak.
///   * Else if `|deltaMs| < driftThresholdMs`: no apply, emit Sample,
///     reset failure counter — drift is below perception threshold.
///   * Else: `newDelay = currentDelay + deltaMs` clamped `[0, 5000]`,
///     `await applyDelayMs(newDelay)`, emit Sample, reset counter.
///   * Repeat until `stop()` flips the cancel flag.
///
/// On runner throw or `consecutiveFailureLimit` sequential failures,
/// we log + keep retrying — there is no remediation possible from
/// inside the loop, and the user-driven `stop()` is the only exit.
public final class ContinuousActiveCalibrator: @unchecked Sendable {

    public static var verboseTracing: Bool = true
    @inline(__always)
    private static func trace(_ msg: @autoclosure () -> String) {
        guard verboseTracing else { return }
        CalibTrace.log(msg())
    }

    /// Per-cycle observation. `appliedDelayMs` equals the previous
    /// value when we declined to apply (low confidence or under the
    /// drift threshold); the UI uses (`measuredDeltaMs`,
    /// `appliedDelayMs`) together to show "measured X but applied Y".
    public struct Sample: Sendable {
        public let measuredDeltaMs: Int
        public let appliedDelayMs: Int
        public let perDeviceTauMs: [String: Int]
        public let confidence: Double
        public let timestamp: Date
        public init(
            measuredDeltaMs: Int, appliedDelayMs: Int,
            perDeviceTauMs: [String: Int], confidence: Double,
            timestamp: Date
        ) {
            self.measuredDeltaMs = measuredDeltaMs
            self.appliedDelayMs = appliedDelayMs
            self.perDeviceTauMs = perDeviceTauMs
            self.confidence = confidence
            self.timestamp = timestamp
        }
    }

    public typealias Runner =
        @Sendable () async throws -> ActiveCalibrator.Result
    public typealias DelayApplier = @Sendable (Int) async -> Void
    /// Returns the current delay-line value (ms). Invoked once per
    /// cycle on the loop's detached Task; caller is responsible for
    /// any actor hops. A stale return is harmless — the next cycle
    /// picks up whatever was actually applied.
    public typealias InitialDelayProvider = @Sendable () async -> Int
    public typealias SampleSink = @Sendable (Sample) -> Void

    /// 30 s — long enough that the user isn't probed too often, short
    /// enough to catch network/temperature drift before it's audible.
    public var measurementIntervalSeconds: Double = 30
    /// 30 ms — below human perception of inter-channel latency for
    /// music; also above `ActiveCalibrator`'s ±15 ms run-to-run noise
    /// floor. Below this we don't apply, avoiding audible "wobble"
    /// from constant micro-adjustments to the delay-line.
    public var driftThresholdMs: Int = 30
    /// 4.0 — one notch above the calibrator's 3.0 detection threshold.
    /// The continuous loop is more conservative than the manual
    /// one-shot because a wrong value applied every 30 s is much more
    /// damaging than one the user can immediately re-trigger.
    public var confidenceFloor: Double = 4.0
    /// Sequential failed cycles before we log a one-time `WARN`. Reset
    /// on success. Loop never backs off / gives up — `stop()` is the
    /// only exit.
    public var consecutiveFailureLimit: Int = 5

    private let runner: Runner
    private let applyDelayMs: DelayApplier
    private let initialDelayMs: InitialDelayProvider
    private let onSample: SampleSink

    private let stateLock = OSAllocatedUnfairLock()
    private var _running = false
    private var _stopRequested = false
    private var _loopTask: Task<Void, Never>?
    private var _consecutiveFailures: Int = 0
    private var _warnedOnFailureStreak: Bool = false
    private var _iterationCount: UInt64 = 0

    public init(
        runner: @escaping Runner,
        applyDelayMs: @escaping DelayApplier,
        initialDelayMs: @escaping InitialDelayProvider,
        onSample: @escaping SampleSink
    ) {
        self.runner = runner
        self.applyDelayMs = applyDelayMs
        self.initialDelayMs = initialDelayMs
        self.onSample = onSample
    }

    deinit { stop() }

    /// Begin the loop. Idempotent. Throws is reserved for ABI parity
    /// with `PassiveCalibrator.start()` — the current implementation
    /// has no fallible setup.
    public func start() async throws {
        let alreadyRunning: Bool = stateLock.withLock {
            if _running { return true }
            _running = true
            _stopRequested = false
            _consecutiveFailures = 0
            _warnedOnFailureStreak = false
            _iterationCount = 0
            return false
        }
        if alreadyRunning { return }
        Self.trace(
            "[ContActiveCalib] start: interval=\(measurementIntervalSeconds)s driftThreshold=\(driftThresholdMs)ms confidenceFloor=\(confidenceFloor)"
        )
        let task: Task<Void, Never> = Task.detached(priority: .utility) {
            [weak self] in
            guard let self else { return }
            await self.runMeasurementLoop()
        }
        stateLock.withLockUnchecked { _loopTask = task }
    }

    /// Stop. Idempotent. Loop observes the cancel flag within 500 ms.
    public func stop() {
        let task: Task<Void, Never>? = stateLock.withLockUnchecked {
            _stopRequested = true
            _running = false
            let t = _loopTask
            _loopTask = nil
            return t
        }
        task?.cancel()
        Self.trace("[ContActiveCalib] stop: requested")
    }

    private func isStopRequested() -> Bool {
        stateLock.withLock { _stopRequested }
    }

    private func runMeasurementLoop() async {
        // Initial wait — gives the audio pipeline time to reach steady
        // state after a mode-switch / bridge-bring-up.
        if await !sleepInSlices(seconds: measurementIntervalSeconds) {
            Self.trace("[ContActiveCalib] loop: stop during initial wait")
            return
        }
        while !isStopRequested() {
            let interval = measurementIntervalSeconds
            let threshold = driftThresholdMs
            let confFloor = confidenceFloor
            let iter: UInt64 = stateLock.withLockUnchecked {
                _iterationCount &+= 1
                return _iterationCount
            }
            await runOneCycle(
                iter: iter, threshold: threshold, confFloor: confFloor
            )
            if await !sleepInSlices(seconds: interval) {
                Self.trace("[ContActiveCalib] loop: stop during inter-cycle sleep iter=\(iter)")
                return
            }
        }
    }

    private func runOneCycle(
        iter: UInt64, threshold: Int, confFloor: Double
    ) async {
        if isStopRequested() { return }
        let beforeDelayMs = await initialDelayMs()
        let result: ActiveCalibrator.Result
        do {
            result = try await runner()
        } catch {
            recordFailure(reason: "runner_threw: \(error)")
            Self.trace(
                "[ContActiveCalib] iter=\(iter) runner threw \(error) — skip cycle"
            )
            return
        }
        if isStopRequested() { return }

        let delta = result.deltaMs
        let confidence = result.aggregateConfidence

        if confidence < confFloor {
            recordFailure(
                reason: "low_confidence \(String(format: "%.2f", confidence))"
            )
            Self.trace(
                "[ContActiveCalib] skip cycle: confidence \(String(format: "%.1f", confidence)) below threshold \(String(format: "%.1f", confFloor)) iter=\(iter) delta=\(delta)ms"
            )
            emitSample(
                measuredDelta: delta, appliedDelay: beforeDelayMs,
                perDeviceTau: result.perDeviceTauMs, confidence: confidence
            )
            return
        }
        if abs(delta) < threshold {
            recordSuccess()
            Self.trace(
                "[ContActiveCalib] iter=\(iter) delta=\(delta)ms within threshold ±\(threshold)ms — no action confidence=\(String(format: "%.2f", confidence))"
            )
            emitSample(
                measuredDelta: delta, appliedDelay: beforeDelayMs,
                perDeviceTau: result.perDeviceTauMs, confidence: confidence
            )
            return
        }
        let proposed = beforeDelayMs + delta
        let clamped = min(5000, max(0, proposed))
        await applyDelayMs(clamped)
        recordSuccess()
        Self.trace(
            "[ContActiveCalib] iter=\(iter) delta=\(delta)ms applied: \(beforeDelayMs)ms -> \(clamped)ms confidence=\(String(format: "%.2f", confidence))"
        )
        emitSample(
            measuredDelta: delta, appliedDelay: clamped,
            perDeviceTau: result.perDeviceTauMs, confidence: confidence
        )
    }

    private func emitSample(
        measuredDelta: Int, appliedDelay: Int,
        perDeviceTau: [String: Int], confidence: Double
    ) {
        onSample(Sample(
            measuredDeltaMs: measuredDelta, appliedDelayMs: appliedDelay,
            perDeviceTauMs: perDeviceTau, confidence: confidence,
            timestamp: Date()
        ))
    }

    private func recordSuccess() {
        stateLock.withLockUnchecked {
            _consecutiveFailures = 0
            _warnedOnFailureStreak = false
        }
    }

    private func recordFailure(reason: String) {
        let (count, shouldWarn): (Int, Bool) = stateLock.withLockUnchecked {
            _consecutiveFailures &+= 1
            let n = _consecutiveFailures
            let warn = !_warnedOnFailureStreak
                && n >= consecutiveFailureLimit
            if warn { _warnedOnFailureStreak = true }
            return (n, warn)
        }
        if shouldWarn {
            CalibTrace.log(
                "[ContActiveCalib] WARN \(count) consecutive failed cycles — last reason: \(reason). Loop continues; user-driven stop() is the only exit."
            )
        }
    }

    /// Sleep `seconds` in 500 ms slices. Returns `true` on natural
    /// completion or `false` if `stop()` was requested mid-sleep.
    private func sleepInSlices(seconds: Double) async -> Bool {
        var remaining = UInt64(max(0, seconds) * 1_000_000_000)
        while remaining > 0 {
            if isStopRequested() { return false }
            let slice = min(remaining, UInt64(500_000_000))
            do {
                try await Task.sleep(nanoseconds: slice)
            } catch {
                return false
            }
            remaining &-= slice
        }
        return !isStopRequested()
    }
}
