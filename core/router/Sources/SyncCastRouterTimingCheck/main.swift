import Foundation
import os
import SyncCastRouter

struct TimingCheckError: Error, CustomStringConvertible {
    let description: String
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw TimingCheckError(description: message)
    }
}

func checkFullyPreArmCallbackDropsAllFrames() throws {
    let plan = PassiveMicFrameAlignment.plan(
        callbackFrames: 128,
        sampleRate: 48_000,
        armedAtNs: 1_000_000_000,
        callbackFirstHostNs: 990_000_000,
        remainingCapacityFrames: 512,
        alreadyHasFirstSample: false
    )
    try expect(!plan.shouldCopy, "fully pre-arm callback must not copy")
    try expect(plan.warmupDropFrames == 128, "fully pre-arm callback drop count")
}

func checkStraddlingCallbackDropsOnlyPreArmFrames() throws {
    let plan = PassiveMicFrameAlignment.plan(
        callbackFrames: 128,
        sampleRate: 48_000,
        armedAtNs: 1_001_000_000,
        callbackFirstHostNs: 1_000_000_000,
        remainingCapacityFrames: 512,
        alreadyHasFirstSample: false
    )
    try expect(plan.shouldCopy, "straddling callback should copy post-arm frames")
    try expect(plan.copyStartFrame == 48, "straddling callback source offset")
    try expect(plan.copyFrameCount == 80, "straddling callback copy count")
    try expect(plan.startPaddingFrames == 0, "straddling callback no front padding")
    try expect(
        plan.firstSampleAtNs == 1_001_000_000,
        "straddling callback first sample timestamp"
    )
}

func checkPostArmCallbackPadsMicWav() throws {
    let plan = PassiveMicFrameAlignment.plan(
        callbackFrames: 128,
        sampleRate: 48_000,
        armedAtNs: 1_000_000_000,
        callbackFirstHostNs: 1_001_000_000,
        remainingCapacityFrames: 512,
        alreadyHasFirstSample: false
    )
    try expect(plan.shouldCopy, "post-arm callback should copy")
    try expect(plan.copyStartFrame == 0, "post-arm callback source offset")
    try expect(plan.copyFrameCount == 128, "post-arm callback copy count")
    try expect(plan.startPaddingFrames == 48, "post-arm callback padding")
    try expect(
        plan.firstSampleAtNs == 1_001_000_000,
        "post-arm callback first sample timestamp"
    )
}

func checkCapacityLimitsCopyCount() throws {
    let plan = PassiveMicFrameAlignment.plan(
        callbackFrames: 128,
        sampleRate: 48_000,
        armedAtNs: 1_000_000_000,
        callbackFirstHostNs: 1_000_000_000,
        remainingCapacityFrames: 12,
        alreadyHasFirstSample: true
    )
    try expect(plan.shouldCopy, "capacity-limited callback should copy")
    try expect(plan.copyStartFrame == 0, "capacity-limited source offset")
    try expect(plan.copyFrameCount == 12, "capacity-limited copy count")
    try expect(plan.firstSampleAtNs == nil, "existing first-sample should not reset")
}

func checkActiveAcousticDiagnosticsRequireBothFlags() throws {
    let now = Date(timeIntervalSince1970: 1_000)
    let freshEvidence = ActiveAcousticDiagnosticsGate.LabSessionEvidence(
        token: "session-1",
        modifiedAt: now.addingTimeInterval(-10)
    )
    let staleEvidence = ActiveAcousticDiagnosticsGate.LabSessionEvidence(
        token: "session-1",
        modifiedAt: now.addingTimeInterval(
            -ActiveAcousticDiagnosticsGate.labSessionMaxAgeSeconds - 1
        )
    )
    let mismatchedEvidence = ActiveAcousticDiagnosticsGate.LabSessionEvidence(
        token: "other-session",
        modifiedAt: now.addingTimeInterval(-10)
    )
    let fullEnvironment = [
        ActiveAcousticDiagnosticsGate.enableFlag: "1",
        ActiveAcousticDiagnosticsGate.audibleProbeFlag: "yes",
        ActiveAcousticDiagnosticsGate.confirmationFlag: "1",
        ActiveAcousticDiagnosticsGate.labSessionFlag: "session-1",
    ]
    try expect(
        !ActiveAcousticDiagnosticsGate.isEnabled(environment: [:]),
        "active diagnostics must default off"
    )
    try expect(
        !ActiveAcousticDiagnosticsGate.isEnabled(environment: [
            ActiveAcousticDiagnosticsGate.enableFlag: "1",
        ]),
        "legacy single active-calibration flag must not enable audible probes"
    )
    try expect(
        !ActiveAcousticDiagnosticsGate.isEnabled(environment: [
            ActiveAcousticDiagnosticsGate.audibleProbeFlag: "1",
        ]),
        "audible-probe flag alone must not enable active diagnostics"
    )
    try expect(
        !ActiveAcousticDiagnosticsGate.isEnabled(environment: [
            ActiveAcousticDiagnosticsGate.enableFlag: "1",
            ActiveAcousticDiagnosticsGate.audibleProbeFlag: "yes",
            ActiveAcousticDiagnosticsGate.confirmationFlag: "1",
        ]),
        "three stale lab flags must not enable active diagnostics without a session token"
    )
    try expect(
        !ActiveAcousticDiagnosticsGate.isEnabled(
            environment: fullEnvironment,
            now: now,
            labSessionEvidence: mismatchedEvidence
        ),
        "active diagnostics must reject mismatched lab-session evidence"
    )
    try expect(
        !ActiveAcousticDiagnosticsGate.isEnabled(
            environment: fullEnvironment,
            now: now,
            labSessionEvidence: staleEvidence
        ),
        "active diagnostics must reject stale lab-session evidence"
    )
    try expect(
        ActiveAcousticDiagnosticsGate.isEnabled(
            environment: fullEnvironment,
            now: now,
            labSessionEvidence: freshEvidence
        ),
        "active diagnostics require explicit lab flags plus fresh session evidence"
    )
}

func checkActiveAcousticDiagnosticsMessageNamesBothFlags() throws {
    try expect(
        ActiveAcousticDiagnosticsGate.disabledMessage.contains(
            ActiveAcousticDiagnosticsGate.enableFlag
        ),
        "disabled message must name the active-calibration flag"
    )
    try expect(
        ActiveAcousticDiagnosticsGate.disabledMessage.contains(
            ActiveAcousticDiagnosticsGate.audibleProbeFlag
        ),
        "disabled message must name the audible-probe flag"
    )
    try expect(
        ActiveAcousticDiagnosticsGate.disabledMessage.contains(
            ActiveAcousticDiagnosticsGate.confirmationFlag
        ),
        "disabled message must name the audible-probe confirmation flag"
    )
    try expect(
        ActiveAcousticDiagnosticsGate.disabledMessage.contains(
            ActiveAcousticDiagnosticsGate.labSessionFlag
        ),
        "disabled message must name the lab-session token flag"
    )
}

func checkActiveAcousticDiagnosticsStartupState() throws {
    let now = Date(timeIntervalSince1970: 2_000)
    try expect(
        ActiveAcousticDiagnosticsGate.startupLogState(environment: [:])
            == "disabled; passive no-probe diagnostics only",
        "startup log should clearly state default disabled/passive state"
    )
    try expect(
        ActiveAcousticDiagnosticsGate.startupLogState(
            environment: [
                ActiveAcousticDiagnosticsGate.enableFlag: "true",
                ActiveAcousticDiagnosticsGate.audibleProbeFlag: " TRUE ",
                ActiveAcousticDiagnosticsGate.confirmationFlag: "yes",
                ActiveAcousticDiagnosticsGate.labSessionFlag: "session-1",
            ],
            now: now,
            labSessionEvidence: .init(
                token: "session-1",
                modifiedAt: now.addingTimeInterval(-1)
            )
        )
            == "enabled by explicit lab tone flags",
        "startup log should clearly state explicit lab tone state"
    )
}

func checkCalibrationInternalVolumeChangesDoNotInvalidateTiming() throws {
    try expect(
        !Router.airplayVolumeChangeInvalidatesTiming(
            previous: 1.0,
            next: 0.0,
            invalidatesTiming: false
        ),
        "calibration-owned mute/restore volume changes must not invalidate their own timing snapshot"
    )
    try expect(
        Router.airplayVolumeChangeInvalidatesTiming(
            previous: 1.0,
            next: 0.0,
            invalidatesTiming: true
        ),
        "external AirPlay volume changes must still invalidate timing"
    )
    try expect(
        !Router.airplayVolumeChangeInvalidatesTiming(
            previous: 1.0,
            next: 0.98,
            invalidatesTiming: true
        ),
        "small AirPlay volume deltas should remain below the timing invalidation threshold"
    )
}

func checkAirPlayConnectionEventsInvalidateTiming() throws {
    try expect(
        Router.airplayConnectionEventInvalidatesTiming(
            previous: nil,
            next: .connected,
            isActiveAirplay: true
        ),
        "first connected AirPlay event must invalidate timing"
    )
    try expect(
        Router.airplayConnectionEventInvalidatesTiming(
            previous: .connecting,
            next: .connected,
            isActiveAirplay: true
        ),
        "connecting->connected AirPlay event must invalidate timing"
    )
    try expect(
        Router.airplayConnectionEventInvalidatesTiming(
            previous: .connected,
            next: .connected,
            isActiveAirplay: true
        ),
        "repeated connected event for an active AirPlay receiver may mean relock and must invalidate timing"
    )
    try expect(
        !Router.airplayConnectionEventInvalidatesTiming(
            previous: .connected,
            next: .connected,
            isActiveAirplay: false
        ),
        "repeated connected event for inactive AirPlay receiver should not churn timing"
    )
    try expect(
        !Router.airplayConnectionEventInvalidatesTiming(
            previous: .disconnected,
            next: .disconnected,
            isActiveAirplay: true
        ),
        "repeated disconnected event should not churn timing"
    )
}

func checkAirPlayStreamStartNoopResponse() throws {
    try expect(
        Router.streamStartResponseIndicatesNoop([
            "started": true,
            "noop": true,
        ]),
        "same-set stream.start noop response should not force timing invalidation"
    )
    try expect(
        !Router.streamStartResponseIndicatesNoop([
            "started": true,
            "device_count": 1,
        ]),
        "non-noop stream.start response should still allow timing invalidation"
    )
    try expect(
        !Router.streamStartResponseIndicatesNoop(nil),
        "missing stream.start response must not be treated as a noop"
    )
}

func checkStereoOutputDefaultsToDirect() throws {
    try expect(
        StereoOutputPathPolicy.selectedPath(environment: [:]) == .direct,
        "Stereo output should default to Direct Stereo for no-SCK local playback"
    )
    try expect(
        StereoOutputPathPolicy.selectedPath(environment: [
            StereoOutputPathPolicy.environmentFlag: "direct",
        ]) == .direct,
        "explicit direct stereo path should select Direct Stereo"
    )
}

func checkStereoOutputCaptureOptOutsRemainAvailable() throws {
    try expect(
        StereoOutputPathPolicy.selectedPath(environment: [
            StereoOutputPathPolicy.environmentFlag: "capture",
        ]) == .capture,
        "capture stereo fallback should remain available"
    )
    try expect(
        StereoOutputPathPolicy.selectedPath(environment: [
            StereoOutputPathPolicy.environmentFlag: "sck",
        ]) == .capture,
        "sck alias should select capture stereo fallback"
    )
}

func checkStereoOutputUnknownFallsForwardToDirectWithWarning() throws {
    let env = [StereoOutputPathPolicy.environmentFlag: "surprise"]
    try expect(
        StereoOutputPathPolicy.selectedPath(environment: env) == .direct,
        "unknown stereo path should fall forward to Direct Stereo, not SCK"
    )
    try expect(
        StereoOutputPathPolicy.warningForUnknownValue(environment: env)?
            .contains("using direct stereo path") == true,
        "unknown stereo path warning should name direct fallback"
    )
}

func checkPassiveApplyGuardAcceptsMatchingSmallStep() throws {
    let candidate = PassiveApplyCandidate(
        targetDelayMs: 2210,
        currentDelayMs: 2200,
        contextSignature: "ctx-a",
        enabledAirplayCount: 1,
        airplayTimingEpoch: 42,
        captureBackend: "tap",
        syncContextState: "suspect",
        syncContextRevision: 7
    )
    let runtime = PassiveApplyRuntime(
        currentDelayMs: 2200,
        contextSignature: "ctx-a",
        delayLocked: false,
        enabledAirplayCount: 1,
        activeAirplayCount: 1,
        airplayTimingEpoch: 42,
        captureBackend: "tap",
        syncContextState: "suspect",
        syncContextRevision: 7
    )
    try expect(
        PassiveApplyGuard.rejectionReason(candidate: candidate, runtime: runtime) == nil,
        "matching passive apply candidate should be accepted"
    )
}

func checkPassiveApplyGuardRejectsTimingEpochDrift() throws {
    let candidate = PassiveApplyCandidate(
        targetDelayMs: 2210,
        currentDelayMs: 2200,
        contextSignature: "ctx-a",
        enabledAirplayCount: 1,
        airplayTimingEpoch: 42,
        captureBackend: "tap",
        syncContextState: "suspect",
        syncContextRevision: 7
    )
    let runtime = PassiveApplyRuntime(
        currentDelayMs: 2200,
        contextSignature: "ctx-a",
        delayLocked: false,
        enabledAirplayCount: 1,
        activeAirplayCount: 1,
        airplayTimingEpoch: 43,
        captureBackend: "tap",
        syncContextState: "suspect",
        syncContextRevision: 7
    )
    try expect(
        PassiveApplyGuard.rejectionReason(candidate: candidate, runtime: runtime)
            == "airplay_timing_epoch_changed",
        "passive apply must reject changed AirPlay timing epoch"
    )
}

func checkPassiveApplyGuardRejectsLargeStep() throws {
    let candidate = PassiveApplyCandidate(
        targetDelayMs: 2250,
        currentDelayMs: 2200,
        contextSignature: "ctx-a",
        enabledAirplayCount: 1,
        airplayTimingEpoch: 42,
        captureBackend: "tap",
        syncContextState: "suspect",
        syncContextRevision: 7
    )
    let runtime = PassiveApplyRuntime(
        currentDelayMs: 2200,
        contextSignature: "ctx-a",
        delayLocked: false,
        enabledAirplayCount: 1,
        activeAirplayCount: 1,
        airplayTimingEpoch: 42,
        captureBackend: "tap",
        syncContextState: "suspect",
        syncContextRevision: 7
    )
    try expect(
        PassiveApplyGuard.rejectionReason(candidate: candidate, runtime: runtime)
            == "target_step_too_large",
        "passive apply must reject steps larger than passive decision policy"
    )
}

func passiveCandidate(
    targetDelayMs: Int = 2210,
    currentDelayMs: Int = 2200,
    contextSignature: String = "ctx-a",
    delayLocked: Bool = false,
    enabledAirplayCount: Int = 1,
    airplayTimingEpoch: UInt64 = 42,
    captureBackend: String? = "tap",
    syncContextState: String? = "suspect",
    syncContextRevision: UInt64? = 7
) -> PassiveApplyCandidate {
    PassiveApplyCandidate(
        targetDelayMs: targetDelayMs,
        currentDelayMs: currentDelayMs,
        contextSignature: contextSignature,
        delayLocked: delayLocked,
        enabledAirplayCount: enabledAirplayCount,
        airplayTimingEpoch: airplayTimingEpoch,
        captureBackend: captureBackend,
        syncContextState: syncContextState,
        syncContextRevision: syncContextRevision
    )
}

func passiveRuntime(
    currentDelayMs: Int = 2200,
    contextSignature: String = "ctx-a",
    delayLocked: Bool = false,
    enabledAirplayCount: Int = 1,
    activeAirplayCount: Int = 1,
    airplayTimingEpoch: UInt64 = 42,
    captureBackend: String = "tap",
    syncContextState: String = "suspect",
    syncContextRevision: UInt64 = 7,
    nowUnix: Double = 1_001
) -> PassiveApplyRuntime {
    PassiveApplyRuntime(
        currentDelayMs: currentDelayMs,
        contextSignature: contextSignature,
        delayLocked: delayLocked,
        enabledAirplayCount: enabledAirplayCount,
        activeAirplayCount: activeAirplayCount,
        airplayTimingEpoch: airplayTimingEpoch,
        captureBackend: captureBackend,
        syncContextState: syncContextState,
        syncContextRevision: syncContextRevision,
        nowUnix: nowUnix
    )
}

func checkPassiveApplyGuardRejectsRuntimeMutationMatrix() throws {
    try expect(
        PassiveApplyGuard.rejectionReason(
            candidate: passiveCandidate(enabledAirplayCount: 2),
            runtime: passiveRuntime(enabledAirplayCount: 2, activeAirplayCount: 2)
        ) == nil,
        "passive apply should allow a fully-connected AirPlay receiver group"
    )
    let cases: [(String, PassiveApplyCandidate, PassiveApplyRuntime, String)] = [
        ("candidate lock", passiveCandidate(delayLocked: true), passiveRuntime(), "candidate_delay_locked"),
        ("runtime lock", passiveCandidate(), passiveRuntime(delayLocked: true), "delay_locked"),
        ("missing sync state", passiveCandidate(syncContextState: nil), passiveRuntime(), "missing_sync_context_state"),
        ("sync state changed", passiveCandidate(syncContextState: "suspect"), passiveRuntime(syncContextState: "readyToDryRun"), "sync_context_state_changed"),
        ("missing sync revision", passiveCandidate(syncContextRevision: nil), passiveRuntime(), "missing_sync_context_revision"),
        ("sync revision changed", passiveCandidate(syncContextRevision: 7), passiveRuntime(syncContextRevision: 8), "sync_context_revision_changed"),
        ("sync measuring", passiveCandidate(syncContextState: "measuring"), passiveRuntime(syncContextState: "measuring"), "sync_context_measuring"),
        ("sync dry-run ready", passiveCandidate(syncContextState: "dryRunReady"), passiveRuntime(syncContextState: "dryRunReady"), "sync_context_dry_run_ready"),
        ("delay changed", passiveCandidate(), passiveRuntime(currentDelayMs: 2201), "delay_changed"),
        ("context changed", passiveCandidate(), passiveRuntime(contextSignature: "ctx-b"), "context_changed"),
        ("enabled count changed", passiveCandidate(), passiveRuntime(enabledAirplayCount: 0, activeAirplayCount: 0), "enabled_airplay_count_changed"),
        ("too many AirPlay", passiveCandidate(enabledAirplayCount: 9), passiveRuntime(enabledAirplayCount: 9, activeAirplayCount: 9), "too_many_airplay_receivers_not_apply_safe"),
        ("no AirPlay", passiveCandidate(enabledAirplayCount: 0), passiveRuntime(enabledAirplayCount: 0, activeAirplayCount: 0), "no_airplay_receiver"),
        ("inactive AirPlay", passiveCandidate(), passiveRuntime(activeAirplayCount: 0), "airplay_not_fully_connected"),
        ("epoch changed", passiveCandidate(), passiveRuntime(airplayTimingEpoch: 43), "airplay_timing_epoch_changed"),
        ("missing backend", passiveCandidate(captureBackend: nil), passiveRuntime(), "missing_capture_backend"),
        ("unsupported candidate backend", passiveCandidate(captureBackend: "unknown"), passiveRuntime(), "capture_backend_unsupported"),
        ("unsupported runtime backend", passiveCandidate(), passiveRuntime(captureBackend: "unknown"), "capture_backend_unsupported"),
        ("backend changed", passiveCandidate(), passiveRuntime(captureBackend: "sck"), "capture_backend_changed"),
        ("large step", passiveCandidate(targetDelayMs: 2250), passiveRuntime(), "target_step_too_large"),
    ]
    for (name, candidate, runtime, expected) in cases {
        try expect(
            PassiveApplyGuard.rejectionReason(candidate: candidate, runtime: runtime) == expected,
            "passive apply mutation matrix failed for \(name)"
        )
    }
}

func passiveAcceptedCandidate(
    targetDelayMs: Int = 2210,
    currentDelayMs: Int = 2200,
    contextSignature: String = "ctx-a",
    captureBackend: String = "tap",
    enabledAirplayCount: Int = 1,
    activeAirplayCount: Int = 1,
    airplayTimingEpoch: UInt64 = 42,
    acceptedSyncContextRevision: UInt64 = 8,
    acceptedUnix: Double = 1_000
) -> PassiveAcceptedDryRunCandidate {
    PassiveAcceptedDryRunCandidate(
        targetDelayMs: targetDelayMs,
        currentDelayMs: currentDelayMs,
        contextSignature: contextSignature,
        captureBackend: captureBackend,
        enabledAirplayCount: enabledAirplayCount,
        activeAirplayCount: activeAirplayCount,
        airplayTimingEpoch: airplayTimingEpoch,
        acceptedSyncContextRevision: acceptedSyncContextRevision,
        acceptedUnix: acceptedUnix
    )
}

func checkAcceptedPassiveApplyGuardRequiresDryRunReadyRuntime() throws {
    let accepted = passiveAcceptedCandidate()
    try expect(
        PassiveApplyGuard.acceptedDryRunRejectionReason(
            accepted: accepted,
            runtime: passiveRuntime(
                syncContextState: "dryRunReady",
                syncContextRevision: 8
            )
        ) == nil,
        "accepted passive dry-run candidate should pass against matching dryRunReady runtime"
    )
    let cases: [(String, PassiveAcceptedDryRunCandidate, PassiveApplyRuntime, String)] = [
        ("not dry-run ready", accepted, passiveRuntime(syncContextState: "valid", syncContextRevision: 8), "sync_context_not_dry_run_ready"),
        ("revision changed", accepted, passiveRuntime(syncContextState: "dryRunReady", syncContextRevision: 9), "accepted_sync_context_revision_changed"),
        ("delay changed", accepted, passiveRuntime(currentDelayMs: 2190, syncContextState: "dryRunReady", syncContextRevision: 8), "delay_changed"),
        ("context changed", accepted, passiveRuntime(contextSignature: "ctx-b", syncContextState: "dryRunReady", syncContextRevision: 8), "context_changed"),
        ("backend changed", accepted, passiveRuntime(captureBackend: "sck", syncContextState: "dryRunReady", syncContextRevision: 8), "capture_backend_changed"),
        ("epoch changed", accepted, passiveRuntime(airplayTimingEpoch: 43, syncContextState: "dryRunReady", syncContextRevision: 8), "airplay_timing_epoch_changed"),
        ("active count changed", accepted, passiveRuntime(activeAirplayCount: 0, syncContextState: "dryRunReady", syncContextRevision: 8), "active_airplay_count_changed"),
        ("large step", passiveAcceptedCandidate(targetDelayMs: 2250), passiveRuntime(syncContextState: "dryRunReady", syncContextRevision: 8), "target_step_too_large"),
        ("invalid accepted time", passiveAcceptedCandidate(acceptedUnix: .nan), passiveRuntime(syncContextState: "dryRunReady", syncContextRevision: 8), "accepted_candidate_time_invalid"),
        ("runtime time invalid", accepted, passiveRuntime(syncContextState: "dryRunReady", syncContextRevision: 8, nowUnix: .nan), "runtime_time_invalid"),
        ("accepted time from future", passiveAcceptedCandidate(acceptedUnix: 1_020), passiveRuntime(syncContextState: "dryRunReady", syncContextRevision: 8, nowUnix: 1_000), "accepted_candidate_from_future"),
        ("accepted candidate expired", accepted, passiveRuntime(syncContextState: "dryRunReady", syncContextRevision: 8, nowUnix: 1_121), "accepted_candidate_expired"),
    ]
    for (name, accepted, runtime, expected) in cases {
        try expect(
            PassiveApplyGuard.acceptedDryRunRejectionReason(
                accepted: accepted,
                runtime: runtime
            ) == expected,
            "accepted passive apply guard failed for \(name)"
        )
    }
}

func checkPassiveApplyResultPayloadEchoesDecisionRuntime() throws {
    let candidate = passiveCandidate()
    let initialRuntime = passiveRuntime()
    let latestRuntime = passiveRuntime(
        currentDelayMs: 2205,
        syncContextRevision: 8
    )
    let dryRunPayload = CalibrationDiagnosticServer.passiveApplyResultPayload(
        candidate: candidate,
        runtime: initialRuntime,
        applied: false,
        wouldApply: true,
        reason: "dry_run"
    )
    try expect(
        dryRunPayload["currentDelayMs"] as? Int == 2200,
        "passive apply dry-run payload should echo the checked runtime delay"
    )
    let latestRejectionPayload = CalibrationDiagnosticServer.passiveApplyResultPayload(
        candidate: candidate,
        runtime: latestRuntime,
        applied: false,
        wouldApply: false,
        reason: "sync_context_revision_changed"
    )
    try expect(
        latestRejectionPayload["currentDelayMs"] as? Int == 2205,
        "passive apply late rejection payload should echo the latest runtime delay"
    )
    try expect(
        (latestRejectionPayload["syncContextRevision"] as? NSNumber)?.uint64Value == 8,
        "passive apply late rejection payload should echo the latest sync revision"
    )
    try expect(
        latestRejectionPayload["reason"] as? String == "sync_context_revision_changed",
        "passive apply payload should keep the guard rejection reason"
    )
}

func passiveBaselineRequest(
    currentDelayMs: Int = 2200,
    contextSignature: String = "ctx-a",
    delayLocked: Bool = false,
    enabledAirplayCount: Int = 1,
    activeAirplayCount: Int? = 1,
    airplayTimingEpoch: UInt64 = 42,
    captureBackend: String = "tap",
    syncContextState: String = "suspect",
    syncContextRevision: UInt64 = 7
) -> PassiveBaselineMarkRequest {
    PassiveBaselineMarkRequest(
        currentDelayMs: currentDelayMs,
        contextSignature: contextSignature,
        delayLocked: delayLocked,
        enabledAirplayCount: enabledAirplayCount,
        activeAirplayCount: activeAirplayCount,
        airplayTimingEpoch: airplayTimingEpoch,
        captureBackend: captureBackend,
        syncContextState: syncContextState,
        syncContextRevision: syncContextRevision
    )
}

func passiveBaselineRuntime(
    currentDelayMs: Int = 2200,
    contextSignature: String = "ctx-a",
    delayLocked: Bool = false,
    enabledAirplayCount: Int = 1,
    activeAirplayCount: Int = 1,
    airplayTimingEpoch: UInt64 = 42,
    captureBackend: String = "tap",
    syncContextState: String = "suspect",
    syncContextRevision: UInt64 = 7
) -> PassiveBaselineMarkRuntime {
    PassiveBaselineMarkRuntime(
        currentDelayMs: currentDelayMs,
        contextSignature: contextSignature,
        delayLocked: delayLocked,
        enabledAirplayCount: enabledAirplayCount,
        activeAirplayCount: activeAirplayCount,
        airplayTimingEpoch: airplayTimingEpoch,
        captureBackend: captureBackend,
        syncContextState: syncContextState,
        syncContextRevision: syncContextRevision
    )
}

func checkPassiveBaselineMarkGuard() throws {
    try expect(
        PassiveBaselineMarkGuard.rejectionReason(
            request: passiveBaselineRequest(enabledAirplayCount: 2, activeAirplayCount: 2),
            runtime: passiveBaselineRuntime(enabledAirplayCount: 2, activeAirplayCount: 2)
        ) == nil,
        "passive baseline mark should allow multi-AirPlay evidence"
    )
    let cases: [(String, PassiveBaselineMarkRequest, PassiveBaselineMarkRuntime, String)] = [
        ("request lock", passiveBaselineRequest(delayLocked: true), passiveBaselineRuntime(), "candidate_delay_locked"),
        ("runtime lock", passiveBaselineRequest(), passiveBaselineRuntime(delayLocked: true), "delay_locked"),
        ("state changed", passiveBaselineRequest(), passiveBaselineRuntime(syncContextState: "valid"), "sync_context_state_changed"),
        ("revision changed", passiveBaselineRequest(), passiveBaselineRuntime(syncContextRevision: 8), "sync_context_revision_changed"),
        ("ready candidate", passiveBaselineRequest(syncContextState: "readyToDryRun"), passiveBaselineRuntime(syncContextState: "readyToDryRun"), "sync_context_not_markable"),
        ("delay changed", passiveBaselineRequest(), passiveBaselineRuntime(currentDelayMs: 2201), "delay_changed"),
        ("context changed", passiveBaselineRequest(), passiveBaselineRuntime(contextSignature: "ctx-b"), "context_changed"),
        ("enabled changed", passiveBaselineRequest(), passiveBaselineRuntime(enabledAirplayCount: 2, activeAirplayCount: 2), "enabled_airplay_count_changed"),
        ("too many AirPlay", passiveBaselineRequest(enabledAirplayCount: 9, activeAirplayCount: 9), passiveBaselineRuntime(enabledAirplayCount: 9, activeAirplayCount: 9), "too_many_airplay_receivers"),
        ("active changed", passiveBaselineRequest(activeAirplayCount: 1), passiveBaselineRuntime(activeAirplayCount: 0), "active_airplay_count_changed"),
        ("inactive AirPlay", passiveBaselineRequest(activeAirplayCount: nil), passiveBaselineRuntime(activeAirplayCount: 0), "airplay_not_fully_connected"),
        ("epoch changed", passiveBaselineRequest(), passiveBaselineRuntime(airplayTimingEpoch: 43), "airplay_timing_epoch_changed"),
        ("backend unsupported", passiveBaselineRequest(captureBackend: "unknown"), passiveBaselineRuntime(), "capture_backend_unsupported"),
        ("backend changed", passiveBaselineRequest(), passiveBaselineRuntime(captureBackend: "sck"), "capture_backend_changed"),
    ]
    for (name, request, runtime, expected) in cases {
        try expect(
            PassiveBaselineMarkGuard.rejectionReason(request: request, runtime: runtime)
                == expected,
            "passive baseline mark mutation matrix failed for \(name)"
        )
    }
}

func passiveSnapshot(
    currentDelayMs: Int = 2200,
    contextSignature: String = "ctx-a",
    delayLocked: Bool = false,
    enabledAirplayCount: Int = 1,
    activeAirplayCount: Int = 1,
    airplayTimingEpoch: UInt64 = 42,
    syncContextState: String = "suspect",
    syncContextReason: String = "AirPlay timing changed",
    syncContextRevision: UInt64 = 7
) -> CalibrationDiagnosticServer.Snapshot {
    CalibrationDiagnosticServer.Snapshot(
        devices: [],
        microphoneDeviceID: nil,
        currentDelayMs: currentDelayMs,
        contextSignature: contextSignature,
        delayLocked: delayLocked,
        enabledAirplayCount: enabledAirplayCount,
        activeAirplayCount: activeAirplayCount,
        airplayTimingEpoch: airplayTimingEpoch,
        syncContextState: syncContextState,
        syncContextReason: syncContextReason,
        syncContextRevision: syncContextRevision,
        syncContextUpdatedUnix: 1_778_887_421
    )
}

func checkCalibrateApplyRejectsStaleFreshness() throws {
    let start = passiveSnapshot()
    try expect(
        CalibrationDiagnosticServer.calibrateApplyFreshnessRejectionReason(
            start: start,
            latest: passiveSnapshot()
        ) == nil,
        "matching active calibrate_apply freshness snapshot should pass"
    )
    let cases: [(String, CalibrationDiagnosticServer.Snapshot, String)] = [
        ("delay", passiveSnapshot(currentDelayMs: 2201), "delay_changed"),
        ("context", passiveSnapshot(contextSignature: "ctx-b"), "context_changed"),
        (
            "enabled count",
            passiveSnapshot(enabledAirplayCount: 2, activeAirplayCount: 2),
            "enabled_airplay_count_changed"
        ),
        (
            "active count",
            passiveSnapshot(activeAirplayCount: 0),
            "airplay_not_fully_connected"
        ),
        (
            "epoch",
            passiveSnapshot(airplayTimingEpoch: 43),
            "airplay_timing_epoch_changed"
        ),
        (
            "sync state",
            passiveSnapshot(syncContextState: "valid"),
            "sync_context_state_changed"
        ),
        (
            "sync revision",
            passiveSnapshot(syncContextRevision: 8),
            "sync_context_revision_changed"
        ),
        ("delay lock", passiveSnapshot(delayLocked: true), "delay_locked"),
    ]
    for (name, latest, expected) in cases {
        try expect(
            CalibrationDiagnosticServer
                .calibrateApplyFreshnessRejectionReason(
                    start: start,
                    latest: latest
                ) == expected,
            "active calibrate_apply freshness matrix failed for \(name)"
        )
    }
}

func checkPassiveEvidenceIntentClassifiesSyncContext() throws {
    let suspect = CalibrationDiagnosticServer.passiveEvidenceIntent(
        snapshot: passiveSnapshot(syncContextState: "suspect")
    )
    try expect(
        suspect.intent == "baseline_required" && suspect.baselineRequired,
        "suspect sync context must request a passive baseline"
    )
    try expect(
        !suspect.passiveCanApply,
        "suspect sync context must not allow passive apply"
    )

    let locked = CalibrationDiagnosticServer.passiveEvidenceIntent(
        snapshot: passiveSnapshot(delayLocked: true, syncContextState: "locked")
    )
    try expect(
        locked.intent == "diagnostic_locked" && !locked.passiveCanApply,
        "locked sync context must be diagnostic only"
    )

    let applied = CalibrationDiagnosticServer.passiveEvidenceIntent(
        snapshot: passiveSnapshot(syncContextState: "applied")
    )
    try expect(
        applied.intent == "post_apply_validation" && !applied.passiveCanApply,
        "applied sync context must request post-apply validation"
    )

    let valid = CalibrationDiagnosticServer.passiveEvidenceIntent(
        snapshot: passiveSnapshot(syncContextState: "valid")
    )
    try expect(
        valid.intent == "drift_monitor" && valid.passiveCanApply,
        "valid sync context should allow drift-monitor evidence"
    )

    let unknown = CalibrationDiagnosticServer.passiveEvidenceIntent(
        snapshot: passiveSnapshot(syncContextState: "futureState")
    )
    try expect(
        unknown.intent == "sync_context_unknown" && !unknown.passiveCanApply,
        "unknown sync context must fail closed instead of allowing drift-monitor evidence"
    )
    try expect(
        !CalibrationDiagnosticServer.passiveSyncContextStateIsKnown("futureState"),
        "future sync context states must not be treated as known by default"
    )
}

func checkPassiveSnapshotRejectsZeroCaptureTicks() throws {
    let rejection = CalibrationDiagnosticServer.passiveSnapshotRejection(
        snapshot: passiveSnapshot(),
        passiveStatus: CalibrationDiagnosticServer.PassiveStatus(
            captureBackend: "tap",
            captureDiagnostic: "backend=tap seen=0 written=0 ticks=0",
            tickCount: 0
        ),
        passiveAvailable: true,
        busy: false
    )
    try expect(
        rejection?.contains("system-audio frames") == true,
        "passive snapshot must reject zero-tick capture before opening the microphone"
    )
}

func checkDDCPacketConstructionAndChecksum() throws {
    // Golden vectors verified against real hardware (ASUS ExternalDisplay over
    // DisplayPort, SyncCastDDCProbe 2026-06-12).
    try expect(
        DDCPacket.readRequest(vcp: 0x62) == [0x82, 0x01, 0x62, 0x8F],
        "DDC read request for VCP 0x62 must match the verified packet"
    )
    try expect(
        DDCPacket.writeRequest(vcp: 0x62, value: 80)
            == [0x84, 0x03, 0x62, 0x00, 0x50, 0x8A],
        "DDC write request for VCP 0x62=80 must match the verified packet"
    )
    try expect(
        DDCPacket.checksum(seed: 0x6E, bytes: [0x82, 0x01, 0x62][0...2]) == 0x8F,
        "DDC XOR checksum seed/fold must match the spec"
    )

    // Reply captured from the ExternalDisplay: current=75 max=100.
    let volumeReply: [UInt8] = [
        0x6E, 0x88, 0x02, 0x00, 0x62, 0x00, 0x00, 0x64, 0x00, 0x4B, 0xF9,
    ]
    let parsedVolume = DDCPacket.parseReadReply(volumeReply, vcp: 0x62)
    try expect(
        parsedVolume?.current == 75 && parsedVolume?.max == 100,
        "DDC volume reply must parse current=75 max=100"
    )

    // Mute reply captured from the ExternalDisplay: current=2 (unmuted) max=2.
    let muteReply: [UInt8] = [
        0x6E, 0x88, 0x02, 0x00, 0x8D, 0x00, 0x00, 0x02, 0x00, 0x02, 0x39,
    ]
    let parsedMute = DDCPacket.parseReadReply(muteReply, vcp: 0x8D)
    try expect(
        parsedMute?.current == 2 && parsedMute?.max == 2,
        "DDC mute reply must parse current=2 max=2"
    )

    var corrupted = volumeReply
    corrupted[10] ^= 0xFF
    try expect(
        DDCPacket.parseReadReply(corrupted, vcp: 0x62) == nil,
        "DDC reply with a bad checksum must fail closed"
    )
    try expect(
        DDCPacket.parseReadReply(volumeReply, vcp: 0x10) == nil,
        "DDC reply with a mismatched opcode echo must fail closed"
    )
    var errorResult = volumeReply
    errorResult[3] = 0x01  // result code: unsupported VCP
    errorResult[10] = DDCPacket.checksum(seed: 0x50, bytes: errorResult[0...9])
    try expect(
        DDCPacket.parseReadReply(errorResult, vcp: 0x62) == nil,
        "DDC reply with a non-zero result code must fail closed"
    )
    try expect(
        DDCPacket.parseReadReply([0x6E, 0x88], vcp: 0x62) == nil,
        "short DDC reply must fail closed"
    )
    try expect(
        DDCPacket.parseReadReply(
            [UInt8](repeating: 0, count: 11), vcp: 0x62
        ) == nil,
        "all-zero DDC reply must fail closed"
    )
}

func checkDDCVolumeScaleConversion() throws {
    try expect(
        DDCVolumeScale.toVCPValue(normalized: 0.75, max: 100) == 75,
        "0.75 of max 100 must map to VCP 75"
    )
    try expect(
        DDCVolumeScale.toVCPValue(normalized: 0, max: 100) == 0
            && DDCVolumeScale.toVCPValue(normalized: 1, max: 100) == 100,
        "scale endpoints must map exactly"
    )
    try expect(
        DDCVolumeScale.toVCPValue(normalized: -0.5, max: 100) == 0
            && DDCVolumeScale.toVCPValue(normalized: 1.5, max: 100) == 100,
        "out-of-range scalars must clamp"
    )
    try expect(
        DDCVolumeScale.toVCPValue(normalized: 0.5, max: 0) == 0,
        "degenerate max=0 must map to 0"
    )
    try expect(
        DDCVolumeScale.toVCPValue(normalized: .nan, max: 100) == 0,
        "non-finite scalars must fail closed to 0"
    )
    try expect(
        DDCVolumeScale.toNormalized(current: 75, max: 100) == 0.75,
        "VCP 75/100 must normalize to 0.75"
    )
    try expect(
        DDCVolumeScale.toNormalized(current: 2, max: 2) == 1.0,
        "VCP current==max must normalize to 1"
    )
    try expect(
        DDCVolumeScale.toNormalized(current: 5, max: 0) == nil,
        "degenerate max=0 must not normalize"
    )
}

func checkDDCDisplayMatchingDecision() throws {
    try expect(
        DDCDisplayMatching.matchIndex(
            audioDeviceName: "ExternalDisplay",
            isHDMIOrDisplayPortTransport: false,
            displayProductNames: ["ExternalDisplay"]
        ) == 0,
        "exact product-name match must win regardless of transport"
    )
    try expect(
        DDCDisplayMatching.matchIndex(
            audioDeviceName: " pg27ucdm ",
            isHDMIOrDisplayPortTransport: false,
            displayProductNames: ["ExternalDisplay"]
        ) == 0,
        "name match must ignore case and surrounding whitespace"
    )
    try expect(
        DDCDisplayMatching.matchIndex(
            audioDeviceName: "B",
            isHDMIOrDisplayPortTransport: false,
            displayProductNames: ["A", "B"]
        ) == 1,
        "name match must pick the right display among several"
    )
    try expect(
        DDCDisplayMatching.matchIndex(
            audioDeviceName: "ExternalDisplay",
            isHDMIOrDisplayPortTransport: true,
            displayProductNames: ["ExternalDisplay", "ExternalDisplay"]
        ) == nil,
        "duplicate product names are ambiguous and must fail closed"
    )
    try expect(
        DDCDisplayMatching.matchIndex(
            audioDeviceName: "ASUS ExternalDisplay Audio",
            isHDMIOrDisplayPortTransport: true,
            displayProductNames: ["Some Other Name"]
        ) == 0,
        "single external display + HDMI/DP transport may match without a name hit"
    )
    try expect(
        DDCDisplayMatching.matchIndex(
            audioDeviceName: "MacBook Pro Speakers",
            isHDMIOrDisplayPortTransport: false,
            displayProductNames: ["Some Other Name"]
        ) == nil,
        "non-HDMI/DP transport must not use the single-display fallback"
    )
    try expect(
        DDCDisplayMatching.matchIndex(
            audioDeviceName: "Unknown",
            isHDMIOrDisplayPortTransport: true,
            displayProductNames: ["A", "B"]
        ) == nil,
        "multiple displays without a name match must fail closed"
    )
    try expect(
        DDCDisplayMatching.matchIndex(
            audioDeviceName: nil,
            isHDMIOrDisplayPortTransport: true,
            displayProductNames: ["ExternalDisplay"]
        ) == 0,
        "unreadable audio name still allows the single-display HDMI/DP fallback"
    )
    try expect(
        DDCDisplayMatching.matchIndex(
            audioDeviceName: nil,
            isHDMIOrDisplayPortTransport: false,
            displayProductNames: ["ExternalDisplay"]
        ) == nil,
        "unreadable audio name without HDMI/DP transport must fail closed"
    )
    try expect(
        DDCDisplayMatching.matchIndex(
            audioDeviceName: "ExternalDisplay",
            isHDMIOrDisplayPortTransport: true,
            displayProductNames: []
        ) == nil,
        "no external DDC displays must fail closed"
    )
}

func checkDDCMuteEmulationPreservesUserVolume() throws {
    // Display WITHOUT a native mute VCP (0x8D): mute is emulated as
    // 0x62 = 0. The user-volume layer — what cachedNormalizedVolume /
    // Router.readDirectStereoVolume report — must keep the user's level,
    // otherwise a snapshot writes 0 back as route.volume and a later
    // unmute "restores" silence.
    let emulatedMute = DDCVolumeLevels.planned(
        volume: 0.75, muted: true, supportsMuteVCP: false
    )
    try expect(
        emulatedMute.outputLevel == 0,
        "emulated mute must drive the panel's 0x62 level to 0"
    )
    try expect(
        emulatedMute.userVolume == 0.75,
        "read after an emulated mute must return the user volume, not 0"
    )
    let emulatedUnmute = DDCVolumeLevels.planned(
        volume: 0.75, muted: false, supportsMuteVCP: false
    )
    try expect(
        emulatedUnmute == DDCVolumeLevels(userVolume: 0.75, outputLevel: 0.75),
        "unmute after an emulated mute must restore the user volume"
    )

    // Display WITH a native mute VCP: 0x62 stays at the user level even
    // while muted, so both layers carry the user volume.
    let nativeMute = DDCVolumeLevels.planned(
        volume: 0.6, muted: true, supportsMuteVCP: true
    )
    try expect(
        nativeMute == DDCVolumeLevels(userVolume: 0.6, outputLevel: 0.6),
        "native mute must keep 0x62 at the user level"
    )

    // Both layers clamp out-of-range intents.
    let clamped = DDCVolumeLevels.planned(
        volume: 1.5, muted: true, supportsMuteVCP: false
    )
    try expect(
        clamped.userVolume == 1.0 && clamped.outputLevel == 0,
        "out-of-range intents must clamp in the user layer and still mute"
    )
    let clampedLow = DDCVolumeLevels.planned(
        volume: -0.25, muted: false, supportsMuteVCP: true
    )
    try expect(
        clampedLow == DDCVolumeLevels(userVolume: 0, outputLevel: 0),
        "negative intents must clamp to 0 in both layers"
    )
}

func checkDirectStereoVolumeReadbackSourceDecision() throws {
    // Some HDMI/DP devices expose a READABLE-but-unsettable CoreAudio
    // VolumeScalar — a stale mirror that never tracks the panel's real
    // speaker level. Readback must follow the backend that owns WRITES,
    // so a DDC-classified device reads the DDC user-intent cache and
    // never that mirror (otherwise a snapshot writes the stale level back
    // into routing and the next media key re-applies it).
    try expect(
        DirectStereoVolumeReadback.backend(
            coreAudioVolumeSettable: false,
            coreAudioPreviouslyRejected: false,
            ddcKnownSupported: true
        ) == .ddc,
        "readable-but-unsettable CoreAudio with a DDC backend must read the DDC cache"
    )
    try expect(
        DirectStereoVolumeReadback.backend(
            coreAudioVolumeSettable: true,
            coreAudioPreviouslyRejected: false,
            ddcKnownSupported: false
        ) == .coreAudioHardware,
        "settable CoreAudio volume must keep the CoreAudio readback"
    )
    try expect(
        DirectStereoVolumeReadback.backend(
            coreAudioVolumeSettable: true,
            coreAudioPreviouslyRejected: false,
            ddcKnownSupported: true
        ) == .coreAudioHardware,
        "settable CoreAudio must win over DDC, matching the capability snapshot"
    )
    try expect(
        DirectStereoVolumeReadback.backend(
            coreAudioVolumeSettable: true,
            coreAudioPreviouslyRejected: true,
            ddcKnownSupported: true
        ) == .ddc,
        "a CoreAudio write rejection must demote the settability claim to DDC"
    )
    try expect(
        DirectStereoVolumeReadback.backend(
            coreAudioVolumeSettable: false,
            coreAudioPreviouslyRejected: false,
            ddcKnownSupported: false
        ) == DirectStereoVolumeBackend.none,
        "no usable backend must read nothing instead of a stale CoreAudio mirror"
    )
    try expect(
        DirectStereoVolumeReadback.backend(
            coreAudioVolumeSettable: true,
            coreAudioPreviouslyRejected: true,
            ddcKnownSupported: false
        ) == DirectStereoVolumeBackend.none,
        "rejected CoreAudio without DDC support must fail closed to none"
    )
}

func checkDirectStereoCoreAudioMutePreservesVolume() throws {
    // CoreAudio mirror of the DDC two-layer rule (Codex P1): a device
    // whose Mute property accepted the write must NOT have VolumeScalar
    // driven to 0 — the observer's post-suppression echo read that 0,
    // overwrote route.volume, and unmute "restored" silence.
    try expect(
        DirectStereoOutput.plannedCoreAudioVolume(
            volume: 0.75, muted: true, muteAccepted: true
        ) == 0.75,
        "accepted mute write must keep VolumeScalar at the user level"
    )
    try expect(
        DirectStereoOutput.plannedCoreAudioVolume(
            volume: 0.75, muted: true, muteAccepted: false
        ) == 0,
        "unwritable mute must degrade to emulated mute (scalar = 0)"
    )
    try expect(
        DirectStereoOutput.plannedCoreAudioVolume(
            volume: 0.75, muted: false, muteAccepted: false
        ) == 0.75,
        "unmute after an emulated mute must restore the user volume"
    )
    try expect(
        DirectStereoOutput.plannedCoreAudioVolume(
            volume: 0.6, muted: false, muteAccepted: true
        ) == 0.6,
        "unmuted apply must write the user volume unchanged"
    )
    try expect(
        DirectStereoOutput.plannedCoreAudioVolume(
            volume: 1.5, muted: true, muteAccepted: true
        ) == 1.0
            && DirectStereoOutput.plannedCoreAudioVolume(
                volume: -0.25, muted: false, muteAccepted: true
            ) == 0,
        "out-of-range intents must clamp to 0...1 in every mute state"
    )
}

func checkDirectStereoVolumeApplyBookkeeping() throws {
    // A successful DDC fallback must NOT mask a failed CoreAudio level
    // write (Codex P2): the failure is recorded — demoting the driver's
    // settability claim — WITHOUT counting a user-visible rejection, and
    // the follow-on classification must be .ddc, never .coreAudioHardware.
    // The old single-Bool return skipped all bookkeeping whenever DDC
    // saved the intent.
    typealias Outcome = DirectStereoOutput.HardwareVolumeApplyOutcome
    let ddcSaved = Outcome(
        attempted: true,
        coreAudioVolumeAccepted: false,
        coreAudioMuteAccepted: false,
        ddcAccepted: true
    )
    try expect(
        ddcSaved.disprovesCoreAudioSettability,
        "a failed CoreAudio level write must be recorded even when DDC accepts the fallback"
    )
    try expect(
        !ddcSaved.isUserVisibleRejection && ddcSaved.anyBackendAccepted,
        "a successful DDC fallback must not count as a user-visible rejection"
    )
    try expect(
        DirectStereoVolumeReadback.backend(
            coreAudioVolumeSettable: true,
            coreAudioPreviouslyRejected: ddcSaved.disprovesCoreAudioSettability,
            ddcKnownSupported: true
        ) == .ddc,
        "after a DDC-saved apply the device must classify as ddc, not coreAudioHardware"
    )
    let coreAudioOK = Outcome(
        attempted: true,
        coreAudioVolumeAccepted: true,
        coreAudioMuteAccepted: true,
        ddcAccepted: false
    )
    try expect(
        !coreAudioOK.disprovesCoreAudioSettability
            && !coreAudioOK.isUserVisibleRejection
            && coreAudioOK.anyBackendAccepted,
        "a clean CoreAudio level write must record nothing"
    )
    let bothFailed = Outcome(
        attempted: true,
        coreAudioVolumeAccepted: false,
        coreAudioMuteAccepted: false,
        ddcAccepted: false
    )
    try expect(
        bothFailed.disprovesCoreAudioSettability
            && bothFailed.isUserVisibleRejection,
        "both backends failing must demote settability AND count the rejection"
    )
    let muteOnly = Outcome(
        attempted: true,
        coreAudioVolumeAccepted: false,
        coreAudioMuteAccepted: true,
        ddcAccepted: false
    )
    try expect(
        muteOnly.disprovesCoreAudioSettability
            && !muteOnly.isUserVisibleRejection
            && muteOnly.anyBackendAccepted,
        "mute-only CoreAudio success carries the intent but still demotes the level settability claim"
    )
    let notAttempted = Outcome(
        attempted: false,
        coreAudioVolumeAccepted: false,
        coreAudioMuteAccepted: false,
        ddcAccepted: false
    )
    try expect(
        !notAttempted.disprovesCoreAudioSettability
            && !notAttempted.isUserVisibleRejection
            && !notAttempted.anyBackendAccepted,
        "an unattempted intent (raced teardown) must record nothing"
    )
}

func checkDDCDroppedPendingIntentReporting() throws {
    // Codex P2: an intent accepted while the capability probe is in
    // flight ("probing" optimistic accept) must be REPORTED when the
    // probe concludes unsupported — previously it vanished silently:
    // enqueueApply returned true, the Router booked it as carried, and
    // no rejection diagnostics ever recorded the loss.
    //
    // Behavioral check against a real controller instance: a UID that
    // matches no CoreAudio device fails the fail-closed probe chain at
    // its first step, so the probe settles on unsupported quickly and
    // without touching any display.
    guard DDCDisplayEnumerator.isSupported else {
        print("  (skipped DDC dropped-intent check — IOAVService unavailable on this host)")
        return
    }
    let controller = DDCDisplayVolumeController()
    let droppedUIDs = OSAllocatedUnfairLock(initialState: [String]())
    let dropped = DispatchSemaphore(value: 0)
    controller.setOnPendingIntentDropped { uid in
        droppedUIDs.withLock { $0.append(uid) }
        dropped.signal()
    }
    let uid = "syncast-timingcheck-no-such-device"
    let accepted = controller.enqueueApply(uid: uid, volume: 0.5, muted: false)
    try expect(
        accepted,
        "an intent for an unprobed UID must be optimistically accepted (probe in flight)"
    )
    try expect(
        dropped.wait(timeout: .now() + 5.0) == .success,
        "the unsupported probe verdict must fire onPendingIntentDropped for the accepted intent"
    )
    try expect(
        droppedUIDs.withLock { $0 } == [uid],
        "onPendingIntentDropped must carry exactly the dropped intent's UID"
    )
    try expect(
        controller.isKnownUnsupported(uid: uid),
        "the probe verdict for a nonexistent device must settle on unsupported"
    )
    // Fail-closed contract unchanged: once unsupported, further intents
    // are rejected up front (Router books those itself) and must NOT
    // re-fire the dropped-intent signal — nothing was ever queued.
    let rejected = controller.enqueueApply(uid: uid, volume: 0.4, muted: false)
    try expect(
        !rejected,
        "an intent for a known-unsupported UID must still be rejected synchronously"
    )
    try expect(
        dropped.wait(timeout: .now() + 0.5) == .timedOut,
        "a synchronously rejected intent must not fire onPendingIntentDropped (it was never queued)"
    )
}

let checks = [
    checkFullyPreArmCallbackDropsAllFrames,
    checkStraddlingCallbackDropsOnlyPreArmFrames,
    checkPostArmCallbackPadsMicWav,
    checkCapacityLimitsCopyCount,
    checkActiveAcousticDiagnosticsRequireBothFlags,
    checkActiveAcousticDiagnosticsMessageNamesBothFlags,
    checkActiveAcousticDiagnosticsStartupState,
    checkCalibrationInternalVolumeChangesDoNotInvalidateTiming,
    checkAirPlayConnectionEventsInvalidateTiming,
    checkAirPlayStreamStartNoopResponse,
    checkStereoOutputDefaultsToDirect,
    checkStereoOutputCaptureOptOutsRemainAvailable,
    checkStereoOutputUnknownFallsForwardToDirectWithWarning,
    checkPassiveApplyGuardAcceptsMatchingSmallStep,
    checkPassiveApplyGuardRejectsTimingEpochDrift,
    checkPassiveApplyGuardRejectsLargeStep,
    checkPassiveApplyGuardRejectsRuntimeMutationMatrix,
    checkAcceptedPassiveApplyGuardRequiresDryRunReadyRuntime,
    checkPassiveApplyResultPayloadEchoesDecisionRuntime,
    checkCalibrateApplyRejectsStaleFreshness,
    checkPassiveBaselineMarkGuard,
    checkPassiveEvidenceIntentClassifiesSyncContext,
    checkPassiveSnapshotRejectsZeroCaptureTicks,
    checkDDCPacketConstructionAndChecksum,
    checkDDCVolumeScaleConversion,
    checkDDCDisplayMatchingDecision,
    checkDDCMuteEmulationPreservesUserVolume,
    checkDirectStereoVolumeReadbackSourceDecision,
    checkDirectStereoCoreAudioMutePreservesVolume,
    checkDirectStereoVolumeApplyBookkeeping,
    checkDDCDroppedPendingIntentReporting,
]

do {
    for check in checks {
        try check()
    }
    print("Router timing and active-diagnostics gate checks passed (\(checks.count))")
} catch {
    FileHandle.standardError.write(Data("Router timing/gate check failed: \(error)\n".utf8))
    exit(1)
}
