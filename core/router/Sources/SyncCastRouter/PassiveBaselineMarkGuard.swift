import Foundation

public struct PassiveBaselineMarkRequest: Sendable, Equatable {
    public let currentDelayMs: Int
    public let contextSignature: String
    public let delayLocked: Bool
    public let enabledAirplayCount: Int
    public let activeAirplayCount: Int?
    public let airplayTimingEpoch: UInt64
    public let captureBackend: String
    public let syncContextState: String
    public let syncContextRevision: UInt64

    public init(
        currentDelayMs: Int,
        contextSignature: String,
        delayLocked: Bool = false,
        enabledAirplayCount: Int,
        activeAirplayCount: Int? = nil,
        airplayTimingEpoch: UInt64,
        captureBackend: String,
        syncContextState: String,
        syncContextRevision: UInt64
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
    }
}

public struct PassiveBaselineMarkRuntime: Sendable, Equatable {
    public let currentDelayMs: Int
    public let contextSignature: String
    public let delayLocked: Bool
    public let enabledAirplayCount: Int
    public let activeAirplayCount: Int
    public let airplayTimingEpoch: UInt64
    public let captureBackend: String
    public let syncContextState: String
    public let syncContextRevision: UInt64

    public init(
        currentDelayMs: Int,
        contextSignature: String,
        delayLocked: Bool = false,
        enabledAirplayCount: Int,
        activeAirplayCount: Int,
        airplayTimingEpoch: UInt64,
        captureBackend: String,
        syncContextState: String,
        syncContextRevision: UInt64
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
    }
}

public enum PassiveBaselineMarkGuard {
    public static let delayRange: ClosedRange<Int> = 0...5000
    public static let maxAirplayReceivers = 8

    private static let supportedBackends: Set<String> = ["sck", "tap"]
    private static let markableStates: Set<String> = ["suspect", "applied", "valid"]

    public static func rejectionReason(
        request: PassiveBaselineMarkRequest,
        runtime: PassiveBaselineMarkRuntime
    ) -> String? {
        guard delayRange.contains(request.currentDelayMs),
              delayRange.contains(runtime.currentDelayMs) else {
            return "delay_out_of_range"
        }
        guard !request.contextSignature.isEmpty else {
            return "missing_context"
        }
        guard !request.delayLocked else {
            return "candidate_delay_locked"
        }
        guard !runtime.delayLocked else {
            return "delay_locked"
        }
        guard !request.syncContextState.isEmpty else {
            return "missing_sync_context_state"
        }
        guard request.syncContextState == runtime.syncContextState else {
            return "sync_context_state_changed"
        }
        guard request.syncContextRevision == runtime.syncContextRevision else {
            return "sync_context_revision_changed"
        }
        guard markableStates.contains(runtime.syncContextState) else {
            return "sync_context_not_markable"
        }
        guard request.currentDelayMs == runtime.currentDelayMs else {
            return "delay_changed"
        }
        guard request.contextSignature == runtime.contextSignature else {
            return "context_changed"
        }
        guard request.enabledAirplayCount == runtime.enabledAirplayCount else {
            return "enabled_airplay_count_changed"
        }
        guard runtime.enabledAirplayCount <= maxAirplayReceivers else {
            return "too_many_airplay_receivers"
        }
        guard runtime.enabledAirplayCount > 0 else {
            return "no_airplay_receiver"
        }
        if let requestedActive = request.activeAirplayCount,
           requestedActive != runtime.activeAirplayCount {
            return "active_airplay_count_changed"
        }
        guard runtime.activeAirplayCount == runtime.enabledAirplayCount else {
            return "airplay_not_fully_connected"
        }
        guard request.airplayTimingEpoch == runtime.airplayTimingEpoch else {
            return "airplay_timing_epoch_changed"
        }
        guard supportedBackends.contains(request.captureBackend),
              supportedBackends.contains(runtime.captureBackend) else {
            return "capture_backend_unsupported"
        }
        guard request.captureBackend == runtime.captureBackend else {
            return "capture_backend_changed"
        }
        return nil
    }
}
