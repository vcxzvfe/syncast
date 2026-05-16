import Foundation

public struct PassiveApplyCandidate: Sendable, Equatable {
    public let targetDelayMs: Int
    public let currentDelayMs: Int
    public let contextSignature: String
    public let delayLocked: Bool
    public let enabledAirplayCount: Int
    public let airplayTimingEpoch: UInt64
    public let captureBackend: String?
    public let syncContextState: String?
    public let syncContextRevision: UInt64?

    public init(
        targetDelayMs: Int,
        currentDelayMs: Int,
        contextSignature: String,
        delayLocked: Bool = false,
        enabledAirplayCount: Int,
        airplayTimingEpoch: UInt64,
        captureBackend: String? = nil,
        syncContextState: String? = nil,
        syncContextRevision: UInt64? = nil
    ) {
        self.targetDelayMs = targetDelayMs
        self.currentDelayMs = currentDelayMs
        self.contextSignature = contextSignature
        self.delayLocked = delayLocked
        self.enabledAirplayCount = enabledAirplayCount
        self.airplayTimingEpoch = airplayTimingEpoch
        self.captureBackend = captureBackend
        self.syncContextState = syncContextState
        self.syncContextRevision = syncContextRevision
    }
}

public struct PassiveApplyRuntime: Sendable, Equatable {
    public let currentDelayMs: Int
    public let contextSignature: String
    public let delayLocked: Bool
    public let enabledAirplayCount: Int
    public let activeAirplayCount: Int
    public let airplayTimingEpoch: UInt64
    public let captureBackend: String
    public let syncContextState: String
    public let syncContextRevision: UInt64
    public let nowUnix: Double

    public init(
        currentDelayMs: Int,
        contextSignature: String,
        delayLocked: Bool,
        enabledAirplayCount: Int,
        activeAirplayCount: Int,
        airplayTimingEpoch: UInt64,
        captureBackend: String,
        syncContextState: String = "",
        syncContextRevision: UInt64 = 0,
        nowUnix: Double = Date().timeIntervalSince1970
    ) {
        self.currentDelayMs = currentDelayMs
        self.contextSignature = contextSignature
        self.delayLocked = delayLocked
        self.enabledAirplayCount = enabledAirplayCount
        self.activeAirplayCount = activeAirplayCount
        self.airplayTimingEpoch = airplayTimingEpoch
        self.captureBackend = captureBackend
        self.syncContextState = syncContextState
        self.syncContextRevision = syncContextRevision
        self.nowUnix = nowUnix
    }
}

public struct PassiveAcceptedDryRunCandidate: Sendable, Equatable {
    public let targetDelayMs: Int
    public let currentDelayMs: Int
    public let contextSignature: String
    public let captureBackend: String
    public let enabledAirplayCount: Int
    public let activeAirplayCount: Int
    public let airplayTimingEpoch: UInt64
    public let acceptedSyncContextRevision: UInt64
    public let acceptedUnix: Double

    public init(
        targetDelayMs: Int,
        currentDelayMs: Int,
        contextSignature: String,
        captureBackend: String,
        enabledAirplayCount: Int,
        activeAirplayCount: Int,
        airplayTimingEpoch: UInt64,
        acceptedSyncContextRevision: UInt64,
        acceptedUnix: Double
    ) {
        self.targetDelayMs = targetDelayMs
        self.currentDelayMs = currentDelayMs
        self.contextSignature = contextSignature
        self.captureBackend = captureBackend
        self.enabledAirplayCount = enabledAirplayCount
        self.activeAirplayCount = activeAirplayCount
        self.airplayTimingEpoch = airplayTimingEpoch
        self.acceptedSyncContextRevision = acceptedSyncContextRevision
        self.acceptedUnix = acceptedUnix
    }
}

public enum PassiveApplyGuard {
    public static let maxStepMs = 20
    public static let maxAirplayReceivers = 8
    public static let delayRange: ClosedRange<Int> = 0...5000
    public static let acceptedDryRunMaxAgeSeconds: Double = 120
    public static let acceptedDryRunFutureSkewSeconds: Double = 5
    private static let supportedBackends: Set<String> = ["sck", "tap"]

    public static func rejectionReason(
        candidate: PassiveApplyCandidate,
        runtime: PassiveApplyRuntime
    ) -> String? {
        guard delayRange.contains(candidate.targetDelayMs) else {
            return "target_out_of_range"
        }
        guard !candidate.contextSignature.isEmpty else {
            return "missing_context"
        }
        guard !candidate.delayLocked else {
            return "candidate_delay_locked"
        }
        guard !runtime.delayLocked else {
            return "delay_locked"
        }
        guard let candidateBackend = candidate.captureBackend?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !candidateBackend.isEmpty else {
            return "missing_capture_backend"
        }
        let runtimeBackend = runtime.captureBackend
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard supportedBackends.contains(candidateBackend),
              supportedBackends.contains(runtimeBackend) else {
            return "capture_backend_unsupported"
        }
        if let candidateState = candidate.syncContextState,
           !candidateState.isEmpty {
            guard candidateState == runtime.syncContextState else {
                return "sync_context_state_changed"
            }
        } else {
            return "missing_sync_context_state"
        }
        guard let candidateRevision = candidate.syncContextRevision else {
            return "missing_sync_context_revision"
        }
        guard candidateRevision == runtime.syncContextRevision else {
            return "sync_context_revision_changed"
        }
        guard runtime.syncContextState != "locked" else {
            return "sync_context_locked"
        }
        guard runtime.syncContextState != "measuring" else {
            return "sync_context_measuring"
        }
        guard runtime.syncContextState != "dryRunReady" else {
            return "sync_context_dry_run_ready"
        }
        guard candidate.currentDelayMs == runtime.currentDelayMs else {
            return "delay_changed"
        }
        guard candidate.contextSignature == runtime.contextSignature else {
            return "context_changed"
        }
        guard candidate.enabledAirplayCount == runtime.enabledAirplayCount else {
            return "enabled_airplay_count_changed"
        }
        guard runtime.enabledAirplayCount <= maxAirplayReceivers else {
            return "too_many_airplay_receivers_not_apply_safe"
        }
        guard runtime.enabledAirplayCount > 0 else {
            return "no_airplay_receiver"
        }
        guard runtime.activeAirplayCount == runtime.enabledAirplayCount else {
            return "airplay_not_fully_connected"
        }
        guard candidate.airplayTimingEpoch == runtime.airplayTimingEpoch else {
            return "airplay_timing_epoch_changed"
        }
        if candidateBackend != runtimeBackend {
            return "capture_backend_changed"
        }
        guard abs(candidate.targetDelayMs - runtime.currentDelayMs) <= maxStepMs else {
            return "target_step_too_large"
        }
        return nil
    }

    public static func acceptedDryRunRejectionReason(
        accepted: PassiveAcceptedDryRunCandidate,
        runtime: PassiveApplyRuntime
    ) -> String? {
        guard delayRange.contains(accepted.targetDelayMs) else {
            return "target_out_of_range"
        }
        guard !accepted.contextSignature.isEmpty else {
            return "missing_context"
        }
        guard !runtime.delayLocked else {
            return "delay_locked"
        }
        guard runtime.syncContextState == "dryRunReady" else {
            return "sync_context_not_dry_run_ready"
        }
        guard accepted.acceptedSyncContextRevision == runtime.syncContextRevision else {
            return "accepted_sync_context_revision_changed"
        }
        guard accepted.acceptedUnix.isFinite, accepted.acceptedUnix > 0 else {
            return "accepted_candidate_time_invalid"
        }
        guard runtime.nowUnix.isFinite, runtime.nowUnix > 0 else {
            return "runtime_time_invalid"
        }
        let acceptedAge = runtime.nowUnix - accepted.acceptedUnix
        guard acceptedAge >= -acceptedDryRunFutureSkewSeconds else {
            return "accepted_candidate_from_future"
        }
        guard acceptedAge <= acceptedDryRunMaxAgeSeconds else {
            return "accepted_candidate_expired"
        }
        let acceptedBackend = accepted.captureBackend
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let runtimeBackend = runtime.captureBackend
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard supportedBackends.contains(acceptedBackend),
              supportedBackends.contains(runtimeBackend) else {
            return "capture_backend_unsupported"
        }
        guard accepted.currentDelayMs == runtime.currentDelayMs else {
            return "delay_changed"
        }
        guard accepted.contextSignature == runtime.contextSignature else {
            return "context_changed"
        }
        guard accepted.enabledAirplayCount == runtime.enabledAirplayCount else {
            return "enabled_airplay_count_changed"
        }
        guard accepted.activeAirplayCount == runtime.activeAirplayCount else {
            return "active_airplay_count_changed"
        }
        guard runtime.enabledAirplayCount <= maxAirplayReceivers else {
            return "too_many_airplay_receivers_not_apply_safe"
        }
        guard runtime.enabledAirplayCount > 0 else {
            return "no_airplay_receiver"
        }
        guard runtime.activeAirplayCount == runtime.enabledAirplayCount else {
            return "airplay_not_fully_connected"
        }
        guard accepted.airplayTimingEpoch == runtime.airplayTimingEpoch else {
            return "airplay_timing_epoch_changed"
        }
        if acceptedBackend != runtimeBackend {
            return "capture_backend_changed"
        }
        guard abs(accepted.targetDelayMs - runtime.currentDelayMs) <= maxStepMs else {
            return "target_step_too_large"
        }
        return nil
    }
}
