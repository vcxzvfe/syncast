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

    /// Per-device AirPlay pairing state pushed up by the sidecar, keyed by the
    /// device's stable persistence key. Read by the pairing extension
    /// (`Router+Pairing.swift`).
    var pairingStatesStorage: [String: PairingState] = [:]
    var pairingErrorsStorage: [String: String] = [:]

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
    // MARK: System sink stereo path state
    //
    // The sink path (`stereoOutputPath == .sink`) installs a virtual HAL
    // device as the macOS default output so the SYSTEM volume UI controls
    // SyncCast, then captures that device with a pinned Process Tap and fans
    // the audio out through the normal aggregate/AUHAL machinery. See
    // `SystemSinkDevice` and docs/adr/ADR-007-system-sink-volume.md.
    /// The installed sink while the path runs; nil otherwise.
    private var systemSink: SystemSinkDevice?
    /// Process Tap pinned to the sink. Held as the protocol type because
    /// `TapCapture` is macOS 14.2+ and Router is not availability-annotated.
    /// Replaces `capture` as the ring source while it is non-nil.
    private var sinkCapture: (any SystemAudioCapture)?
    /// The system volume, as last read from (or written to) the sink's
    /// `kAudioDevicePropertyVolumeScalar`. 0…1 on the HAL's perceptual scale,
    /// NOT a linear amplitude — `SystemSinkVolumeLaw` does that conversion.
    private var sinkMasterVolume: Float = 1
    private var sinkMasterMuted: Bool = false
    /// The sink's own scalar↔dB law, read once per start. Used for the
    /// software-gain backend and for composing per-device balance.
    private var sinkVolumeLaw = SystemSinkVolumeLaw.appleBuiltInLaw
    /// Per-UID backend verdicts for the sink path, refreshed on each apply so
    /// a device that starts rejecting writes is demoted mid-session.
    private var sinkVolumeBackends: [String: SystemSinkVolumeLaw.Backend] = [:]
    /// Sample rate / channel count the path was constructed with, so the sink
    /// path can build its pinned tap with the same contract as `capture`.
    private let sampleRate: Double
    private let channelCount: Int
    /// Whole-home mode's named system sink ("AirPlay 全屋"): a public
    /// aggregate wrapping BlackHole 2ch that we install as the macOS default
    /// output for the duration of whole-home mode. Nil in stereo mode and
    /// after teardown. See `WholeHomeSinkOutput` for why the rename cannot be
    /// done on BlackHole itself.
    private var wholeHomeSink: WholeHomeSinkOutput?
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
    /// Shared JSON-RPC channel to the sidecar. Internal (not private) so the
    /// pairing extension in `Router+Pairing.swift` can issue bounded pairing
    /// calls on the same connection.
    var ipc: IpcClient?
    private var audioWriter: AudioSocketWriter?

    /// Whole-home master fader, 0…100 on `VolumeCurve`'s scale.
    ///
    /// Held here rather than only inside the writer because `attachIpc`
    /// constructs a NEW `AudioSocketWriter` every time the sidecar connection
    /// is (re)established. Without a Router-side copy to re-seed from, a
    /// sidecar restart would silently snap the master back to full scale
    /// under a UI still showing the user's setting.
    private var masterVolumePercent: Int = VolumeCurve.defaultPercent
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
    /// Last delay-line value we successfully pushed to (or read back from)
    /// the sidecar broadcaster. Used only as the fallback for
    /// `localFifoCurrentDelayMsForDiagnostics()` when the sidecar's own
    /// diagnostics are unavailable.
    private var lastAppliedLocalFifoDelayMs: Int = 0

    /// Diagnostic socket server: lets command-line callers
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
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.stereoOutputPath = StereoOutputPathPolicy.resolvedPath()
        if let warning = StereoOutputPathPolicy.warningForUnknownValue() {
            RouterLog.write("[Router] \(warning)\n")
        }
        if let warning = StereoOutputPathPolicy.sinkFallbackWarning(
            sinkAvailable: StereoOutputPathPolicy.sinkPathUsable
        ) {
            RouterLog.write("[Router] \(warning)\n")
        }
        // A SIGKILLed previous run can leave the macOS default output pointed
        // at a silent sink: audio "works" everywhere in the UI and nothing is
        // audible. Gated on an ownership claim left by a dead process, so a
        // user who deliberately selected BlackHole for their own recording
        // setup is never disturbed by SyncCast merely launching.
        if let swept = SystemSinkDevice.sweepStaleDefault() {
            RouterLog.write("[Router] system sink recovery: \(swept)")
        }

        let requestedBackend = ProcessInfo.processInfo
            .environment["SYNCAST_CAPTURE_BACKEND"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if requestedBackend == "tap" {
            if #available(macOS 14.2, *) {
                self.capture = TapCapture(sampleRate: sampleRate, channelCount: channelCount)
            } else {
                RouterLog.write(
                    "[Router] SYNCAST_CAPTURE_BACKEND=tap requested but macOS 14.2+ is required; failing closed instead of falling back to SCK\n"
                )
                self.capture = UnavailableSystemAudioCapture(
                    backendName: "tap-unavailable",
                    reason: "Process Tap capture requires macOS 14.2 or later; refusing to fall back to ScreenCaptureKit"
                )
            }
        } else {
            if let requestedBackend, requestedBackend != "sck" {
                RouterLog.write(
                    "[Router] unknown SYNCAST_CAPTURE_BACKEND=\(requestedBackend); falling back to SCK\n"
                )
            }
            self.capture = SCKCapture(sampleRate: sampleRate, channelCount: channelCount)
        }
        self.scheduler = Scheduler(sampleRate: sampleRate)
        // Reap any private aggregate devices left behind by a prior crash
        // BEFORE we ever try to create one in this run. Header docs say
        // private aggregates auto-clean on process exit, but coreaudiod
        // has been observed to leak them after SIGKILL or fast user
        // switching. Sweep is keyed by the AggregateDevice.uidPrefix.
        let reaped = AggregateDevice.sweepOrphans()
        if reaped > 0 {
            // Logged as a warning so we notice in the field if SIGKILL
            // crashes start happening.
            RouterLog.write("[Router] swept \(reaped) orphan aggregate device(s) at init")
        }
        // Public Direct Stereo aggregates can become the macOS default
        // output. Sweep them on every launch, not only direct-mode launches,
        // so a normal fallback launch can recover after a prior SIGKILL.
        let directReaped = DirectStereoOutput.sweepOrphans()
        if directReaped > 0 {
            RouterLog.write("[Router] swept \(directReaped) orphan direct stereo aggregate device(s) at init")
        }
        // Whole-home sinks share that hazard — they also become the macOS
        // default output, so a SIGKILL can leave the system pointed at a
        // device nobody owns. The sweep moves the default to a real speaker
        // before destroying such a leftover.
        let sinkReaped = WholeHomeSinkOutput.sweepOrphans()
        if sinkReaped > 0 {
            RouterLog.write("[Router] swept \(sinkReaped) orphan whole-home sink device(s) at init")
        }
        if #available(macOS 14.2, *) {
            let tapReaped = TapCapture.sweepOrphans()
            if tapReaped > 0 {
                RouterLog.write("[Router] swept \(tapReaped) orphan process tap aggregate device(s) at init")
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
        // Wire the DDC controller's "accepted intent was dropped" signal
        // into the actor (same hop pattern as onUnexpectedStop above).
        // `enqueueApply` optimistically accepts intents while a capability
        // probe is in flight; if the probe (or a later revalidation /
        // write-failure demotion) lands on unsupported, the queued intent
        // is discarded — without this hook that loss never reached the
        // rejection bookkeeping ("UI moved, hardware didn't, nothing
        // logged"; Codex P2). The controller is process-wide, so the most
        // recently constructed Router owns the handler — in production
        // exactly one Router exists per process.
        DDCDisplayVolumeController.shared.setOnPendingIntentDropped {
            [weak self] uid in
            Task { await self?.recordDroppedDDCVolumeIntent(uid: uid) }
        }
    }

    /// Retroactive rejection bookkeeping for a DDC intent that was
    /// accepted (probe in flight / binding then demoted) and dropped when
    /// the UID's verdict landed on unsupported. Mirrors exactly what
    /// `applyDirectStereoHardwareVolume` records for an immediate
    /// both-backends rejection, so diagnostics can't tell the two apart —
    /// which is the point: to the user both are "the slider moved, the
    /// hardware didn't".
    private func recordDroppedDDCVolumeIntent(uid: String) {
        aggregateHwVolumeUnsupportedUIDs.insert(uid)
        aggregateHwVolumeRejectionCounts[uid, default: 0] += 1
        if !loggedHwVolumeRejectionUIDs.contains(uid) {
            loggedHwVolumeRejectionUIDs.insert(uid)
            RouterLog.write(
                ("[Router] DDC volume intent for \(uid.prefix(20)) was accepted while probing but dropped — probe concluded unsupported; use the device OSD or hardware controls (further rejections silenced)\n")
            )
        }
    }

    /// Called when the capture backend terminates on its own. We
    /// deliberately do NOT restart capture here — `forceLocalDriverRebuild`
    /// owns capture lifecycle during wake recovery, and racing it with this
    /// callback could double-start the backend or interleave with an
    /// in-flight rebuild. Logging only is sufficient: AppModel fires
    /// `forceLocalDriverRebuild` after every wake event.
    private func handleCaptureDied() {
        RouterLog.write(
            "[Router] capture backend \(capture.backendName) died unexpectedly — wake handler's forceLocalDriverRebuild will restart it\n"
        )
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
            // Pairing progresses asynchronously behind a human-scale window
            // (the user has to read a PIN off the receiver's own screen and
            // type it back), so the sidecar reports it by notification rather
            // than as the result of a long-blocking call.
            if method == "event.pairing_state",
               let deviceKey = params["device_key"] as? String,
               let stateStr = params["state"] as? String {
                let reason = params["last_error"] as? String
                Task { await self.recordPairingState(
                    deviceKey: deviceKey, stateStr: stateStr, reason: reason,
                ) }
            }
        }
        _ = try await client.call("sidecar.hello", params: ["v": 1, "router_pid": ProcessInfo.processInfo.processIdentifier])
        self.ipc = client
        // A fresh sidecar process knows nothing about the trims we pushed to
        // its predecessor, so forget what we think it is carrying. Otherwise
        // the "unchanged ⇒ don't push" guard would suppress the one push that
        // re-establishes them, and every AirPlay receiver would silently run
        // untrimmed for the rest of the session.
        lastPushedAirplayTrimsMs = [:]
        let writer = AudioSocketWriter(ring: capture.ringBuffer, socketPath: sockets.audio)
        // Re-seed the master fader: this writer is brand new and would
        // otherwise start at unity, overriding the user's setting the moment
        // the sidecar reconnects. `seedMasterGain`, not `setMasterGain` —
        // the latter only moves the ramp target, so the first packet after a
        // reconnect would start at full scale and ramp DOWN to the user's
        // level, i.e. ~10 ms of full-volume audio out of a system they had
        // turned down or muted.
        writer.seedMasterGain(
            VolumeCurve.masterAmplitude(forPercent: masterVolumePercent)
        )
        // Same reasoning for the AirPlay group curve: a brand-new writer
        // starts flat and would drop the user's tone setting on the floor at
        // every sidecar reconnect.
        writer.setEqualizer(airPlayGroupEqualizer)
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
            if mode == .stereo, stereoOutputPath == .sink {
                // Sink path: the system-volume-owning virtual device becomes
                // the default output, a pinned Process Tap reads what macOS
                // renders into it, and the ordinary local driver fans that out
                // to the real speakers. No ScreenCaptureKit, no event tap.
                await capture.stopAndWait()
                tearDownLocalDriver()
                try stopDirectStereoOutput()
                // Same ordering rule as Direct Stereo: give the user's real
                // default back BEFORE the sink snapshots it, or we would
                // remember a device that is about to be destroyed.
                try stopWholeHomeSink()
                try await startSystemSinkPath(devices: devices)
            } else if mode == .stereo, stereoOutputPath == .direct {
                await capture.stopAndWait()
                tearDownLocalDriver()
                try stopSystemSinkPath()
                // Restore the user's real default output BEFORE Direct Stereo
                // snapshots it. Reversed, Direct Stereo would remember our
                // sink as "the previous default" and restore the system to a
                // device that no longer exists.
                try stopWholeHomeSink()
                try reconcileDirectStereo(devices: devices, allowEmpty: false)
            } else if mode == .stereo {
                try stopSystemSinkPath()
                try await capture.start()
                try stopDirectStereoOutput()
                try stopWholeHomeSink()
                reconcileLocalDriver(devices: devices)
            } else {
                // Whole-home never runs on the sink path: its own named sink
                // is the default output and OwnTone owns the clock domain.
                try stopSystemSinkPath()
                try await capture.start()
                try stopDirectStereoOutput()
                // Whole_home: ensure no stale aggregate AUHAL is left over
                // from a previous mode. tearDownLocalDriver is idempotent
                // (no-op if localOutputs is already empty + aggregate is nil).
                tearDownLocalDriver()
                // Install the named silent sink as the system default output.
                // This is the AUTHORITATIVE bring-up point (rather than
                // `setMode`) because it is the one whole-home path that can
                // report failure to the user: a throw here lands in the catch
                // below, sets state = .error, and surfaces `lastError` — which
                // is exactly what a missing BlackHole must do instead of
                // silently double-playing every track.
                try startWholeHomeSink()
            }
            replan()
            state = .running
        } catch {
            state = .error
            lastError = "\(error)"
            _ = try? stopDirectStereoOutput()
            _ = try? stopWholeHomeSink()
            tearDownLocalDriver()
            // The sink path can fail after the sink is already the default
            // output (e.g. the tap is refused). Unwinding it here is what
            // keeps a failed start from leaving macOS pointed at a silent
            // device with nothing rendering it.
            await stopSystemSinkPathIgnoringErrors()
            await capture.stopAndWait()
            throw error
        }
    }

    public func stop() async {
        state = .stopping
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
        // 3a-bis. The system sink: stop its pinned tap and hand the default
        //     output back. Ordered after the AUHAL teardown (the outputs read
        //     from the tap's ring) and before the whole-home sink so only one
        //     default-output owner is ever mid-restore.
        var teardownFailures: [String] = []
        do {
            try stopDirectStereoOutput()
        } catch {
            teardownFailures.append("direct stereo stop failed: \(error)")
        }
        do {
            try stopSystemSinkPath()
        } catch {
            teardownFailures.append("system sink stop failed: \(error)")
        }
        // 3b. Give the user's default output back. Same fail-loud contract as
        //     Direct Stereo: if we cannot restore it we must NOT let the app
        //     quit, or macOS is left pointed at a device that dies with us.
        do {
            try stopWholeHomeSink()
        } catch {
            teardownFailures.append("whole-home sink stop failed: \(error)")
        }
        // EVERY default-output owner gets its teardown attempted, and the
        // failures are aggregated. Short-circuiting on the first one made one
        // owner's fail-loud contract depend on an unrelated owner succeeding —
        // the second owner would silently keep the system default.
        if !teardownFailures.isEmpty {
            lastError = teardownFailures.joined(separator: "; ")
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

    // MARK: - Capture diagnostics
    //
    // Retired 2026-08-09: this section used to describe an acoustic
    // auto-calibration scheme that played click pulses through the live path
    // and measured their arrival with the microphone. It was deleted along
    // with `ActiveCalibrator` / `MuteDipCalibrator` / the passive drift
    // observers. Synchronisation now comes entirely from the OwnTone clock
    // domain plus the Layer-2 ring-level PLL, and NO code path opens the
    // microphone (README.md states that as a guarantee).

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
            // `floor` is the added latency this output is paying and the three
            // glitch counters say whether that floor is holding: a headless run
            // proves "no glitches in N minutes" by showing resync/underrun
            // unchanged while ticks climbs. `schedBackoff` sits beside them
            // because it does NOT move the read cursor (see
            // LocalOutput._readBackoffFrames) and reading the two as one number
            // is how the 71 ms latency claim got written down wrong.
            renderInfo += " render[\(label)]=ticks:\(out.renderTickCount)"
                + " peak:\(String(format: "%.4f", out.lastRenderPeak))"
                + " floor:\(String(format: "%.0fms", RingFloorPolicy.milliseconds(frames: out.ringFloorFrames, sampleRate: out.sampleRate)))"
                + " \(out.glitchSummary())"
                + " schedBackoff:\(out.readBackoffFramesDiagnostic)"
        }
        var awInfo = ""
        if let aw = audioWriter {
            let eqClip = aw.equalizerClipCount
            awInfo = " airplayWriter=pkts:\(aw.packetsSent) underrun:\(aw.underrunPackets) partial:\(aw.partialSends) bytes:\(aw.bytesSent)\(eqClip > 0 ? " eqClip:\(eqClip)" : "") err:\(aw.lastSendError.isEmpty ? "none" : aw.lastSendError)"
        }
        // Driver mode: most useful in field reports — tells us instantly
        // if the kernel-level synchronized aggregate is engaged or not.
        let driverInfo: String
        if mode == .wholeHome {
            driverInfo = " driver=wholeHome(\(localBridges.count))"
        } else if let direct = directStereoOutput, direct.isActive {
            driverInfo = " driver=directStereo"
        } else if let sink = systemSink, sink.isActive {
            let floorMs = RingFloorPolicy.milliseconds(
                frames: ringFloorFrames(logWarnings: false),
                sampleRate: activeCapture.sampleRate
            )
            driverInfo = " driver=systemSink("
                + "\(aggregateDevice != nil ? aggregateCoveredUIDs.count : localOutputs.count)"
                + ",floor=\(String(format: "%.0fms", floorMs)))"
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
        // `peak` is measured PRE-gain, so `peak: 0.0000` still means "nothing
        // is arriving" no matter where the user left the faders; `gain` is
        // reported beside it so the audible level is still recoverable.
        var bridgeInfo = ""
        for (id, b) in localBridges {
            // `eqClip` only once it is non-zero, the same rule
            // `LocalOutput.glitchSummary()` follows: it is a fault signal, and
            // a permanent `eqClip:0` would train the reader to skip it.
            let eqClip = b.equalizerClipCount
            bridgeInfo += " bridge[\(id.prefix(6))]=pkts:\(b.packetsReceived) ticks:\(b.renderTickCount) peak:\(String(format: "%.4f", b.lastRenderPeak)) gain:\(String(format: "%.3f", b.lastRenderGain))\(eqClip > 0 ? " eqClip:\(eqClip)" : "") err:\(b.lastError.isEmpty ? "none" : b.lastError)"
        }
        let masterInfo =
            " master=\(masterVolumePercent)%"
            + "/\(String(format: "%.3f", VolumeCurve.masterAmplitude(forPercent: masterVolumePercent)))"
        // Per-subdevice hardware-volume rejection counters. Surfaced
        // here because the stderr log emits ONCE per UID per session;
        // a support ticket needs to see total rejection counts for
        // any device routed through software-gain fallback (typical:
        // DP / HDMI displays).
        var hwVolInfo = ""
        for (uid, count) in aggregateHwVolumeRejectionCounts {
            hwVolInfo += " hwVolRejected[\(uid.prefix(6))]=\(count)"
        }
        // DDC takeover marker: " ddc=N ..." appears once any covered UID is
        // (or was) volume-controlled over DDC/CI, so field reports can tell
        // "display slider works via DDC" from "display has no volume path".
        let directInfo = directStereoOutput.map {
            " \($0.diagnostic)\(DDCDisplayVolumeController.shared.diagnosticSuffix())"
        } ?? ""
        // Whole-home sink state. Present in field logs so "the system default
        // output silently went back to a real speaker" is diagnosable without
        // asking the user to open System Settings.
        let sinkInfo = wholeHomeSink.map { " \($0.diagnostic)" } ?? ""
        // System-sink path state: which device owns the system volume, whether
        // macOS is still rendering into it, and where the master sits. Without
        // this line "the user moved the output away in the Sound menu" and
        // "the master is at 0" look identical in a field report.
        let systemSinkInfo = systemSink.map {
            " \($0.diagnostic) master=\(String(format: "%.3f", sinkMasterVolume))\(sinkMasterMuted ? "(muted)" : "")"
                + " sinkBackends=[" + sinkVolumeBackends
                    .map { "\($0.key.prefix(6))=\($0.value.rawValue)" }
                    .sorted().joined(separator: ",") + "]"
        } ?? ""
        let captureInfo: String
        if mode == .stereo,
           let direct = directStereoOutput,
           direct.isActive {
            captureInfo = "backend=directNoCapture seen=0 written=0 ticks=0 peak=0.0000/0.0000 readback=0.0000@-1 last=directStereo"
        } else {
            captureInfo = activeCapture.diagnosticReport()
        }
        return "\(captureInfo)\(driverInfo)\(directInfo)\(sinkInfo)\(systemSinkInfo)\(streamInfo)\(renderInfo)\(awInfo)\(masterInfo)\(bridgeInfo)\(hwVolInfo)"
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

    /// Best-effort hardware volume/mute write for Direct Stereo.
    ///
    /// Direct Stereo has no AUHAL render callback and therefore no software
    /// gain stage. A user-visible volume change can only be reflected on
    /// physical devices whose CoreAudio driver exposes writable output
    /// volume/mute controls, or — for HDMI/DP monitors that expose none —
    /// on the display's DDC/CI speaker volume (handled inside
    /// `DirectStereoOutput.applyHardwareVolume`, applied asynchronously off
    /// this actor). Devices neither backend can control are logged once and
    /// otherwise left to their own OSD/hardware control; the rejection
    /// counters only ever record intents that BOTH backends refused.
    ///
    /// Bookkeeping is per backend: an actual CoreAudio LEVEL write failure
    /// lands in `aggregateHwVolumeUnsupportedUIDs` EVEN when the DDC
    /// fallback carried the intent. `classifyDirectStereoVolumeBackend`
    /// keys on that set to distrust the driver's settability probe —
    /// without the entry, a device whose driver claims "settable" but
    /// rejects real writes would keep classifying (and reading back) as
    /// `.coreAudioHardware` instead of using the DDC cache.
    @discardableResult
    public func applyDirectStereoHardwareVolume(
        deviceID: String,
        uid: String,
        volume: Float,
        muted: Bool
    ) -> Bool {
        guard mode == .stereo,
              stereoOutputPath == .direct,
              let direct = directStereoOutput,
              direct.covers(uid: uid)
        else {
            return false
        }
        let outcome = direct.applyHardwareVolume(
            uid: uid, volume: volume, muted: muted
        )
        if outcome.disprovesCoreAudioSettability {
            aggregateHwVolumeUnsupportedUIDs.insert(uid)
        }
        if outcome.isUserVisibleRejection {
            aggregateHwVolumeRejectionCounts[uid, default: 0] += 1
            if !loggedHwVolumeRejectionUIDs.contains(uid) {
                loggedHwVolumeRejectionUIDs.insert(uid)
                RouterLog.write(
                    ("[Router] direct stereo hardware volume unsupported for \(uid.prefix(20)) — neither CoreAudio nor DDC/CI can control this device; use the device OSD or hardware controls\n")
                )
            }
        }
        _ = deviceID
        return outcome.anyBackendAccepted
    }

    /// Per-device volume-backend capability snapshot for the active Direct
    /// Stereo output, keyed by CoreAudio device UID. Consumed by the
    /// menubar UI to decide which sliders are live.
    ///
    /// Classification is conservative: CoreAudio writability comes from a
    /// read-only settability probe (cached); DDC support from the async
    /// probe — when a probe is still pending/in-flight this method waits
    /// (bounded, ~2 s) for the verdict so the first snapshot after Direct
    /// Stereo starts doesn't misreport a DDC display as uncontrollable.
    /// On timeout it stays fail closed: unknown reports `.none`.
    ///
    /// Reentrancy: the Router actor is free to interleave during the
    /// bounded wait. No intermediate actor state is held across the
    /// suspension — mode/output/UIDs are re-read and re-validated after it.
    public func directStereoVolumeCapabilities() async -> [String: DirectStereoVolumeBackend] {
        guard let direct = activeDirectStereoOutput(), direct.isActive else {
            return [:]
        }
        // Kick probes for UIDs we haven't classified yet (no-op for
        // already-probed UIDs), then wait for in-flight verdicts to land.
        DDCDisplayVolumeController.shared.probeCapabilities(
            uids: Array(direct.coveredOutputUIDs)
        )
        await DDCDisplayVolumeController.shared.waitForSettledCapabilities(
            uids: Array(direct.coveredOutputUIDs)
        )
        // Re-validate after the suspension: Direct Stereo may have been
        // reconciled away (or rebuilt with different devices) while the
        // actor interleaved.
        guard let settled = activeDirectStereoOutput(), settled.isActive else {
            return [:]
        }
        var result: [String: DirectStereoVolumeBackend] = [:]
        for uid in settled.coveredOutputUIDs {
            result[uid] = classifyDirectStereoVolumeBackend(uid: uid)
        }
        return result
    }

    /// Best-available 0...1 volume readback for a Direct Stereo device,
    /// sourced from the backend that owns the device's WRITES (the same
    /// classification as `directStereoVolumeCapabilities()`):
    /// `.coreAudioHardware` reads the device's VolumeScalar, `.ddc` reads
    /// the DDC controller's cached user-intent level (probe-time read,
    /// updated after each applied write), `.none` reads nothing.
    ///
    /// Following the backend matters: some HDMI/DP devices expose a
    /// READABLE-but-unsettable CoreAudio VolumeScalar — a stale mirror
    /// that never tracks the panel's real speaker level. A "CoreAudio
    /// read first" order would return that mirror for `.ddc` devices, the
    /// snapshot would write it back as route.volume, and the next media
    /// key / slider step would re-apply the wrong level.
    ///
    /// Like the capability snapshot, a pending/in-flight DDC probe is
    /// awaited (bounded) before classifying, and all actor state is
    /// re-validated after the suspension.
    public func readDirectStereoVolume(uid: String) async -> Float? {
        guard let direct = activeDirectStereoOutput(), direct.covers(uid: uid)
        else {
            return nil
        }
        DDCDisplayVolumeController.shared.probeCapabilities(uids: [uid])
        await DDCDisplayVolumeController.shared.waitForSettledCapabilities(
            uids: [uid]
        )
        guard let settled = activeDirectStereoOutput(), settled.covers(uid: uid)
        else {
            return nil
        }
        switch classifyDirectStereoVolumeBackend(uid: uid) {
        case .coreAudioHardware:
            return AggregateDevice.readHardwareVolume(uid: uid)
        case .ddc:
            return DDCDisplayVolumeController.shared.cachedNormalizedVolume(
                uid: uid
            )
        case .none:
            return nil
        }
    }

    /// One UID's volume-backend verdict, shared by the capability snapshot
    /// and the readback path so they can never diverge. The decision
    /// itself is the pure `DirectStereoVolumeReadback.backend`; this
    /// wrapper just feeds it live state.
    private func classifyDirectStereoVolumeBackend(
        uid: String
    ) -> DirectStereoVolumeBackend {
        DirectStereoVolumeReadback.backend(
            coreAudioVolumeSettable:
                AggregateDevice.probeHardwareVolumeWritable(uid: uid),
            coreAudioPreviouslyRejected:
                aggregateHwVolumeUnsupportedUIDs.contains(uid),
            ddcKnownSupported:
                DDCDisplayVolumeController.shared.isKnownSupported(uid: uid)
        )
    }

    /// The Direct Stereo output iff the router is currently in
    /// stereo/direct mode. Helper for the volume snapshot/readback paths,
    /// which must re-validate this exact condition after every suspension.
    private func activeDirectStereoOutput() -> DirectStereoOutput? {
        guard mode == .stereo, stereoOutputPath == .direct else { return nil }
        return directStereoOutput
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
        if mode == .stereo, stereoOutputPath == .sink {
            // Wake recovery for the sink path: the sink device survives sleep,
            // but the pinned tap and the AUHALs on HDMI/DP subdevices do not.
            // Rebuild the whole chain rather than only the outputs — an AUHAL
            // reading a dead tap's ring is silent with no error.
            RouterLog.write(
                "[Router] forceLocalDriverRebuild: rebuilding system sink path\n"
            )
            tearDownLocalDriver()
            let stopStatus: String?
            do {
                stopStatus = try stopSystemSinkPath()
            } catch {
                lastError = "system sink rebuild failed to stop cleanly: \(error)"
                RouterLog.write(
                    "[Router] forceLocalDriverRebuild: system sink stop failed — \(error)\n"
                )
                return false
            }
            // Same rule as the Direct Stereo branch: if the user moved the
            // default output away (before sleep, or while we were down),
            // restarting would grab it back out from under them. Wake recovery
            // is not consent — the AppModel's displacement policy owns the
            // decision to resume.
            if stopStatus?.contains("user changed default") == true {
                RouterLog.write(
                    "[Router] forceLocalDriverRebuild: system sink rebuild skipped because the user changed the default output\n"
                )
                replan()
                return true
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
            do {
                try await startSystemSinkPath(devices: devices)
                replan()
                RouterLog.write(
                    "[Router] forceLocalDriverRebuild: system sink rebuild OK\n"
                )
                return true
            } catch {
                lastError = "system sink rebuild failed: \(error)"
                RouterLog.write(
                    "[Router] forceLocalDriverRebuild: system sink rebuild failed — \(error)\n"
                )
                // Same unwind `start()` performs: a half-built sink path can
                // leave macOS pointed at a silent device, and nothing else
                // runs after a failed rebuild to notice.
                await stopSystemSinkPathIgnoringErrors()
                return false
            }
        }
        if mode == .stereo, stereoOutputPath == .direct {
            RouterLog.write(
                "[Router] forceLocalDriverRebuild: rebuilding direct stereo default output\n"
            )
            do {
                let stopStatus = try stopDirectStereoOutput()
                if stopStatus?.contains("user changed default") == true {
                    RouterLog.write(
                        "[Router] forceLocalDriverRebuild: direct stereo rebuild skipped because user changed default output\n"
                    )
                    replan()
                    return true
                }
                try reconcileDirectStereo(devices: devices, allowEmpty: false)
                replan()
                RouterLog.write(
                    "[Router] forceLocalDriverRebuild: direct stereo rebuild OK\n"
                )
                return true
            } catch {
                lastError = "direct stereo rebuild failed: \(error)"
                RouterLog.write(
                    "[Router] forceLocalDriverRebuild: direct stereo rebuild failed — \(error.localizedDescription)\n"
                )
                return false
            }
        }
        RouterLog.write(
            "[Router] forceLocalDriverRebuild: tearing down + rebuilding (incl. capture backend \(capture.backendName))\n"
        )
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
            RouterLog.write(
                "[Router] forceLocalDriverRebuild: capture restart OK (\(capture.backendName))\n"
            )
        } catch {
            RouterLog.write(
                "[Router] forceLocalDriverRebuild: capture restart failed (\(capture.backendName)) — \(error.localizedDescription)\n"
            )
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
            // about to come up would double-play.
                for (_, b) in localBridges { b.stop() }
            localBridges.removeAll()
            // Layer 3: the sidecar zeroes the AirPlay offsets on its own
            // `mode.set("stereo")` (it owns the OwnTone REST session and the
            // persisted `speakers.offset_ms` rows). Forget our cached value
            // so the next whole-home session re-pushes rather than being
            // silenced by the deadband against a figure no longer in force.
            lastPushedAirplayOffsetMs = nil
            // Hand the default output back BEFORE any stereo path starts.
            // Direct Stereo snapshots the current default when it starts, so
            // leaving our sink installed here would make it remember a device
            // that is about to be destroyed.
            do {
                try stopWholeHomeSink()
            } catch {
                lastError = "mode.set(\(newMode.rawValue)): whole-home sink stop failed: \(error)"
                return
            }
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
            // Our own whole-home sink wraps the silent device under a
            // friendly name, so the name-based filter below cannot see it.
            // Rendering a bridge into it would close a feedback loop:
            // bridge → sink → silent device → ScreenCaptureKit → OwnTone →
            // bridge.
            if uid.hasPrefix(WholeHomeSinkOutput.uidPrefix) { return nil }
            // The raw silent sinks themselves. BlackHole is caught by the name
            // filter below, but `SyncCastAudio_UID` is named "SyncCast" and
            // would sail straight through it into the same feedback loop.
            if SystemSinkDevice.isSinkUID(uid) { return nil }
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
                RouterLog.write(
                    "[Router] bridge: rebuilt \(t.name) after AudioDeviceID changed \(existing.deviceID) -> \(coreAudioID)\n"
                )
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
            bridge.setVolume(Self.localBridgeGain(for: r))
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
        // Seed every bridge (including ones just created) with the user's
        // trim before it has rendered enough blocks to matter. The AirPlay
        // half needs IPC and is pushed by the caller via
        // `applyDeviceDelayTrims()`.
        applyLocalDelayTrims(normalizedDelayTrims())
        // Same for the tone curves: a bridge that was just created (or rebuilt
        // after an AudioDeviceID change) starts flat, and the user's curve for
        // that UID has to be pushed onto it before it renders anything the
        // user hears. Idempotent, so re-applying the whole map costs nothing.
        applyEqualizers()
        applyStereoImages()
        scheduleMeasuredAirPlayOffsetPush()
    }

    /// Measure `L_local` once the bridges have settled and push it as the
    /// AirPlay offset (Layer 3). Detached because `localPipelineLatencyMs`
    /// is nil until the first AUHAL render, and because the caller must not
    /// block bridge bring-up on a REST round trip. The deadband inside
    /// `pushMeasuredAirPlayOffset` makes repeat calls — one per
    /// `startWholeHome`, which the reconciler fires often — cheap.
    private func scheduleMeasuredAirPlayOffsetPush() {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.airplayOffsetSettleNanos)
            await self?.pushMeasuredAirPlayOffset()
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
            // `isOrdinaryOutputUID` already rejects every SyncCast-owned UID
            // prefix (including the whole-home sink) and every aggregate.
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
        // Warm the DDC capability cache off-actor so the first volume
        // intent (and the menubar's capability snapshot) doesn't race the
        // slow I2C probe, and retry previously-unsupported UIDs so display
        // sleep/replug recovers without a restart. Fail-closed:
        // unmatched/unsupported devices simply stay on the existing
        // CoreAudio-or-nothing path.
        DDCDisplayVolumeController.shared.refreshCapabilities(
            uids: Array(direct.coveredOutputUIDs)
        )
        RouterLog.write(
            "[Router] direct stereo active: \(direct.diagnostic)\n"
        )
    }

    @discardableResult
    private func stopDirectStereoOutput() throws -> String? {
        guard let direct = directStereoOutput else { return nil }
        guard direct.stop() else {
            let status = direct.lastStopStatusText ?? direct.diagnostic
            RouterLog.write(
                "[Router] direct stereo stop failed: \(status) \(direct.diagnostic)\n"
            )
            throw DirectStereoOutput.DirectStereoError.stopFailed(status)
        }
        let status = direct.lastStopStatusText
        RouterLog.write(
            "[Router] direct stereo stopped: \(status ?? "unknown")\n"
        )
        directStereoOutput = nil
        return status
    }

    // MARK: - System sink stereo path
    //
    // The point of this path is one thing: make the macOS volume UI — the
    // menu-bar slider, F11/F12, the HUD, LinearMouse's scroll wheel — control
    // SyncCast's local Stereo output natively, with no CGEventTap and no
    // Accessibility permission. It does that by giving macOS a virtual HAL
    // device that HAS a volume control (`SystemSinkDevice`), tapping that
    // device pre-driver, and re-applying the scalar ourselves on the way out.

    /// Snapshot of the sink path for the UI.
    public struct SystemSinkStatus: Sendable, Equatable {
        public let active: Bool
        public let uid: String?
        /// What the Sound menu shows while the path runs.
        public let displayName: String?
        /// False while active means the user picked another output.
        public let isSystemDefaultOutput: Bool
        /// System volume, on the HAL's 0…1 perceptual scale.
        public let masterVolume: Float
        public let masterMuted: Bool

        public init(
            active: Bool,
            uid: String?,
            displayName: String?,
            isSystemDefaultOutput: Bool,
            masterVolume: Float,
            masterMuted: Bool
        ) {
            self.active = active
            self.uid = uid
            self.displayName = displayName
            self.isSystemDefaultOutput = isSystemDefaultOutput
            self.masterVolume = masterVolume
            self.masterMuted = masterMuted
        }
    }

    /// Which stereo output path this Router is running.
    public var stereoPath: StereoOutputPathPolicy.Path { stereoOutputPath }

    public func systemSinkStatus() -> SystemSinkStatus {
        guard let sink = systemSink, sink.isActive else {
            return SystemSinkStatus(
                active: false,
                uid: SystemSinkDevice.resolved?.uid,
                displayName: SystemSinkDevice.resolved?.displayName,
                isSystemDefaultOutput: false,
                masterVolume: sinkMasterVolume,
                masterMuted: sinkMasterMuted
            )
        }
        return SystemSinkStatus(
            active: true,
            uid: sink.sinkUID,
            displayName: sink.displayName,
            isSystemDefaultOutput: sink.isSystemDefaultOutput,
            masterVolume: sinkMasterVolume,
            masterMuted: sinkMasterMuted
        )
    }

    /// The sink path is not merely SELECTED but actually running. Everything
    /// that changes audio behaviour keys on this, so the volume stage and the
    /// gain stage can never disagree about which regime is in force.
    private var systemSinkPathIsLive: Bool {
        mode == .stereo && stereoOutputPath == .sink
            && (systemSink?.isActive ?? false)
    }

    /// True when the sink path is running but macOS is rendering somewhere
    /// else — the user picked another output in the Sound menu. Treated as
    /// intent by the AppModel (stop routing), never fought with a re-assert.
    public var systemSinkDisplaced: Bool {
        guard let sink = systemSink, sink.isActive else { return false }
        return !sink.isSystemDefaultOutput
    }

    /// Push a new system volume (the sink's scalar) into the output stage.
    ///
    /// Called by the menubar's sink volume observer whenever the SINK's
    /// `kAudioDevicePropertyVolumeScalar` / `Mute` changes — i.e. whenever the
    /// user moves the system slider, presses a volume key, scrolls
    /// LinearMouse, or asks Siri. Nil arguments leave that half unchanged.
    public func setSystemSinkMaster(volume: Float?, muted: Bool?) {
        // The payload is a HINT that something changed, not the value. Two
        // unstructured Task hops separate the HAL callback from this actor and
        // neither guarantees ordering, so with a 20 ms debounce and a held
        // volume key repeating every ~33 ms a STALE value could be the last to
        // land and stick. Re-reading the device makes ordering irrelevant: the
        // sink is the authority on its own scalar.
        let authoritative: (volume: Float?, muted: Bool?) =
            systemSink?.readMaster() ?? (volume: nil, muted: nil)
        let volume = authoritative.volume ?? volume
        let muted = authoritative.muted ?? muted
        var changed = false
        if let volume {
            let clamped = max(0, min(1, volume))
            if clamped != sinkMasterVolume {
                sinkMasterVolume = clamped
                changed = true
            }
        }
        if let muted, muted != sinkMasterMuted {
            sinkMasterMuted = muted
            changed = true
        }
        guard changed else { return }
        replan()
    }

    /// Per-device backend verdicts for the sink path, keyed by CoreAudio UID.
    /// Same conservative classification as Direct Stereo, except that a device
    /// with neither CoreAudio volume nor DDC is `.softwareGain` rather than
    /// uncontrollable: unlike Direct Stereo, the sink path renders the samples
    /// itself and can always attenuate them.
    public func systemSinkVolumeCapabilities() async -> [String: SystemSinkVolumeLaw.Backend] {
        guard mode == .stereo, stereoOutputPath == .sink,
              let sink = systemSink, sink.isActive
        else {
            return [:]
        }
        let uids = sinkOutputUIDs()
        // Each of these drives real I2C traffic to the display, and neither
        // checks cancellation itself, so a burst of eligibility transitions
        // would queue up probes whose results are all discarded but which all
        // still run. Check the task's own cancellation around them.
        if Task.isCancelled { return [:] }
        DDCDisplayVolumeController.shared.probeCapabilities(uids: uids)
        await DDCDisplayVolumeController.shared.waitForSettledCapabilities(uids: uids)
        if Task.isCancelled { return [:] }
        guard mode == .stereo, stereoOutputPath == .sink,
              let settled = systemSink, settled.isActive
        else {
            return [:]
        }
        var result: [String: SystemSinkVolumeLaw.Backend] = [:]
        var changed = false
        for uid in sinkOutputUIDs() {
            let backend = classifySinkVolumeBackend(uid: uid)
            result[uid] = backend
            if sinkVolumeBackends[uid] != backend {
                sinkVolumeBackends[uid] = backend
                changed = true
            }
        }
        // The DDC verdict lands ASYNCHRONOUSLY. Until it does, a display with
        // no CoreAudio volume classifies as `.softwareGain` — correct, but the
        // cached verdict would then keep it there forever. Adopting the
        // settled answer here (and replanning when it moved) is what promotes
        // the display to its own DDC volume once the probe finishes.
        if changed { replan() }
        return result
    }

    /// CoreAudio UIDs the sink path currently renders to.
    private func sinkOutputUIDs() -> [String] {
        if !aggregateUIDByDeviceID.isEmpty {
            return Array(aggregateUIDByDeviceID.values)
        }
        return localOutputs.values.map(\.deviceUID)
    }

    private func classifySinkVolumeBackend(
        uid: String
    ) -> SystemSinkVolumeLaw.Backend {
        switch DirectStereoVolumeReadback.backend(
            coreAudioVolumeSettable:
                AggregateDevice.probeHardwareVolumeWritable(uid: uid),
            coreAudioPreviouslyRejected:
                aggregateHwVolumeUnsupportedUIDs.contains(uid),
            ddcKnownSupported:
                DDCDisplayVolumeController.shared.isKnownSupported(uid: uid)
        ) {
        case .coreAudioHardware: return .coreAudioHardware
        case .ddc: return .ddc
        case .none: return .softwareGain
        }
    }

    /// The level the system volume should ADOPT when the sink takes over the
    /// default output — never a jump.
    ///
    /// This is a hearing-safety decision, not a nicety. The master is copied
    /// straight onto each physical device's hardware volume, and a sink's own
    /// scalar is 1.0 on a first activation (fresh driver, or a BlackHole
    /// nobody has touched). Seeding from the level the user is ALREADY
    /// listening at makes the takeover silent-running: the first write to the
    /// speakers is the value they already had.
    ///
    /// Order of evidence:
    ///   1. the outgoing default output's own scalar — that IS "how loud
    ///      things are right now";
    ///   2. failing that (an aggregate has no volume), the loudest of the
    ///      physical outputs we are about to drive, so nothing gets turned UP;
    ///   3. failing that, nil — leave the sink's stored level alone rather
    ///      than inventing a number.
    private func systemSinkSeedVolume(devices: [Device]) -> Float? {
        if let currentDefault = try? DirectStereoOutput.readDefaultOutput(),
           let uid = DirectStereoOutput.readDeviceUID(currentDefault),
           !SystemSinkDevice.isSinkUID(uid),
           let level = AggregateDevice.readHardwareVolume(uid: uid) {
            return level
        }
        let targetLevels = devices.compactMap { device -> Float? in
            guard device.transport == .coreAudio,
                  routing[device.id]?.enabled ?? false,
                  let uid = device.coreAudioUID,
                  !SystemSinkDevice.isSinkUID(uid)
            else {
                return nil
            }
            return AggregateDevice.readHardwareVolume(uid: uid)
        }
        return targetLevels.max()
    }

    /// Bring the sink path up: install the sink as default output, pin a
    /// Process Tap to it, then open the ordinary local driver on top of the
    /// tap's ring.
    private func startSystemSinkPath(devices: [Device]) async throws {
        guard #available(macOS 14.2, *) else {
            throw NSError(domain: "SyncCastRouter", code: 110, userInfo: [
                NSLocalizedDescriptionKey:
                    "the system-volume Stereo path needs macOS 14.2+ (Core Audio Process Tap)"
            ])
        }
        // Refuse virtual devices as OUTPUTS before anything is taken over.
        //
        // Rendering into a userland audio plug-in while tapping another one
        // wedges coreaudiod on this machine — see `VirtualOutputPolicy` for
        // the measured failure (108 s start, a teardown that never returns,
        // every virtual device dead machine-wide until coreaudiod is killed).
        // The AppModel hides these from the picker on the sink path; this is
        // the backstop for a selection that arrives some other way (persisted
        // routing, a device that appears mid-session, an API caller).
        //
        // Placed FIRST, so the failure costs nothing: no sink installed, no
        // sample rate changed, no default output to give back.
        //
        // Phase timing runs from here. The 108 s stall on 2026-09-05 left a
        // log that said only "started" and "finished", which fits every
        // candidate cause equally well; `PhaseTimer` makes the next one name
        // itself. Cheap: four `DispatchTime.now()` reads per start.
        var phases = PhaseTimer(scope: "[Router] systemSink.start")
        let virtualTargets = enabledLocalOutputs(devices: devices)
            .filter { VirtualOutputPolicy.isVirtualOutput(uid: $0.uid) }
        if !virtualTargets.isEmpty {
            let message = VirtualOutputPolicy.rejectionMessage(
                names: virtualTargets.map { "\($0.name) (\($0.uid))" }
            )
            RouterLog.write("[Router] system sink refused: \(message)")
            throw NSError(domain: "SyncCastRouter", code: 113, userInfo: [
                NSLocalizedDescriptionKey: message
            ])
        }
        guard let candidate = SystemSinkDevice.resolved else {
            throw SystemSinkDevice.SystemSinkError.noSinkInstalled
        }
        // A sink with no volume control would hand the user exactly the greyed
        // slider this path exists to remove. Fail loudly instead.
        guard SystemSinkDevice.exposesVolumeControl(uid: candidate.uid) else {
            throw NSError(domain: "SyncCastRouter", code: 111, userInfo: [
                NSLocalizedDescriptionKey:
                    "sink device \(candidate.uid) exposes no volume control; refusing to make it the default output"
            ])
        }
        phases.mark("preflight")
        let sink = systemSink ?? SystemSinkDevice(candidate: candidate)
        // `SystemSinkDevice.start` emits its own sub-phases (sample-rate
        // settle, default-output write, system-output write, volume seed), so
        // this mark is the takeover total those add up to.
        try sink.start(seedVolume: systemSinkSeedVolume(devices: devices))
        phases.mark("sink takeover")
        systemSink = sink
        sinkVolumeLaw = SystemSinkVolumeLaw.law(forDeviceUID: candidate.uid)
        // Seed the master from the device so the first replan reproduces the
        // level the user already had, rather than jumping to full scale.
        let master = sink.readMaster()
        sinkMasterVolume = master.volume ?? sinkMasterVolume
        sinkMasterMuted = master.muted ?? false

        let tap = TapCapture(
            sampleRate: sampleRate,
            channelCount: channelCount,
            tapDeviceUID: candidate.uid
        )
        tap.onUnexpectedStop = { [weak self] in
            Task { await self?.handleCaptureDied() }
        }
        do {
            try await tap.start()
            phases.mark("tap start")
        } catch {
            phases.mark("tap start (failed)")
            // If the rollback ALSO fails to give the default output back, keep
            // the sink: the outer unwind (`stopSystemSinkPathIgnoringErrors`)
            // is the only thing left that can retry, and it needs an object to
            // retry with. Dropping it here would leave macOS pointed at a
            // silent device with nobody owning the restore.
            if sink.stop() {
                systemSink = nil
            } else {
                RouterLog.write(
                    "[Router] system sink rollback could not restore the default output (\(sink.lastStopStatusText ?? "unknown")); keeping ownership so teardown can retry\n"
                )
            }
            throw error
        }
        sinkCapture = tap
        RouterLog.write(
            "[Router] system sink active: \(sink.diagnostic) law=minDb\(sinkVolumeLaw.minDb)\n"
        )
        reconcileLocalDriver(devices: devices)
        phases.mark("output open")
        // `reconcileLocalDriver` reports failures by setting `lastError` and
        // returning — fine on the other paths, fatal here: the sink is already
        // the system default, so "no output opened" means macOS is rendering
        // into a silent device and nothing plays it. Throwing hands it to the
        // start() catch, which unwinds the sink and gives the default back.
        guard !localOutputs.isEmpty else {
            throw NSError(domain: "SyncCastRouter", code: 112, userInfo: [
                NSLocalizedDescriptionKey:
                    "system sink is the default output but no local output could be opened"
                    + (lastError.map { ": \($0)" } ?? "")
            ])
        }
    }

    /// Tear the sink path down. Returns the sink's stop status (nil when the
    /// path was not running). Throws when the default output could not be
    /// restored — same fail-loud contract as the other default-output owners,
    /// so app termination is blocked rather than leaving macOS mute.
    @discardableResult
    private func stopSystemSinkPath() throws -> String? {
        sinkCapture?.stop()
        sinkCapture = nil
        sinkVolumeBackends.removeAll()
        guard let sink = systemSink else { return nil }
        guard sink.stop() else {
            let status = sink.lastStopStatusText ?? sink.diagnostic
            RouterLog.write(
                "[Router] system sink stop failed: \(status)\n"
            )
            throw SystemSinkDevice.SystemSinkError.stopFailed(status)
        }
        let status = sink.lastStopStatusText
        RouterLog.write(
            "[Router] system sink stopped: \(status ?? "unknown")\n"
        )
        systemSink = nil
        return status
    }

    /// Failure-path unwind: used where we are already handling an error and
    /// have nothing better to do with a second one than log it.
    private func stopSystemSinkPathIgnoringErrors() async {
        do {
            try stopSystemSinkPath()
        } catch {
            RouterLog.write(
                "[Router] system sink unwind failed: \(error)\n"
            )
        }
    }

    /// Apply the system volume to every output the sink path drives.
    ///
    /// Per device: hardware scalar where the device has one (loudness then
    /// matches what macOS would have done natively), DDC/CI where a display
    /// answers it, and software gain — converted through the sink's dB law —
    /// for everything else. The per-device slider rides on top as a balance.
    private func applySystemSinkVolumes() {
        guard systemSinkPathIsLive else { return }
        if let agg = aggregateDevice, let aggOut = localOutputs[agg.aggregateUID] {
            for (devID, uid) in aggregateUIDByDeviceID {
                let route = routing[devID] ?? DeviceRouting(deviceID: devID)
                let pair = agg.subdeviceChannelOffset(uid: uid)
                    .map { $0 / max(1, aggOut.channelCount) }
                applySystemSinkDeviceVolume(
                    uid: uid, route: route, output: aggOut, pair: pair
                )
            }
            return
        }
        for (devID, out) in localOutputs {
            let route = routing[devID] ?? DeviceRouting(deviceID: devID)
            applySystemSinkDeviceVolume(
                uid: out.deviceUID, route: route, output: out, pair: 0
            )
        }
    }

    private func applySystemSinkDeviceVolume(
        uid: String,
        route: DeviceRouting,
        output: LocalOutput,
        pair: Int?
    ) {
        let backend = sinkVolumeBackends[uid] ?? classifySinkVolumeBackend(uid: uid)
        sinkVolumeBackends[uid] = backend
        let plan = SystemSinkVolumeLaw.plan(
            masterScalar: sinkMasterVolume,
            masterMuted: sinkMasterMuted,
            balance: route.volume,
            deviceMuted: route.muted,
            backend: backend,
            law: sinkVolumeLaw
        )
        switch plan.backend {
        case .coreAudioHardware:
            let muteOK = AggregateDevice.applyHardwareMute(uid: uid, muted: plan.muted)
            let target = DirectStereoOutput.plannedCoreAudioVolume(
                volume: plan.hardwareScalar ?? 0,
                muted: plan.muted,
                muteAccepted: muteOK
            )
            if AggregateDevice.applyHardwareVolume(uid: uid, volume: target) {
                // Hardware carries it — make sure no stale software gain from
                // a previous classification double-attenuates.
                if let pair { output.setSoftwareGain(pair: pair, gain: 1.0) }
                return
            }
            // The driver claimed settable and refused the write. Demote and
            // re-apply through the next backend on the SAME replan, so the
            // user never sees a slider that did nothing.
            aggregateHwVolumeUnsupportedUIDs.insert(uid)
            aggregateHwVolumeRejectionCounts[uid, default: 0] += 1
            sinkVolumeBackends[uid] = classifySinkVolumeBackend(uid: uid)
            applySystemSinkDeviceVolume(
                uid: uid, route: route, output: output, pair: pair
            )
        case .ddc:
            let normalized = Float(plan.ddcPercent ?? 0) / 100
            let accepted = DDCDisplayVolumeController.shared.enqueueApply(
                uid: uid, volume: normalized, muted: plan.muted
            )
            // Software gain is the safety net, never a second attenuator: it
            // only engages when DDC refused outright.
            if accepted {
                if let pair { output.setSoftwareGain(pair: pair, gain: 1.0) }
                return
            }
            sinkVolumeBackends[uid] = .softwareGain
            applySystemSinkDeviceVolume(
                uid: uid, route: route, output: output, pair: pair
            )
        case .softwareGain:
            // Software gain is the LAST attenuator on this path — the whole-
            // output gain is pinned to unity and both hardware backends have
            // already refused. A nil pair (the aggregate's subdevice map and
            // ours disagreeing mid-rebuild) would mean this device ignores the
            // system volume AND its own mute, at full scale. Fall back to the
            // first pair and say so once.
            let resolvedPair = pair ?? 0
            if pair == nil, !loggedHwVolumeRejectionUIDs.contains(uid) {
                loggedHwVolumeRejectionUIDs.insert(uid)
                RouterLog.write(
                    "[Router] system sink: no channel-pair offset for \(uid.prefix(20)); applying software gain to pair 0 (further reports silenced)\n"
                )
            }
            output.setSoftwareGain(
                pair: resolvedPair, gain: plan.softwareAmplitude ?? 0
            )
        }
    }

    // MARK: - Per-device equalizer
    //
    // One tone curve per physical output, keyed by CoreAudio UID and applied
    // inside `LocalOutput.render()` on that device's own channel pair. The
    // Router keeps the whole map rather than pushing one-shot edits so that a
    // device which is re-plugged, re-enabled, or lands in a rebuilt aggregate
    // picks its curve straight back up: `applyEqualizers()` runs on every
    // driver reconcile and every replan, and is a no-op when nothing moved.
    //
    // SCOPE: every leg whose samples this process renders.
    //
    //   * Local Stereo on the system-sink or ScreenCaptureKit legs
    //     (`localOutputs`), individual or aggregate — one pair per physical
    //     device.
    //   * Whole-home local outputs (`localBridges`) — one bridge per physical
    //     device, rendering OwnTone's fifo broadcast. Same UID key, so a
    //     speaker tuned in Stereo keeps its curve in whole-home.
    //   * The whole-home AirPlay leg, as ONE group curve applied upstream in
    //     `AudioSocketWriter` — see `airPlayGroupEqualizerUID`.
    //
    // It does NOT cover Direct Stereo: the HAL renders straight to the public
    // aggregate and we never see the samples. That is stated in the UI so a
    // hidden control is never mistaken for a broken one.

    /// User curves keyed by CoreAudio UID. Absent means flat.
    ///
    /// One reserved key, `airPlayGroupEqualizerUID`, is not a CoreAudio device
    /// at all: it carries the AirPlay group curve. Keeping it in the same map
    /// means the menubar pushes ONE map, persists it in ONE store, and the
    /// group curve is remembered exactly like a device's.
    private var equalizerSettingsByUID: [String: EqualizerSettings] = [:]

    /// Reserved pseudo-UID for the AirPlay group curve.
    ///
    /// OwnTone sends ONE stream to every receiver — the sidecar's fifo input
    /// is upstream of the fan-out — so per-receiver equalisation is not
    /// something this architecture can express at all. What it CAN do is shape
    /// that single stream, which is what this key means: one curve, applied to
    /// every AirPlay receiver together.
    ///
    /// Namespaced so it cannot collide with a real CoreAudio device UID.
    public static let airPlayGroupEqualizerUID = "syncast.airplay-group"

    /// The AirPlay group curve currently held, whether or not a writer exists
    /// to apply it. Kept separate from the writer so a sidecar reconnect
    /// (which builds a brand-new `AudioSocketWriter`) can re-seed it, exactly
    /// as the master fader is re-seeded.
    private var airPlayGroupEqualizer: EqualizerSettings {
        equalizerSettingsByUID[Self.airPlayGroupEqualizerUID] ?? .flat
    }

    /// Replace the whole UID → curve map. The menubar owns the persisted
    /// store and pushes it in full, which keeps "the user deleted a device's
    /// curve" and "the user changed it" on the same path.
    public func setEqualizers(_ settingsByUID: [String: EqualizerSettings]) {
        var sanitized: [String: EqualizerSettings] = [:]
        for (uid, settings) in settingsByUID where !uid.isEmpty {
            let clean = settings.sanitized()
            // Storing flat curves would make `applyEqualizers` push identical
            // no-ops forever; absent already means flat.
            guard !clean.isNeutral || clean.hasUserCurve else { continue }
            sanitized[uid] = clean
        }
        guard sanitized != equalizerSettingsByUID else { return }
        equalizerSettingsByUID = sanitized
        applyEqualizers()
    }

    /// Set (or clear, with `.flat`) one device's curve.
    public func setEqualizer(uid: String, settings: EqualizerSettings) {
        guard !uid.isEmpty else { return }
        var next = equalizerSettingsByUID
        let clean = settings.sanitized()
        if clean.isNeutral && !clean.hasUserCurve {
            next.removeValue(forKey: uid)
        } else {
            next[uid] = clean
        }
        setEqualizers(next)
    }

    /// The curves the Router currently holds. Mostly for tests and reports.
    public func equalizers() -> [String: EqualizerSettings] { equalizerSettingsByUID }

    /// CoreAudio UIDs whose samples this process renders itself, and can
    /// therefore equalise: the local Stereo pairs in stereo mode, the local
    /// bridges in whole-home mode. Empty on Direct Stereo — which is exactly
    /// the question the UI asks before offering the control.
    ///
    /// The AirPlay group curve is NOT in this list: it is not a device, and
    /// the UI offers it from its own row.
    public func equalizableOutputUIDs() -> [String] {
        if mode == .wholeHome {
            return localBridges.values.map(\.deviceUID)
        }
        return localPairTargets().map(\.uid)
    }

    /// Per-device limiter counts, keyed by UID. Non-zero means that device's
    /// curve is pushing the signal past full scale.
    public func equalizerClipCounts() -> [String: Int64] {
        // The counter lives on the LocalOutput, not on the pair, so in
        // aggregate mode every subdevice reports the aggregate AUHAL's total.
        // Named honestly in the UI ("this output chain is clipping") rather
        // than pretending to a per-speaker figure we do not have.
        var result: [String: Int64] = [:]
        for target in localPairTargets() {
            result[target.uid] = target.output.equalizerClipCount
        }
        for bridge in localBridges.values {
            result[bridge.deviceUID] = bridge.equalizerClipCount
        }
        if let writer = audioWriter {
            result[Self.airPlayGroupEqualizerUID] = writer.equalizerClipCount
        }
        return result
    }

    /// UID → (AUHAL, channel-pair) for every physical output we render.
    ///
    /// The addressing every per-device render feature shares: the equalizer
    /// and the per-device delay compensation both need "which AUHAL, which
    /// channel pair" for a CoreAudio UID, and two copies of that mapping would
    /// be two chances to disagree about which speaker is pair 1.
    ///
    /// Mirrors `applySystemSinkVolumes`'s mapping: in aggregate mode the pair
    /// comes from the aggregate's subdevice channel offset, in individual mode
    /// there is one output and one pair. A subdevice whose offset cannot be
    /// resolved is SKIPPED rather than defaulted to pair 0 — unlike a volume,
    /// applying the wrong speaker's tone curve (or delay) is silent and
    /// confusing, and the fallback would put device B's setting on device A.
    private func localPairTargets() -> [(uid: String, output: LocalOutput, pair: Int)] {
        guard mode == .stereo else { return [] }
        if let aggregate = aggregateDevice,
           let output = localOutputs[aggregate.aggregateUID] {
            return aggregateUIDByDeviceID.values.compactMap { uid in
                guard let offset = aggregate.subdeviceChannelOffset(uid: uid) else {
                    return nil
                }
                return (uid: uid, output: output, pair: offset / max(1, output.channelCount))
            }
        }
        return localOutputs.values.map { (uid: $0.deviceUID, output: $0, pair: 0) }
    }

    /// Push the stored curves onto the live outputs. Idempotent — a pair
    /// already holding a curve takes `LocalOutput.setEqualizer`'s no-op path —
    /// so this rides along with every reconcile and replan rather than needing
    /// its own trigger.
    private func applyEqualizers() {
        for target in localPairTargets() {
            target.output.setEqualizer(
                pair: target.pair,
                settings: equalizerSettingsByUID[target.uid] ?? .flat
            )
        }
        // Whole-home local leg. Keyed by the SAME CoreAudio UID as the stereo
        // path, which is what makes a curve the user dialled in on one mode
        // apply in the other without re-entering it.
        for bridge in localBridges.values {
            bridge.setEqualizer(equalizerSettingsByUID[bridge.deviceUID] ?? .flat)
        }
        // Whole-home AirPlay leg: one curve for all receivers, applied
        // upstream of OwnTone's fan-out.
        audioWriter?.setEqualizer(airPlayGroupEqualizer)
    }

    // MARK: - Per-device stereo image
    //
    // Mid/side width plus recursive crosstalk cancellation per physical
    // output, keyed by CoreAudio UID and applied inside the same render
    // callbacks as the equalizer, one stage later on the signal. The Router
    // keeps the whole map for the same reason it keeps the whole curve map: a
    // device that is re-plugged, re-enabled, or lands in a rebuilt aggregate
    // picks its setting straight back up.
    //
    // SCOPE is deliberately NARROWER than the equalizer's by one leg:
    //
    //   * Local Stereo on the system-sink / capture legs — yes.
    //   * Whole-home local outputs (`localBridges`) — yes, same UID key.
    //   * Whole-home AirPlay receivers — NO. There is no group setting.
    //     Crosstalk cancellation is a statement about ONE listener's geometry
    //     in front of ONE cabinet; applying a single one upstream of OwnTone's
    //     fan-out would impose one room's numbers on every receiver in the
    //     house. The equalizer's group curve is defensible because "less bass"
    //     survives being shared; "cancel the path from the left driver to my
    //     right ear" does not.
    //   * Direct Stereo — no, the HAL renders straight into the public
    //     aggregate and we never see the samples.

    /// User settings keyed by CoreAudio UID. Absent means neutral.
    private var stereoImageSettingsByUID: [String: StereoImageSettings] = [:]

    /// Replace the whole UID → setting map. The menubar owns the persisted
    /// store and pushes it in full, which keeps "the user cleared a device's
    /// imaging" and "the user changed it" on the same path.
    public func setStereoImages(_ settingsByUID: [String: StereoImageSettings]) {
        var sanitized: [String: StereoImageSettings] = [:]
        for (uid, settings) in settingsByUID where !uid.isEmpty {
            let clean = settings.sanitized()
            // Storing neutral settings would make `applyStereoImages` push
            // identical no-ops forever; absent already means neutral.
            guard !clean.isNeutral || clean.hasUserSetting else { continue }
            sanitized[uid] = clean
        }
        guard sanitized != stereoImageSettingsByUID else { return }
        stereoImageSettingsByUID = sanitized
        applyStereoImages()
    }

    /// Set (or clear, with `.neutral`) one device's stereo image.
    public func setStereoImage(uid: String, settings: StereoImageSettings) {
        guard !uid.isEmpty else { return }
        var next = stereoImageSettingsByUID
        let clean = settings.sanitized()
        if clean.isNeutral && !clean.hasUserSetting {
            next.removeValue(forKey: uid)
        } else {
            next[uid] = clean
        }
        setStereoImages(next)
    }

    /// The settings the Router currently holds. Mostly for tests and reports.
    public func stereoImages() -> [String: StereoImageSettings] { stereoImageSettingsByUID }

    /// CoreAudio UIDs whose samples this process renders itself, and can
    /// therefore image. Same set as `equalizableOutputUIDs()` minus the
    /// AirPlay group, which is not offered here at all.
    public func stereoImageableOutputUIDs() -> [String] {
        equalizableOutputUIDs()
    }

    /// Per-device limiter counts, keyed by UID. Non-zero means that device's
    /// width or crosstalk setting is pushing the signal past full scale.
    public func stereoImageClipCounts() -> [String: Int64] {
        var result: [String: Int64] = [:]
        for target in localPairTargets() {
            result[target.uid] = target.output.stereoImageClipCount
        }
        for bridge in localBridges.values {
            result[bridge.deviceUID] = bridge.stereoImageClipCount
        }
        return result
    }

    /// Push the stored settings onto the live outputs. Idempotent — a pair
    /// already holding a setting takes `LocalOutput.setStereoImage`'s no-op
    /// path — so this rides along with every reconcile and replan rather than
    /// needing its own trigger.
    private func applyStereoImages() {
        for target in localPairTargets() {
            target.output.setStereoImage(
                pair: target.pair,
                settings: stereoImageSettingsByUID[target.uid] ?? .neutral
            )
        }
        for bridge in localBridges.values {
            bridge.setStereoImage(stereoImageSettingsByUID[bridge.deviceUID] ?? .neutral)
        }
    }

    // MARK: - Per-device delay compensation (local Stereo)
    //
    // A millisecond hold per physical output, applied inside
    // `LocalOutput.render()` on that device's own channel pair. It exists
    // because a display's internal audio processing adds tens of milliseconds
    // that `kAudioDevicePropertyLatency` does not describe, so two speakers
    // fed the identical stream still arrive apart.
    //
    // Two parts, both in frames, summed and then normalised so the earliest
    // output sits at 0 (nothing can play early — see `LocalDelayTrimPlanner`):
    //
    //   * an automatic seed from what each device DOES report, so honestly
    //     specified hardware lines up before the user touches anything;
    //   * the user's signed trim, for the latency nothing reports.
    //
    // SCOPE, same as the equalizer's: the `localOutputs` path only. Direct
    // Stereo never routes samples through us, and whole-home has its own
    // per-output trim (`DeviceDelayTrim` / `applyDeviceDelayTrims`) on a
    // different leg with a different clock domain. The two are deliberately
    // separate settings — see `LocalDelayTrim`.

    /// User trims in milliseconds, keyed by CoreAudio UID. Absent means 0.
    private var localDelayTrimMsByUID: [String: Int] = [:]
    /// Automatic seed in frames, keyed by CoreAudio UID. NEGATIVE of the
    /// device's reported output latency: a device that reports more latency
    /// already sounds later and therefore needs less hold.
    private var localDelaySeedFramesByUID: [String: Int] = [:]
    /// The UID set `localDelaySeedFramesByUID` was probed for. Probing walks
    /// CoreAudio properties, so it is redone when the covered set changes
    /// rather than on every replan.
    private var localDelaySeedProbedUIDs: Set<String> = []
    /// Seeds already logged, so a re-probe that finds the same numbers does
    /// not add a line per reconcile.
    private var loggedLocalDelaySeeds: [String: Int] = [:]

    /// Replace the whole UID → trim map. The menubar owns the persisted store
    /// and pushes it in full, which keeps "the user cleared this device" and
    /// "the user changed it" on one path.
    public func setLocalDelayTrims(_ msByUID: [String: Int]) {
        var sanitized: [String: Int] = [:]
        for (uid, ms) in msByUID where !uid.isEmpty {
            let clamped = LocalDelayTrim.clamp(ms)
            // 0 is the default; storing it would make every reconcile push an
            // identical no-op forever, and absent already means 0.
            guard clamped != 0 else { continue }
            sanitized[uid] = clamped
        }
        guard sanitized != localDelayTrimMsByUID else { return }
        localDelayTrimMsByUID = sanitized
        applyLocalPairDelays()
    }

    /// Set (or clear, with 0) one device's trim.
    public func setLocalDelayTrim(uid: String, ms: Int) {
        guard !uid.isEmpty else { return }
        var next = localDelayTrimMsByUID
        let clamped = LocalDelayTrim.clamp(ms)
        if clamped == 0 { next.removeValue(forKey: uid) } else { next[uid] = clamped }
        setLocalDelayTrims(next)
    }

    /// The trims the Router currently holds. Mostly for tests and reports.
    public func localDelayTrims() -> [String: Int] { localDelayTrimMsByUID }

    /// CoreAudio UIDs whose samples this process renders itself, and which can
    /// therefore be delayed. Empty on Direct Stereo and in whole-home mode —
    /// the same question the UI asks before offering the control.
    public func localDelayTrimmableOutputUIDs() -> [String] {
        localPairTargets().map(\.uid)
    }

    /// The automatic seed actually in force, in milliseconds, keyed by UID.
    /// Reported so a field log can tell "this device declares 21 ms" apart
    /// from "the user dialled 21 ms".
    public func localDelaySeedMs() -> [String: Double] {
        let rate = activeCapture.sampleRate
        return localDelaySeedFramesByUID.mapValues {
            LocalDelayTrim.milliseconds(frames: $0, sampleRate: rate)
        }
    }

    /// Probe each covered device's reported output latency and store its
    /// negative as the seed.
    ///
    /// Sign: `LocalDelayTrimPlanner` reads a larger value as "hold this pair
    /// back more". A device with a LARGER reported latency already presents
    /// later, so it needs LESS hold — hence the negation, after which
    /// normalisation slides the whole set non-negative again.
    ///
    /// Latency the device does not report is exactly what the user's trim is
    /// for; this only removes the part the hardware is honest about.
    private func refreshLocalDelaySeeds(uids: Set<String>) {
        guard uids != localDelaySeedProbedUIDs else { return }
        localDelaySeedProbedUIDs = uids
        let extraByUID = aggregateDevice?.subdeviceExtraLatencyFrames() ?? [:]
        var seeds: [String: Int] = [:]
        for uid in uids {
            guard let deviceID = try? Capture.deviceID(forUID: uid), deviceID != 0 else {
                // A UID we cannot resolve gets no seed rather than a guessed
                // one; the user's trim still applies on top of 0.
                continue
            }
            let reported = LocalOutput.outputLatencyFrames(deviceID: deviceID)
                + Int64(extraByUID[uid] ?? 0)
            seeds[uid] = -Int(clamping: reported)
        }
        localDelaySeedFramesByUID = seeds
        let rate = activeCapture.sampleRate
        for (uid, frames) in seeds where loggedLocalDelaySeeds[uid] != frames {
            loggedLocalDelaySeeds[uid] = frames
            let ms = LocalDelayTrim.milliseconds(frames: -frames, sampleRate: rate)
            RouterLog.write(
                String(
                    format: "[Router] delay seed: %@ reports %.1f ms output latency\n",
                    String(uid.prefix(20)), ms
                )
            )
        }
    }

    /// Push seed + user trim onto every live output's channel pairs.
    ///
    /// Idempotent (`LocalOutput.setPairDelays` no-ops on an unchanged map), so
    /// this rides along with every reconcile and replan the way the equalizer
    /// does. Distinct from the whole-home `applyLocalDelayTrims(_:)` above it,
    /// which pushes `DeviceDelayTrim` values to `localBridges`.
    private func applyLocalPairDelays() {
        let targets = localPairTargets()
        guard !targets.isEmpty else { return }
        refreshLocalDelaySeeds(uids: Set(targets.map(\.uid)))
        // Group by AUHAL: normalisation is per output, because the pairs of
        // one output share one read cursor. In aggregate mode that is a single
        // group covering every physical device, which is exactly the set the
        // user is comparing by ear.
        var groups: [ObjectIdentifier: (output: LocalOutput, seeds: [Int: Int], user: [Int: Int])] = [:]
        for target in targets {
            let key = ObjectIdentifier(target.output)
            var group = groups[key] ?? (output: target.output, seeds: [:], user: [:])
            group.seeds[target.pair] = localDelaySeedFramesByUID[target.uid] ?? 0
            group.user[target.pair] = localDelayTrimMsByUID[target.uid] ?? 0
            groups[key] = group
        }
        let rate = activeCapture.sampleRate
        let headroom = LocalDelayTrimPlanner.headroomFrames(
            capacityFrames: activeCapture.ringBuffer.capacityFrames,
            floorFrames: ringFloorFrames(logWarnings: false)
        )
        for (_, group) in groups {
            let pairCount = max(1, group.output.outputChannelCount / max(1, group.output.channelCount))
            let offsets = LocalDelayTrimPlanner.offsetFrames(
                pairCount: pairCount,
                seedFrames: group.seeds,
                userMs: group.user,
                sampleRate: rate,
                headroomFrames: headroom
            )
            var byPair: [Int: Int] = [:]
            for (pair, frames) in offsets.enumerated() { byPair[pair] = frames }
            group.output.setPairDelays(byPair)
        }
    }

    // MARK: - Whole-home system sink ("AirPlay 全屋")

    /// Install the named silent sink as the macOS default output.
    /// Idempotent — safe to call from every whole-home start path.
    /// Throws `WholeHomeSinkOutput.WholeHomeSinkError.noSilentSinkInstalled`
    /// when neither SyncCast's own driver nor BlackHole 2ch is installed,
    /// which is the one condition that used to fail silently into
    /// double-played audio.
    private func startWholeHomeSink() throws {
        guard WholeHomeSinkOutput.enabled else { return }
        let sink = wholeHomeSink ?? WholeHomeSinkOutput()
        try sink.start()
        wholeHomeSink = sink
        RouterLog.write(
            "[Router] whole-home sink active: \(sink.diagnostic)\n"
        )
    }

    /// Restore the user's previous default output and destroy the sink.
    /// Throws when the restore failed, so callers can refuse to proceed (and
    /// `Router.stop` can block app termination) rather than leaving macOS
    /// pointed at a device that is about to disappear.
    @discardableResult
    private func stopWholeHomeSink() throws -> String? {
        guard let sink = wholeHomeSink else { return nil }
        guard sink.stop() else {
            let status = sink.lastStopStatusText ?? sink.diagnostic
            RouterLog.write(
                "[Router] whole-home sink stop failed: \(status) \(sink.diagnostic)\n"
            )
            throw WholeHomeSinkOutput.WholeHomeSinkError.stopFailed(status)
        }
        let status = sink.lastStopStatusText
        RouterLog.write(
            "[Router] whole-home sink stopped: \(status ?? "unknown")\n"
        )
        wholeHomeSink = nil
        return status
    }

    /// True when whole-home is running but macOS is no longer sending system
    /// audio into our sink — i.e. the user (or a headphone plug) moved the
    /// default output away and every track is now playing twice: once out of
    /// the new default directly, once through the SCK tap → OwnTone → outputs.
    ///
    /// Polled by the app's 1 Hz health loop. See
    /// `WholeHomeSinkOutput.isSystemDefaultOutput` for why this is a poll
    /// rather than a CoreAudio property listener.
    public var wholeHomeSinkDisplaced: Bool {
        guard mode == .wholeHome, let sink = wholeHomeSink, sink.isActive else {
            return false
        }
        return !sink.isSystemDefaultOutput
    }

    /// Put the named sink back as the macOS default output. Driven only by an
    /// explicit user action — see `WholeHomeSinkOutput.reassertDefaultOutput`
    /// for why this must never be automatic.
    @discardableResult
    public func reassertWholeHomeSink() -> Bool {
        guard let sink = wholeHomeSink else { return false }
        let ok = sink.reassertDefaultOutput()
        if !ok {
            lastError = "whole-home sink: could not reclaim the default output"
        }
        RouterLog.write(
            "[Router] whole-home sink reassert: \(ok ? "ok" : "failed") \(sink.diagnostic)\n"
        )
        return ok
    }

    /// The CoreAudio devices this Router would actually open AUHALs on: every
    /// device the user has toggled on, minus a few classes that are unsafe to
    /// route into:
    ///   - BlackHole (it's a virtual sink that may be the system source
    ///     for SCK capture; routing audio TO it could feedback)
    ///   - any of OUR previously-spawned aggregates (UID prefix match)
    ///
    /// We deliberately DO NOT exclude user-created aggregates from
    /// Audio MIDI Setup any more. With our own private aggregate now
    /// a first-class concept, blanket-filtering aggregates would
    /// surprise users who set one up themselves.
    ///
    /// Factored out of `reconcileLocalDriver` so `startSystemSinkPath` can ask
    /// the SAME question ("what will we render into?") before it takes the
    /// default output over. Two copies of this filter would be two chances for
    /// the pre-flight check and the thing it checks to disagree.
    private func enabledLocalOutputs(devices: [Device]) -> [EnabledLocalOutput] {
        devices.compactMap { dev in
            guard dev.transport == .coreAudio else { return nil }
            guard routing[dev.id]?.enabled ?? false else { return nil }
            guard let uid = dev.coreAudioUID else { return nil }
            if uid.hasPrefix(AggregateDevice.uidPrefix) { return nil }
            if uid.hasPrefix(DirectStereoOutput.uidPrefix) { return nil }
            // The whole-home sink is a BlackHole wrapper under a friendly
            // name; the name check below cannot catch it.
            if uid.hasPrefix(WholeHomeSinkOutput.uidPrefix) { return nil }
            // Never render INTO the system sink: the sink path taps it, so
            // routing audio back would be a capture loop (and on the legacy
            // paths it is simply a silent device).
            if SystemSinkDevice.isSinkUID(uid) { return nil }
            let lower = dev.name.lowercased()
            if lower.contains("blackhole") { return nil }
            return EnabledLocalOutput(deviceID: dev.id, uid: uid, name: dev.name)
        }
    }

    private func reconcileLocalDriver(devices: [Device]) {
        // Index name lookups so master picker can score by device name.
        var nameByUID: [String: String] = [:]
        for dev in devices {
            if let u = dev.coreAudioUID { nameByUID[u] = dev.name }
        }

        let enabled = enabledLocalOutputs(devices: devices)
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
        // A rebuilt driver has fresh, flat AUHALs. Re-seed the user's curves
        // here — this is the one place that sees every open/close, so a
        // re-plugged monitor gets its tone control back without the menubar
        // having to notice the transition. Same argument for the per-device
        // delay: a rebuilt aggregate starts at 0 on every pair.
        applyEqualizers()
        applyStereoImages()
        applyLocalPairDelays()
    }

    /// The producer the local outputs read from.
    ///
    /// The sink path replaces the process-wide capture backend with a Process
    /// Tap pinned to the sink device, so every consumer must resolve the ring
    /// through here rather than reaching for `capture` directly — an AUHAL
    /// opened on the wrong ring is silent with no error anywhere.
    private var activeCapture: any SystemAudioCapture {
        sinkCapture ?? capture
    }

    /// How far behind the producer a freshly opened AUHAL should render.
    ///
    /// Keyed on WHICH producer is feeding the ring, not on which mode the user
    /// picked: ScreenCaptureKit's 1024-frame chunks arrive on a media-service
    /// thread we do not control and need the historical 100 ms of slack, while
    /// the sink path's Process Tap is a HAL IOProc delivering regular
    /// 512-frame blocks and only needs ~3 of them. The difference is pure A/V
    /// lag, so it is worth keeping them apart. `SYNCAST_SINK_RING_FLOOR_MS`
    /// overrides the sink figure (10…500; anything else logs and falls back).
    private var localOutputRingFloorFrames: Int {
        ringFloorFrames(logWarnings: true)
    }

    /// `logWarnings: false` is for read-only callers (the diagnostic line), so
    /// polling a report never emits log lines.
    private func ringFloorFrames(logWarnings: Bool) -> Int {
        let source = activeCapture
        guard sinkCapture != nil else {
            return RingFloorPolicy.frames(
                ms: RingFloorPolicy.legacyFloorMs, sampleRate: source.sampleRate
            )
        }
        let resolved = RingFloorPolicy.resolveSinkFloorMs()
        if logWarnings, let warning = resolved.warning, warning != lastSinkFloorWarning {
            lastSinkFloorWarning = warning
            RouterLog.write("[Router] \(warning)\n")
        }
        return RingFloorPolicy.frames(ms: resolved.ms, sampleRate: source.sampleRate)
    }
    /// Last emitted floor-override warning, so a bad env var is reported once
    /// per distinct value instead of on every AUHAL open.
    private var lastSinkFloorWarning: String?

    private func openIndividualAUHAL(deviceID: String, uid: String, name: String) {
        guard let coreAudioID = try? Capture.deviceID(forUID: uid),
              coreAudioID != 0 else {
            lastError = "device \(name) not found in CoreAudio"
            return
        }
        let source = activeCapture
        let out = LocalOutput(
            deviceID: coreAudioID, deviceUID: uid,
            ring: source.ringBuffer,
            sampleRate: source.sampleRate,
            channelCount: source.channelCount,
            ringFloorFrames: localOutputRingFloorFrames
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
        RouterLog.write(
            "[Router] aggregate stream diag: \(diag.summary) outputCh=\(agg.outputChannelCount)\n"
        )
        aggregateStreamDiagnostic = diag

        // AUHAL is configured for the aggregate's REAL channel count.
        // If approach (A) succeeded in narrowing every stream to 2-ch,
        // outputChannelCount == 2 and render() emits a clean stereo pair.
        // If (A) was rejected and outputChannelCount is wider (typically
        // 2*subdeviceCount), render() splats the source stereo into
        // every channel pair so all subdevices play.
        let source = activeCapture
        let out = LocalOutput(
            deviceID: agg.deviceID, deviceUID: agg.aggregateUID,
            ring: source.ringBuffer,
            sampleRate: source.sampleRate,
            channelCount: source.channelCount,
            outputChannelCount: agg.outputChannelCount,
            ringFloorFrames: localOutputRingFloorFrames
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
        // Force a re-probe on the next `applyLocalPairDelays`: CoreAudio
        // AudioObjectIDs are re-minted when a device is re-plugged, and a
        // rebuilt aggregate can carry different per-subdevice extra latency.
        // The user's trims are untouched — those are keyed by UID and belong
        // to the speaker, not to this driver instance.
        localDelaySeedProbedUIDs = []
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
            replan()
        }
    }

    private func bumpAirplayTimingEpoch(reason: String) {
        airplayTimingEpoch &+= 1
        RouterLog.write(
            "[Router] AirPlay timing epoch \(airplayTimingEpoch): \(reason)\n"
        )
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
    public func registerAirplayDevice(
        id: String,
        name: String,
        host: String,
        port: Int,
        airplayDeviceID: String? = nil
    ) async {
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
            registeredAirplayEndpointsByID[id] = endpoint
        }
        do {
            var params: [String: Any] = [
                "device_id": id,
                "transport": "airplay2",
                "host": host,
                "port": port,
                "name": name,
            ]
            // The stable Bonjour `deviceid` lets the sidecar match this
            // receiver to its OwnTone output arithmetically instead of by
            // display name. Names collide in practice — the live OwnTone
            // database already holds two different machines sharing one — and
            // a collision silently routes audio to someone else's speaker.
            if let airplayDeviceID { params["airplay_device_id"] = airplayDeviceID }
            _ = try await ipc.call("device.add", params: params)
        } catch let IpcClient.IpcError.rpcError(code, message) {
            // -32602 INVALID_PARAMS / "device_id already exists" is benign
            if code != -32602 {
                lastError = "device.add(\(name)): \(code) \(message)"
            }
        } catch {
            lastError = "device.add(\(name)): \(error)"
        }
    }

    // MARK: - Master volume

    /// Set the whole-home master fader (0…100).
    ///
    /// Applied once, upstream of OwnTone, by `AudioSocketWriter` — so it
    /// reaches the AirPlay receivers and the local bridges as the same
    /// samples, and needs no per-leg curve reconciliation. See
    /// `AudioSocketWriter`'s master-volume note for why no other placement
    /// works.
    ///
    /// Idempotent, and safe to call when no writer exists (stereo mode, or
    /// before the sidecar has connected): the value is remembered and applied
    /// to the next writer that is built.
    public func setMasterVolume(percent: Int) {
        let clamped = VolumeCurve.clampPercent(percent)
        masterVolumePercent = clamped
        audioWriter?.setMasterGain(
            VolumeCurve.masterAmplitude(forPercent: clamped)
        )
    }

    /// Current master fader position, for UI re-sync and tests.
    public var currentMasterVolumePercent: Int { masterVolumePercent }

    /// Linear gain one whole-home local bridge should apply for a routing
    /// entry.
    ///
    /// The slider's 0…1 position is a POSITION, not an amplitude:
    /// `VolumeCurve` converts it to the same decibel attenuation OwnTone
    /// applies on the AirPlay leg for the identical slider position, which is
    /// what keeps a MacBook speaker and a Xiaomi Sound equally loud at the
    /// same setting. Passing `r.volume` straight through — as this used to —
    /// made the local leg up to 10.5 dB louder mid-scale.
    ///
    /// Mute is the deliberate exception: locally we can write true zeros, so
    /// we do, even though the AirPlay leg's mute can only reach OwnTone's
    /// -30 dB floor.
    static func localBridgeGain(for routing: DeviceRouting) -> Float {
        VolumeCurve.deviceAmplitude(
            forPercent: VolumeCurve.percent(forFraction: Double(routing.volume)),
            muted: routing.muted
        )
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
        // Snap onto OwnTone's integer-percent grid before anything else. The
        // sidecar rounds to a percent anyway, so sending an unsnapped fraction
        // would leave `lastAirplayVolumeByID` holding a value the receiver
        // never actually got — and would let the local leg (which reads the
        // same slider through `VolumeCurve`) land on a different step.
        let percent = VolumeCurve.percent(forFraction: Double(volume))
        let clamped = Float(VolumeCurve.fraction(forPercent: percent))
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
        }
        lastAirplayVolumeByID[id] = clamped
        guard let ipc else { return }
        do {
            _ = try await ipc.call("device.set_volume", params: [
                "device_id": id,
                "volume": VolumeCurve.fraction(forPercent: percent),
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
        // `manualTrimMs` is deliberately EMPTY here. `DeviceRouting.manualDelayMs`
        // is now the user's per-output listening-position trim, and it is
        // applied in whole-home mode only — on the local leg via
        // `LocalAirPlayBridge.setTrimMs` and on the AirPlay leg via OwnTone's
        // per-output `offset_ms`. Feeding it to the Scheduler as well would
        // ALSO move `readBackoffFrames` for stereo-mode `localOutputs`, which
        // is a different code path with a different clock domain and is
        // explicitly out of scope. The Scheduler keeps the parameter (and its
        // tests) so the capability is not lost, but this caller never uses it.
        let plans = scheduler.plan(latencies: latencies, manualTrimMs: [:])
        // On the sink path the whole-output gain stage stays at unity: level
        // is decided per device by `applySystemSinkVolumes()` (hardware
        // scalar / DDC / per-pair software gain), and applying `route.volume`
        // here as well would attenuate twice — once as a balance, once as a
        // master — which is the classic "slider at 50 % is inaudible" bug.
        // MUST be the same predicate `applySystemSinkVolumes()` guards on —
        // an ACTIVITY check, not a configuration check. If they disagree (sink
        // selected but not running: after a displacement stop, a failed start,
        // or a stop that threw), this loop would pin every output to unity and
        // un-mute it while `applySystemSinkVolumes()` returned early, silently
        // discarding both the per-device balance AND the per-device mute.
        let sinkPath = systemSinkPathIsLive
        for plan in plans {
            guard let out = localOutputs[plan.deviceID] else { continue }
            let r = routing[plan.deviceID] ?? DeviceRouting(deviceID: plan.deviceID)
            out.setRouting(
                readBackoffFrames: plan.readBackoffFrames,
                gain: sinkPath ? 1 : r.volume,
                muted: sinkPath ? false : r.muted
            )
        }
        applySystemSinkVolumes()
        // Cheap and idempotent (an unchanged curve takes the bank's no-op
        // path), so it rides along with every replan the way the delay trims
        // do, and covers any path that reopens an AUHAL without going through
        // `reconcileLocalDriver`.
        applyEqualizers()
        applyStereoImages()
        applyLocalPairDelays()

        // In aggregate mode, also apply per-device HARDWARE volume on
        // the underlying physical DACs. The single AUHAL atop the
        // aggregate cannot natively do this — it sees one stream and
        // applies gain uniformly to every subdevice. Hardware volume
        // bypasses the AUHAL entirely … but only on devices whose
        // CoreAudio driver actually exposes
        // `kAudioDevicePropertyVolumeScalar` as writable.
        //
        // DP / HDMI display speakers (an ASUS ExternalDisplay is the
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
        //
        // Skipped entirely on the sink path: there the same devices are driven
        // by `applySystemSinkVolumes()`, which composes the SYSTEM volume with
        // the per-device balance. Running both would have this loop overwrite
        // the master with the raw balance value on every replan.
        if !sinkPath,
           let agg = aggregateDevice,
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
        // speakers (e.g. ExternalDisplay) is unavailable for the same reason
        // it's unavailable in stereo mode — the device exposes no
        // writable VolumeScalar. The bridge's render callback applies
        // the gain digitally to every Float32 sample it writes to
        // AUHAL. Without this loop the slider would silently no-op
        // for any bridge-driven device (the user-reported regression).
        for (devID, bridge) in localBridges {
            let r = routing[devID] ?? DeviceRouting(deviceID: devID)
            bridge.setVolume(Self.localBridgeGain(for: r))
        }

        // Per-device delay trim, local leg. Cheap and idempotent — a bridge
        // already holding the value takes the no-op path in render() — so it
        // rides along with every replan rather than needing its own trigger.
        // The AirPlay leg needs IPC and therefore an async context; see
        // `applyDeviceDelayTrims()`.
        applyLocalDelayTrims(normalizedDelayTrims())
    }

    // MARK: - Per-device delay trim
    //
    // One user-settable millisecond bias per enabled output, compensating the
    // listener's distance to each speaker (1 ms ≈ 34 cm) plus residual
    // systematic skew. Stored signed in `DeviceRouting.manualDelayMs`,
    // normalised to non-negative per-leg values here, and applied downstream
    // of everything the Layer-1/2/3 sync stack does.

    /// Sidecar JSON-RPC method that carries the AirPlay leg's trims.
    private static let deviceTrimSetMethod = "sync.set_output_trims_ms"

    /// Smallest trim magnitude worth putting on the wire. Values below it are
    /// PRUNED from the pushed map, which under `sync.set_output_trims_ms`'s
    /// full-replacement contract is how an output gets reset to zero.
    ///
    /// This is NOT the repeat-push suppressor — that is the
    /// `lastPushedAirplayTrimsMs` comparison below, which is what actually
    /// keeps a replan from buying the user a relatch dropout. Equal to the UI
    /// step, and since trims are whole milliseconds the two together mean
    /// exactly "drop the zeros". Raising `DeviceDelayTrim.stepMs` without
    /// revisiting this would start pruning trims the user really set, and
    /// pruning means reset-to-zero, not leave-alone.
    private static let minPushableTrimMs = DeviceDelayTrim.stepMs

    /// Non-zero AirPlay trims last pushed to the sidecar, so a replan that
    /// changes nothing emits no IPC at all.
    private var lastPushedAirplayTrimsMs: [String: Int] = [:]

    /// The outputs a trim can currently reach: local bridges plus AirPlay
    /// receivers the sidecar has been told are active. Anything else (a
    /// disabled row, a receiver that has not been registered yet) is excluded
    /// from BOTH the normalisation minimum and the result — see
    /// `DelayTrimNormalizer`.
    private func trimmableOutputIDs() -> Set<String> {
        guard mode == .wholeHome else { return [] }
        var ids = Set(localBridges.keys)
        for id in activeAirplayDeviceIDs where routing[id]?.enabled ?? false {
            ids.insert(id)
        }
        return ids.filter { routing[$0]?.enabled ?? false }
    }

    /// Signed user intent turned into the non-negative delays the legs can
    /// actually apply. Empty outside whole-home mode: stereo runs a different
    /// output path (`localOutputs`, not `localBridges`) whose timing is
    /// deliberately left untouched.
    private func normalizedDelayTrims() -> [String: Int] {
        let enabled = trimmableOutputIDs()
        guard !enabled.isEmpty else { return [:] }
        return DelayTrimNormalizer.normalize(
            raw: routing.mapValues { $0.manualDelayMs },
            enabled: enabled
        )
    }

    /// Push the local half of a normalised trim map. Bridges absent from the
    /// map are reset to 0 rather than left holding a stale bias — a device
    /// that just got disabled must not keep delaying itself.
    private func applyLocalDelayTrims(_ normalized: [String: Int]) {
        for (devID, bridge) in localBridges {
            bridge.setTrimMs(normalized[devID] ?? 0)
        }
    }

    /// Recompute the per-output trims and fan them out to both legs.
    ///
    /// Both legs are driven from ONE normalisation of ONE routing snapshot,
    /// which is why this lives on the Router: it is the only place that holds
    /// `routing`, `localBridges` and the sidecar IPC handle at the same time.
    /// The sidecar cannot do it (local CoreAudio devices are invisible to it,
    /// so it can never compute the global minimum) and a single bridge cannot
    /// (no global view).
    ///
    /// The AirPlay push is skipped entirely when the non-zero trim set is
    /// unchanged. That matters more than it looks: OwnTone latches
    /// `offset_ms` when it builds an output session and refuses to change a
    /// live one, so applying an AirPlay trim costs a disable → 0.4 s →
    /// enable dropout on that receiver.
    ///
    /// - Returns: `.applied` when the AirPlay leg now carries what the user
    ///   asked for (including the "nothing changed" and "nothing to send"
    ///   cases), `.failed` when it does not and the caller must retry. The
    ///   distinction exists because a dropped push is invisible: the local
    ///   leg has already moved, so a silent failure leaves the two legs
    ///   disagreeing by exactly the trim the user just dialled in.
    @discardableResult
    public func applyDeviceDelayTrims() async -> DeviceTrimPushResult {
        // Stereo runs a different output path whose timing is deliberately
        // untouched, and the sidecar independently returns 0 for every
        // AirPlay offset outside whole-home. Reporting `.applied` (rather
        // than falling through to a "no sidecar attached" failure) keeps a
        // stereo-mode re-seed from driving the caller's retry loop and
        // surfacing an error for work that was never meant to happen.
        guard mode == .wholeHome else { return .applied }
        let normalized = normalizedDelayTrims()
        applyLocalDelayTrims(normalized)

        let airplayIDs = activeAirplayDeviceIDs.filter {
            localBridges[$0] == nil && (routing[$0]?.enabled ?? false)
        }
        var airplayTrims: [String: Int] = [:]
        for id in airplayIDs {
            let value = normalized[id] ?? 0
            if abs(value) >= Self.minPushableTrimMs { airplayTrims[id] = value }
        }
        guard airplayTrims != lastPushedAirplayTrimsMs else { return .applied }
        guard let ipc else {
            // No sidecar attached: remember nothing, so the push is retried
            // once IPC comes back rather than being suppressed by a
            // record that never actually landed. Reported as a failure for
            // the same reason — outside whole-home there is nothing to push
            // in the first place, so `normalizedDelayTrims()` is empty and
            // we never reach here.
            return .failed
        }
        do {
            _ = try await ipc.call(
                Self.deviceTrimSetMethod,
                params: ["trims_ms": airplayTrims]
            )
            lastPushedAirplayTrimsMs = airplayTrims
            return .applied
        } catch {
            lastError = "device trim push failed: \(error)"
            return .failed
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
            RouterLog.write(
                ("[Router] hardware volume unsupported for \(uid.prefix(20)) — falling back to software gain (this device's level must be controlled via its OSD or via SyncCast's per-device slider; further rejections silenced)\n")
            )
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
            lastAppliedLocalFifoDelayMs = max(0, min(5000, applied))
            return applied
        }
        lastAppliedLocalFifoDelayMs = max(0, min(5000, ms))
        return ms
    }

    // MARK: - Layer 3: residual AirPlay offset
    //
    // Layer 1 (broadcaster delay 0) and Layer 2 (the PLL in
    // `LocalAirPlayBridge` that slaves the local device clock to OwnTone's
    // fifo write rate) leave both legs departing OwnTone together and never
    // drifting apart. The residual is the LOCAL leg's own pipeline latency
    // `L_local` — ring fill + render quantum + packet quantisation + the
    // CoreAudio device's presentation latency. The local leg cannot be
    // advanced, so the AirPlay leg is delayed by `L_local` instead, using
    // OwnTone's per-output `offset_ms` (positive = delay, verified against
    // outputs/airplay.c:2180 and docs/json-api.md).

    /// Sidecar JSON-RPC method that sets the AirPlay-side offset.
    private static let airplayOffsetSetMethod = "sync.set_airplay_offset_ms"
    /// Sidecar JSON-RPC method that reads the offset state back.
    private static let airplayOffsetGetMethod = "sync.airplay_offset"
    /// `source` label the sidecar records when the value came from this
    /// measurement path rather than from a human moving a slider.
    public static let airplayOffsetMeasuredSource = "router_measured"
    /// `source` label the sidecar records for a hand-tuned value. A manual
    /// offset is never overwritten by the measurement path.
    public static let airplayOffsetManualSource = "manual"
    /// Don't churn the offset for sub-audible changes. Re-applying it costs a
    /// disable/enable cycle on every AirPlay receiver (OwnTone latches the
    /// offset at session construction), so a 1-2 ms wobble in the measured
    /// value must not buy the user a dropout. 5 ms is well under the ~10 ms
    /// threshold where two sources start to read as separate.
    private static let airplayOffsetDeadbandMs = 5
    /// How long to let a freshly-started bridge run before measuring. The
    /// render quantum is only known after the first AUHAL callback, and
    /// `localPipelineLatencyMs` deliberately returns nil until then rather
    /// than guessing.
    private static let airplayOffsetSettleNanos: UInt64 = 1_500_000_000

    /// Last offset (ms) successfully pushed to the sidecar, so
    /// `pushMeasuredAirPlayOffset` can honour the deadband. nil until the
    /// first push of this session.
    private var lastPushedAirplayOffsetMs: Int?

    /// Measured `L_local` across the running local bridges, or nil when no
    /// bridge has rendered yet.
    ///
    /// With several local devices their latencies differ (built-in speakers
    /// are a few ms, a DisplayPort monitor tens), and one AirPlay offset
    /// cannot satisfy all of them. We take the MAXIMUM, which puts the AirPlay
    /// leg level with the slowest local device; the faster ones then lead it
    /// by their own shortfall instead of the whole budget. Taking the minimum
    /// would leave every local device late by up to the same spread, which is
    /// the more noticeable failure because the local speaker is the one the
    /// user is standing next to.
    public func measuredLocalPipelineLatencyMs() -> Double? {
        localBridges.values.compactMap { $0.localPipelineLatencyMs }.max()
    }

    /// Push a specific AirPlay offset (ms) to the sidecar. Positive delays
    /// the AirPlay leg; 0 retires the correction. Returns the value the
    /// sidecar actually applied (it clamps to OwnTone's ±2000 ms range).
    ///
    /// `relatch` cycles already-playing outputs so the new value takes effect
    /// now instead of at their next enable — OwnTone copies the offset into
    /// an output session when it builds it and will not change a live one.
    ///
    /// `source` defaults to `manual`, matching the sidecar's own default,
    /// because everything except `pushMeasuredAirPlayOffset` is by definition
    /// a human asking for a specific value. Labelling a hand-tuned offset
    /// `router_measured` would let the next measurement overwrite it — the
    /// exact outcome the "a manual value outranks our measurement" rule in
    /// `pushMeasuredAirPlayOffset` exists to prevent.
    @discardableResult
    public func setAirPlayOffsetMs(
        _ ms: Int,
        source: String = Router.airplayOffsetManualSource,
        relatch: Bool = true
    ) async throws -> Int {
        guard let ipc else {
            throw NSError(domain: "SyncCastRouter", code: 101, userInfo: [
                NSLocalizedDescriptionKey: "sidecar not attached"
            ])
        }
        let result = try await ipc.call(
            Self.airplayOffsetSetMethod,
            params: [
                "offset_ms": ms,
                "source": source,
                "relatch": relatch,
            ]
        )
        let applied = (result as? [String: Any])?["offset_ms"] as? Int ?? ms
        lastPushedAirplayOffsetMs = applied
        return applied
    }

    /// Current sidecar-side offset state, or nil when IPC is unavailable.
    public func airPlayOffsetState() async -> [String: Any]? {
        guard let ipc else { return nil }
        let result = try? await ipc.call(Self.airplayOffsetGetMethod, params: [:])
        return result as? [String: Any]
    }

    /// Measure `L_local` from the running bridges and push it as the AirPlay
    /// offset. No-op when nothing has been measured yet or when the change is
    /// inside the deadband. Failures land in `lastError` rather than
    /// propagating: a whole-home session that is merely a few ms out of
    /// alignment must not be torn down over it.
    public func pushMeasuredAirPlayOffset() async {
        guard let measured = measuredLocalPipelineLatencyMs() else { return }
        let target = Int(measured.rounded())
        let state = await airPlayOffsetState()
        // A value the user dialled in by hand outranks our measurement. The
        // measurement is a model of the pipeline; the human was listening to
        // it. Silently overwriting a field-tuned offset is the worst outcome
        // here, because it looks like the tuning simply did not stick.
        if (state?["source"] as? String) == Self.airplayOffsetManualSource {
            return
        }
        if lastPushedAirplayOffsetMs == nil {
            // First push of the session: seed the deadband from what the
            // outputs are actually CARRYING, so a measurement that merely
            // confirms what is already latched does not buy the user a
            // relatch dropout on every whole-home start.
            //
            // Deliberately not `effective_offset_ms`: that is the sidecar's
            // INTENT, and the two diverge precisely where it matters. Any
            // receiver that was already selected in OwnTone when whole-home
            // began kept the offset its live session latched (OwnTone will
            // not change a playing one), while the sidecar still reports its
            // intended value — so seeding from intent suppressed the one push
            // that would have re-latched it, and that receiver ran ~L_local
            // ahead of the local leg for the entire session with nothing in
            // the log. Seeding from the per-output truth leaves the seed nil
            // in exactly that case, and nil forces the push through.
            lastPushedAirplayOffsetMs = Self.latchedOffsetMs(from: state)
        }
        if let previous = lastPushedAirplayOffsetMs,
           abs(previous - target) < Self.airplayOffsetDeadbandMs {
            return
        }
        do {
            let applied = try await setAirPlayOffsetMs(
                target, source: Self.airplayOffsetMeasuredSource
            )
            RouterLog.write(
                "[Router] airplay offset: L_local measured \(target) ms, applied \(applied) ms\n"
            )
        } catch {
            lastError = "airplay offset push failed: \(error)"
        }
    }

    /// The offset the AirPlay outputs are known to be CARRYING, from the
    /// sidecar's per-output `latched` map. nil means "not knowable", which
    /// every caller must read as "push, do not assume it is already right".
    ///
    /// nil in three cases, all of which genuinely need a push: no state at
    /// all (IPC down), an empty map (nothing latched yet this session, or an
    /// output that was already live when we wrote its offset and therefore
    /// never latched ours), and any output whose offset write failed (its
    /// value is whatever a previous session persisted).
    ///
    /// When several outputs are latched at different values, the MINIMUM is
    /// the honest summary: the deadband must only suppress a push when EVERY
    /// output is already close enough, and the furthest-away one decides that.
    static func latchedOffsetMs(from state: [String: Any]?) -> Int? {
        guard let state else { return nil }
        if let failures = state["write_failures"] as? [Any], !failures.isEmpty {
            return nil
        }
        guard let latched = state["latched"] as? [String: Any] else { return nil }
        return latched.values.compactMap { intDiagnosticValue($0) }.min()
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
            return lastAppliedLocalFifoDelayMs
        }
        return Self.intDiagnosticValue(diagnostics["current_delay_ms"])
            ?? Self.intDiagnosticValue(diagnostics["delay_ms"])
            ?? lastAppliedLocalFifoDelayMs
    }

    private static func intDiagnosticValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Double, value.isFinite { return Int(value.rounded()) }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

}
