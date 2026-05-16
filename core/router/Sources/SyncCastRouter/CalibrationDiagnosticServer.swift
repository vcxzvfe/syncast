import Foundation
import Darwin
import CoreAudio
import SyncCastDiscovery

/// Unix-domain JSON-RPC listener that lets `scripts/calibration_test.sh`
/// drive `Router.runCalibration` from the CLI without touching the menubar.
/// Whole-home only — Router binds it on entering whole-home+running and
/// tears it down on every other state. NDJSON over SOCK_STREAM, mode 0600.
/// Single-flight: a second concurrent connection gets -32002 and closes.
public final class CalibrationDiagnosticServer: @unchecked Sendable {
    public struct Snapshot: Sendable {
        public let devices: [Device]
        public let microphoneDeviceID: AudioDeviceID?
        public let currentDelayMs: Int
        public let contextSignature: String
        public let delayLocked: Bool
        public let enabledAirplayCount: Int
        public let activeAirplayCount: Int
        public let airplayTimingEpoch: UInt64
        public let airplayConnectionStates: [String: String]
        public let syncContextState: String
        public let syncContextReason: String
        public let syncContextRevision: UInt64
        public let syncContextUpdatedUnix: Double
        public let passiveDryRunTargetDelayMs: Int?
        public let passiveDryRunCurrentDelayMs: Int?
        public let passiveDryRunContextSignature: String?
        public let passiveDryRunCaptureBackend: String?
        public let passiveDryRunEnabledAirplayCount: Int?
        public let passiveDryRunActiveAirplayCount: Int?
        public let passiveDryRunAirplayTimingEpoch: UInt64?
        public let passiveDryRunAcceptedFromSyncContextState: String?
        public let passiveDryRunAcceptedFromSyncContextRevision: UInt64?
        public let passiveDryRunAcceptedSyncContextRevision: UInt64?
        public let passiveDryRunSessionRoot: String?
        public let passiveDryRunControlReport: String?
        public let passiveDryRunAcceptedUnix: Double?
        public init(
            devices: [Device],
            microphoneDeviceID: AudioDeviceID?,
            currentDelayMs: Int = 0,
            contextSignature: String = "",
            delayLocked: Bool = false,
            enabledAirplayCount: Int = 0,
            activeAirplayCount: Int? = nil,
            airplayTimingEpoch: UInt64 = 0,
            airplayConnectionStates: [String: String] = [:],
            syncContextState: String = "valid",
            syncContextReason: String = "",
            syncContextRevision: UInt64 = 0,
            syncContextUpdatedUnix: Double = 0,
            passiveDryRunTargetDelayMs: Int? = nil,
            passiveDryRunCurrentDelayMs: Int? = nil,
            passiveDryRunContextSignature: String? = nil,
            passiveDryRunCaptureBackend: String? = nil,
            passiveDryRunEnabledAirplayCount: Int? = nil,
            passiveDryRunActiveAirplayCount: Int? = nil,
            passiveDryRunAirplayTimingEpoch: UInt64? = nil,
            passiveDryRunAcceptedFromSyncContextState: String? = nil,
            passiveDryRunAcceptedFromSyncContextRevision: UInt64? = nil,
            passiveDryRunAcceptedSyncContextRevision: UInt64? = nil,
            passiveDryRunSessionRoot: String? = nil,
            passiveDryRunControlReport: String? = nil,
            passiveDryRunAcceptedUnix: Double? = nil
        ) {
            self.devices = devices
            self.microphoneDeviceID = microphoneDeviceID
            self.currentDelayMs = currentDelayMs
            self.contextSignature = contextSignature
            self.delayLocked = delayLocked
            self.enabledAirplayCount = enabledAirplayCount
            self.activeAirplayCount = activeAirplayCount ?? enabledAirplayCount
            self.airplayTimingEpoch = airplayTimingEpoch
            self.airplayConnectionStates = airplayConnectionStates
            self.syncContextState = syncContextState
            self.syncContextReason = syncContextReason
            self.syncContextRevision = syncContextRevision
            self.syncContextUpdatedUnix = syncContextUpdatedUnix
            self.passiveDryRunTargetDelayMs = passiveDryRunTargetDelayMs
            self.passiveDryRunCurrentDelayMs = passiveDryRunCurrentDelayMs
            self.passiveDryRunContextSignature = passiveDryRunContextSignature
            self.passiveDryRunCaptureBackend = passiveDryRunCaptureBackend
            self.passiveDryRunEnabledAirplayCount =
                passiveDryRunEnabledAirplayCount
            self.passiveDryRunActiveAirplayCount =
                passiveDryRunActiveAirplayCount
            self.passiveDryRunAirplayTimingEpoch =
                passiveDryRunAirplayTimingEpoch
            self.passiveDryRunAcceptedFromSyncContextState =
                passiveDryRunAcceptedFromSyncContextState
            self.passiveDryRunAcceptedFromSyncContextRevision =
                passiveDryRunAcceptedFromSyncContextRevision
            self.passiveDryRunAcceptedSyncContextRevision =
                passiveDryRunAcceptedSyncContextRevision
            self.passiveDryRunSessionRoot = passiveDryRunSessionRoot
            self.passiveDryRunControlReport = passiveDryRunControlReport
            self.passiveDryRunAcceptedUnix = passiveDryRunAcceptedUnix
        }
    }
    public struct PassiveStatus: Sendable {
        public let captureBackend: String
        public let captureDiagnostic: String
        public let tickCount: UInt64?
        public let ringWritePosition: Int64?
        public let sampleRate: Double?
        public let channelCount: Int?
        public let ringCapacityFrames: Int?
        public init(
            captureBackend: String,
            captureDiagnostic: String = "",
            tickCount: UInt64? = nil,
            ringWritePosition: Int64? = nil,
            sampleRate: Double? = nil,
            channelCount: Int? = nil,
            ringCapacityFrames: Int? = nil
        ) {
            self.captureBackend = captureBackend
            self.captureDiagnostic = captureDiagnostic
            self.tickCount = tickCount
            self.ringWritePosition = ringWritePosition
            self.sampleRate = sampleRate
            self.channelCount = channelCount
            self.ringCapacityFrames = ringCapacityFrames
        }
    }
    public struct PassiveEvidenceIntent: Sendable {
        public let intent: String
        public let baselineRequired: Bool
        public let passiveCanApply: Bool
        public let nextAction: String
        public let reason: String

        public init(
            intent: String,
            baselineRequired: Bool,
            passiveCanApply: Bool,
            nextAction: String,
            reason: String
        ) {
            self.intent = intent
            self.baselineRequired = baselineRequired
            self.passiveCanApply = passiveCanApply
            self.nextAction = nextAction
            self.reason = reason
        }
    }
    public typealias Provider = @Sendable () async -> Snapshot?
    public typealias PassiveStatusProvider = @Sendable () async -> PassiveStatus
    public typealias RunnerReturn = (
            deltaMs: Int,
            confidence: Double,
            perDeviceOffsetMs: [String: Int],
            perDeviceConfidence: [String: Double],
            perDeviceUncertaintyMs: [String: Int]
        )
    public typealias Runner = @Sendable (Snapshot) async throws -> RunnerReturn
    /// Runner for the `freqresponse` sweep. Returns the same struct
    /// `runFrequencyResponseTest` produces; the server serializes it to
    /// JSON via `Codable` for the wire format.
    /// **v7**: optional `frequencies` and `toneAmplitude` are forwarded
    /// from the JSON-RPC `params` payload — both nil means "use the
    /// router default sweep" (the previous behavior). Either non-nil
    /// overrides only that one parameter.
    public typealias FreqRunner = @Sendable (
        _ snapshot: Snapshot,
        _ frequencies: [Double]?,
        _ toneAmplitude: Double?
    ) async throws -> FrequencyResponseResult
    public typealias DelayApplier = @Sendable (Int) async throws -> Int
    public typealias PassiveCaptureRunner = @Sendable (
        _ snapshot: Snapshot,
        _ durationSec: Double,
        _ maxDelayMs: Int,
        _ outputDirectory: String?
    ) async throws -> PassiveCaptureResult
    public typealias PassiveDelayApplier = @Sendable (
        _ candidate: PassiveApplyCandidate
    ) async throws -> Int
    public struct SyncContextMarkResult: Sendable {
        public let state: String
        public let reason: String
        public let revision: UInt64
        public let updatedUnix: Double

        public init(
            state: String,
            reason: String,
            revision: UInt64,
            updatedUnix: Double
        ) {
            self.state = state
            self.reason = reason
            self.revision = revision
            self.updatedUnix = updatedUnix
        }
    }
    public typealias SyncContextMarker = @Sendable (
        _ reason: String,
        _ request: PassiveBaselineMarkRequest
    ) async throws -> SyncContextMarkResult

    private static func passiveCaptureContextMismatch(
        start: Snapshot,
        end: Snapshot
    ) -> String? {
        let checks: [(String, String, String)] = [
            ("contextSignature", start.contextSignature, end.contextSignature),
            ("currentDelayMs", String(start.currentDelayMs), String(end.currentDelayMs)),
            ("delayLocked", String(start.delayLocked), String(end.delayLocked)),
            ("enabledAirplayCount", String(start.enabledAirplayCount), String(end.enabledAirplayCount)),
            ("activeAirplayCount", String(start.activeAirplayCount), String(end.activeAirplayCount)),
            ("airplayTimingEpoch", String(start.airplayTimingEpoch), String(end.airplayTimingEpoch)),
            ("syncContextState", start.syncContextState, end.syncContextState),
            ("syncContextRevision", String(start.syncContextRevision), String(end.syncContextRevision)),
        ]
        let changed = checks.compactMap { field, before, after -> String? in
            before == after ? nil : "\(field) \(before) -> \(after)"
        }
        return changed.isEmpty ? nil : changed.joined(separator: "; ")
    }

    public static func calibrateApplyFreshnessRejectionReason(
        start: Snapshot,
        latest: Snapshot
    ) -> String? {
        guard !latest.delayLocked else { return "delay_locked" }
        guard latest.currentDelayMs == start.currentDelayMs else {
            return "delay_changed"
        }
        guard latest.contextSignature == start.contextSignature else {
            return "context_changed"
        }
        guard latest.enabledAirplayCount == start.enabledAirplayCount else {
            return "enabled_airplay_count_changed"
        }
        guard latest.activeAirplayCount == latest.enabledAirplayCount else {
            return "airplay_not_fully_connected"
        }
        guard latest.activeAirplayCount == start.activeAirplayCount else {
            return "active_airplay_count_changed"
        }
        guard latest.airplayTimingEpoch == start.airplayTimingEpoch else {
            return "airplay_timing_epoch_changed"
        }
        guard latest.syncContextState == start.syncContextState else {
            return "sync_context_state_changed"
        }
        guard latest.syncContextRevision == start.syncContextRevision else {
            return "sync_context_revision_changed"
        }
        return nil
    }

    public static func passiveSnapshotRejection(
        snapshot: Snapshot,
        passiveStatus: PassiveStatus?,
        passiveAvailable: Bool,
        busy: Bool
    ) -> String? {
        guard passiveAvailable else { return "passive capture runner is unavailable" }
        guard !busy else { return "passive capture is already in progress" }
        guard snapshot.enabledAirplayCount > 0 else {
            return "passive_capture requires at least one enabled AirPlay receiver"
        }
        guard snapshot.activeAirplayCount == snapshot.enabledAirplayCount else {
            return "passive_capture requires all enabled AirPlay receivers to be connected "
                + "(\(snapshot.activeAirplayCount)/\(snapshot.enabledAirplayCount) connected)"
        }
        guard !snapshot.contextSignature.isEmpty else {
            return "passive_capture route context is missing"
        }
        guard snapshot.currentDelayMs >= Self.autoApplyDelayRange.lowerBound,
              snapshot.currentDelayMs <= Self.autoApplyDelayRange.upperBound else {
            return "passive_capture current delay is outside supported range"
        }
        let backend = passiveStatus?.captureBackend ?? ""
        guard backend == "sck" || backend == "tap" else {
            return "passive_capture backend is not ready or unsupported: \(backend.isEmpty ? "missing" : backend)"
        }
        guard let tickCount = passiveStatus?.tickCount, tickCount > 0 else {
            let diagnostic = passiveStatus?.captureDiagnostic
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let detail = diagnostic.isEmpty ? "" : "; \(diagnostic)"
            let tickText = passiveStatus?.tickCount.map { String($0) } ?? "missing"
            return "passive_capture reference has not received system-audio frames: "
                + "captureTickCount=\(tickText)"
                + detail
        }
        guard !snapshot.syncContextState.isEmpty else {
            return "passive_capture sync context state is missing"
        }
        guard Self.passiveSyncContextStateIsKnown(snapshot.syncContextState) else {
            return "passive_capture sync context state is unknown: \(snapshot.syncContextState)"
        }
        guard snapshot.syncContextState != "measuring" else {
            return "passive_capture blocked while another measurement owns the sync context"
        }
        return nil
    }

    public static func passiveSyncContextStateIsKnown(_ state: String) -> Bool {
        switch state.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "valid", "suspect", "measuring", "readyToDryRun",
             "dryRunReady", "applied", "locked":
            return true
        default:
            return false
        }
    }

    public static func passiveEvidenceIntent(
        snapshot: Snapshot
    ) -> PassiveEvidenceIntent {
        let state = snapshot.syncContextState
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = snapshot.syncContextReason
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if snapshot.delayLocked || state == "locked" {
            return PassiveEvidenceIntent(
                intent: "diagnostic_locked",
                baselineRequired: false,
                passiveCanApply: false,
                nextAction: "run a no-probe passive drift session for diagnostics only; automatic delay apply is blocked while the delay is locked",
                reason: reason.isEmpty ? "delay is locked" : reason
            )
        }
        if state == "suspect" || state.isEmpty {
            return PassiveEvidenceIntent(
                intent: "baseline_required",
                baselineRequired: true,
                passiveCanApply: false,
                nextAction: "record a no-probe passive baseline for the current Local+AirPlay route before considering any correction",
                reason: reason.isEmpty ? "Local+AirPlay sync context is suspect" : reason
            )
        }
        if state == "applied" {
            return PassiveEvidenceIntent(
                intent: "post_apply_validation",
                baselineRequired: false,
                passiveCanApply: false,
                nextAction: "run a no-probe passive drift session to validate the recently applied delay before trusting further corrections",
                reason: reason.isEmpty ? "recent passive/diagnostic delay apply" : reason
            )
        }
        if state == "readyToDryRun" {
            return PassiveEvidenceIntent(
                intent: "dry_run_candidate",
                baselineRequired: false,
                passiveCanApply: false,
                nextAction: "run the app-side passive apply dry-run guard; do not write delay unless a separate apply step is explicitly enabled",
                reason: reason.isEmpty ? "repeat-confirmed passive correction candidate" : reason
            )
        }
        if state == "dryRunReady" {
            return PassiveEvidenceIntent(
                intent: "manual_validation_required",
                baselineRequired: false,
                passiveCanApply: false,
                nextAction: "manual listening validation or an explicit apply workflow is required before changing delay",
                reason: reason.isEmpty ? "app-side passive dry-run accepted a correction candidate" : reason
            )
        }
        if !Self.passiveSyncContextStateIsKnown(state) {
            return PassiveEvidenceIntent(
                intent: "sync_context_unknown",
                baselineRequired: false,
                passiveCanApply: false,
                nextAction: "update SyncCast and bundled passive tools before running passive diagnostics",
                reason: "unknown sync context state: \(state.isEmpty ? "<missing>" : state)"
            )
        }
        return PassiveEvidenceIntent(
            intent: "drift_monitor",
            baselineRequired: false,
            passiveCanApply: true,
            nextAction: "run the no-probe passive drift session",
            reason: reason.isEmpty ? "passive capture readiness gate passed" : reason
        )
    }

    public static func passiveApplyResultPayload(
        candidate: PassiveApplyCandidate,
        runtime: PassiveApplyRuntime,
        applied: Bool,
        wouldApply: Bool,
        reason: String,
        appliedDelayMs: Int? = nil,
        previousDelayMs: Int? = nil
    ) -> [String: Any] {
        var result: [String: Any] = [
            "targetDelayMs": candidate.targetDelayMs,
            "currentDelayMs": runtime.currentDelayMs,
            "contextSignature": runtime.contextSignature,
            "delayLocked": runtime.delayLocked,
            "enabledAirplayCount": runtime.enabledAirplayCount,
            "activeAirplayCount": runtime.activeAirplayCount,
            "airplayTimingEpoch": NSNumber(value: runtime.airplayTimingEpoch),
            "captureBackend": runtime.captureBackend,
            "syncContextState": runtime.syncContextState,
            "syncContextRevision": NSNumber(value: runtime.syncContextRevision),
            "applied": applied,
            "wouldApply": wouldApply,
            "reason": reason,
        ]
        if let appliedDelayMs {
            result["appliedDelayMs"] = appliedDelayMs
        }
        if let previousDelayMs {
            result["previousDelayMs"] = previousDelayMs
        }
        return result
    }

    private static func passiveApplyRuntime(
        snapshot: Snapshot,
        passiveStatus: PassiveStatus?
    ) -> PassiveApplyRuntime {
        PassiveApplyRuntime(
            currentDelayMs: snapshot.currentDelayMs,
            contextSignature: snapshot.contextSignature,
            delayLocked: snapshot.delayLocked,
            enabledAirplayCount: snapshot.enabledAirplayCount,
            activeAirplayCount: snapshot.activeAirplayCount,
            airplayTimingEpoch: snapshot.airplayTimingEpoch,
            captureBackend: passiveStatus?.captureBackend ?? "unknown",
            syncContextState: snapshot.syncContextState,
            syncContextRevision: snapshot.syncContextRevision,
            nowUnix: Date().timeIntervalSince1970
        )
    }

    private static func passiveCandidate(
        accepted: PassiveAcceptedDryRunCandidate,
        runtime: PassiveApplyRuntime
    ) -> PassiveApplyCandidate {
        PassiveApplyCandidate(
            targetDelayMs: accepted.targetDelayMs,
            currentDelayMs: accepted.currentDelayMs,
            contextSignature: accepted.contextSignature,
            delayLocked: false,
            enabledAirplayCount: accepted.enabledAirplayCount,
            airplayTimingEpoch: accepted.airplayTimingEpoch,
            captureBackend: accepted.captureBackend,
            syncContextState: runtime.syncContextState,
            syncContextRevision: runtime.syncContextRevision
        )
    }

    private static func acceptedCandidateSnapshotMismatch(
        accepted: PassiveAcceptedDryRunCandidate,
        snapshot: Snapshot
    ) -> String? {
        guard let targetDelayMs = snapshot.passiveDryRunTargetDelayMs,
              let currentDelayMs = snapshot.passiveDryRunCurrentDelayMs,
              let contextSignature = snapshot.passiveDryRunContextSignature,
              let captureBackend = snapshot.passiveDryRunCaptureBackend,
              let enabledAirplayCount = snapshot.passiveDryRunEnabledAirplayCount,
              let activeAirplayCount = snapshot.passiveDryRunActiveAirplayCount,
              let airplayTimingEpoch = snapshot.passiveDryRunAirplayTimingEpoch,
              let acceptedRevision = snapshot.passiveDryRunAcceptedSyncContextRevision,
              let acceptedUnix = snapshot.passiveDryRunAcceptedUnix
        else {
            return "no_accepted_passive_candidate"
        }
        guard accepted.targetDelayMs == targetDelayMs else {
            return "accepted_candidate_target_changed"
        }
        guard accepted.currentDelayMs == currentDelayMs else {
            return "accepted_candidate_current_delay_changed"
        }
        guard accepted.contextSignature == contextSignature else {
            return "accepted_candidate_context_changed"
        }
        guard accepted.captureBackend == captureBackend else {
            return "accepted_candidate_backend_changed"
        }
        guard accepted.enabledAirplayCount == enabledAirplayCount else {
            return "accepted_candidate_airplay_count_changed"
        }
        guard accepted.activeAirplayCount == activeAirplayCount else {
            return "accepted_candidate_active_airplay_count_changed"
        }
        guard accepted.airplayTimingEpoch == airplayTimingEpoch else {
            return "accepted_candidate_airplay_epoch_changed"
        }
        guard accepted.acceptedSyncContextRevision == acceptedRevision else {
            return "accepted_candidate_revision_changed"
        }
        guard abs(accepted.acceptedUnix - acceptedUnix) <= 0.001 else {
            return "accepted_candidate_time_changed"
        }
        return nil
    }

    private static func doubleParam(
        _ params: [String: Any]?,
        _ key: String
    ) throws -> Double {
        guard let value = params?[key] else {
            throw NSError(
                domain: "SyncCastPassiveApply",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "missing required param \(key)"]
            )
        }
        if let doubleValue = value as? Double { return doubleValue }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String, let doubleValue = Double(string) {
            return doubleValue
        }
        throw NSError(
            domain: "SyncCastPassiveApply",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "invalid number param \(key)"]
        )
    }

    private static func passiveCapturePayload(
        _ result: PassiveCaptureResult
    ) throws -> [String: Any] {
        let data = try JSONEncoder().encode(result)
        guard let obj = try JSONSerialization.jsonObject(with: data)
            as? [String: Any]
        else {
            throw NSError(domain: "SyncCastRouter", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "passive_capture: result not a JSON object"
            ])
        }
        return obj
    }

    private static func persistPassiveCaptureMetadata(_ payload: [String: Any]) {
        guard let metadataPath = payload["metadataPath"] as? String,
              !metadataPath.isEmpty,
              JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys]
              )
        else { return }
        try? data.write(to: URL(fileURLWithPath: metadataPath), options: .atomic)
    }

    public let socketPath: URL
    private let provider: Provider
    private let passiveStatusProvider: PassiveStatusProvider?
    private let activeProbeMethodsEnabled: Bool
    private let runner: Runner
    private let freqRunner: FreqRunner?
    private let delayApplier: DelayApplier?
    private let passiveDelayApplier: PassiveDelayApplier?
    private let passiveCaptureRunner: PassiveCaptureRunner?
    private let syncContextMarker: SyncContextMarker?
    private var listenFd: Int32 = -1
    private var acceptThread: Thread?
    private let lock = NSLock()
    private var inProgress: Bool = false

    public init(
        socketPath: URL,
        provider: @escaping Provider,
        passiveStatusProvider: PassiveStatusProvider? = nil,
        activeProbeMethodsEnabled: Bool = false,
        runner: @escaping Runner,
        freqRunner: FreqRunner? = nil,
        delayApplier: DelayApplier? = nil,
        passiveDelayApplier: PassiveDelayApplier? = nil,
        passiveCaptureRunner: PassiveCaptureRunner? = nil,
        syncContextMarker: SyncContextMarker? = nil
    ) {
        self.socketPath = socketPath
        self.provider = provider
        self.passiveStatusProvider = passiveStatusProvider
        self.activeProbeMethodsEnabled = activeProbeMethodsEnabled
        self.runner = runner
        self.freqRunner = freqRunner
        self.delayApplier = delayApplier
        self.passiveDelayApplier = passiveDelayApplier
        self.passiveCaptureRunner = passiveCaptureRunner
        self.syncContextMarker = syncContextMarker
    }

    public func start() throws {
        if lock.calibLock({ listenFd >= 0 }) { return }
        try? FileManager.default.removeItem(at: socketPath)
        let s = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        if s < 0 { throw IpcClient.IpcError.socketCreationFailed(errno) }
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        socketPath.path.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                let p = UnsafeMutableRawPointer(dst).assumingMemoryBound(to: CChar.self)
                let n = min(strlen(src), cap - 1); memcpy(p, src, n); p[n] = 0
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(s, $0, len) }
        }
        if rc != 0 { let e = errno; Darwin.close(s); throw IpcClient.IpcError.socketCreationFailed(e) }
        chmod(socketPath.path, 0o600)
        if Darwin.listen(s, 4) != 0 {
            let e = errno; Darwin.close(s); throw IpcClient.IpcError.socketCreationFailed(e)
        }
        lock.calibLock { listenFd = s }
        let captured = s
        let t = Thread { [weak self] in self?.acceptLoop(fd: captured) }
        t.name = "syncast.calibration.diag.accept"; t.qualityOfService = .utility; t.start()
        acceptThread = t
    }

    public func stop() {
        let s: Int32 = lock.calibLock { let f = listenFd; listenFd = -1; return f }
        // Closing the listener fd unblocks the accept thread (returns -1).
        if s >= 0 { Darwin.close(s) }
        acceptThread = nil
        try? FileManager.default.removeItem(at: socketPath)
    }

    // MARK: - Internals

    private func acceptLoop(fd: Int32) {
        while true {
            var ca = sockaddr_un()
            var cl = socklen_t(MemoryLayout<sockaddr_un>.size)
            let client: Int32 = withUnsafeMutablePointer(to: &ca) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.accept(fd, $0, &cl) }
            }
            if client < 0 {
                if errno == EBADF || errno == EINVAL { return }
                if errno == EINTR { continue }
                return
            }
            handleClient(client: client)
        }
    }

    private func handleClient(client: Int32) {
        defer { Darwin.close(client) }
        // 4 KiB cap is plenty for `calibrate` (no payload). EOF-terminated
        // requests (no trailing \n) are also accepted.
        var buf = Data()
        var tmp = [UInt8](repeating: 0, count: 1024)
        while buf.count < 4096 {
            let n = tmp.withUnsafeMutableBytes { raw -> Int in
                guard let p = raw.baseAddress else { return -1 }
                return Darwin.read(client, p, raw.count)
            }
            if n <= 0 { break }
            buf.append(tmp, count: n)
            if buf.contains(0x0a) { break }
        }
        let line: Data
        if let nl = buf.firstIndex(of: 0x0a) { line = buf.subdata(in: 0..<nl) }
        else if buf.isEmpty { return }
        else { line = buf }
        var rid: Any = NSNull()
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            sendError(client: client, id: rid, code: -32700, message: "parse error"); return
        }
        if let id = obj["id"] { rid = id }
        guard let method = obj["method"] as? String else {
            sendError(client: client, id: rid, code: -32600, message: "missing method"); return
        }
        let params = obj["params"] as? [String: Any]
        switch method {
        case "calibrate":
            guard activeProbeMethodsEnabled else {
                rejectActiveProbeMethod(client: client, id: rid); return
            }
            handleCalibrate(client: client, id: rid)
        case "calibrate_apply":
            guard activeProbeMethodsEnabled else {
                rejectActiveProbeMethod(client: client, id: rid); return
            }
            handleCalibrateApply(client: client, id: rid)
        case "freqresponse":
            guard activeProbeMethodsEnabled else {
                rejectActiveProbeMethod(client: client, id: rid); return
            }
            handleFreqResponse(client: client, id: rid, params: params)
        case "passive_status":  handlePassiveStatus(client: client, id: rid)
        case "passive_capture": handlePassiveCapture(client: client, id: rid, params: params)
        case "passive_apply_candidate":
            handlePassiveApplyCandidate(client: client, id: rid, params: params)
        case "passive_apply_accepted_candidate":
            handlePassiveApplyAcceptedCandidate(client: client, id: rid, params: params)
        case "passive_mark_baseline_valid":
            handlePassiveMarkBaselineValid(client: client, id: rid, params: params)
        case "ping":           sendResult(client: client, id: rid, result: ["ok": true])
        default:               sendError(client: client, id: rid, code: -32601,
                                         message: "method not found: \(method)")
        }
    }

    private func rejectActiveProbeMethod(client: Int32, id: Any) {
        sendError(
            client: client,
            id: id,
            code: -32601,
            message: ActiveAcousticDiagnosticsGate.disabledMessage
        )
    }

    private func handlePassiveStatus(client: Int32, id: Any) {
        final class Box: @unchecked Sendable {
            var success: [String: Any]?
            var error: (Int, String)?
        }
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        let passiveAvailable = passiveCaptureRunner != nil
        let busy = lock.calibLock { inProgress }
        Task.detached { [provider, passiveStatusProvider] in
            defer { sem.signal() }
            guard let snap = await provider() else {
                box.error = (-32001, "router not in whole-home + running state")
                return
            }
            let passiveStatus = await passiveStatusProvider?()
            let passiveRouteReady = snap.enabledAirplayCount > 0
                && snap.activeAirplayCount == snap.enabledAirplayCount
            let snapshotReady = Self.passiveSnapshotRejection(
                snapshot: snap,
                passiveStatus: passiveStatus,
                passiveAvailable: passiveAvailable,
                busy: busy
            ) == nil
            let evidenceIntent = Self.passiveEvidenceIntent(snapshot: snap)
            let devices = snap.devices.map { device -> [String: Any] in
                var row: [String: Any] = [
                    "id": device.id,
                    "name": device.name,
                    "transport": device.transport.rawValue,
                    "isOutputCapable": device.isOutputCapable,
                    "supportsHardwareVolume": device.supportsHardwareVolume,
                ]
                if let coreAudioUID = device.coreAudioUID {
                    row["coreAudioUID"] = coreAudioUID
                }
                if let model = device.model {
                    row["model"] = model
                }
                if let host = device.host {
                    row["host"] = host
                }
                if let port = device.port {
                    row["port"] = port
                }
                if let nominalSampleRate = device.nominalSampleRate {
                    row["nominalSampleRate"] = nominalSampleRate
                }
                return row
            }
            var result: [String: Any] = [
                "ok": true,
                "passiveCaptureAvailable": passiveAvailable && passiveRouteReady && snapshotReady,
                "inProgress": busy,
                "captureBackend": passiveStatus?.captureBackend ?? "unknown",
                "currentDelayMs": snap.currentDelayMs,
                "contextSignature": snap.contextSignature,
                "delayLocked": snap.delayLocked,
                "enabledAirplayCount": snap.enabledAirplayCount,
                "activeAirplayCount": snap.activeAirplayCount,
                "airplayTimingEpoch": NSNumber(value: snap.airplayTimingEpoch),
                "syncContextState": snap.syncContextState,
                "syncContextReason": snap.syncContextReason,
                "syncContextRevision": NSNumber(value: snap.syncContextRevision),
                "syncContextUpdatedUnix": snap.syncContextUpdatedUnix,
                "passiveEvidenceIntent": evidenceIntent.intent,
                "baselineRequired": evidenceIntent.baselineRequired,
                "passiveCanApply": evidenceIntent.passiveCanApply,
                "passiveNextAction": evidenceIntent.nextAction,
                "passiveEvidenceReason": evidenceIntent.reason,
                "devicesTotal": snap.devices.count,
                "coreAudioDeviceCount": snap.devices.filter { $0.transport == .coreAudio }.count,
                "airplayDeviceCount": snap.devices.filter { $0.transport == .airplay2 }.count,
                "devices": devices,
            ]
            if let targetDelayMs = snap.passiveDryRunTargetDelayMs {
                result["passiveDryRunTargetDelayMs"] = targetDelayMs
            }
            if let currentDelayMs = snap.passiveDryRunCurrentDelayMs {
                result["passiveDryRunCurrentDelayMs"] = currentDelayMs
            }
            if let contextSignature = snap.passiveDryRunContextSignature {
                result["passiveDryRunContextSignature"] = contextSignature
            }
            if let captureBackend = snap.passiveDryRunCaptureBackend {
                result["passiveDryRunCaptureBackend"] = captureBackend
            }
            if let enabledAirplayCount = snap.passiveDryRunEnabledAirplayCount {
                result["passiveDryRunEnabledAirplayCount"] =
                    enabledAirplayCount
            }
            if let activeAirplayCount = snap.passiveDryRunActiveAirplayCount {
                result["passiveDryRunActiveAirplayCount"] =
                    activeAirplayCount
            }
            if let airplayTimingEpoch = snap.passiveDryRunAirplayTimingEpoch {
                result["passiveDryRunAirplayTimingEpoch"] =
                    NSNumber(value: airplayTimingEpoch)
            }
            if let state = snap.passiveDryRunAcceptedFromSyncContextState {
                result["passiveDryRunAcceptedFromSyncContextState"] = state
            }
            if let revision = snap.passiveDryRunAcceptedFromSyncContextRevision {
                result["passiveDryRunAcceptedFromSyncContextRevision"] =
                    NSNumber(value: revision)
            }
            if let revision = snap.passiveDryRunAcceptedSyncContextRevision {
                result["passiveDryRunAcceptedSyncContextRevision"] =
                    NSNumber(value: revision)
            }
            if let sessionRoot = snap.passiveDryRunSessionRoot {
                result["passiveDryRunSessionRoot"] = sessionRoot
            }
            if let controlReport = snap.passiveDryRunControlReport {
                result["passiveDryRunControlReport"] = controlReport
            }
            if let acceptedUnix = snap.passiveDryRunAcceptedUnix {
                result["passiveDryRunAcceptedUnix"] = acceptedUnix
            }
            if !passiveRouteReady {
                result["passiveUnavailableReason"] = (
                    "enabled AirPlay receivers are not all connected: "
                    + "\(snap.activeAirplayCount)/\(snap.enabledAirplayCount)"
                )
            } else if let rejection = Self.passiveSnapshotRejection(
                snapshot: snap,
                passiveStatus: passiveStatus,
                passiveAvailable: passiveAvailable,
                busy: busy
            ) {
                result["passiveUnavailableReason"] = rejection
            }
            if let microphoneDeviceID = snap.microphoneDeviceID {
                result["microphoneDeviceID"] = Int(microphoneDeviceID)
            }
            if let diagnostic = passiveStatus?.captureDiagnostic, !diagnostic.isEmpty {
                result["captureDiagnostic"] = diagnostic
            }
            if let tickCount = passiveStatus?.tickCount {
                result["captureTickCount"] = NSNumber(value: tickCount)
            }
            if let ringWritePosition = passiveStatus?.ringWritePosition {
                result["captureRingWritePosition"] = NSNumber(value: ringWritePosition)
            }
            if let sampleRate = passiveStatus?.sampleRate {
                result["captureSampleRate"] = sampleRate
            }
            if let channelCount = passiveStatus?.channelCount {
                result["captureChannelCount"] = channelCount
            }
            if let ringCapacityFrames = passiveStatus?.ringCapacityFrames {
                result["captureRingCapacityFrames"] = ringCapacityFrames
            }
            box.success = result
        }
        sem.wait()
        if let err = box.error {
            sendError(client: client, id: id, code: err.0, message: err.1)
        } else if let ok = box.success {
            sendResult(client: client, id: id, result: ok)
        } else {
            sendError(client: client, id: id, code: -32000, message: "no result")
        }
    }

    private func handlePassiveCapture(
        client: Int32, id: Any, params: [String: Any]?
    ) {
        guard let passiveCaptureRunner else {
            sendError(client: client, id: id, code: -32601,
                      message: "passive_capture runner not configured")
            return
        }
        let claimed: Bool = lock.calibLock {
            if inProgress { return false }
            inProgress = true; return true
        }
        if !claimed {
            sendError(client: client, id: id, code: -32002,
                      message: "calibration already in progress"); return
        }
        let durationSec = (params?["durationSec"] as? NSNumber)?.doubleValue ?? 10.0
        let maxDelayMs = (params?["maxDelayMs"] as? NSNumber)?.intValue ?? 3500
        let outputDirectory = params?["outputDirectory"] as? String
        final class Box: @unchecked Sendable {
            var success: [String: Any]?
            var error: (Int, String)?
        }
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        Task.detached { [provider, passiveStatusProvider] in
            defer { sem.signal() }
            guard let snap = await provider() else {
                box.error = (-32001, "router not in whole-home + running state"); return
            }
            guard snap.enabledAirplayCount > 0,
                  snap.activeAirplayCount == snap.enabledAirplayCount else {
                box.error = (
                    -32003,
                    "passive_capture requires all enabled AirPlay receivers to be connected "
                    + "(\(snap.activeAirplayCount)/\(snap.enabledAirplayCount) connected)"
                )
                return
            }
            let passiveStatus = await passiveStatusProvider?()
            if let rejection = Self.passiveSnapshotRejection(
                snapshot: snap,
                passiveStatus: passiveStatus,
                passiveAvailable: true,
                busy: false
            ) {
                box.error = (-32003, rejection)
                return
            }
            do {
                let result = try await passiveCaptureRunner(
                    snap,
                    durationSec,
                    maxDelayMs,
                    outputDirectory
                )
                let startPayload = try Self.passiveCapturePayload(result)
                guard let endSnap = await provider() else {
                    var failed = startPayload
                    failed["contextStableDuringCapture"] = false
                    failed["contextFailureReason"] = (
                        "passive_capture route context disappeared during capture"
                    )
                    Self.persistPassiveCaptureMetadata(failed)
                    box.error = (
                        -32004,
                        "passive_capture route context disappeared during capture"
                    )
                    return
                }
                guard endSnap.enabledAirplayCount > 0,
                      endSnap.activeAirplayCount == endSnap.enabledAirplayCount else {
                    var failed = startPayload
                    failed["contextStableDuringCapture"] = false
                    failed["contextFailureReason"] = (
                        "passive_capture AirPlay receiver disconnected during capture "
                        + "(\(endSnap.activeAirplayCount)/\(endSnap.enabledAirplayCount) connected)"
                    )
                    failed["endCurrentDelayMs"] = endSnap.currentDelayMs
                    failed["endContextSignature"] = endSnap.contextSignature
                    failed["endDelayLocked"] = endSnap.delayLocked
                    failed["endEnabledAirplayCount"] = endSnap.enabledAirplayCount
                    failed["endActiveAirplayCount"] = endSnap.activeAirplayCount
                    failed["endAirplayTimingEpoch"] = NSNumber(
                        value: endSnap.airplayTimingEpoch
                    )
                    failed["endSyncContextState"] = endSnap.syncContextState
                    failed["endSyncContextReason"] = endSnap.syncContextReason
                    failed["endSyncContextRevision"] = NSNumber(
                        value: endSnap.syncContextRevision
                    )
                    failed["endSyncContextUpdatedUnix"] = endSnap.syncContextUpdatedUnix
                    Self.persistPassiveCaptureMetadata(failed)
                    box.error = (
                        -32004,
                        "passive_capture AirPlay receiver disconnected during capture "
                        + "(\(endSnap.activeAirplayCount)/\(endSnap.enabledAirplayCount) connected)"
                    )
                    return
                }
                if let mismatch = Self.passiveCaptureContextMismatch(
                    start: snap,
                    end: endSnap
                ) {
                    var failed = startPayload
                    failed["contextStableDuringCapture"] = false
                    failed["contextFailureReason"] = (
                        "passive_capture route context changed during capture: \(mismatch)"
                    )
                    failed["endCurrentDelayMs"] = endSnap.currentDelayMs
                    failed["endContextSignature"] = endSnap.contextSignature
                    failed["endDelayLocked"] = endSnap.delayLocked
                    failed["endEnabledAirplayCount"] = endSnap.enabledAirplayCount
                    failed["endActiveAirplayCount"] = endSnap.activeAirplayCount
                    failed["endAirplayTimingEpoch"] = NSNumber(
                        value: endSnap.airplayTimingEpoch
                    )
                    failed["endSyncContextState"] = endSnap.syncContextState
                    failed["endSyncContextReason"] = endSnap.syncContextReason
                    failed["endSyncContextRevision"] = NSNumber(
                        value: endSnap.syncContextRevision
                    )
                    failed["endSyncContextUpdatedUnix"] = endSnap.syncContextUpdatedUnix
                    Self.persistPassiveCaptureMetadata(failed)
                    box.error = (
                        -32004,
                        "passive_capture route context changed during capture: \(mismatch)"
                    )
                    return
                }
                var enriched = startPayload
                enriched["contextStableDuringCapture"] = true
                enriched["endCurrentDelayMs"] = endSnap.currentDelayMs
                enriched["endContextSignature"] = endSnap.contextSignature
                enriched["endDelayLocked"] = endSnap.delayLocked
                enriched["endEnabledAirplayCount"] = endSnap.enabledAirplayCount
                enriched["endActiveAirplayCount"] = endSnap.activeAirplayCount
                enriched["endAirplayTimingEpoch"] = NSNumber(
                    value: endSnap.airplayTimingEpoch
                )
                enriched["endSyncContextState"] = endSnap.syncContextState
                enriched["endSyncContextReason"] = endSnap.syncContextReason
                enriched["endSyncContextRevision"] = NSNumber(
                    value: endSnap.syncContextRevision
                )
                enriched["endSyncContextUpdatedUnix"] = endSnap.syncContextUpdatedUnix
                Self.persistPassiveCaptureMetadata(enriched)
                box.success = enriched
            } catch {
                box.error = (-32000, "\(error)")
            }
        }
        sem.wait()
        lock.calibLock { inProgress = false }
        if let err = box.error {
            sendError(client: client, id: id, code: err.0, message: err.1)
        } else if let ok = box.success {
            sendResult(client: client, id: id, result: ok)
        } else {
            sendError(client: client, id: id, code: -32000, message: "no result")
        }
    }

    private static func intParam(
        _ params: [String: Any]?,
        _ key: String
    ) throws -> Int {
        guard let value = params?[key] else {
            throw NSError(
                domain: "SyncCastPassiveApply",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "missing required param \(key)"]
            )
        }
        if let intValue = value as? Int { return intValue }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String, let intValue = Int(string) {
            return intValue
        }
        throw NSError(
            domain: "SyncCastPassiveApply",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "invalid integer param \(key)"]
        )
    }

    private static func uint64Param(
        _ params: [String: Any]?,
        _ key: String
    ) throws -> UInt64 {
        guard let value = params?[key] else {
            throw NSError(
                domain: "SyncCastPassiveApply",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "missing required param \(key)"]
            )
        }
        if let uintValue = value as? UInt64 { return uintValue }
        if let intValue = value as? Int, intValue >= 0 { return UInt64(intValue) }
        if let number = value as? NSNumber {
            let intValue = number.int64Value
            if intValue >= 0 { return UInt64(intValue) }
        }
        if let string = value as? String, let uintValue = UInt64(string) {
            return uintValue
        }
        throw NSError(
            domain: "SyncCastPassiveApply",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "invalid unsigned integer param \(key)"]
        )
    }

    private static func stringParam(
        _ params: [String: Any]?,
        _ key: String
    ) throws -> String {
        guard let value = params?[key] else {
            throw NSError(
                domain: "SyncCastPassiveApply",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "missing required param \(key)"]
            )
        }
        if let string = value as? String { return string }
        throw NSError(
            domain: "SyncCastPassiveApply",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "invalid string param \(key)"]
        )
    }

    private static func boolParam(
        _ params: [String: Any]?,
        _ key: String,
        default defaultValue: Bool
    ) -> Bool {
        guard let value = params?[key] else { return defaultValue }
        if let boolValue = value as? Bool { return boolValue }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            let normalized = string
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return ["1", "true", "yes", "y"].contains(normalized)
        }
        return defaultValue
    }

    private static func optionalIntParam(
        _ params: [String: Any]?,
        _ key: String
    ) throws -> Int? {
        guard params?[key] != nil else { return nil }
        return try intParam(params, key)
    }

    private static func optionalStringParam(
        _ params: [String: Any]?,
        _ key: String
    ) throws -> String? {
        guard params?[key] != nil else { return nil }
        return try stringParam(params, key)
    }

    private func handlePassiveMarkBaselineValid(
        client: Int32, id: Any, params: [String: Any]?
    ) {
        guard let syncContextMarker else {
            sendError(client: client, id: id, code: -32601,
                      message: "passive baseline marker not configured")
            return
        }
        let dryRun = Self.boolParam(params, "dryRun", default: true)
        let request: PassiveBaselineMarkRequest
        let markerReason: String?
        do {
            request = PassiveBaselineMarkRequest(
                currentDelayMs: try Self.intParam(params, "currentDelayMs"),
                contextSignature: try Self.stringParam(params, "contextSignature"),
                delayLocked: Self.boolParam(params, "delayLocked", default: false),
                enabledAirplayCount: try Self.intParam(params, "enabledAirplayCount"),
                activeAirplayCount: try Self.optionalIntParam(params, "activeAirplayCount"),
                airplayTimingEpoch: try Self.uint64Param(params, "airplayTimingEpoch"),
                captureBackend: try Self.stringParam(params, "captureBackend"),
                syncContextState: try Self.stringParam(params, "syncContextState"),
                syncContextRevision: try Self.uint64Param(params, "syncContextRevision")
            )
            markerReason = try Self.optionalStringParam(params, "reason")
        } catch {
            sendError(client: client, id: id, code: -32602, message: "\(error)")
            return
        }

        let claimed: Bool = lock.calibLock {
            if inProgress { return false }
            inProgress = true; return true
        }
        if !claimed {
            sendError(client: client, id: id, code: -32002,
                      message: "calibration already in progress"); return
        }

        final class Box: @unchecked Sendable {
            var success: [String: Any]?
            var error: (Int, String)?
        }
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        Task.detached { [provider, passiveStatusProvider, syncContextMarker] in
            defer { sem.signal() }
            guard let snap = await provider() else {
                box.error = (-32001, "router not in whole-home + running state"); return
            }
            let passiveStatus = await passiveStatusProvider?()
            func reject(_ reason: String) {
                box.success = [
                    "accepted": false,
                    "applied": false,
                    "dryRun": dryRun,
                    "reason": reason,
                    "currentDelayMs": snap.currentDelayMs,
                    "contextSignature": snap.contextSignature,
                    "delayLocked": snap.delayLocked,
                    "enabledAirplayCount": snap.enabledAirplayCount,
                    "activeAirplayCount": snap.activeAirplayCount,
                    "airplayTimingEpoch": NSNumber(value: snap.airplayTimingEpoch),
                    "captureBackend": passiveStatus?.captureBackend ?? "unknown",
                    "syncContextState": snap.syncContextState,
                    "syncContextRevision": NSNumber(value: snap.syncContextRevision),
                    "emitsAudio": false,
                    "opensMicrophone": false,
                    "appliesDelay": false,
                ]
            }

            let runtime = PassiveBaselineMarkRuntime(
                currentDelayMs: snap.currentDelayMs,
                contextSignature: snap.contextSignature,
                delayLocked: snap.delayLocked,
                enabledAirplayCount: snap.enabledAirplayCount,
                activeAirplayCount: snap.activeAirplayCount,
                airplayTimingEpoch: snap.airplayTimingEpoch,
                captureBackend: passiveStatus?.captureBackend ?? "unknown",
                syncContextState: snap.syncContextState,
                syncContextRevision: snap.syncContextRevision
            )
            if let rejection = PassiveBaselineMarkGuard.rejectionReason(
                request: request,
                runtime: runtime
            ) {
                reject(rejection)
                return
            }

            let reason = markerReason
                ?? "passive baseline validated for current Local+AirPlay route"
            if dryRun {
                box.success = [
                    "accepted": true,
                    "applied": false,
                    "dryRun": true,
                    "reason": reason,
                    "currentDelayMs": snap.currentDelayMs,
                    "contextSignature": snap.contextSignature,
                    "delayLocked": snap.delayLocked,
                    "enabledAirplayCount": snap.enabledAirplayCount,
                    "activeAirplayCount": snap.activeAirplayCount,
                    "airplayTimingEpoch": NSNumber(value: snap.airplayTimingEpoch),
                    "captureBackend": passiveStatus?.captureBackend ?? "unknown",
                    "syncContextState": snap.syncContextState,
                    "syncContextRevision": NSNumber(value: snap.syncContextRevision),
                    "emitsAudio": false,
                    "opensMicrophone": false,
                    "appliesDelay": false,
                ]
                return
            }

            do {
                let marked = try await syncContextMarker(reason, request)
                box.success = [
                    "accepted": true,
                    "applied": true,
                    "dryRun": false,
                    "reason": reason,
                    "currentDelayMs": snap.currentDelayMs,
                    "contextSignature": snap.contextSignature,
                    "delayLocked": snap.delayLocked,
                    "enabledAirplayCount": snap.enabledAirplayCount,
                    "activeAirplayCount": snap.activeAirplayCount,
                    "airplayTimingEpoch": NSNumber(value: snap.airplayTimingEpoch),
                    "captureBackend": passiveStatus?.captureBackend ?? "unknown",
                    "previousSyncContextState": snap.syncContextState,
                    "previousSyncContextRevision": NSNumber(value: snap.syncContextRevision),
                    "syncContextState": marked.state,
                    "syncContextReason": marked.reason,
                    "syncContextRevision": NSNumber(value: marked.revision),
                    "syncContextUpdatedUnix": marked.updatedUnix,
                    "emitsAudio": false,
                    "opensMicrophone": false,
                    "appliesDelay": false,
                ]
            } catch {
                box.error = (-32000, "\(error)")
            }
        }
        sem.wait()
        lock.calibLock { inProgress = false }
        if let err = box.error {
            sendError(client: client, id: id, code: err.0, message: err.1)
        } else if let ok = box.success {
            sendResult(client: client, id: id, result: ok)
        } else {
            sendError(client: client, id: id, code: -32000, message: "no result")
        }
    }

    private func handlePassiveApplyCandidate(
        client: Int32, id: Any, params: [String: Any]?
    ) {
        guard delayApplier != nil || passiveDelayApplier != nil else {
            sendError(client: client, id: id, code: -32601,
                      message: "passive_apply_candidate runner not configured")
            return
        }
        let candidate: PassiveApplyCandidate
        let dryRun = Self.boolParam(params, "dryRun", default: true)
        do {
            candidate = PassiveApplyCandidate(
                targetDelayMs: try Self.intParam(params, "targetDelayMs"),
                currentDelayMs: try Self.intParam(params, "currentDelayMs"),
                contextSignature: try Self.stringParam(params, "contextSignature"),
                delayLocked: Self.boolParam(params, "delayLocked", default: false),
                enabledAirplayCount: try Self.intParam(params, "enabledAirplayCount"),
                airplayTimingEpoch: try Self.uint64Param(params, "airplayTimingEpoch"),
                captureBackend: params?["captureBackend"] as? String,
                syncContextState: try Self.stringParam(params, "syncContextState"),
                syncContextRevision: try Self.uint64Param(params, "syncContextRevision")
            )
        } catch {
            sendError(client: client, id: id, code: -32602, message: "\(error)")
            return
        }

        let claimed: Bool = lock.calibLock {
            if inProgress { return false }
            inProgress = true; return true
        }
        if !claimed {
            sendError(client: client, id: id, code: -32002,
                      message: "calibration already in progress"); return
        }
        final class Box: @unchecked Sendable {
            var success: [String: Any]?
            var error: (Int, String)?
        }
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        Task.detached { [provider, passiveStatusProvider, passiveDelayApplier, delayApplier] in
            defer { sem.signal() }
            guard let snap = await provider() else {
                box.error = (-32001, "router not in whole-home + running state"); return
            }
            let passiveStatus = await passiveStatusProvider?()
            let runtime = PassiveApplyRuntime(
                currentDelayMs: snap.currentDelayMs,
                contextSignature: snap.contextSignature,
                delayLocked: snap.delayLocked,
                enabledAirplayCount: snap.enabledAirplayCount,
                activeAirplayCount: snap.activeAirplayCount,
                airplayTimingEpoch: snap.airplayTimingEpoch,
                captureBackend: passiveStatus?.captureBackend ?? "unknown",
                syncContextState: snap.syncContextState,
                syncContextRevision: snap.syncContextRevision
            )
            if let reason = PassiveApplyGuard.rejectionReason(
                candidate: candidate,
                runtime: runtime
            ) {
                box.success = Self.passiveApplyResultPayload(
                    candidate: candidate,
                    runtime: runtime,
                    applied: false,
                    wouldApply: false,
                    reason: reason
                )
                return
            }
            if dryRun {
                box.success = Self.passiveApplyResultPayload(
                    candidate: candidate,
                    runtime: runtime,
                    applied: false,
                    wouldApply: true,
                    reason: "dry_run"
                )
                return
            }
            do {
                guard let latest = await provider() else {
                    box.error = (-32001, "router not in whole-home + running state")
                    return
                }
                let latestStatus = await passiveStatusProvider?()
                let latestRuntime = PassiveApplyRuntime(
                    currentDelayMs: latest.currentDelayMs,
                    contextSignature: latest.contextSignature,
                    delayLocked: latest.delayLocked,
                    enabledAirplayCount: latest.enabledAirplayCount,
                    activeAirplayCount: latest.activeAirplayCount,
                    airplayTimingEpoch: latest.airplayTimingEpoch,
                    captureBackend: latestStatus?.captureBackend ?? "unknown",
                    syncContextState: latest.syncContextState,
                    syncContextRevision: latest.syncContextRevision
                )
                if let reason = PassiveApplyGuard.rejectionReason(
                    candidate: candidate,
                    runtime: latestRuntime
                ) {
                    box.success = Self.passiveApplyResultPayload(
                        candidate: candidate,
                        runtime: latestRuntime,
                        applied: false,
                        wouldApply: false,
                        reason: reason
                    )
                    return
                }
                let applied: Int
                if let passiveDelayApplier {
                    applied = try await passiveDelayApplier(candidate)
                } else if let delayApplier {
                    applied = try await delayApplier(candidate.targetDelayMs)
                } else {
                    throw NSError(
                        domain: "SyncCastPassiveApply",
                        code: -1,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "passive_apply_candidate runner not configured"
                        ]
                    )
                }
                box.success = Self.passiveApplyResultPayload(
                    candidate: candidate,
                    runtime: latestRuntime,
                    applied: true,
                    wouldApply: true,
                    reason: "passive_ready_candidate",
                    appliedDelayMs: applied,
                    previousDelayMs: latestRuntime.currentDelayMs
                )
            } catch { box.error = (-32000, "\(error)") }
        }
        sem.wait()
        lock.calibLock { inProgress = false }
        if let err = box.error {
            sendError(client: client, id: id, code: err.0, message: err.1)
        } else if let ok = box.success {
            sendResult(client: client, id: id, result: ok)
        } else {
            sendError(client: client, id: id, code: -32000, message: "no result")
        }
    }

    private func handlePassiveApplyAcceptedCandidate(
        client: Int32, id: Any, params: [String: Any]?
    ) {
        guard delayApplier != nil || passiveDelayApplier != nil else {
            sendError(client: client, id: id, code: -32601,
                      message: "passive_apply_accepted_candidate runner not configured")
            return
        }
        let accepted: PassiveAcceptedDryRunCandidate
        let dryRun = Self.boolParam(params, "dryRun", default: true)
        do {
            accepted = PassiveAcceptedDryRunCandidate(
                targetDelayMs: try Self.intParam(params, "targetDelayMs"),
                currentDelayMs: try Self.intParam(params, "currentDelayMs"),
                contextSignature: try Self.stringParam(params, "contextSignature"),
                captureBackend: try Self.stringParam(params, "captureBackend"),
                enabledAirplayCount: try Self.intParam(params, "enabledAirplayCount"),
                activeAirplayCount: try Self.intParam(params, "activeAirplayCount"),
                airplayTimingEpoch: try Self.uint64Param(params, "airplayTimingEpoch"),
                acceptedSyncContextRevision: try Self.uint64Param(
                    params,
                    "acceptedSyncContextRevision"
                ),
                acceptedUnix: try Self.doubleParam(params, "acceptedUnix")
            )
        } catch {
            sendError(client: client, id: id, code: -32602, message: "\(error)")
            return
        }

        let claimed: Bool = lock.calibLock {
            if inProgress { return false }
            inProgress = true; return true
        }
        if !claimed {
            sendError(client: client, id: id, code: -32002,
                      message: "calibration already in progress"); return
        }
        final class Box: @unchecked Sendable {
            var success: [String: Any]?
            var error: (Int, String)?
        }
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        Task.detached { [provider, passiveStatusProvider, passiveDelayApplier, delayApplier] in
            defer { sem.signal() }
            guard let snap = await provider() else {
                box.error = (-32001, "router not in whole-home + running state"); return
            }
            let passiveStatus = await passiveStatusProvider?()
            let runtime = Self.passiveApplyRuntime(
                snapshot: snap,
                passiveStatus: passiveStatus
            )
            let candidate = Self.passiveCandidate(
                accepted: accepted,
                runtime: runtime
            )
            if let reason = Self.acceptedCandidateSnapshotMismatch(
                accepted: accepted,
                snapshot: snap
            ) ?? PassiveApplyGuard.acceptedDryRunRejectionReason(
                accepted: accepted,
                runtime: runtime
            ) {
                box.success = Self.passiveApplyResultPayload(
                    candidate: candidate,
                    runtime: runtime,
                    applied: false,
                    wouldApply: false,
                    reason: reason
                )
                return
            }
            if dryRun {
                box.success = Self.passiveApplyResultPayload(
                    candidate: candidate,
                    runtime: runtime,
                    applied: false,
                    wouldApply: true,
                    reason: "accepted_candidate_dry_run"
                )
                return
            }
            do {
                guard let latest = await provider() else {
                    box.error = (-32001, "router not in whole-home + running state")
                    return
                }
                let latestStatus = await passiveStatusProvider?()
                let latestRuntime = Self.passiveApplyRuntime(
                    snapshot: latest,
                    passiveStatus: latestStatus
                )
                let latestCandidate = Self.passiveCandidate(
                    accepted: accepted,
                    runtime: latestRuntime
                )
                if let reason = Self.acceptedCandidateSnapshotMismatch(
                    accepted: accepted,
                    snapshot: latest
                ) ?? PassiveApplyGuard.acceptedDryRunRejectionReason(
                    accepted: accepted,
                    runtime: latestRuntime
                ) {
                    box.success = Self.passiveApplyResultPayload(
                        candidate: latestCandidate,
                        runtime: latestRuntime,
                        applied: false,
                        wouldApply: false,
                        reason: reason
                    )
                    return
                }
                let applied: Int
                if let passiveDelayApplier {
                    applied = try await passiveDelayApplier(latestCandidate)
                } else if let delayApplier {
                    applied = try await delayApplier(accepted.targetDelayMs)
                } else {
                    throw NSError(
                        domain: "SyncCastPassiveApply",
                        code: -1,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "passive_apply_accepted_candidate runner not configured"
                        ]
                    )
                }
                box.success = Self.passiveApplyResultPayload(
                    candidate: latestCandidate,
                    runtime: latestRuntime,
                    applied: true,
                    wouldApply: true,
                    reason: "accepted_passive_candidate",
                    appliedDelayMs: applied,
                    previousDelayMs: latestRuntime.currentDelayMs
                )
            } catch { box.error = (-32000, "\(error)") }
        }
        sem.wait()
        lock.calibLock { inProgress = false }
        if let err = box.error {
            sendError(client: client, id: id, code: err.0, message: err.1)
        } else if let ok = box.success {
            sendResult(client: client, id: id, result: ok)
        } else {
            sendError(client: client, id: id, code: -32000, message: "no result")
        }
    }

    private func handleFreqResponse(
        client: Int32, id: Any, params: [String: Any]?
    ) {
        guard let runner = freqRunner else {
            sendError(client: client, id: id, code: -32601,
                      message: "freqresponse runner not configured"); return
        }
        let claimed: Bool = lock.calibLock {
            if inProgress { return false }
            inProgress = true; return true
        }
        if !claimed {
            sendError(client: client, id: id, code: -32002,
                      message: "calibration already in progress"); return
        }
        // Extract optional frequencies / toneAmplitude from the JSON-RPC
        // `params` payload. JSON's number type lands in Foundation as
        // either `NSNumber` (most common) or `Double`; the cast chain
        // handles both. Invalid types (e.g. strings) silently fall back
        // to nil — the runner uses its defaults in that case.
        let frequenciesParam: [Double]? = (params?["frequencies"] as? [Any])
            .flatMap { arr -> [Double]? in
                let doubles = arr.compactMap { ($0 as? NSNumber)?.doubleValue }
                return doubles.count == arr.count ? doubles : nil
            }
        let amplitudeParam: Double? = (params?["toneAmplitude"] as? NSNumber)?
            .doubleValue
        final class Box: @unchecked Sendable {
            var success: [String: Any]?
            var error: (Int, String)?
        }
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        Task.detached { [provider] in
            defer { sem.signal() }
            guard let snap = await provider() else {
                box.error = (-32001, "router not in whole-home + running state"); return
            }
            do {
                let result = try await runner(
                    snap, frequenciesParam, amplitudeParam
                )
                // Encode through Codable → JSONSerialization round-trip so
                // the existing `writeFrame` (Foundation JSON) can handle it.
                let data = try JSONEncoder().encode(result)
                if let obj = try JSONSerialization.jsonObject(with: data)
                    as? [String: Any]
                {
                    box.success = obj
                } else {
                    box.error = (-32000, "freqresponse: result not a JSON object")
                }
            } catch { box.error = (-32000, "\(error)") }
        }
        sem.wait()
        lock.calibLock { inProgress = false }
        if let err = box.error {
            sendError(client: client, id: id, code: err.0, message: err.1)
        } else if let ok = box.success {
            sendResult(client: client, id: id, result: ok)
        } else {
            sendError(client: client, id: id, code: -32000, message: "no result")
        }
    }

    private func handleCalibrate(client: Int32, id: Any) {
        // Single-flight: reject concurrent runs (-32002) instead of letting
        // two click-injection loops race the live ring + mic AUHAL.
        let claimed: Bool = lock.calibLock {
            if inProgress { return false }
            inProgress = true; return true
        }
        if !claimed {
            sendError(client: client, id: id, code: -32002,
                      message: "calibration already in progress"); return
        }
        // Box result so the @Sendable Task closure can mutate by reference.
        final class Box: @unchecked Sendable {
            var success: [String: Any]?
            var error: (Int, String)?
        }
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        Task.detached { [provider, runner] in
            defer { sem.signal() }
            guard let snap = await provider() else {
                box.error = (-32001, "router not in whole-home + running state"); return
            }
            do {
                let r = try await runner(snap)
                box.success = [
                    "deltaMs": r.deltaMs,
                    "confidence": r.confidence,
                    "perDeviceOffsetMs": r.perDeviceOffsetMs,
                    "perDeviceConfidence": r.perDeviceConfidence,
                    "perDeviceUncertaintyMs": r.perDeviceUncertaintyMs,
                    "applied": false,
                ]
            } catch { box.error = (-32000, "\(error)") }
        }
        // Block this connection thread (NOT the listener) until done.
        // Calibration takes ~5-30s; netcat client uses -w 60 to match.
        sem.wait()
        lock.calibLock { inProgress = false }
        if let err = box.error {
            sendError(client: client, id: id, code: err.0, message: err.1)
        } else if let ok = box.success {
            sendResult(client: client, id: id, result: ok)
        } else {
            sendError(client: client, id: id, code: -32000, message: "no result")
        }
    }

    private func handleCalibrateApply(client: Int32, id: Any) {
        guard let delayApplier else {
            sendError(client: client, id: id, code: -32601,
                      message: "calibrate_apply runner not configured")
            return
        }
        let claimed: Bool = lock.calibLock {
            if inProgress { return false }
            inProgress = true; return true
        }
        if !claimed {
            sendError(client: client, id: id, code: -32002,
                      message: "calibration already in progress"); return
        }
        final class Box: @unchecked Sendable {
            var success: [String: Any]?
            var error: (Int, String)?
        }
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        Task.detached { [provider, runner] in
            defer { sem.signal() }
            guard let snap1 = await provider() else {
                box.error = (-32001, "router not in whole-home + running state"); return
            }
            guard !snap1.delayLocked else {
                box.success = [
                    "deltaMs": snap1.currentDelayMs,
                    "confidence": 0.0,
                    "perDeviceOffsetMs": [String: Int](),
                    "perDeviceConfidence": [String: Double](),
                    "perDeviceUncertaintyMs": [String: Int](),
                    "applied": false,
                    "appliedDelayMs": snap1.currentDelayMs,
                    "reason": "delay_locked",
                ]
                return
            }
            do {
                let first = try await runner(snap1)
                let target1 = Self.clampDelay(first.deltaMs)
                guard snap1.enabledAirplayCount <= Self.autoApplyMaxAirplayReceivers else {
                    box.success = Self.applyResult(
                        measurement: first, applied: false,
                        appliedDelayMs: snap1.currentDelayMs,
                        reason: "airplay_group_dominant_only"
                    )
                    return
                }
                guard first.confidence >= Self.autoApplyConfidenceFloor else {
                    box.success = Self.applyResult(
                        measurement: first, applied: false,
                        appliedDelayMs: snap1.currentDelayMs,
                        reason: "low_confidence"
                    )
                    return
                }
                guard Self.measurementUncertaintyIsAcceptable(first) else {
                    box.success = Self.applyResult(
                        measurement: first, applied: false,
                        appliedDelayMs: snap1.currentDelayMs,
                        reason: Self.maxUncertainty(first.perDeviceUncertaintyMs) == nil
                            ? "missing_uncertainty" : "high_uncertainty"
                    )
                    return
                }
                let jump = abs(target1 - snap1.currentDelayMs)
                if jump <= Self.autoApplyMaxSingleJumpMs {
                    guard let latest = await provider() else {
                        box.success = Self.applyResult(
                            measurement: first, applied: false,
                            appliedDelayMs: snap1.currentDelayMs,
                            reason: "context_changed"
                        )
                        return
                    }
                    if let reason = Self.calibrateApplyFreshnessRejectionReason(
                        start: snap1,
                        latest: latest
                    ) {
                        box.success = Self.applyResult(
                            measurement: first, applied: false,
                            appliedDelayMs: latest.currentDelayMs,
                            reason: reason
                        )
                        return
                    }
                    let applied = try await delayApplier(target1)
                    box.success = Self.applyResult(
                        measurement: first, applied: true,
                        appliedDelayMs: applied, reason: "small_jump"
                    )
                    return
                }

                let second = try await runner(snap1)
                let target2 = Self.clampDelay(second.deltaMs)
                guard second.confidence >= Self.autoApplyConfidenceFloor else {
                    box.success = Self.applyResult(
                        measurement: second, applied: false,
                        appliedDelayMs: snap1.currentDelayMs,
                        reason: "verify_low_confidence",
                        firstDeltaMs: first.deltaMs
                    )
                    return
                }
                guard Self.measurementUncertaintyIsAcceptable(second) else {
                    box.success = Self.applyResult(
                        measurement: second, applied: false,
                        appliedDelayMs: snap1.currentDelayMs,
                        reason: Self.maxUncertainty(second.perDeviceUncertaintyMs) == nil
                            ? "verify_missing_uncertainty" : "verify_high_uncertainty",
                        firstDeltaMs: first.deltaMs
                    )
                    return
                }
                guard abs(target2 - target1) <= Self.autoApplyRepeatAgreementMs else {
                    box.success = Self.applyResult(
                        measurement: second, applied: false,
                        appliedDelayMs: snap1.currentDelayMs,
                        reason: "verify_disagreed",
                        firstDeltaMs: first.deltaMs
                    )
                    return
                }
                guard let snap2 = await provider() else {
                    box.success = Self.applyResult(
                        measurement: second, applied: false,
                        appliedDelayMs: snap1.currentDelayMs,
                        reason: "context_changed",
                        firstDeltaMs: first.deltaMs
                    )
                    return
                }
                if let reason = Self.calibrateApplyFreshnessRejectionReason(
                    start: snap1,
                    latest: snap2
                ) {
                    box.success = Self.applyResult(
                        measurement: second, applied: false,
                        appliedDelayMs: snap2.currentDelayMs,
                        reason: reason,
                        firstDeltaMs: first.deltaMs
                    )
                    return
                }
                let applied = try await delayApplier(target2)
                box.success = Self.applyResult(
                    measurement: second, applied: true,
                    appliedDelayMs: applied,
                    reason: "verified_large_jump",
                    firstDeltaMs: first.deltaMs
                )
            } catch { box.error = (-32000, "\(error)") }
        }
        sem.wait()
        lock.calibLock { inProgress = false }
        if let err = box.error {
            sendError(client: client, id: id, code: err.0, message: err.1)
        } else if let ok = box.success {
            sendResult(client: client, id: id, result: ok)
        } else {
            sendError(client: client, id: id, code: -32000, message: "no result")
        }
    }

    public static let autoApplyConfidenceFloor: Double = 3.0
    public static let autoApplyMaxSingleJumpMs: Int = 15
    public static let autoApplyRepeatAgreementMs: Int = 20
    public static let autoApplyMaxUncertaintyMs: Int = 15
    public static let autoApplyMaxAirplayReceivers: Int = 1
    public static let autoApplyDelayRange: ClosedRange<Int> = 0...5000
    private static func clampDelay(_ ms: Int) -> Int {
        min(max(ms, autoApplyDelayRange.lowerBound), autoApplyDelayRange.upperBound)
    }
    private static func maxUncertainty(_ values: [String: Int]) -> Int? {
        values.values.filter { $0 >= 0 }.max()
    }
    private static func measurementUncertaintyIsAcceptable(_ measurement: RunnerReturn) -> Bool {
        guard let max = maxUncertainty(measurement.perDeviceUncertaintyMs) else {
            return false
        }
        return max <= autoApplyMaxUncertaintyMs
    }
    private static func applyResult(
        measurement: RunnerReturn,
        applied: Bool,
        appliedDelayMs: Int,
        reason: String,
        firstDeltaMs: Int? = nil
    ) -> [String: Any] {
        var result: [String: Any] = [
            "deltaMs": measurement.deltaMs,
            "confidence": measurement.confidence,
            "perDeviceOffsetMs": measurement.perDeviceOffsetMs,
            "perDeviceConfidence": measurement.perDeviceConfidence,
            "perDeviceUncertaintyMs": measurement.perDeviceUncertaintyMs,
            "applied": applied,
            "appliedDelayMs": appliedDelayMs,
            "reason": reason,
        ]
        if let firstDeltaMs { result["firstDeltaMs"] = firstDeltaMs }
        return result
    }

    private func sendResult(client: Int32, id: Any, result: [String: Any]) {
        var p: [String: Any] = ["jsonrpc": "2.0", "result": result]
        p["id"] = id is NSNull ? NSNull() : id
        writeFrame(client: client, payload: p)
    }
    private func sendError(client: Int32, id: Any, code: Int, message: String) {
        var p: [String: Any] = ["jsonrpc": "2.0",
                                "error": ["code": code, "message": message]]
        p["id"] = id is NSNull ? NSNull() : id
        writeFrame(client: client, payload: p)
    }
    private func writeFrame(client: Int32, payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []) else { return }
        var f = Data(); f.append(data); f.append(0x0a)
        f.withUnsafeBytes { raw in
            var ptr = raw.baseAddress!; var rem = raw.count
            while rem > 0 {
                let n = Darwin.write(client, ptr, rem)
                if n < 0 { if errno == EINTR { continue }; return }
                ptr = ptr.advanced(by: n); rem -= n
            }
        }
    }
}

private extension NSLock {
    // Distinct name from AudioSocketWriter's withLock — both are file-private.
    func calibLock<T>(_ body: () -> T) -> T {
        self.lock(); defer { self.unlock() }
        return body()
    }
}
