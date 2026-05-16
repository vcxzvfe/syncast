import Foundation
import CoreAudio
import SyncCastDiscovery

/// Helper struct used inside Router.reconcileLocalDriver to carry the
/// (id, uid, name) triple for each enabled local CoreAudio output. Defined
/// at file scope so it can cross from the reconcile entry point into the
/// per-mode helpers without an extra indirection.
private struct EnabledLocalOutput {
    let deviceID: String
    let uid: String
    let name: String
}

private struct AirplayTauCache: Sendable {
    let groupTau: Int
    let groupConfidence: Double
    let groupUncertaintyMs: Int
    let probeProfile: String
    let routeSignature: String
    let calibratedAt: Date
}

/// Injects `CalibrationSession.clickPulse` samples into the live capture
/// ringBuffer so they ride through the existing whole-home audio path.
/// AirPlay receivers play the click after their PTP latency; local
/// bridges play it after the broadcaster's delay-line. The mic in
/// `CalibrationRunner` measures the per-output arrival time so we can
/// compute the delta needed to align them.
///
/// We deliberately race with the capture backend's write thread on this ring
/// rather than pause capture for calibration — the click is a 10 ms transient
/// every couple seconds, the worst case is a single chunk of garbled
/// audio in the user's actual playback (recoverable, barely audible),
/// vs. interrupting their audio entirely. Acceptable for v1 calibration.
private struct RingBufferClickEmitter: ClickEmitter {
    let ringBuffer: RingBuffer

    func emit(samples: [[Float]], at anchorNs: UInt64) async {
        let nowNs = DispatchTime.now().uptimeNanoseconds
        if anchorNs > nowNs {
            try? await Task.sleep(nanoseconds: anchorNs - nowNs)
        }
        guard samples.count >= 2,
              !samples[0].isEmpty,
              samples[0].count == samples[1].count
        else { return }
        let frames = samples[0].count
        samples[0].withUnsafeBufferPointer { ch0 in
            samples[1].withUnsafeBufferPointer { ch1 in
                let ptrArray: [UnsafePointer<Float>] = [
                    ch0.baseAddress!, ch1.baseAddress!,
                ]
                ptrArray.withUnsafeBufferPointer { ptrs in
                    ringBuffer.write(channels: ptrs.baseAddress!, frames: frames)
                }
            }
        }
    }
}

/// The Router is the top-level coordinator: it owns the capture, the ring
/// buffer, the local outputs, and the IPC client to the sidecar. The view
/// layer talks to this actor; CoreAudio threads talk to its members directly.
public actor Router {
    public static let airplayVolumeTimingInvalidationThreshold: Float = 0.03

    public struct LocalBridgeTimingDiagnostic: Sendable, Equatable {
        public let driftResyncCount: UInt64
        public let driftResyncReason: String
        public let driftResyncFrameDelta: Int64

        public init(
            driftResyncCount: UInt64,
            driftResyncReason: String,
            driftResyncFrameDelta: Int64
        ) {
            self.driftResyncCount = driftResyncCount
            self.driftResyncReason = driftResyncReason
            self.driftResyncFrameDelta = driftResyncFrameDelta
        }
    }

    public static func airplayVolumeChangeInvalidatesTiming(
        previous: Float?,
        next: Float,
        invalidatesTiming: Bool
    ) -> Bool {
        guard invalidatesTiming, let previous else { return false }
        return abs(previous - next) > airplayVolumeTimingInvalidationThreshold
    }

    public static func airplayConnectionEventInvalidatesTiming(
        previous: DeviceConnectionState?,
        next: DeviceConnectionState,
        isActiveAirplay: Bool
    ) -> Bool {
        if previous != next { return true }
        return isActiveAirplay && previous == .connected && next == .connected
    }

    public static func streamStartResponseIndicatesNoop(_ response: Any?) -> Bool {
        guard let payload = response as? [String: Any] else { return false }
        return payload["noop"] as? Bool == true
    }

    private static let activeAcousticCalibrationEnabled: Bool = {
        ActiveAcousticDiagnosticsGate.isEnabled()
    }()
    private static let activeAcousticCalibrationDisabledMessage =
        ActiveAcousticDiagnosticsGate.disabledMessage

    public enum RouterState: String, Sendable {
        case idle
        case starting
        case running
        case stopping
        case error
    }

    /// Top-level data-plane mode.
    ///
    /// - ``stereo``     — captured PCM is fed through the
    ///                    sidecar to AirPlay 2 receivers, while local
    ///                    CoreAudio outputs render from the same capture
    ///                    ring directly. Two clocks: capture for local,
    ///                    AirPlay's RTSP anchor for remote.
    /// - ``wholeHome``  — Strategy 1: bundled OwnTone produces ONE
    ///                    player-clock stream that fans out to AirPlay
    ///                    receivers (via OwnTone's existing AirPlay
    ///                    output) AND to local CoreAudio devices via
    ///                    `LocalAirPlayBridge` instances reading the
    ///                    sidecar's fifo broadcast socket. Single
    ///                    clock everywhere.
    public enum Mode: String, Sendable {
        case stereo
        case wholeHome = "whole_home"
    }

    public private(set) var state: RouterState = .idle
    public private(set) var lastError: String?
    public private(set) var mode: Mode = .stereo

    private let capture: any SystemAudioCapture
    private let stereoOutputPath: StereoOutputPathPolicy.Path
    private let scheduler: Scheduler
    /// Open AUHAL outputs. Keyed differently depending on driver mode:
    ///   - In `.individual` mode: keyed by SyncCast device ID — one
    ///     LocalOutput per enabled physical device.
    ///   - In `.aggregate` mode: a single entry keyed by the aggregate
    ///     device's UID. The kernel-side aggregate fans out audio to all
    ///     constituent physical devices with sample-accurate drift
    ///     correction; that's why we only need one AUHAL on top of it.
    private var localOutputs: [String: LocalOutput] = [:]
    /// Active synchronized aggregate, when 2+ local outputs are enabled.
    /// `nil` in idle mode, in single-output mode, or after a transition
    /// teardown. The teardown order is strict — see Router.stop().
    private var aggregateDevice: AggregateDevice?
    /// Set of physical device UIDs the active aggregate currently fans
    /// audio out to. Used to decide if a routing change requires destroy +
    /// recreate (different set) or is a no-op (same set).
    private var aggregateCoveredUIDs: Set<String> = []
    /// Maps SyncCast device ID → coreAudio UID for every device the
    /// active aggregate covers. Used by replan() to apply per-device
    /// hardware volume — routing is keyed by SyncCast ID, but the
    /// hardware-volume API needs the underlying device's UID.
    private var aggregateUIDByDeviceID: [String: String] = [:]
    /// Cached stream-format diagnostic from the most recent aggregate
    /// build. Surfaced by `diagnosticCaptureReport()` so field logs show the
    /// actual channel layout of the kernel-level fan-out — invaluable
    /// for diagnosing the "only one speaker plays" symptom (which is
    /// almost always a channel-count mismatch between AUHAL stream
    /// format and the aggregate's exposed stream layout).
    private var aggregateStreamDiagnostic: AggregateDevice.StreamDiagnostic?
    private var directStereoOutput: DirectStereoOutput?
    private var routing: [String: DeviceRouting] = [:]
    /// Monotonic route/context epoch. Incremented for user/app-driven route,
    /// mode, AirPlay active-set, connection, and measured-latency changes.
    /// Active calibration snapshots this value so it can fail closed instead
    /// of restoring stale routing over a newer user change.
    private var routeMutationRevision: UInt64 = 0
    /// Monotonic AirPlay timing epoch for passive evidence. Incremented when
    /// AirPlay receiver connection/active-set/volume/latency state changes,
    /// because the route can look identical while the buffered timing domain
    /// has shifted.
    private var airplayTimingEpoch: UInt64 = 0
    private var measuredAirplayLatencyMs: Int = 1800
    /// Per-session set of subdevice UIDs we've already logged the
    /// "hardware volume rejected" warning for. Each UID logs ONCE,
    /// then goes silent — many DP / HDMI displays expose no writable
    /// VolumeScalar on any element, so without this gate the log
    /// would emit on every single replan (every slider drag) and
    /// drown out every other diagnostic. The diagnostic report can
    /// inspect `aggregateHwVolumeRejectionCounts` to surface the
    /// total rejection count per UID without spamming stderr.
    private var loggedHwVolumeRejectionUIDs: Set<String> = []
    /// Total number of rejected hardware-volume writes per UID this
    /// session. Incremented on every rejection regardless of whether
    /// we logged. Surfaced through `diagnosticCaptureReport()` so a
    /// support ticket can show "we tried 47 times, never accepted".
    private var aggregateHwVolumeRejectionCounts: [String: Int] = [:]
    /// Per-session set of subdevice UIDs whose hardware volume is
    /// known unsupported (a write attempt returned false at least
    /// once). Future replans skip the call into CoreAudio entirely
    /// and go straight to the software-gain fallback. Cleared on
    /// teardown so re-plug or device hot-swap gets a fresh probe.
    private var aggregateHwVolumeUnsupportedUIDs: Set<String> = []
    private var ipc: IpcClient?
    private var audioWriter: AudioSocketWriter?
    /// Per-device connection state, keyed by SyncCast device ID. Updated
    /// in the sidecar-notification handler on every `event.device_state`
    /// arrival (see `attachSidecar`). Surfaced to the UI via
    /// `connectionState(deviceID:)` + `connectionStatesSnapshot()`.
    ///
    /// Why the actor owns this rather than AppModel: AppModel runs on
    /// the MainActor, so funnelling per-event notifications all the way
    /// up to the UI thread for every device-state event would generate
    /// dozens of MainActor hops per session start (the sidecar emits
    /// connecting+connected+occasional failed for every device). The
    /// actor keeps the latest cache and AppModel polls every second
    /// (see `AppModel.subscribeConnectionStates`). v1 is intentionally
    /// poll-based — pushing every event to MainActor can be added later
    /// when we have a need (e.g. instant-failure UI animation).
    private var connectionStates: [String: DeviceConnectionState] = [:]
    /// Per-device "last_error" string from the most recent failed
    /// event. Surfaced in the UI as a one-line under-row message.
    /// Nil for any device whose state is not currently `.failed`.
    private var connectionFailureReasons: [String: String] = [:]
    /// Whole-home AirPlay mode bridges, keyed by SyncCast device ID.
    /// Each entry owns one Unix-socket connection to the sidecar's
    /// broadcast listener and one AUHAL on a physical CoreAudio device.
    /// Empty in stereo mode and after teardown. Fully replaces the
    /// `localOutputs` set while in whole-home mode — the two are never
    /// active at the same time on the same physical device.
    private var localBridges: [String: LocalAirPlayBridge] = [:]
    /// Cached path returned by `local_fifo.path` IPC — fetched once on
    /// the first whole-home transition and reused for all bridges.
    private var localFifoSocketPath: URL?

    /// Diagnostic socket server: lets command-line callers
    /// (`scripts/calibration_test.sh`) trigger a one-shot calibration
    /// without driving the SwiftUI menubar. Lifecycle: bound when the
    /// AppModel calls `startCalibrationDiagnosticServer` after entering
    /// whole-home + running, torn down on every other state. nil when
    /// idle / in stereo mode.
    private var calibrationDiagnosticServer: CalibrationDiagnosticServer?

    /// Per-AirPlay-device τ (ms) captured from the most recent SUCCESSFUL
    /// full calibration (Phase 1 + Phase 2), with the route/volume
    /// signature it was measured against. Continuous mode refuses to
    /// apply local-only drift against this cache after AirPlay route,
    /// volume, connection, or OwnTone timing state changes.
    private var airplayTauCache: AirplayTauCache?
    private var activeAirplayDeviceIDs: Set<String> = []
    private var registeredAirplayEndpointsByID: [String: String] = [:]
    private var lastAirplayVolumeByID: [String: Float] = [:]
    private let airplayTauCacheTTLSeconds: TimeInterval = 30 * 60

    /// Sockets used to talk to the Python sidecar. May be nil in unit tests
    /// or when running without AirPlay support.
    public struct SidecarSockets: Sendable {
        public let control: URL
        public let audio: URL
        public init(control: URL, audio: URL) {
            self.control = control
            self.audio = audio
        }
    }

    public init(sampleRate: Double = 48_000, channelCount: Int = 2) {
        self.stereoOutputPath = StereoOutputPathPolicy.selectedPath()
        if let warning = StereoOutputPathPolicy.warningForUnknownValue() {
            FileHandle.standardError.write(Data("[Router] \(warning)\n".utf8))
        }

        let requestedBackend = ProcessInfo.processInfo
            .environment["SYNCAST_CAPTURE_BACKEND"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if requestedBackend == "tap" {
            if #available(macOS 14.2, *) {
                self.capture = TapCapture(sampleRate: sampleRate, channelCount: channelCount)
            } else {
                FileHandle.standardError.write(Data(
                    "[Router] SYNCAST_CAPTURE_BACKEND=tap requested but macOS 14.2+ is required; failing closed instead of falling back to SCK\n".utf8
                ))
                self.capture = UnavailableSystemAudioCapture(
                    backendName: "tap-unavailable",
                    reason: "Process Tap capture requires macOS 14.2 or later; refusing to fall back to ScreenCaptureKit"
                )
            }
        } else {
            if let requestedBackend, requestedBackend != "sck" {
                FileHandle.standardError.write(Data(
                    "[Router] unknown SYNCAST_CAPTURE_BACKEND=\(requestedBackend); falling back to SCK\n".utf8
                ))
            }
            self.capture = SCKCapture(sampleRate: sampleRate, channelCount: channelCount)
        }
        self.scheduler = Scheduler(sampleRate: sampleRate)
        let probeFrequencies = ActiveCalibrator.fingerprintFrequencies
            .map { String(Int($0)) }
            .joined(separator: ",")
        FileHandle.standardError.write(Data(
            "[Router] calibration probe profile=\(ActiveCalibrator.fingerprintProbeProfileName) tones=[\(probeFrequencies)] symbols=\(ActiveCalibrator.fingerprintSymbols) duration=\(ActiveCalibrator.fingerprintDurationMs)ms local_amp=\(String(format: "%.3f", ActiveCalibrator.fingerprintLocalAmplitude)) airplay_amp=\(String(format: "%.3f", ActiveCalibrator.fingerprintAirplayAmplitude))\n".utf8
        ))
        // Reap any private aggregate devices left behind by a prior crash
        // BEFORE we ever try to create one in this run. Header docs say
        // private aggregates auto-clean on process exit, but coreaudiod
        // has been observed to leak them after SIGKILL or fast user
        // switching. Sweep is keyed by the AggregateDevice.uidPrefix.
        let reaped = AggregateDevice.sweepOrphans()
        if reaped > 0 {
            // Logged as a warning so we notice in the field if SIGKILL
            // crashes start happening.
            print("[Router] swept \(reaped) orphan aggregate device(s) at init")
        }
        // Public Direct Stereo aggregates can become the macOS default
        // output. Sweep them on every launch, not only direct-mode launches,
        // so a normal fallback launch can recover after a prior SIGKILL.
        let directReaped = DirectStereoOutput.sweepOrphans()
        if directReaped > 0 {
            print("[Router] swept \(directReaped) orphan direct stereo aggregate device(s) at init")
        }
        if #available(macOS 14.2, *) {
            let tapReaped = TapCapture.sweepOrphans()
            if tapReaped > 0 {
                print("[Router] swept \(tapReaped) orphan process tap aggregate device(s) at init")
            }
        }
        // Wire the capture backend's "I died" notification into the actor.
        // Display sleep can break the active source; without this hop the
        // Router would never learn capture was gone and wake recovery would
        // rebuild a silent aggregate. We deliberately just record the event
        // here — AppModel's wake handler still drives the single restart
        // chokepoint via `forceLocalDriverRebuild`.
        capture.onUnexpectedStop = { [weak self] in
            Task { await self?.handleCaptureDied() }
        }
    }

    /// Called when the capture backend terminates on its own. We
    /// deliberately do NOT restart capture here — `forceLocalDriverRebuild`
    /// owns capture lifecycle during wake recovery, and racing it with this
    /// callback could double-start the backend or interleave with an
    /// in-flight rebuild. Logging only is sufficient: AppModel fires
    /// `forceLocalDriverRebuild` after every wake event.
    private func handleCaptureDied() {
        FileHandle.standardError.write(Data(
            "[Router] capture backend \(capture.backendName) died unexpectedly — wake handler's forceLocalDriverRebuild will restart it\n".utf8
        ))
    }

    public func attachSidecar(_ sockets: SidecarSockets) async throws {
        let client = IpcClient(socketPath: sockets.control)
        try await client.connect { method, params in
            // Notifications from sidecar: parse device latency events to
            // re-plan, and per-device connection-state events to drive
            // the UI sync dots. Other events are observed by the UI
            // layer via a separate subscription mechanism (TODO P3).
            if method == "event.measured_latency",
               let measured = params["measured_ms"] as? Int {
                Task { await self.updateAirplayLatency(measured) }
            }
            if method == "event.device_state",
               let deviceID = params["device_id"] as? String,
               let stateStr = params["state"] as? String {
                let reason = params["last_error"] as? String
                Task { await self.recordConnectionState(
                    deviceID: deviceID, stateStr: stateStr, reason: reason,
                ) }
            }
        }
        _ = try await client.call("sidecar.hello", params: ["v": 1, "router_pid": ProcessInfo.processInfo.processIdentifier])
        self.ipc = client
        let writer = AudioSocketWriter(ring: capture.ringBuffer, socketPath: sockets.audio)
        self.audioWriter = writer
    }

    public func setRouting(_ r: DeviceRouting) {
        let prior = routing[r.deviceID]
        if prior != r { routeMutationRevision &+= 1 }
        routing[r.deviceID] = r
        replan()
    }

    public func disable(deviceID: String) {
        var r = routing[deviceID] ?? DeviceRouting(deviceID: deviceID)
        let prior = r
        r.enabled = false
        if prior != r { routeMutationRevision &+= 1 }
        routing[deviceID] = r
        replan()
    }

    public func enable(deviceID: String) {
        var r = routing[deviceID] ?? DeviceRouting(deviceID: deviceID)
        let prior = r
        r.enabled = true
        if prior != r { routeMutationRevision &+= 1 }
        routing[deviceID] = r
        replan()
    }

    public func start(devices: [Device]) async throws {
        state = .starting
        do {
            // Mode-gated local driver setup. In stereo mode the capture ring
            // feeds AUHALs on enabled physical devices directly (low-latency
            // path). In direct stereo mode there is no capture at all: the
            // app temporarily makes a CoreAudio aggregate the system default
            // output so media apps render directly to hardware. In whole_home
            // mode local audio flows via the bridge chain: capture →
            // audioWriter → sidecar → OwnTone → fifo broadcaster →
            // LocalAirPlayBridge → AUHAL. The paths MUST NOT both render to
            // the same physical device — that produces double-audio at
            // different latencies (garbled). Bridges are brought up by
            // `startWholeHome(devices:)`, which the AppModel calls right after
            // `start` resolves.
            if mode == .stereo, stereoOutputPath == .direct {
                await capture.stopAndWait()
                tearDownLocalDriver()
                try reconcileDirectStereo(devices: devices, allowEmpty: false)
            } else if mode == .stereo {
                try await capture.start()
                try stopDirectStereoOutput()
                reconcileLocalDriver(devices: devices)
            } else {
                try await capture.start()
                try stopDirectStereoOutput()
                // Whole_home: ensure no stale aggregate AUHAL is left over
                // from a previous mode. tearDownLocalDriver is idempotent
                // (no-op if localOutputs is already empty + aggregate is nil).
                tearDownLocalDriver()
            }
            replan()
            state = .running
        } catch {
            state = .error
            lastError = "\(error)"
            _ = try? stopDirectStereoOutput()
            tearDownLocalDriver()
            await capture.stopAndWait()
            throw error
        }
    }

    public func stop() async {
        state = .stopping
        // 0a. Tear down the diagnostic socket listener. Cheap; safe to
        //     call even when not bound. Done first so a CLI client
        //     can't race a request against the rest of the teardown.
        stopCalibrationDiagnosticServer()
        // 0. Tear down whole-home bridges first (if any). They hold
        //    Unix sockets pointing at the sidecar and AUHALs on
        //    physical devices; both need to release before the rest of
        //    the local driver shutdown sequence.
        for (_, b) in localBridges { b.stop() }
        localBridges.removeAll()
        // 1. Stop the audio writer's send loop, but DO NOT nil it. The
        //    instance holds the ring + socket-path; .start() can reconnect
        //    cleanly on the next reconcile. Nilling this and `ipc` below
        //    is what made "toggle Xiaomi off then back on → silent
        //    forever" — subsequent setActiveAirplayDevices saw `ipc==nil`
        //    and silently returned without re-arming the AirPlay stream.
        audioWriter?.stop()
        // 2. Tell the sidecar to stop its current stream session, but
        //    KEEP the IPC connection open. The sidecar's `_on_client`
        //    finally was previously hardened to NOT shutdown OwnTone on
        //    disconnect, so this socket stays valid; closing it here
        //    forces a reconnect-from-scratch path that doesn't exist
        //    (attachSidecar is bootstrap-only).
        if let ipc = ipc {
            _ = try? await ipc.call("stream.stop", params: [:])
        }
        // 3. Tear down local AUHALs and the synchronized aggregate (if any).
        //    Strict order: stop AUHAL → Uninit + Dispose → destroy
        //    aggregate. Reversing this deadlocks coreaudiod on some macOS
        //    versions (per AggregateDevice.swift docstring + BlackHole
        //    issue tracker).
        tearDownLocalDriver()
        do {
            try stopDirectStereoOutput()
        } catch {
            lastError = "direct stereo stop failed: \(error)"
            state = .error
            return
        }
        // 4. Stop the capture stream.
        await capture.stopAndWait()
        state = .idle
    }

    /// Notify the sidecar to begin streaming, then start the audio-socket
    /// writer that pumps PCM into the sidecar.
    public func beginAirplayStream(deviceIDs: [String]) async throws {
        guard let ipc, let audioWriter else {
            throw NSError(domain: "SyncCastRouter", code: 100, userInfo: [
                NSLocalizedDescriptionKey: "sidecar not attached"
            ])
        }
        let anchorNs = Clock.nowNs() + UInt64(measuredAirplayLatencyMs) * 1_000_000
        _ = try await ipc.call("stream.start", params: [
            "device_ids": deviceIDs,
            "anchor_time_ns": Int(anchorNs),
            "sample_rate": 48_000,
            "channels": 2,
            "format": "pcm_s16le",
        ])
        try audioWriter.start()
    }

    // MARK: - Auto-calibration
    //
    // Plays brief click pulses through the live whole-home audio path
    // (capture ringBuffer → AudioSocketWriter → sidecar → both AirPlay and
    // local-bridge fan-outs) and listens via the chosen microphone to
    // measure the relative arrival time at each output. Returns the
    // ABSOLUTE TARGET (in ms) for `airplayDelayMs` (NOT a delta to add)
    // — Phase 1 local τ comes from the bridge's direct synthesis path
    // which bypasses the delay-line. See `CalibrationDelta.deltaMs`.
    //
    // Note on click injection: we write directly to `capture.ringBuffer`
    // from a Task that races with the capture backend's write thread. The ring's
    // "single-writer" invariant is technically violated, but the click
    // is a 10 ms burst once every couple seconds — even if it interleaves
    // with a capture callback, the resulting glitch is at most a single
    // chunk, recoverable, and irrelevant for cross-correlation peak
    // detection. Pausing capture for calibration would interrupt user audio,
    // which is worse UX. Acceptable for v1.
    public struct CalibrationDelta: Sendable {
        /// ABSOLUTE TARGET delay-line value in ms (NOT a delta to add).
        /// Computed as `max(airplay τ) − max(local τ)`; local τ is from
        /// the bridge's direct synthesis which bypasses the delay-line,
        /// so this is the delay-line setting to align all outputs.
        /// Field name kept for ABI stability — was wrongly interpreted
        /// as an additive delta in earlier versions.
        public let deltaMs: Int
        public let confidence: Double         // 0.0–1.0
        public let perDeviceOffsetMs: [String: Int]
        public let perDeviceConfidence: [String: Double]
        public let perDeviceUncertaintyMs: [String: Int]
    }

    public enum CalibrationFailure: Error {
        case noEnabledDevices
        case engineFailed(String)
    }

    /// Per-device sequential measurement. The previous "all devices at
    /// once" approach injected one click into the live ring and let it
    /// fan out to every enabled output simultaneously; the mic captured
    /// one merged signal, so cross-correlation found ONE peak (dominated
    /// by the loudest/closest speaker) and per-device offsets were
    /// indistinguishable. To actually distinguish "Xiaomi is fast vs
    /// PG27 is slow", we measure each device in isolation by SOLOing it:
    /// keep every enabled device's data path live (so OwnTone never
    /// rebuilds its session — disabling a receiver tears it down and
    /// triggers a multi-second mDNS rediscovery), but zero the AUDIBLE
    /// output on every device except the one being measured. AirPlay is
    /// soloed via `device.set_volume` (sidecar → OwnTone REST PUT
    /// /api/outputs/{id} with volume=0); local CoreAudio in whole-home
    /// is soloed via `bridge.setVolume(0)`, reached by setting
    /// `routing[d].muted = true` and letting `replan()` propagate.
    /// Stereo-mode local outputs follow the same `replan()` path through
    /// `LocalOutput.setRouting(muted:)`.
    public func runCalibration(
        devices: [Device],
        microphoneDeviceID: AudioDeviceID?,
        pulseCount: Int = 5,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> CalibrationDelta {
        // v4 calibration — mixed-architecture active signals.
        //
        // Pipeline:
        //   * Phase 1 (local FDM, parallel ~1.5 s): each enabled local
        //     bridge plays a unique pilot tone (1 kHz, 2 kHz, 3 kHz,
        //     4 kHz). The mic bandpasses each frequency independently
        //     and reports per-device onset time. TRUE FDM — measurements
        //     are fully parallel.
        //   * Phase 2 (AirPlay TDMA, sequential ~2.5 s/device): for each
        //     enabled AirPlay device, mute every other AirPlay output
        //     via `device.set_volume(0)`, inject a unique linear chirp
        //     into the SCK ring, cross-correlate the captured mic
        //     against the chirp template. AirPlay 2 multi-room is a
        //     single-stream architecture so per-device differentiation
        //     MUST be temporal; FDM in the AirPlay band is structurally
        //     impossible.
        //   * Phase 3: delta = max(AirPlay τ) − max(local τ). ABSOLUTE
        //     TARGET for airplayDelayMs (NOT a delta to add); see
        //     `CalibrationDelta.deltaMs` doc.
        //
        // v3 (MuteDipCalibrator, retained as fallback) modulated the
        // user's MUSIC volume in TDMA slots and cross-correlated the
        // envelope. With ambient music as the carrier, run-to-run
        // variance was ±90 ms — the chosen genre/loudness affected the
        // per-slot envelope shape too much. v4's active signals are
        // independent of the user's audio content.
        //
        // The legacy `pulseCount` parameter is ignored — Phase 1 and
        // Phase 2 timings come from `ActiveCalibrator` defaults. Body
        // delegated to `runCalibrationRaw` (also used by the continuous
        // loop) so probe-build / routing-restore plumbing is single-
        // sourced.
        _ = pulseCount

        let enabled = devices.filter { routing[$0.id]?.enabled == true }
        guard !enabled.isEmpty else { throw CalibrationFailure.noEnabledDevices }
        let enabledLocal = enabled.filter { $0.transport == .coreAudio }
        let enabledAirplay = enabled.filter { $0.transport == .airplay2 }
        guard !enabledLocal.isEmpty && !enabledAirplay.isEmpty else {
            throw CalibrationFailure.engineFailed(
                "calibration requires at least one local and one AirPlay output"
            )
        }
        let silentAirplay = enabledAirplay.filter { dev in
            let route = routing[dev.id]
            return (route?.muted ?? false) || (route?.volume ?? 1.0) <= 0.01
        }
        guard silentAirplay.isEmpty else {
            throw CalibrationFailure.engineFailed(
                "calibration requires audible AirPlay receivers; muted/zero-volume ids \(silentAirplay.map { String($0.id.prefix(8)) })"
            )
        }
        let inactiveAirplay = enabledAirplay.filter {
            !activeAirplayDeviceIDs.contains($0.id)
        }
        guard inactiveAirplay.isEmpty else {
            throw CalibrationFailure.engineFailed(
                "calibration requires active AirPlay receivers; inactive ids \(inactiveAirplay.map { String($0.id.prefix(8)) })"
            )
        }
        let disconnectedAirplay = enabledAirplay.filter { dev in
            let state = connectionStates[dev.id] ?? .unknown
            return state == .failed || state == .disconnected
        }
        guard disconnectedAirplay.isEmpty else {
            throw CalibrationFailure.engineFailed(
                "calibration requires connected AirPlay receivers; disconnected ids \(disconnectedAirplay.map { String($0.id.prefix(8)) })"
            )
        }
        progress?("Calibrating \(enabled.count) device\(enabled.count == 1 ? "" : "s") (active signals)…")
        let result = try await runCalibrationRaw(
            devices: devices, microphoneDeviceID: microphoneDeviceID
        )
        // Cache Phase-2 AirPlay group tau so the continuous loop (Phase 1
        // only) can recompute drift without re-doing the disruptive
        // mute-dip. This is deliberately a group-domain cache keyed by the
        // whole AirPlay route signature, not a per-receiver tau cache.
        if let groupTau = result.perDeviceTauMs[ActiveCalibrator.airplayGroupDeviceID],
           groupTau >= 0 {
            airplayTauCache = AirplayTauCache(
                groupTau: groupTau,
                groupConfidence: result.perDeviceConfidence[
                    ActiveCalibrator.airplayGroupDeviceID
                ] ?? result.aggregateConfidence,
                groupUncertaintyMs: result.perDeviceUncertaintyMs[
                    ActiveCalibrator.airplayGroupDeviceID
                ] ?? Int.max,
                probeProfile: ActiveCalibrator.fingerprintProbeProfileName,
                routeSignature: airplayRouteSignature(enabled: enabled),
                calibratedAt: Date()
            )
        } else {
            airplayTauCache = nil
        }
        return CalibrationDelta(
            deltaMs: result.deltaMs,
            confidence: result.aggregateConfidence,
            perDeviceOffsetMs: result.perDeviceTauMs,
            perDeviceConfidence: result.perDeviceConfidence,
            perDeviceUncertaintyMs: result.perDeviceUncertaintyMs
        )
    }

    // MARK: - Frequency-Response Sweep (diagnostic)
    //
    // Drives every enabled LOCAL bridge through a frequency sweep so the
    // operator can pick the highest frequency that still clears a target
    // SNR on the user's mic + speaker chain. Goal: enable v4+
    // calibration to choose the highest high-band probe a route can
    // support. High-band reduces audibility risk, but it is not a silent
    // guarantee on every speaker/DSP chain.
    //
    // AirPlay is intentionally NOT swept — playing different tones on
    // different AirPlay receivers requires TDMA mute/unmute (~3 s
    // overhead per device per frequency) and a more complex chirp-injection
    // path. The summary string surfaces "airplay frequency response =
    // unknown without per-device path" so the caller knows.
    public func runFrequencyResponseTest(
        devices: [Device],
        microphoneDeviceID: AudioDeviceID? = nil,
        frequencies: [Double] = [
            500, 1000, 2000, 4000, 8000, 12000, 14000,
            15000, 16000, 17000, 18000, 18500, 19000, 19500,
            20000, 21000, 22000,
        ],
        toneAmplitude: Float = 0.1,
        toneDurationMs: Int = 500
    ) async throws -> FrequencyResponseResult {
        guard Self.activeAcousticCalibrationEnabled else {
            throw CalibrationFailure.engineFailed(
                Self.activeAcousticCalibrationDisabledMessage
            )
        }
        let enabled = devices.filter { routing[$0.id]?.enabled == true }
        guard !enabled.isEmpty else { throw CalibrationFailure.noEnabledDevices }
        let bridgeSnapshot: [String: LocalAirPlayBridge] = localBridges
        var probes: [ActiveCalibrator.FrequencyResponseProbe] = []
        for dev in enabled where dev.transport == .coreAudio {
            if let bridge = bridgeSnapshot[dev.id] {
                probes.append(.init(deviceID: dev.id, bridge: bridge))
            }
        }
        guard !probes.isEmpty else {
            throw CalibrationFailure.engineFailed(
                "frequency-response sweep requires whole-home mode with at least one local bridge enabled"
            )
        }
        let calibrator = ActiveCalibrator(microphoneDeviceID: microphoneDeviceID)
        do {
            return try await calibrator.runFrequencyResponseSweep(
                probes: probes,
                frequencies: frequencies,
                toneAmplitude: toneAmplitude,
                toneDurationMs: toneDurationMs
            )
        } catch {
            if error is CancellationError { throw error }
            throw CalibrationFailure.engineFailed("\(error)")
        }
    }

    // MARK: - Calibration diagnostic socket
    //
    // Bring up / tear down the Unix-socket listener that lets
    // `scripts/calibration_test.sh` run a calibration from the CLI.
    // The provider closure supplies a snapshot (devices + mic id) at the
    // moment the request lands; we don't cache device lists in the
    // Router, so the closure is the bridge to AppModel's MainActor state.

    /// Start the diagnostic listener. Idempotent. Caller is the AppModel,
    /// which fires this after the engine is running in whole-home mode.
    /// `provider` is invoked once per request to get the live device set;
    /// returning nil signals "router not ready, reply with error".
    public func startCalibrationDiagnosticServer(
        socketPath: URL,
        provider: @escaping CalibrationDiagnosticServer.Provider,
        activeProbeMethodsEnabled: Bool = false,
        delayApplier: CalibrationDiagnosticServer.DelayApplier? = nil,
        passiveDelayApplier: CalibrationDiagnosticServer.PassiveDelayApplier? = nil,
        syncContextMarker: CalibrationDiagnosticServer.SyncContextMarker? = nil
    ) {
        if let existing = calibrationDiagnosticServer {
            if FileManager.default.fileExists(atPath: socketPath.path) {
                return
            }
            existing.stop()
            calibrationDiagnosticServer = nil
        }
        let server = CalibrationDiagnosticServer(
            socketPath: socketPath,
            provider: provider,
            passiveStatusProvider: { [weak self] in
                guard let self else {
                    return CalibrationDiagnosticServer.PassiveStatus(
                        captureBackend: "router-gone"
                    )
                }
                return await self.passiveDiagnosticStatus()
            },
            activeProbeMethodsEnabled: activeProbeMethodsEnabled,
            runner: { [weak self] snap in
                guard let self else {
                    throw CalibrationFailure.engineFailed("router gone")
                }
                let delta = try await self.runCalibration(
                    devices: snap.devices,
                    microphoneDeviceID: snap.microphoneDeviceID,
                    pulseCount: 5,
                    progress: nil
                )
                return (
                    deltaMs: delta.deltaMs,
                    confidence: delta.confidence,
                    perDeviceOffsetMs: delta.perDeviceOffsetMs,
                    perDeviceConfidence: delta.perDeviceConfidence,
                    perDeviceUncertaintyMs: delta.perDeviceUncertaintyMs
                )
            },
            freqRunner: { [weak self] snap, frequencies, toneAmplitude in
                guard let self else {
                    throw CalibrationFailure.engineFailed("router gone")
                }
                // **v7**: forward optional sweep params from the
                // diagnostic socket. Both nil ⇒ default sweep (the
                // pre-v7 behavior). Either non-nil overrides only
                // that parameter — `runFrequencyResponseTest` already
                // accepts these as defaulted parameters, so the
                // pattern below avoids duplicating its signature.
                if let frequencies, let toneAmplitude {
                    return try await self.runFrequencyResponseTest(
                        devices: snap.devices,
                        microphoneDeviceID: snap.microphoneDeviceID,
                        frequencies: frequencies,
                        toneAmplitude: Float(toneAmplitude)
                    )
                } else if let frequencies {
                    return try await self.runFrequencyResponseTest(
                        devices: snap.devices,
                        microphoneDeviceID: snap.microphoneDeviceID,
                        frequencies: frequencies
                    )
                } else if let toneAmplitude {
                    return try await self.runFrequencyResponseTest(
                        devices: snap.devices,
                        microphoneDeviceID: snap.microphoneDeviceID,
                        toneAmplitude: Float(toneAmplitude)
                    )
                } else {
                    return try await self.runFrequencyResponseTest(
                        devices: snap.devices,
                        microphoneDeviceID: snap.microphoneDeviceID
                    )
                }
            },
            delayApplier: delayApplier ?? { [weak self] ms in
                guard let self else {
                    throw CalibrationFailure.engineFailed("router gone")
                }
                return try await self.setLocalFifoDelayMs(ms)
            },
            passiveDelayApplier: passiveDelayApplier,
            passiveCaptureRunner: { [weak self] snap, durationSec, maxDelayMs, outputDirectory in
                guard let self else {
                    throw CalibrationFailure.engineFailed("router gone")
                }
                let outputURL = outputDirectory.map {
                    URL(fileURLWithPath: $0)
                }
                return try await PassiveCapture.capture(
                    captureBackend: self.capture,
                    microphoneDeviceID: snap.microphoneDeviceID,
                    durationSec: durationSec,
                    maxDelayMs: maxDelayMs,
                    outputDirectory: outputURL,
                    currentDelayMs: snap.currentDelayMs,
                    contextSignature: snap.contextSignature,
                    delayLocked: snap.delayLocked,
                    enabledAirplayCount: snap.enabledAirplayCount,
                    activeAirplayCount: snap.activeAirplayCount,
                    airplayTimingEpoch: snap.airplayTimingEpoch,
                    syncContextState: snap.syncContextState,
                    syncContextReason: snap.syncContextReason,
                    syncContextRevision: snap.syncContextRevision,
                    syncContextUpdatedUnix: snap.syncContextUpdatedUnix,
                    devices: snap.devices,
                    airplayConnectionStates: snap.airplayConnectionStates
                )
            },
            syncContextMarker: syncContextMarker
        )
        do {
            try server.start()
            calibrationDiagnosticServer = server
            FileHandle.standardError.write(Data(
                "[Router] calibration diagnostic socket bound at \(socketPath.path)\n".utf8
            ))
        } catch {
            lastError = "calibration diagnostic socket: \(error)"
        }
    }

    private func passiveDiagnosticStatus() -> CalibrationDiagnosticServer.PassiveStatus {
        CalibrationDiagnosticServer.PassiveStatus(
            captureBackend: capture.backendName,
            captureDiagnostic: capture.diagnosticReport(),
            tickCount: capture.tickCount,
            ringWritePosition: capture.ringBuffer.writePosition,
            sampleRate: capture.sampleRate,
            channelCount: capture.channelCount,
            ringCapacityFrames: capture.ringBuffer.capacityFrames
        )
    }

    /// Stop the diagnostic listener. Idempotent. Called on whole-home
    /// exit and from `Router.stop()`.
    public func stopCalibrationDiagnosticServer() {
        calibrationDiagnosticServer?.stop()
        calibrationDiagnosticServer = nil
    }

    /// Diagnostic: how many capture callbacks have been processed?
    /// Zero after a few seconds with system audio playing means the active
    /// backend is not delivering audio.
    public func diagnosticTickCount() -> UInt64 {
        capture.tickCount
    }

    public func captureBackendNameForDiagnostics() -> String {
        capture.backendName
    }

    public func airplayTimingEpochForDiagnostics() -> UInt64 {
        airplayTimingEpoch
    }

    public func noteWholeHomeTimingInstability(reason: String) {
        routeMutationRevision &+= 1
        bumpAirplayTimingEpoch(reason: "whole-home timing instability: \(reason)")
        invalidateAirplayTauCache(reason: "whole-home timing instability: \(reason)")
    }

    public func localBridgeTimingDiagnostics() -> [String: LocalBridgeTimingDiagnostic] {
        Dictionary(
            uniqueKeysWithValues: localBridges.map { id, bridge in
                (
                    id,
                    LocalBridgeTimingDiagnostic(
                        driftResyncCount: bridge.driftResyncCount,
                        driftResyncReason: bridge.lastDriftResyncReason,
                        driftResyncFrameDelta: bridge.lastDriftResyncFrameDelta
                    )
                )
            }
        )
    }

    /// Returns a one-line diagnostic snapshot of the active capture pipeline.
    public func diagnosticCaptureReport() -> String {
        var renderInfo = ""
        for (id, out) in localOutputs {
            // Aggregate driver mode keys its single LocalOutput by the
            // aggregate's UID, which starts with our well-known prefix.
            // Show "agg" + a short tail rather than the noisy prefix.
            let label: String
            if id.hasPrefix(AggregateDevice.uidPrefix) {
                label = "agg:\(id.suffix(6))"
            } else {
                label = String(id.prefix(6))
            }
            renderInfo += " render[\(label)]=ticks:\(out.renderTickCount) peak:\(String(format: "%.4f", out.lastRenderPeak))"
        }
        var awInfo = ""
        if let aw = audioWriter {
            awInfo = " airplayWriter=pkts:\(aw.packetsSent) underrun:\(aw.underrunPackets) partial:\(aw.partialSends) bytes:\(aw.bytesSent) overlays:\(aw.overlaysScheduled)/\(aw.overlayFramesMixed)/drop\(aw.overlaysDroppedLate) err:\(aw.lastSendError.isEmpty ? "none" : aw.lastSendError)"
        }
        // Driver mode: most useful in field reports — tells us instantly
        // if the kernel-level synchronized aggregate is engaged or not.
        let driverInfo: String
        if mode == .wholeHome {
            driverInfo = " driver=wholeHome(\(localBridges.count))"
        } else if let direct = directStereoOutput, direct.isActive {
            driverInfo = " driver=directStereo"
        } else if aggregateDevice != nil {
            driverInfo = " driver=aggregate(\(aggregateCoveredUIDs.count))"
        } else if !localOutputs.isEmpty {
            driverInfo = " driver=individual(\(localOutputs.count))"
        } else {
            driverInfo = " driver=idle"
        }
        // Aggregate stream-format diagnostic (Strategy 2 fix): surfaces
        // the actual channel layout so field logs make the "only one
        // speaker plays" bug unambiguous. Format:
        //   streamChannelCount=streams=1 ch=[2] total=2 master=2  (good)
        //   streamChannelCount=streams=1 ch=[4] total=4 master=2  (was bug)
        let streamInfo: String
        if let diag = aggregateStreamDiagnostic {
            streamInfo = " streamChannelCount=\(diag.summary)"
        } else {
            streamInfo = ""
        }
        // Whole-home bridges (Strategy 1): one line per active bridge
        // with packet + render counters. Empty when not in wholeHome
        // mode or no bridges are active.
        var bridgeInfo = ""
        for (id, b) in localBridges {
            bridgeInfo += " bridge[\(id.prefix(6))]=pkts:\(b.packetsReceived) ticks:\(b.renderTickCount) peak:\(String(format: "%.4f", b.lastRenderPeak)) err:\(b.lastError.isEmpty ? "none" : b.lastError)"
        }
        // Per-subdevice hardware-volume rejection counters. Surfaced
        // here because the stderr log emits ONCE per UID per session;
        // a support ticket needs to see total rejection counts for
        // any device routed through software-gain fallback (typical:
        // DP / HDMI displays).
        var hwVolInfo = ""
        for (uid, count) in aggregateHwVolumeRejectionCounts {
            hwVolInfo += " hwVolRejected[\(uid.prefix(6))]=\(count)"
        }
        let directInfo = directStereoOutput.map { " \($0.diagnostic)" } ?? ""
        return "\(capture.diagnosticReport())\(driverInfo)\(directInfo)\(streamInfo)\(renderInfo)\(awInfo)\(bridgeInfo)\(hwVolInfo)"
    }

    /// Backward-compatible wrapper for older diagnostic call sites.
    public func diagnosticSCKReport() -> String {
        diagnosticCaptureReport()
    }

    /// Reconcile the open AUHAL set against the current routing snapshot.
    /// Called whenever the user toggles a local device while the engine
    /// is already running.
    public func syncLocalOutputs(devices: [Device]) async {
        if mode == .stereo, stereoOutputPath == .direct {
            do {
                try reconcileDirectStereo(devices: devices, allowEmpty: true)
            } catch {
                lastError = "direct stereo reconcile failed: \(error)"
            }
        } else {
            reconcileLocalDriver(devices: devices)
        }
        replan()
    }

    /// Force a complete local-driver tear-down + rebuild, bypassing the
    /// `alreadyCorrect` short-circuit in `reconcileLocalDriver`. Used by
    /// `AppModel`'s sleep/wake handler when display sleep + wake invalidates
    /// the underlying AudioDeviceID for HDMI / DisplayPort sub-devices even
    /// though their `coreAudioUID` is the same — `reconcileLocalDriver`
    /// would otherwise see "same enabled UID set" and skip the rebuild,
    /// leaving the existing AggregateDevice pointing at dead AudioDeviceIDs
    /// (silent underrun, the user-reported "no sound after monitor wakes"
    /// bug). The manual workaround was deselect + reselect each device,
    /// which produced exactly this tear-down → rebuild sequence; this
    /// helper automates it.
    ///
    /// Caller is expected to have already waited ~1.5s for coreaudiod IPC
    /// to settle after the wake event; the extra 200 ms cushion below is
    /// belt-and-suspenders against tight wake-event clusters where a
    /// burst of CoreAudio device-change callbacks can still be in flight
    /// when the rebuild starts.
    /// - Returns: `true` if both the capture restart succeeded AND the
    ///   local driver was rebuilt cleanly. `false` if the capture restart
    ///   failed (caller should retry — driver is half-rebuilt without
    ///   a source, "no sound" state). Codex must-fix #3.
    public func forceLocalDriverRebuild(devices: [Device]) async -> Bool {
        if mode == .stereo, stereoOutputPath == .direct {
            FileHandle.standardError.write(Data(
                "[Router] forceLocalDriverRebuild: rebuilding direct stereo default output\n".utf8
            ))
            do {
                let stopStatus = try stopDirectStereoOutput()
                if stopStatus?.contains("user changed default") == true {
                    FileHandle.standardError.write(Data(
                        "[Router] forceLocalDriverRebuild: direct stereo rebuild skipped because user changed default output\n".utf8
                    ))
                    replan()
                    return true
                }
                try reconcileDirectStereo(devices: devices, allowEmpty: false)
                replan()
                FileHandle.standardError.write(Data(
                    "[Router] forceLocalDriverRebuild: direct stereo rebuild OK\n".utf8
                ))
                return true
            } catch {
                lastError = "direct stereo rebuild failed: \(error)"
                FileHandle.standardError.write(Data(
                    "[Router] forceLocalDriverRebuild: direct stereo rebuild failed — \(error.localizedDescription)\n".utf8
                ))
                return false
            }
        }
        FileHandle.standardError.write(Data(
            "[Router] forceLocalDriverRebuild: tearing down + rebuilding (incl. capture backend \(capture.backendName))\n".utf8
        ))
        // 1. Tear down the local driver (aggregate device + any AUHALs).
        tearDownLocalDriver()

        // 2. Stop + restart the capture stream.
        //
        //    Display sleep is observed to break the source stream. Before
        //    Round 12 the Router rebuilt only the aggregate + AUHAL —
        //    perfectly silent because no source was feeding the new ring.
        //    Field log
        //    (~/Library/Logs/SyncCast/launch.log, 2026-04-28 21:25:27)
        //    shows zero capture report lines for 75 s after wake until the
        //    user manually deselected + reselected each device, which
        //    routed through `start()` and triggered `capture.start()`.
        //    We replicate that restart here.
        await capture.stopAndWait()
        try? await Task.sleep(nanoseconds: 200_000_000)  // 200 ms cushion
        var captureOK = false
        do {
            try await capture.start()
            captureOK = true
            FileHandle.standardError.write(Data(
                "[Router] forceLocalDriverRebuild: capture restart OK (\(capture.backendName))\n".utf8
            ))
        } catch {
            FileHandle.standardError.write(Data(
                "[Router] forceLocalDriverRebuild: capture restart failed (\(capture.backendName)) — \(error.localizedDescription)\n".utf8
            ))
        }

        // 3. Rebuild the local driver against the post-wake device snapshot.
        //    We always do this even if capture failed — the new aggregate is
        //    correctly wired and the next wake-handler retry can attempt
        //    capture restart again without re-tearing the driver.
        reconcileLocalDriver(devices: devices)
        replan()
        return captureOK
    }

    // MARK: - Whole-home AirPlay mode (Strategy 1)
    //
    // Two public entry points the menubar app drives:
    //
    //   setMode(_:)         — round-trip the mode change with the
    //                          sidecar via `mode.set`. Tearing down
    //                          existing local bridges happens here so
    //                          the SCK driver path is clean before any
    //                          subsequent stereo `start(devices:)`.
    //
    //   startWholeHome(devices:) — for each enabled local CoreAudio
    //                          device in `devices`, open one
    //                          LocalAirPlayBridge against the sidecar's
    //                          broadcast socket.
    //
    // The two are separate because the menubar may want to set the mode
    // FIRST (so OwnTone has time to spin up) and bring the bridges up
    // only after the user has chosen which devices participate.

    /// Tell the sidecar to switch data planes, and synchronize our
    /// local state with the result. The two paths are mutually
    /// exclusive — in stereo mode only the SCK→AUHAL aggregate runs;
    /// in whole_home mode only LocalAirPlayBridge instances run.
    /// Allowing both to render to the same physical device produces
    /// double-audio at different latencies (garbled). To make the
    /// invariant impossible to violate, this function fully tears down
    /// whichever path belongs to the OPPOSITE mode before the new mode
    /// can come up via `start(devices:)` / `startWholeHome(devices:)`.
    public func setMode(_ newMode: Mode) async {
        guard let ipc else {
            lastError = "ipc not attached, cannot set mode"
            return
        }
        if newMode != mode {
            routeMutationRevision &+= 1
            bumpAirplayTimingEpoch(reason: "mode changed to \(newMode.rawValue)")
            invalidateAirplayTauCache(reason: "mode changed to \(newMode.rawValue)")
        }
        do {
            _ = try await ipc.call("mode.set", params: ["mode": newMode.rawValue])
        } catch {
            lastError = "mode.set(\(newMode.rawValue)): \(error)"
            return
        }
        // Mode change accepted by sidecar. Local cleanup — drop the
        // OPPOSITE mode's audio path so the two never render to the
        // same physical device simultaneously.
        switch newMode {
        case .stereo:
            // Going to stereo: kill every bridge. They're useless
            // without the sidecar broadcaster on the other end, and
            // leaving them running while the SCK→aggregate path is
            // about to come up would double-play. Also drop the
            // calibration diagnostic socket — calibration is a
            // whole-home feature and the socket file would be stale.
            stopCalibrationDiagnosticServer()
            for (_, b) in localBridges { b.stop() }
            localBridges.removeAll()
        case .wholeHome:
            // Going to whole_home: tear down the SCK→aggregate path.
            // Otherwise reconcileEngineAsync's running-true→wholeHome
            // arm could leave the aggregate AUHAL rendering at the
            // same time the bridges spin up (Symptom 2 in the field
            // report — `driver=wholeHome(2)` AND `render[agg:…]`
            // ticking concurrently).
            tearDownLocalDriver()
            do {
                try stopDirectStereoOutput()
            } catch {
                lastError = "mode.set(\(newMode.rawValue)): direct stereo stop failed: \(error)"
                return
            }
        }
        // Stash the new mode AFTER the IPC succeeds so a failed call
        // doesn't lie about our state.
        self.mode = newMode
    }

    /// Open `LocalAirPlayBridge` instances for every enabled local
    /// CoreAudio device in `devices`. The bridge connects to the
    /// sidecar's broadcast socket and renders OwnTone's player-clock
    /// PCM through AUHAL on the device.
    ///
    /// Preconditions:
    ///   * `setMode(.wholeHome)` has already returned successfully.
    ///   * The IPC connection is up (otherwise we cannot resolve the
    ///     broadcast socket path).
    ///
    /// Idempotent: re-calling with the same `devices` is a no-op for
    /// existing bridges. Devices not enabled or not local-CoreAudio are
    /// skipped silently. Devices that USED to have a bridge but are no
    /// longer enabled get their bridge stopped + removed.
    public func startWholeHome(devices: [Device]) async {
        guard mode == .wholeHome else {
            lastError = "startWholeHome called outside whole_home mode"
            return
        }
        guard let ipc else {
            lastError = "ipc not attached, cannot start whole_home"
            return
        }
        // Resolve the broadcast socket path once per session.
        if localFifoSocketPath == nil {
            do {
                let any = try await ipc.call("local_fifo.path", params: [:])
                if let dict = any as? [String: Any],
                   let pathStr = dict["socket_path"] as? String {
                    localFifoSocketPath = URL(fileURLWithPath: pathStr)
                } else {
                    lastError = "local_fifo.path returned malformed result"
                    return
                }
            } catch {
                lastError = "local_fifo.path failed: \(error)"
                return
            }
        }
        guard let socketURL = localFifoSocketPath else { return }

        // Build the target set of (deviceID, uid) tuples from `devices`,
        // honouring the same "enabled and local-coreaudio" predicate as
        // reconcileLocalDriver. We deliberately do NOT filter out our
        // own private aggregates here — in whole-home mode we don't use
        // them, but if the user has a third-party aggregate they want
        // to drive, that's fine.
        struct Target { let deviceID: String; let uid: String; let name: String }
        let targets: [Target] = devices.compactMap { dev in
            guard dev.transport == .coreAudio else { return nil }
            guard routing[dev.id]?.enabled ?? false else { return nil }
            guard let uid = dev.coreAudioUID else { return nil }
            // Skip our own private aggregates — they're an artifact of
            // stereo mode's reconciliation and would re-open the SCK
            // driver path, defeating the purpose.
            if uid.hasPrefix(AggregateDevice.uidPrefix) { return nil }
            if uid.hasPrefix(DirectStereoOutput.uidPrefix) { return nil }
            // Same blackhole filter as stereo mode — never route audio
            // back into the loopback source.
            if dev.name.lowercased().contains("blackhole") { return nil }
            return Target(deviceID: dev.id, uid: uid, name: dev.name)
        }
        let targetIDs = Set(targets.map { $0.deviceID })

        // Tear down bridges that are no longer in the target set.
        for (id, b) in localBridges where !targetIDs.contains(id) {
            b.stop()
            localBridges.removeValue(forKey: id)
            noteWholeHomeTimingInstability(
                reason: "local bridge removed \(id.prefix(8))"
            )
        }

        // Bring up bridges for new targets. Even when a bridge already
        // exists, re-resolve its coreAudioUID: display sleep / replug can
        // preserve the stable UID while replacing the transient AudioDeviceID.
        for t in targets {
            // Resolve UID -> AudioObjectID. Failure here is per-device,
            // not fatal for the whole call. If an old bridge exists, stop it:
            // continuing to render into a stale AudioDeviceID is worse than a
            // visible per-device error.
            let coreAudioID: AudioObjectID
            do {
                coreAudioID = try Capture.deviceID(forUID: t.uid)
            } catch {
                if let existing = localBridges.removeValue(forKey: t.deviceID) {
                    existing.stop()
                }
                lastError = "bridge: device \(t.name) not found: \(error)"
                continue
            }
            guard coreAudioID != 0 else {
                if let existing = localBridges.removeValue(forKey: t.deviceID) {
                    existing.stop()
                }
                lastError = "bridge: device \(t.name) resolved to id 0"
                continue
            }
            if let existing = localBridges[t.deviceID] {
                if existing.deviceID == coreAudioID { continue }
                existing.stop()
                localBridges.removeValue(forKey: t.deviceID)
                noteWholeHomeTimingInstability(
                    reason: "local bridge rebuilt \(t.name)"
                )
                FileHandle.standardError.write(Data(
                    "[Router] bridge: rebuilt \(t.name) after AudioDeviceID changed \(existing.deviceID) -> \(coreAudioID)\n".utf8
                ))
            }
            let bridge = LocalAirPlayBridge(
                deviceID: coreAudioID,
                deviceUID: t.uid,
                socketPath: socketURL
            )
            // Seed the bridge with the user's current slider value so a
            // device that comes up MID-session (e.g. enabled while the
            // user already moved the slider for a different device)
            // doesn't briefly play at full volume before the next
            // replan() snaps it to the right level.
            let r = routing[t.deviceID] ?? DeviceRouting(deviceID: t.deviceID)
            bridge.setVolume(r.muted ? 0 : r.volume)
            do {
                try bridge.start()
                localBridges[t.deviceID] = bridge
                noteWholeHomeTimingInstability(
                    reason: "local bridge started \(t.name)"
                )
            } catch {
                lastError = "bridge \(t.name) start failed: \(error)"
            }
        }
    }

    // MARK: - Local driver reconciliation
    //
    // The core decision: how do we drive the user's enabled CoreAudio
    // outputs? Two modes:
    //
    //   .individual  — count == 1. Open one AUHAL on the physical device.
    //                  No aggregate; no SRC; lowest possible latency.
    //
    //   .aggregate   — count >= 2. Create a private CoreAudio Aggregate
    //                  Device with all enabled outputs as subdevices, drift
    //                  correction enabled on all non-master subdevices, and
    //                  open ONE AUHAL on the aggregate. The kernel handles
    //                  per-device sync with continuous SRC tuning. This is
    //                  the only way to get sub-sample-accurate alignment
    //                  between independent physical outputs (e.g. MBP
    //                  built-in speaker + a DisplayPort monitor).
    //
    // count == 0 ⇒ tear everything down; the engine itself will be stopped
    // by the AppModel reconciler one rung up.
    //
    // Transitions are "tear down then build up" rather than "patch the
    // existing driver in place" — patching adds complexity for marginal
    // benefit (a few ms of silence during transition, well under the
    // user-perceptible threshold for a UI toggle).
    private func directStereoTargets(devices: [Device]) -> [DirectStereoOutput.Target] {
        devices.compactMap { dev in
            guard dev.transport == .coreAudio else { return nil }
            guard routing[dev.id]?.enabled ?? false else { return nil }
            guard let uid = dev.coreAudioUID else { return nil }
            let lower = dev.name.lowercased()
            if lower.contains("blackhole") { return nil }
            guard DirectStereoOutput.isOrdinaryOutputUID(uid) else { return nil }
            return DirectStereoOutput.Target(uid: uid, name: dev.name)
        }
    }

    private func reconcileDirectStereo(devices: [Device], allowEmpty: Bool) throws {
        let targets = directStereoTargets(devices: devices)
        guard !targets.isEmpty else {
            try stopDirectStereoOutput()
            if allowEmpty {
                return
            }
            throw DirectStereoOutput.DirectStereoError.noTargets
        }
        let direct = directStereoOutput ?? DirectStereoOutput()
        try direct.reconcile(targets: targets)
        directStereoOutput = direct
        FileHandle.standardError.write(Data(
            "[Router] direct stereo active: \(direct.diagnostic)\n".utf8
        ))
    }

    @discardableResult
    private func stopDirectStereoOutput() throws -> String? {
        guard let direct = directStereoOutput else { return nil }
        guard direct.stop() else {
            let status = direct.lastStopStatusText ?? direct.diagnostic
            FileHandle.standardError.write(Data(
                "[Router] direct stereo stop failed: \(status) \(direct.diagnostic)\n".utf8
            ))
            throw DirectStereoOutput.DirectStereoError.stopFailed(status)
        }
        let status = direct.lastStopStatusText
        FileHandle.standardError.write(Data(
            "[Router] direct stereo stopped: \(status ?? "unknown")\n".utf8
        ))
        directStereoOutput = nil
        return status
    }

    private func reconcileLocalDriver(devices: [Device]) {
        // Index name lookups so master picker can score by device name.
        var nameByUID: [String: String] = [:]
        for dev in devices {
            if let u = dev.coreAudioUID { nameByUID[u] = dev.name }
        }

        // Compute the target enabled set: every CoreAudio device that the
        // user has toggled on, minus a few classes that are unsafe to
        // route into:
        //   - BlackHole (it's a virtual sink that may be the system source
        //     for SCK capture; routing audio TO it could feedback)
        //   - any of OUR previously-spawned aggregates (UID prefix match)
        //
        // We deliberately DO NOT exclude user-created aggregates from
        // Audio MIDI Setup any more. With our own private aggregate now
        // a first-class concept, blanket-filtering aggregates would
        // surprise users who set one up themselves.
        let enabled: [EnabledLocalOutput] = devices.compactMap { dev in
            guard dev.transport == .coreAudio else { return nil }
            guard routing[dev.id]?.enabled ?? false else { return nil }
            guard let uid = dev.coreAudioUID else { return nil }
            if uid.hasPrefix(AggregateDevice.uidPrefix) { return nil }
            if uid.hasPrefix(DirectStereoOutput.uidPrefix) { return nil }
            let lower = dev.name.lowercased()
            if lower.contains("blackhole") { return nil }
            return EnabledLocalOutput(deviceID: dev.id, uid: uid, name: dev.name)
        }
        let targetUIDs = Set(enabled.map { $0.uid })

        switch enabled.count {
        case 0:
            tearDownLocalDriver()
        case 1:
            // Switch to individual mode if we aren't already covering
            // exactly this single device.
            let only = enabled[0]
            let alreadyCorrect =
                aggregateDevice == nil &&
                localOutputs.count == 1 &&
                localOutputs.keys.first == only.deviceID
            if !alreadyCorrect {
                tearDownLocalDriver()
                openIndividualAUHAL(deviceID: only.deviceID, uid: only.uid, name: only.name)
            }
        default:
            // Switch to aggregate mode if we aren't already covering
            // exactly this set.
            let alreadyCorrect =
                aggregateDevice != nil &&
                aggregateCoveredUIDs == targetUIDs
            if !alreadyCorrect {
                tearDownLocalDriver()
                openAggregateAUHAL(enabled: enabled, nameByUID: nameByUID)
            }
        }
    }

    private func openIndividualAUHAL(deviceID: String, uid: String, name: String) {
        guard let coreAudioID = try? Capture.deviceID(forUID: uid),
              coreAudioID != 0 else {
            lastError = "device \(name) not found in CoreAudio"
            return
        }
        let out = LocalOutput(
            deviceID: coreAudioID, deviceUID: uid,
            ring: capture.ringBuffer,
            sampleRate: capture.sampleRate,
            channelCount: capture.channelCount
        )
        do {
            try out.start()
            localOutputs[deviceID] = out
        } catch {
            lastError = "open \(name) failed: \(error)"
        }
    }

    private func openAggregateAUHAL(
        enabled: [EnabledLocalOutput],
        nameByUID: [String: String]
    ) {
        let candidateUIDs = Set(enabled.map { $0.uid })
        guard let masterUID = AggregateDevice.pickMaster(
            candidateUIDs: candidateUIDs, deviceNames: nameByUID
        ) else {
            lastError = "could not pick master device for aggregate"
            return
        }
        let slaveUIDs = enabled.map { $0.uid }.filter { $0 != masterUID }

        let agg: AggregateDevice
        do {
            agg = try AggregateDevice(masterUID: masterUID, slaveUIDs: slaveUIDs)
        } catch {
            lastError = "aggregate create failed: \(error). Falling back to first-only."
            // Recovery: drive only the master device individually so we
            // still produce SOME audio. Drift between physical speakers
            // returns, but silence is worse.
            if let master = enabled.first(where: { $0.uid == masterUID }) {
                openIndividualAUHAL(deviceID: master.deviceID, uid: master.uid, name: master.name)
            }
            return
        }

        // Diagnose the aggregate's actual output-stream layout BEFORE
        // opening AUHAL. This reads kAudioDevicePropertyStreamConfiguration
        // and lets us correlate AUHAL's mChannelsPerFrame=2 against the
        // aggregate's real channel count. If they mismatch (e.g. 4 ch
        // because the kernel exposed both subdevices' channels via one
        // stream), only the first 2 channels get audio and the second
        // physical speaker is silent — the user-reported bug.
        let diag = agg.diagnoseStreamConfig()
        // stderr — Router has no SyncCastLog dependency.
        FileHandle.standardError.write(Data(
            "[Router] aggregate stream diag: \(diag.summary) outputCh=\(agg.outputChannelCount)\n".utf8
        ))
        aggregateStreamDiagnostic = diag

        // AUHAL is configured for the aggregate's REAL channel count.
        // If approach (A) succeeded in narrowing every stream to 2-ch,
        // outputChannelCount == 2 and render() emits a clean stereo pair.
        // If (A) was rejected and outputChannelCount is wider (typically
        // 2*subdeviceCount), render() splats the source stereo into
        // every channel pair so all subdevices play.
        let out = LocalOutput(
            deviceID: agg.deviceID, deviceUID: agg.aggregateUID,
            ring: capture.ringBuffer,
            sampleRate: capture.sampleRate,
            channelCount: capture.channelCount,
            outputChannelCount: agg.outputChannelCount
        )
        do {
            try out.start()
            // Verify drift correction got applied (Apple Silicon has been
            // observed to silently downgrade quality under low-power).
            // This is read-only; doesn't fix it, but logs let us notice.
            let drift = agg.verifyDriftCorrection()
            let off = drift.filter { $0.key != masterUID && !$0.value.enabled }
            if !off.isEmpty {
                lastError = "aggregate built but drift OFF for: \(off.keys.joined(separator: ","))"
            }
            aggregateDevice = agg
            aggregateCoveredUIDs = candidateUIDs
            // Build the SyncCast-id → UID map needed by replan() to
            // apply per-device hardware volume.
            var idToUID: [String: String] = [:]
            for e in enabled { idToUID[e.deviceID] = e.uid }
            aggregateUIDByDeviceID = idToUID
            // Key the AUHAL by the aggregate UID so diagnostic dumps and
            // setRouting iteration can find it without confusing it with
            // a per-device entry.
            localOutputs[agg.aggregateUID] = out
        } catch {
            lastError = "AUHAL on aggregate failed: \(error)"
            agg.destroy()
        }
    }

    /// Strict teardown order: stop every AUHAL first (synchronously waits
    /// for the in-flight render block to drain), then destroy the
    /// aggregate. Reversing this deadlocks coreaudiod on some macOS
    /// versions — observed in BlackHole's issue tracker and confirmed by
    /// our own crash report at the toggle-off path.
    private func tearDownLocalDriver() {
        for (_, out) in localOutputs { out.stop() }
        localOutputs.removeAll()
        if let agg = aggregateDevice {
            agg.destroy()
            aggregateDevice = nil
        }
        aggregateCoveredUIDs = []
        aggregateUIDByDeviceID.removeAll()
        aggregateStreamDiagnostic = nil
        // Per-session caches that only make sense for the now-defunct
        // aggregate. A re-plug of a device gets a fresh probe; the
        // count of past rejections doesn't survive teardown either,
        // so the diagnostic report reflects only the current session's
        // active aggregate.
        loggedHwVolumeRejectionUIDs.removeAll()
        aggregateHwVolumeRejectionCounts.removeAll()
        aggregateHwVolumeUnsupportedUIDs.removeAll()
    }

    /// Record a per-device connection-state event from the sidecar.
    /// Called from the IPC notification handler closure (off-actor)
    /// via a `Task { await ... }` hop, so it lands inside the actor.
    ///
    /// Translates the sidecar's wire `state` string into a
    /// `DeviceConnectionState`. The legacy `streaming` and `added`
    /// states are mapped to `.unknown` so they don't override a fresh
    /// `connecting` / `connected` flag — the UI cares about the
    /// receiver-wiring lifecycle, not the internal stream lifecycle.
    public func recordConnectionState(
        deviceID: String, stateStr: String, reason: String?,
    ) {
        let state: DeviceConnectionState
        switch stateStr {
        case "connecting", "connected", "failed", "disconnected":
            state = .fromWire(stateStr)
        default:
            // legacy / informational states (added, streaming): leave
            // any prior wiring-state untouched and ignore this event.
            return
        }
        let previousState = connectionStates[deviceID]
        connectionStates[deviceID] = state
        if Self.airplayConnectionEventInvalidatesTiming(
            previous: previousState,
            next: state,
            isActiveAirplay: activeAirplayDeviceIDs.contains(deviceID)
        ) {
            routeMutationRevision &+= 1
            let transition = "\(previousState?.rawValue ?? "unknown") -> \(state.rawValue)"
            bumpAirplayTimingEpoch(
                reason: "connection state for \(deviceID.prefix(8)) changed "
                    + transition
            )
            invalidateAirplayTauCache(
                reason: "connection state for \(deviceID.prefix(8)) changed \(transition)"
            )
        }
        if state == .failed, let reason = reason {
            connectionFailureReasons[deviceID] = reason
        } else if state != .failed {
            connectionFailureReasons.removeValue(forKey: deviceID)
        }
    }

    /// Query the most recent connection state for a single device.
    /// Returns `.unknown` if no event has been received for it yet.
    public func connectionState(deviceID: String) -> DeviceConnectionState {
        connectionStates[deviceID] ?? .unknown
    }

    /// Snapshot the entire connection-state map (states + failure
    /// reasons) for the UI poll loop. Returned as plain Sendable
    /// dictionaries so MainActor consumers can copy them off-actor.
    public func connectionStatesSnapshot() -> (
        states: [String: DeviceConnectionState],
        reasons: [String: String]
    ) {
        (connectionStates, connectionFailureReasons)
    }

    public func updateAirplayLatency(_ measuredMs: Int) {
        if abs(measuredMs - measuredAirplayLatencyMs) > 20 {
            let previous = measuredAirplayLatencyMs
            measuredAirplayLatencyMs = measuredMs
            routeMutationRevision &+= 1
            bumpAirplayTimingEpoch(
                reason: "sidecar measured latency changed \(previous)ms -> \(measuredMs)ms"
            )
            invalidateAirplayTauCache(
                reason: "sidecar measured latency changed to \(measuredMs)ms"
            )
            replan()
        }
    }

    private func invalidateAirplayTauCache(reason: String) {
        guard airplayTauCache != nil else { return }
        airplayTauCache = nil
        FileHandle.standardError.write(Data(
            "[Router] airplay calibration cache invalidated: \(reason)\n".utf8
        ))
    }

    private func bumpAirplayTimingEpoch(reason: String) {
        airplayTimingEpoch &+= 1
        FileHandle.standardError.write(Data(
            "[Router] AirPlay timing epoch \(airplayTimingEpoch): \(reason)\n".utf8
        ))
    }

    private func airplayRouteSignature(enabled devices: [Device]) -> String {
        devices
            .filter { $0.transport == .airplay2 && (routing[$0.id]?.enabled ?? false) }
            .map { dev -> String in
                let volume = routing[dev.id]?.volume ?? 1.0
                let volumeBucket = Int((volume * 100).rounded())
                let muted = routing[dev.id]?.muted ?? false
                let host = dev.host ?? ""
                let port = dev.port ?? 0
                return "\(dev.id)|\(host)|\(port)|v\(volumeBucket)|m\(muted ? 1 : 0)"
            }
            .sorted()
            .joined(separator: ";")
    }

    /// Tell the sidecar about an AirPlay 2 device. Idempotent — re-adding
    /// the same device is a no-op on the sidecar side (returns
    /// `device_id already exists`, which we swallow).
    public func registerAirplayDevice(id: String, name: String, host: String, port: Int) async {
        guard let ipc else {
            lastError = "ipc not attached, cannot register \(name)"
            return
        }
        let endpoint = "\(name)|\(host)|\(port)"
        if registeredAirplayEndpointsByID[id] != endpoint {
            routeMutationRevision &+= 1
            bumpAirplayTimingEpoch(
                reason: "AirPlay endpoint changed for \(id.prefix(8))"
            )
            invalidateAirplayTauCache(
                reason: "AirPlay receiver registered/updated \(id.prefix(8))"
            )
            registeredAirplayEndpointsByID[id] = endpoint
        }
        do {
            _ = try await ipc.call("device.add", params: [
                "device_id": id,
                "transport": "airplay2",
                "host": host,
                "port": port,
                "name": name,
            ])
        } catch let IpcClient.IpcError.rpcError(code, message) {
            // -32602 INVALID_PARAMS / "device_id already exists" is benign
            if code != -32602 {
                lastError = "device.add(\(name)): \(code) \(message)"
            }
        } catch {
            lastError = "device.add(\(name)): \(error)"
        }
    }

    /// Set per-device volume for an AirPlay device on the sidecar.
    public func setAirplayVolume(id: String, volume: Float) async {
        await setAirplayVolume(id: id, volume: volume, invalidatesTiming: true)
    }

    private func setAirplayVolume(
        id: String,
        volume: Float,
        invalidatesTiming: Bool
    ) async {
        let clamped = max(0, min(1, volume))
        if Self.airplayVolumeChangeInvalidatesTiming(
            previous: lastAirplayVolumeByID[id],
            next: clamped,
            invalidatesTiming: invalidatesTiming
        ) {
            let old = lastAirplayVolumeByID[id] ?? clamped
            routeMutationRevision &+= 1
            bumpAirplayTimingEpoch(
                reason: "AirPlay volume changed for \(id.prefix(8)) "
                    + "\(String(format: "%.2f", old)) -> "
                    + "\(String(format: "%.2f", clamped))"
            )
            invalidateAirplayTauCache(
                reason: "AirPlay volume changed for \(id.prefix(8)) \(String(format: "%.2f", old)) -> \(String(format: "%.2f", clamped))"
            )
        }
        lastAirplayVolumeByID[id] = clamped
        guard let ipc else { return }
        do {
            _ = try await ipc.call("device.set_volume", params: [
                "device_id": id,
                "volume": Double(clamped),
            ])
        } catch {
            lastError = "set_volume(\(id.prefix(8))): \(error)"
        }
    }

    /// Enabled AirPlay device IDs that should be in the active stream.
    /// Calling this with an empty list stops the AirPlay stream.
    public func setActiveAirplayDevices(_ ids: [String]) async {
        guard let ipc else {
            lastError = "ipc not attached, cannot start AirPlay stream"
            return
        }
        let requestedIDs = Set(ids)
        let activeSetChanged = requestedIDs != activeAirplayDeviceIDs
        if activeSetChanged {
            routeMutationRevision &+= 1
            bumpAirplayTimingEpoch(
                reason: "AirPlay active set changed "
                    + "\(activeAirplayDeviceIDs.map { String($0.prefix(8)) }) -> "
                    + "\(requestedIDs.map { String($0.prefix(8)) })"
            )
            invalidateAirplayTauCache(
                reason: "AirPlay active set changed \(activeAirplayDeviceIDs.map { String($0.prefix(8)) }) -> \(requestedIDs.map { String($0.prefix(8)) })"
            )
            activeAirplayDeviceIDs = requestedIDs
        }
        // Mode-specific empty-list handling.
        //
        // .stereo:    no AirPlay devices means we don't need OwnTone running
        //             at all — stop the stream and the writer.
        // .wholeHome: even with ZERO AirPlay receivers selected, OwnTone's
        //             player must keep running so its `fifo` output writes
        //             PCM into output.fifo for the local LocalAirPlayBridge
        //             instances. Stopping the stream here would silence
        //             every local speaker — observed user-reported bug:
        //             "在全屋模式下只选 MBP+显示器也没声音".
        if ids.isEmpty {
            if mode == .wholeHome {
                // Tell sidecar "no AirPlay receivers selected" but keep
                // the stream itself active. start_stream now accepts an
                // empty device_ids list in whole-home mode and disables
                // every AirPlay output while leaving fifo + audio reader
                // running.
                let anchor = Clock.nowNs() + UInt64(measuredAirplayLatencyMs) * 1_000_000
                let response = try? await ipc.call("stream.start", params: [
                    "device_ids": ids,
                    "anchor_time_ns": Int(anchor),
                    "sample_rate": 48_000,
                    "channels": 2,
                    "format": "pcm_s16le",
                ])
                if let response,
                   !activeSetChanged,
                   !Self.streamStartResponseIndicatesNoop(response) {
                    routeMutationRevision &+= 1
                    bumpAirplayTimingEpoch(
                        reason: "AirPlay stream restarted for unchanged active set []"
                    )
                    invalidateAirplayTauCache(
                        reason: "AirPlay stream restarted for unchanged active set"
                    )
                }
                do {
                    try audioWriter?.start()
                } catch {
                    lastError = "audioWriter.start failed: \(error)"
                }
                return
            }
            _ = try? await ipc.call("stream.stop", params: [:])
            audioWriter?.stop()
            return
        }
        let anchor = Clock.nowNs() + UInt64(measuredAirplayLatencyMs) * 1_000_000
        let response: Any
        do {
            response = try await ipc.call("stream.start", params: [
                "device_ids": ids,
                "anchor_time_ns": Int(anchor),
                "sample_rate": 48_000,
                "channels": 2,
                "format": "pcm_s16le",
            ])
        } catch {
            lastError = "stream.start failed: \(error)"
            return
        }
        if !activeSetChanged,
           !Self.streamStartResponseIndicatesNoop(response) {
            routeMutationRevision &+= 1
            bumpAirplayTimingEpoch(
                reason: "AirPlay stream restarted for unchanged active set "
                    + "\(requestedIDs.map { String($0.prefix(8)) })"
            )
            invalidateAirplayTauCache(
                reason: "AirPlay stream restarted for unchanged active set"
            )
        }
        do {
            try audioWriter?.start()
        } catch {
            lastError = "audioWriter.start failed: \(error)"
        }
    }

    private func replan() {
        var latencies: [Scheduler.DeviceLatency] = []
        for (id, _) in localOutputs {
            latencies.append(.init(deviceID: id, transport: .coreAudio, measuredMs: 12))
        }
        for (id, r) in routing where r.enabled && localOutputs[id] == nil {
            latencies.append(.init(deviceID: id, transport: .airplay2, measuredMs: measuredAirplayLatencyMs))
        }
        let trims = Dictionary(uniqueKeysWithValues: routing.compactMapValues { $0.manualDelayMs }
            .map { ($0.key, $0.value) })
        let plans = scheduler.plan(latencies: latencies, manualTrimMs: trims)
        for plan in plans {
            guard let out = localOutputs[plan.deviceID] else { continue }
            let r = routing[plan.deviceID] ?? DeviceRouting(deviceID: plan.deviceID)
            out.setRouting(
                readBackoffFrames: plan.readBackoffFrames,
                gain: r.volume,
                muted: r.muted
            )
        }

        // In aggregate mode, also apply per-device HARDWARE volume on
        // the underlying physical DACs. The single AUHAL atop the
        // aggregate cannot natively do this — it sees one stream and
        // applies gain uniformly to every subdevice. Hardware volume
        // bypasses the AUHAL entirely … but only on devices whose
        // CoreAudio driver actually exposes
        // `kAudioDevicePropertyVolumeScalar` as writable.
        //
        // DP / HDMI display speakers (the user's PG27UCDM is the
        // canonical example) DO NOT — there's no hardware path to
        // control their output level, the user must use the OSD.
        // For those, we fall back to per-channel-pair software gain
        // applied at the AUHAL render layer: the splat already writes
        // the source stereo into every output pair, so attenuating
        // just the display's pair (e.g. channels 2..3 with master at
        // channels 0..1) gives the user a working slider without
        // touching the master's volume. This is digital attenuation,
        // so very low values lose effective bit depth — that's the
        // documented quality trade-off the user implicitly accepts
        // by using a monitor speaker.
        if let agg = aggregateDevice,
           let aggOut = localOutputs[agg.aggregateUID] {
            for (devID, uid) in aggregateUIDByDeviceID {
                let r = routing[devID] ?? DeviceRouting(deviceID: devID)
                let target = r.muted ? Float(0) : r.volume
                applyAggregateSubdeviceVolume(
                    aggregate: agg,
                    aggregateOutput: aggOut,
                    deviceID: devID,
                    uid: uid,
                    target: target
                )
            }
        }

        // Whole-home mode: push the user's slider to each per-bridge
        // software gain. Hardware-volume control on DP / HDMI display
        // speakers (e.g. PG27UCDM) is unavailable for the same reason
        // it's unavailable in stereo mode — the device exposes no
        // writable VolumeScalar. The bridge's render callback applies
        // the gain digitally to every Float32 sample it writes to
        // AUHAL. Without this loop the slider would silently no-op
        // for any bridge-driven device (the user-reported regression).
        for (devID, bridge) in localBridges {
            let r = routing[devID] ?? DeviceRouting(deviceID: devID)
            let target = r.muted ? Float(0) : r.volume
            bridge.setVolume(target)
        }
    }

    /// Apply the user's slider value to one subdevice of the active
    /// aggregate. Tries hardware volume first; on rejection (or on a
    /// device that's known unsupported from a prior probe) routes
    /// through the per-channel-pair software gain on the aggregate's
    /// AUHAL.
    ///
    /// The "known unsupported" cache short-circuits the slow CoreAudio
    /// probe loop on every replan — without it, every slider drag
    /// would re-walk 32 elements for the display before falling back,
    /// which is a several-ms-per-frame UI hitch.
    private func applyAggregateSubdeviceVolume(
        aggregate: AggregateDevice,
        aggregateOutput: LocalOutput,
        deviceID: String,
        uid: String,
        target: Float
    ) {
        // Fast-path: we already know this device's hardware volume
        // is unsupported. Skip the CoreAudio call entirely.
        let knownUnsupported =
            aggregateHwVolumeUnsupportedUIDs.contains(uid) ||
            AggregateDevice.isHardwareVolumeKnownUnsupported(uid: uid)
        let hwOk: Bool
        if knownUnsupported {
            hwOk = false
        } else {
            hwOk = aggregate.setSubdeviceVolume(uid: uid, volume: target)
        }
        if hwOk {
            // Hardware accepted. If we previously installed a
            // software-gain fallback for this pair (e.g. the device
            // was unsupported and is now back, after re-plug), reset
            // the pair to 1.0 so we don't double-attenuate.
            if let pair = aggregate.subdeviceChannelOffset(uid: uid)
                .map({ $0 / max(1, aggregateOutput.channelCount) }) {
                aggregateOutput.setSoftwareGain(pair: pair, gain: 1.0)
            }
            return
        }
        // Hardware rejected. Increment the diagnostic counter on every
        // rejection; emit the stderr line ONCE per UID per session.
        aggregateHwVolumeRejectionCounts[uid, default: 0] += 1
        aggregateHwVolumeUnsupportedUIDs.insert(uid)
        if !loggedHwVolumeRejectionUIDs.contains(uid) {
            loggedHwVolumeRejectionUIDs.insert(uid)
            FileHandle.standardError.write(Data(
                ("[Router] hardware volume unsupported for \(uid.prefix(20)) — falling back to software gain (this device's level must be controlled via its OSD or via SyncCast's per-device slider; further rejections silenced)\n").utf8
            ))
        }
        // Route the slider value into the AUHAL's per-pair gain. The
        // channel-pair index is the subdevice's first output channel
        // divided by the source channel count (typically 2). If the
        // aggregate's stream layout doesn't match our model (e.g. one
        // wide stream where we expected per-subdevice pairs), the
        // setSoftwareGain call no-ops on out-of-range pair indices.
        guard let firstChannel = aggregate.subdeviceChannelOffset(uid: uid) else {
            return
        }
        let pair = firstChannel / max(1, aggregateOutput.channelCount)
        aggregateOutput.setSoftwareGain(pair: pair, gain: target)
        _ = deviceID  // intentionally unused — kept in signature for future per-device diagnostics
    }

    // MARK: - Sync Settings (whole-home delay tuning)
    // Thin passthroughs to the sidecar's `local_fifo.*` JSON-RPC methods,
    // surfaced for the menubar UI's live sync slider.

    /// Push a FIFO delay (ms); returns the sidecar-applied value
    /// (sidecar clamps to [0, 10000] ms). Throws if IPC isn't attached.
    public func setLocalFifoDelayMs(_ ms: Int) async throws -> Int {
        guard let ipc else {
            throw NSError(domain: "SyncCastRouter", code: 101, userInfo: [
                NSLocalizedDescriptionKey: "sidecar not attached"
            ])
        }
        let result = try await ipc.call(
            "local_fifo.set_delay_ms", params: ["delay_ms": ms]
        )
        if let dict = result as? [String: Any], let applied = dict["delay_ms"] as? Int {
            continuousActiveCurrentDelayMs = max(0, min(5000, applied))
            continuousActiveCalibrator?.noteExternalDelayChange()
            return applied
        }
        continuousActiveCurrentDelayMs = max(0, min(5000, ms))
        continuousActiveCalibrator?.noteExternalDelayChange()
        return ms
    }

    /// Broadcaster diagnostics (running flag, actual_delivery_lag_ms, etc.)
    /// or nil if IPC is unavailable / the call errors.
    public func localFifoDiagnostics() async -> [String: Any]? {
        guard let ipc else { return nil }
        let result = try? await ipc.call("local_fifo.diagnostics", params: [:])
        return result as? [String: Any]
    }

    public func localFifoCurrentDelayMsForDiagnostics() async -> Int? {
        guard let diagnostics = await localFifoDiagnostics() else {
            return continuousActiveCurrentDelayMs
        }
        return Self.intDiagnosticValue(diagnostics["current_delay_ms"])
            ?? Self.intDiagnosticValue(diagnostics["delay_ms"])
            ?? continuousActiveCurrentDelayMs
    }

    private static func intDiagnosticValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Double, value.isFinite { return Int(value.rounded()) }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    // MARK: - Continuous v4 active calibration
    //
    // Wraps `ActiveCalibrator` in a periodic background loop. Each
    // cycle re-uses `runCalibrationRaw` (same plumbing as the manual
    // one-shot button) and pushes the corrected delay through the
    // existing `setLocalFifoDelayMs` IPC. Replaces the GCC-PHAT
    // passive engine, which couldn't distinguish per-device taus.
    public private(set) var continuousActiveCalibrator: ContinuousActiveCalibrator?
    public private(set) var lastContinuousActiveSample: ContinuousActiveCalibrator.Sample?
    /// Cached most-recent delay-line value. Read by the loop's
    /// `initialDelayMs` callback so each cycle's delta is computed
    /// against the freshest value rather than the original seed.
    private var continuousActiveCurrentDelayMs: Int = 1750
    public typealias ContinuousActiveDeviceProvider =
        @Sendable () async -> [Device]

    /// Begin continuous v4 active calibration. Idempotent. `runner`
    /// re-enters `runCalibrationRaw` so routing / volume / restore is
    /// single-sourced.
    public func startContinuousActiveCalibration(
        intervalSeconds: Int,
        microphoneDeviceID: AudioDeviceID?,
        initialDelayMs: Int,
        deviceProvider: @escaping ContinuousActiveDeviceProvider,
        onSample: @escaping @Sendable (ContinuousActiveCalibrator.Sample) -> Void
    ) async throws {
        guard Self.activeAcousticCalibrationEnabled else {
            throw CalibrationFailure.engineFailed(
                Self.activeAcousticCalibrationDisabledMessage
            )
        }
        if continuousActiveCalibrator != nil { return }
        continuousActiveCurrentDelayMs = max(0, min(5000, initialDelayMs))
        let calibrator = ContinuousActiveCalibrator(
            runner: { [weak self] in
                guard let self else { throw CalibrationFailure.engineFailed("router gone") }
                let devs = await deviceProvider()
                // Phase-1-only — see runCalibrationLocalOnly. AirPlay τ
                // is inherited from the most recent full calibration so
                // continuous mode never silences AirPlay devices.
                return try await self.runCalibrationLocalOnly(
                    devices: devs, microphoneDeviceID: microphoneDeviceID
                )
            },
            applyDelayMs: { [weak self] ms in
                await self?.applyContinuousActiveDelay(ms)
            },
            initialDelayMs: { [weak self] in
                return await self?.continuousActiveDelaySnapshot() ?? 0
            },
            onSample: { [weak self] (sample: ContinuousActiveCalibrator.Sample) in
                guard let self else { return }
                Task { await self.recordContinuousActiveSample(sample) }
                onSample(sample)
            }
        )
        calibrator.measurementIntervalSeconds = Double(intervalSeconds)
        do {
            try await calibrator.start()
        } catch {
            lastError = "continuous active calibration start failed: \(error)"
            throw error
        }
        continuousActiveCalibrator = calibrator
    }

    /// Stop the continuous loop. Idempotent.
    public func stopContinuousActiveCalibration() {
        continuousActiveCalibrator?.stop()
        continuousActiveCalibrator = nil
        lastContinuousActiveSample = nil
    }

    fileprivate func continuousActiveDelaySnapshot() -> Int {
        return continuousActiveCurrentDelayMs
    }

    /// Cache + push to broadcaster. Failures surface in `lastError`
    /// but don't propagate — the next cycle retries.
    private func applyContinuousActiveDelay(_ ms: Int) async {
        let clamped = max(0, min(10_000, ms))
        continuousActiveCurrentDelayMs = max(0, min(5000, ms))
        do {
            _ = try await setLocalFifoDelayMs(clamped)
        } catch {
            lastError = "continuous active set_delay_ms failed: \(error)"
        }
    }

    private func recordContinuousActiveSample(
        _ sample: ContinuousActiveCalibrator.Sample
    ) {
        lastContinuousActiveSample = sample
    }

    /// Phase-1-only variant for the continuous calibration loop. Drives
    /// `ActiveCalibrator.run` with `airplayProbes: []` so Phase 2 (the
    /// disruptive AirPlay TDMA mute-dip — ~24 s of silenced devices for
    /// a typical 2-receiver setup) is skipped entirely. The only on-air
    /// activity per cycle is one local high-band coded probe from the
    /// active `ActiveCalibrator` profile.
    ///
    /// AirPlay group τ is inherited from `airplayTauCache` (populated
    /// by the most recent successful full `runCalibration`). The
    /// returned `Result.perDeviceTauMs` MERGES the freshly-measured
    /// local taus with the cached `airplay-group` tau, and `deltaMs` is
    /// recomputed as `max(0, cachedAirplayGroup − median(freshLocal)
    /// − broadcasterOverheadMs)` so the continuous loop's drift policy
    /// still operates against an AirPlay-vs-local delta.
    ///
    /// If the user has enabled AirPlay devices but never run a full
    /// Auto-calibrate (cache empty), throws `CalibrationFailure.engineFailed`
    /// — the continuous loop's existing failure handling logs once and
    /// keeps trying without disturbing the user.
    public func runCalibrationLocalOnly(
        devices: [Device],
        microphoneDeviceID: AudioDeviceID?
    ) async throws -> ActiveCalibrator.Result {
        let enabled = devices.filter { routing[$0.id]?.enabled == true }
        guard !enabled.isEmpty else { throw CalibrationFailure.noEnabledDevices }
        let enabledLocalIDs = Set(
            enabled.filter { $0.transport == .coreAudio }.map { $0.id }
        )
        let enabledAirplayIDs = Set(
            enabled.filter { $0.transport == .airplay2 }.map { $0.id }
        )
        guard !enabledLocalIDs.isEmpty, !enabledAirplayIDs.isEmpty else {
            throw CalibrationFailure.engineFailed(
                "continuous active calibration requires enabled local and AirPlay outputs"
            )
        }
        guard let cache = airplayTauCache else {
            throw CalibrationFailure.engineFailed(
                "no full calibration cached; run Auto-calibrate once before enabling continuous mode"
            )
        }
        let age = Date().timeIntervalSince(cache.calibratedAt)
        guard age <= airplayTauCacheTTLSeconds else {
            throw CalibrationFailure.engineFailed(
                "stale AirPlay calibration cache (age \(Int(age))s); run Auto-calibrate again"
            )
        }
        let probeProfile = ActiveCalibrator.fingerprintProbeProfileName
        guard cache.probeProfile == probeProfile else {
            throw CalibrationFailure.engineFailed(
                "stale AirPlay calibration cache; probe profile changed from \(cache.probeProfile) to \(probeProfile)"
            )
        }
        let signature = airplayRouteSignature(enabled: enabled)
        guard signature == cache.routeSignature else {
            throw CalibrationFailure.engineFailed(
                "stale AirPlay calibration cache; route or volume changed"
            )
        }
        let raw = try await runCalibrationRaw(
            devices: devices,
            microphoneDeviceID: microphoneDeviceID,
            skipAirplayPhase: true
        )
        // Merge fresh local τ with cached AirPlay group τ. Route signature
        // validation above makes the group tau specific to the exact
        // enabled AirPlay set/volume/mute context without pretending it is
        // independent per-receiver data.
        var merged = raw.perDeviceTauMs
        merged[ActiveCalibrator.airplayGroupDeviceID] = cache.groupTau
        var mergedConfidence = raw.perDeviceConfidence
        mergedConfidence[ActiveCalibrator.airplayGroupDeviceID] =
            cache.groupConfidence
        var mergedUncertainty = raw.perDeviceUncertaintyMs
        mergedUncertainty[ActiveCalibrator.airplayGroupDeviceID] =
            cache.groupUncertaintyMs
        // Recompute delta = cached AirPlay group τ − median(fresh local τ)
        // − broadcasterOverheadMs. ABSOLUTE TARGET delay-line value (the
        // continuous loop SETs, not adds) — same semantics + same bug fix as
        // the manual-calibrate path in `ActiveCalibrator.run`. Median is
        // robust to per-device cycle drift; broadcaster-overhead corrects
        // for Phase 1's tone bypassing the SCK→writer→sidecar→broadcaster
        // chain that real music traverses.
        let airplayCached: [Int] = [cache.groupTau].filter { $0 >= 0 }
        let localFresh: [Int] = enabled
            .filter { $0.transport == .coreAudio }
            .compactMap { raw.perDeviceTauMs[$0.id] }
            .filter { $0 >= 0 }
        guard !airplayCached.isEmpty, !localFresh.isEmpty else {
            throw CalibrationFailure.engineFailed(
                "continuous active calibration cannot merge local drift without cached AirPlay and fresh local taus"
            )
        }
        let airMed = airplayCached.max() ?? 0
        let locMed = ActiveCalibrator.medianInt(localFresh)
        let overheadMs = ActiveCalibrator.resolvedBroadcasterOverheadMs()
        // Defensive clamp: never recommend a negative delay-line.
        let mergedDelta = max(0, airMed - locMed - overheadMs)
        return ActiveCalibrator.Result(
            perDeviceTauMs: merged,
            perDeviceConfidence: mergedConfidence,
            perDeviceUncertaintyMs: mergedUncertainty,
            aggregateConfidence: min(raw.aggregateConfidence, cache.groupConfidence),
            deltaMs: mergedDelta
        )
    }

    /// Variant of `runCalibration` that returns the raw
    /// `ActiveCalibrator.Result` instead of the squashed
    /// `CalibrationDelta`. The continuous loop needs the full result
    /// (per-device taus, aggregate confidence) so it can run its own
    /// drift / confidence policies; the manual one-shot caller only
    /// needs the squashed delta + summary so the existing API is left
    /// alone.
    ///
    /// `skipAirplayPhase` (true → Phase-1-only) is set by the
    /// continuous loop via `runCalibrationLocalOnly`; the manual
    /// Auto-calibrate path leaves it false to run the full Phase 1 +
    /// Phase 2 sequence.
    fileprivate func runCalibrationRaw(
        devices: [Device],
        microphoneDeviceID: AudioDeviceID?,
        skipAirplayPhase: Bool = false
    ) async throws -> ActiveCalibrator.Result {
        guard Self.activeAcousticCalibrationEnabled else {
            throw CalibrationFailure.engineFailed(
                Self.activeAcousticCalibrationDisabledMessage
            )
        }
        let enabled = devices.filter { routing[$0.id]?.enabled == true }
        guard !enabled.isEmpty else { throw CalibrationFailure.noEnabledDevices }
        let calibrationRouteRevision = routeMutationRevision

        let originalRouting: [String: DeviceRouting] = Dictionary(
            uniqueKeysWithValues: enabled.compactMap { dev -> (String, DeviceRouting)? in
                guard let r = routing[dev.id] else { return nil }
                return (dev.id, r)
            }
        )

        let bridgeSnapshot: [String: LocalAirPlayBridge] = localBridges
        var localProbes: [ActiveCalibrator.LocalProbe] = []
        var airplayProbes: [ActiveCalibrator.AirPlayProbe] = []
        for dev in enabled {
            switch dev.transport {
            case .coreAudio:
                if let bridge = bridgeSnapshot[dev.id] {
                    localProbes.append(.init(deviceID: dev.id, bridge: bridge))
                }
            case .airplay2:
                if !skipAirplayPhase {
                    let origVol = originalRouting[dev.id]?.volume ?? 1.0
                    airplayProbes.append(.init(deviceID: dev.id, originalVolume: origVol))
                }
            }
        }
        // Phase-1-only with no local bridges enabled is a no-op; surface
        // it as a typed failure so the continuous loop's recordFailure()
        // path treats it as a skipped cycle.
        if skipAirplayPhase && localProbes.isEmpty {
            throw CalibrationFailure.engineFailed(
                "phase-1-only calibration requires at least one enabled local bridge"
            )
        }

        let writer = audioWriter
        let injectChirpToRing: @Sendable (
            _ samples: [[Float]], _ atNs: UInt64
        ) async -> Void = { samples, atNs in
            guard samples.count >= 2,
                  !samples[0].isEmpty,
                  samples[0].count == samples[1].count
            else { return }
            if writer?.scheduleStereoOverlay(samples: samples, atNs: atNs) != true {
                FileHandle.standardError.write(Data(
                    "[Router] calibration probe overlay schedule failed atNs=\(atNs)\n".utf8
                ))
            }
        }

        let airplaySetter: ActiveCalibrator.AsyncAirplayVolumeSetter = {
            [weak self] devID, vol in
            await self?.setAirplayVolume(
                id: devID,
                volume: vol,
                invalidatesTiming: false
            )
        }

        let muteAirplayBeforeLocal: ActiveCalibrator.AsyncSideEffect?
        let restoreAirplayAfterLocal: ActiveCalibrator.AsyncSideEffect?
        if airplayProbes.isEmpty {
            muteAirplayBeforeLocal = nil
            restoreAirplayAfterLocal = nil
        } else {
            muteAirplayBeforeLocal = { [weak self, airplayProbes] in
                guard let self else { return }
                for probe in airplayProbes {
                    await self.setAirplayVolume(
                        id: probe.deviceID,
                        volume: 0,
                        invalidatesTiming: false
                    )
                }
                try? await Task.sleep(nanoseconds: 900_000_000)
            }
            restoreAirplayAfterLocal = { [weak self, airplayProbes] in
                guard let self else { return }
                for probe in airplayProbes {
                    await self.setAirplayVolume(
                        id: probe.deviceID,
                        volume: probe.originalVolume,
                        invalidatesTiming: false
                    )
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }

        let calibrator = ActiveCalibrator(
            microphoneDeviceID: microphoneDeviceID,
            muteAirplayBeforeLocalPhase: muteAirplayBeforeLocal,
            restoreAirplayAfterLocalPhase: restoreAirplayAfterLocal
        )
        let requiredBridgeIDs = Set(localProbes.map(\.deviceID))
        let transportBefore = calibrationTransportSnapshot(
            bridgeIDs: requiredBridgeIDs
        )

        var didRestore = false
        func restoreOriginalRouting() async {
            if didRestore { return }
            didRestore = true
            guard routeMutationRevision == calibrationRouteRevision else {
                FileHandle.standardError.write(Data(
                    "[Router] calibration routing restore skipped because route revision changed \(calibrationRouteRevision) -> \(routeMutationRevision)\n".utf8
                ))
                return
            }
            for (id, r) in originalRouting {
                routing[id] = r
            }
            replan()
            for dev in enabled where dev.transport == .airplay2 {
                let v = originalRouting[dev.id]?.volume ?? 1.0
                await setAirplayVolume(
                    id: dev.id,
                    volume: v,
                    invalidatesTiming: false
                )
            }
        }

        do {
            try Task.checkCancellation()
            let result = try await calibrator.run(
                localProbes: localProbes,
                airplayProbes: airplayProbes,
                setAirplayVolume: airplaySetter,
                injectChirpToRing: injectChirpToRing,
                sckRingSampleRate: capture.sampleRate
            )
            let transportAfter = calibrationTransportSnapshot(
                bridgeIDs: requiredBridgeIDs
            )
            await restoreOriginalRouting()
            guard routeMutationRevision == calibrationRouteRevision else {
                throw CalibrationFailure.engineFailed(
                    "calibration route context changed during measurement"
                )
            }
            try validateCalibrationTransport(
                before: transportBefore,
                after: transportAfter,
                requiresWriter: !airplayProbes.isEmpty,
                requiredBridgeIDs: requiredBridgeIDs
            )
            return result
        } catch {
            await restoreOriginalRouting()
            if error is CancellationError { throw error }
            throw CalibrationFailure.engineFailed("\(error)")
        }
    }

    private func calibrationTransportSnapshot(
        bridgeIDs: Set<String>
    ) -> CalibrationTransportSnapshot {
        let writerSnapshot = audioWriter.map {
            CalibrationTransportSnapshot.Writer(
                packetsSent: $0.packetsSent,
                underrunPackets: $0.underrunPackets,
                partialSends: $0.partialSends,
                lastError: $0.lastSendError,
                overlaysScheduled: $0.overlaysScheduled,
                overlayFramesScheduled: $0.overlayFramesScheduled,
                overlayFramesMixed: $0.overlayFramesMixed,
                overlaysDroppedLate: $0.overlaysDroppedLate
            )
        }
        var bridgeSnapshots: [String: CalibrationTransportSnapshot.Bridge] = [:]
        for id in bridgeIDs {
            guard let bridge = localBridges[id] else { continue }
            bridgeSnapshots[id] = .init(
                packetsReceived: bridge.packetsReceived,
                renderTickCount: bridge.renderTickCount,
                driftResyncCount: bridge.driftResyncCount,
                driftResyncReason: bridge.lastDriftResyncReason,
                driftResyncFrameDelta: bridge.lastDriftResyncFrameDelta,
                lastError: bridge.lastError
            )
        }
        return .init(writer: writerSnapshot, bridges: bridgeSnapshots)
    }

    private func validateCalibrationTransport(
        before: CalibrationTransportSnapshot,
        after: CalibrationTransportSnapshot,
        requiresWriter: Bool,
        requiredBridgeIDs: Set<String>
    ) throws {
        let failures = CalibrationTransportHealth.failures(
            before: before,
            after: after,
            requiresWriter: requiresWriter,
            requiredBridgeIDs: requiredBridgeIDs
        )
        guard failures.isEmpty else {
            throw CalibrationFailure.engineFailed(
                "calibration transport unhealthy: " + failures.joined(separator: "; ")
            )
        }
    }

}
