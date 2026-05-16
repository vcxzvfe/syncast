import Foundation
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
