# SyncCast Requirements Report

> Date: 2026-05-07; updated through 2026-05-12
> Source: active Codex Goal, user field feedback, local build/install state, hardware calibration evidence, and six Codex agent review tasks.

## Executive Summary

SyncCast is still a Stereo-first product. Local Stereo and screen sleep/wake recovery are user-verified stable, and every AirPlay, Direct Stereo, Tap, or routing change must preserve that baseline.

Whole-home / AirPlay is not solved. The main issue is aligning local Mac/display/CoreAudio speakers to the buffered AirPlay group. Asking the user for one "best delay" is not useful because AirPlay latency changes across sessions, receiver events, and route changes. Automatic calibration must measure the current route and fail closed unless repeated evidence agrees.

The DRM blocker is still real. The normal launch path still depends on ScreenCaptureKit unless an experimental flag is used. Direct Stereo now has local smoke evidence that it avoids SCK, but Netflix / Apple TV+ / Amazon / Disney+ playback has not yet been verified under that path.

## Current Truth

Stable:

- Local Stereo mode is user-verified as excellent.
- Stereo screen sleep/wake recovery is user-verified as resolved.
- Stable CoreAudio UID remains the only safe persistence key.

Experimental but improved:

- All Direct Stereo, TapCapture, calibration, harness, and documentation Goal work described below is local workspace state, not `origin/main`, unless a later session explicitly stages, commits, and pushes it.
- Whole-home / AirPlay can output sound on selected devices.
- Visible `Auto Calibrate` now calls the real calibration path.
- AirPlay event-driven calibration can apply good corrections on the deployed Logitech mic / Xiaomi setup for the proven single-Xiaomi + one-local-display route, including post-apply settle validation, volume/mute mutation recovery, and mid-calibration route-interrupt fail-closed recovery.
- Direct Stereo can launch one or two local outputs without SCK counters or Screen Recording preflight.
- Normal Direct Stereo smoke now verifies default-output restoration with a small CoreAudio C helper before any DRM playback test is trusted.
- Direct Stereo cleanup has additional local hardening: stale Direct aggregates are filtered out of normal SCK/whole-home routing, dead Direct defaults are not treated as restorable previous outputs, and app termination now blocks quit if Direct restore fails.

Still not reliable enough:

- A longer Local + AirPlay run produced an unhealthy result: one failed no-apply cycle plus one `2211ms` outlier against an applied `2149ms`, causing `drift_test` health flags and exit `5`.
- The latest retry / stricter threshold / mic host-time anchoring / reviewer-hardening build has passed repeated single-AirPlay hardware runs, but not the multi-hour, multi-AirPlay interruption matrix.
- Process Tap has passed live non-DRM smoke on this machine, but DRM playback validation is still pending.
- Tap-backed AirPlay calibration is not yet proven. A 2026-05-12 Tap route-interrupt attempt started Process Tap without Screen Recording, but Tap emitted zero callbacks without external non-SyncCast program audio. A temporary system-sound helper was audible to the user, so Tap auxiliary probes are now disabled by default in the smoke/calibration harnesses.
- A `scripts/tap_capture_smoke_test.sh` harness now exists and has been tightened to fail if the no-SCK path touches Screen Recording preflight/request logs or SCK.
- GitHub/origin is still at `d955eb7`; the Goal iteration is local only unless explicitly committed and pushed.
- Remaining algorithmic risks: the grouped AirPlay measurement is intentionally only a group estimate; adaptive AirPlay frequency-response/probe-band selection and clipping/headroom telemetry are still pending.

## Requirements

### R1: Preserve Local Stereo

Acceptance:

- Two or more local CoreAudio outputs stay synchronized in normal use.
- Playback resumes after natural screen sleep/wake.
- Default behavior remains unchanged unless an explicit experimental flag is set.
- New capture/output paths can be disabled without breaking the known-good local Stereo path.

### R2: Make Default Stereo DRM-Safe

Acceptance:

- Local Stereo can route to one or more local outputs without ScreenCaptureKit.
- Screen Recording preflight is skipped in the non-SCK Stereo path.
- DRM video playback works while SyncCast is active.
- The previous macOS default output is restored on stop/quit when SyncCast still owns the default output.
- Direct aggregate cleanup never destroys a current default output and never removes aggregates owned by a live SyncCast process.

Current status:

- `SYNCAST_STEREO_PATH=direct` passed installed smoke for `mbp` and `display,mbp`.
- Two-output Direct Stereo required `kAudioAggregateDeviceIsStackedKey = 1` to expose a normal stereo/Multi-Output surface.
- DRM playback and forced-failure default-output restore cases are still open.

### R3: Make Local + AirPlay Auto-Calibration Conservative

Acceptance:

- Delay lock prevents all automatic writes.
- No-apply diagnostics never persist delay changes.
- A single run may only write a tiny correction: current installed threshold is `<= 15ms`.
- Larger changes require repeat agreement within `20ms` in the same route, mic, volume, mute, and connection context.
- Low confidence, missing/high uncertainty, transport changes, route changes, muted/zero-volume AirPlay, and one-sided routes all fail closed.
- Automatic apply is limited to routes with at most one enabled AirPlay receiver until group acoustics can prove every enabled receiver contributed.

Current status:

- UI and diagnostic paths share `CalibrationDiagnosticServer` thresholds.
- Transport health snapshots guard AirPlay writer and local bridge packet/tick/resync counters.
- Event-driven calibration schedules one retry after `25s` only for `insufficientConfidence`; it does not retry transport/precondition/lock failures.
- Manual delay edits now invalidate in-flight event-driven auto-apply by revision. If the delay is locked, manual slider/nudge edits move the locked target too, so the UI cannot claim one pinned value while persisting another.
- A pending normal event no longer cancels an already scheduled insufficient-confidence retry; the pending reason is held until the retry resolves.
- AirPlay group calibration now requires a stricter median second-peak ratio before accepting a clustered group result, reducing false acceptance of ambiguous reflected/leaked peaks.
- The grouped AirPlay tau is no longer copied onto individual receiver IDs. Continuous drift uses a route-signature-bound `airplay-group` cache, which keeps Local vs AirPlay group alignment working without pretending the group measurement is per-receiver truth.
- Continuous local-only calibration now preserves cached AirPlay group confidence when merging fresh local taus with cached AirPlay tau, and AirPlay group dynamic-cycle extension requires the dominant tau cluster to represent a majority of cycles run. This makes later automatic applies more conservative when AirPlay evidence is stale, borderline, or split across competing clusters.
- Router calibration now snapshots a route/context revision and fails closed if route, mode, AirPlay active set, connection state, sidecar latency, volume, or mute context changes during measurement. This prevents calibration cleanup from restoring stale routing over a newer user/script change.
- AppModel no longer cancels an event-driven calibration that is already inside measurement when a new route/volume event arrives. It records a pending reason instead, so Router's route/context revision guard can invalidate the stale measurement explicitly and then rerun calibration from the new route state.
- Mic/probe timing is now anchored to the actual CoreAudio mic callback host timestamp. Probe starts and AirPlay injection times are converted into mic frame indexes from the first captured sample; missing host time or inconsistent callback cadence fails closed.
- AirPlay probe overlays now expose scheduled/mixed/dropped counters, and calibration rejects runs where the probe was not actually mixed into the AirPlay writer timeline.
- Multiple AirPlay receivers are currently diagnostic-only for automatic apply. `airplay-group` can be dominated by the nearest/loudest receiver, so UI Auto Calibrate and diagnostic `calibrate_apply` refuse automatic writes when more than one AirPlay receiver is enabled.
- Mic startup race hardening added on 2026-05-12: active calibration now waits up to 2000ms for trusted mic host-time callbacks before emitting/injecting local/AirPlay probes, then gives the measurement a 600ms noise-floor pre-roll and 1000ms capture-deadline slack. If mic readiness never arrives, calibration fails closed before emitting/injecting a probe.

### R4: Prove AirPlay With Long-Session Evidence

Acceptance before calling AirPlay reliable:

- At least two AirPlay receivers and at least one local output run for 2+ hours.
- Logs include target delay, applied delay, confidence, uncertainty/MAD, packet flow, local bridge resyncs, stream epoch, receiver connection state, volume/mute state, and recovery events.
- Test matrix covers receiver restart, AirPlay interruption, route switch, volume change, display sleep/wake, sidecar restart, OwnTone restart, and network disruption.
- `scripts/drift_test.sh` health flags are clean, not only the final `Verdict: STABLE`.
- Whole-home / Local + AirPlay tests must not be run while macOS is manually set to a separate Multi-Output device. Use one ordinary system output and let SyncCast own the selected local outputs plus AirPlay receivers. Direct Stereo tests are the exception: that hidden path intentionally switches the system default output and must restore it.
- The acoustic harnesses must enforce that rule without asking the user to touch System Settings. `event_resync_test.sh` and `event_mutation_test.sh` now temporarily switch away from a manual Multi-Output Device or stale SyncCast Direct aggregate to an ordinary target-matching output, then restore the user's previous default output during cleanup.

Current status:

- Short event/drift runs have passed.
- Latest short event smoke after mic host-time / overlay health gates passed: `display,xiaomi 260` held `2253ms`, verified `2255ms`, applied after repeat agreement, then restored defaults to delay `2145`, Continuous `0`, lock `0`.
- A longer pre-extension `display,xiaomi 900 6 60` run remained stable when cycles measured successfully, but failed health gates because one no-apply cycle returned `RPC_ERR insufficientConfidence`. The five OK rows were tightly aligned: final delta `2251ms`, total drift `+2ms`, final applied error `-3ms`, confidence min `13.7`, uncertainty max `8ms`. Logs showed the failed cycle's local phase was valid, while AirPlay group accepted only two true `2297-2299ms` peaks and was distracted by weak late peaks (`2371/2490/2830ms`).
- AirPlay group calibration now self-recovers from this failure mode: it runs the normal five cycles, then extends up to eight cycles only if the dominant tau cluster has fewer than a majority of the cycles run. A Codex reviewer found no blocking issue; two low log-only diagnostics were fixed afterward.
- Post-extension live validation passed: `bash scripts/event_resync_test.sh display,xiaomi 420 3 60` applied `2259ms` after repeat agreement (`2256ms` then `2259ms`), then no-apply drift ran 3 cycles over ~219s with `Health flags: none`, total delta drift `+0ms`, final applied error `-7ms`, confidence min `12.1`, uncertainty max `3ms`.
- Event-trigger fallback update on 2026-05-11: a post-extension long wrapper exposed a control-loop gap where Whole-home routing and AirPlay writer packet flow had started, but the UI did not receive a `.connected` notification, so `autoCalib event scheduled` never appeared. Event-driven full Auto Calibrate now accepts enabled, audible AirPlay receivers unless they are explicitly `failed` or `disconnected`; the final write is still gated by acoustic confidence, uncertainty, repeat agreement, and transport health. Continuous background calibration remains stricter and still requires a connected receiver.
- Post-fallback live validation passed under user background-video noise: `bash scripts/event_resync_test.sh display,xiaomi 420 3 60` scheduled on Xiaomi toggle, router-start fallback, and later connected notification; it applied `2292ms` after repeat agreement (`2277ms` then `2292ms`). Three no-apply drift cycles over ~220s finished with `Health flags: none`, total delta drift `-11ms`, final applied error `-7ms`, confidence min `13.4`, uncertainty max `5ms`.
- Longer post-fallback validation passed under real room/video noise: `bash scripts/event_resync_test.sh display,xiaomi 900 6 60` applied `2253ms` after repeat agreement (`2249ms` then `2253ms`), then six no-apply drift cycles over ~550s finished with `Health flags: none`, total delta drift `-5ms`, final applied error `-2ms`, max applied error `3ms`, confidence min `14.4`, uncertainty max `2ms`.
- A first installed run after control-loop/transport patches exposed a settle failure: event calibration applied `2260ms`, but post-settle drift stabilized around `2224-2231ms`, so `drift_test` failed with `applied error 36ms > 30ms`. This is now a regression fixture, not a pass.
- Post-apply settle validation was added and verified: `bash scripts/event_resync_test.sh display,xiaomi 760 3 60` applied `2258ms`, ran the new 45s post-apply validation, trimmed to `2262ms`, then three no-apply drift cycles over ~220s passed with `Health flags: none`, total delta drift `+8ms`, final applied error `-4ms`, max applied error `14ms`, confidence min `17.6`, uncertainty max `2ms`.
- Volume-mutation validation passed after extending post-apply validation to small event-driven corrections: `bash scripts/event_mutation_test.sh display,xiaomi volume:xiaomi:0.70:260 1100 3 60` changed Xiaomi volume to `0.70`, reran event calibration after cooldown, applied `2260ms`, post-validated/trimmed to `2252ms`, then three no-apply drift cycles over ~220s passed with `Health flags: none`, total delta drift `+5ms`, final applied error `+3ms`, max applied error `4ms`, confidence min `12.9`, uncertainty max `13ms`.
- Mute/unmute validation passed with default-output auto-switch/restore active: `bash scripts/event_mutation_test.sh display,xiaomi 'mute:xiaomi:on:260,mute:xiaomi:off:340' 1100 2 60` started while macOS default output was `多输出设备`, temporarily switched to `PG27UCDM`, restored the previous default afterward, and left no SyncCast/sidecar/OwnTone process running. Initial calibration settled to `2264ms`; muting Xiaomi stopped background calibration and produced only expected fail-closed skips while the route was intentionally inaudible; unmuting triggered a fresh event calibration, applied `2222ms`, post-validated/trimmed to `2228ms`, then two no-apply drift cycles over ~110s passed with `Health flags: none`, total delta drift `+4ms`, max applied error `9ms`, confidence min `15.3`, and uncertainty max `6ms`.
- Majority-cluster/cache-confidence validation passed after reinstall: `bash scripts/event_resync_test.sh display,xiaomi 520 2 60` applied `2258ms` after repeat agreement, post-validated/trimmed to `2254ms`, then two no-apply drift cycles over ~109s passed with `Health flags: none`, total delta drift `-4ms`, final applied error `-4ms`, max applied error `4ms`, confidence min `20.9`, and uncertainty max `5ms`. Logs showed the new group cluster gate running with `cluster=4/5 required=3` and then `5/5 required=3`.
- Route-epoch validation passed after reinstall: `bash scripts/event_resync_test.sh display,xiaomi 520 2 60` applied `2254ms` after repeat agreement, post-validated/trimmed to `2251ms`, then two no-apply drift cycles over ~110s passed with `Health flags: none`, total delta drift `-1ms`, final applied error `+1ms`, max applied error `2ms`, confidence min `21.9`, and uncertainty max `2ms`.
- Mid-calibration route-interrupt validation passed after reinstall: `bash scripts/calibration_interrupt_test.sh display,xiaomi volume:xiaomi:0.37:40 300 0 60` changed Xiaomi volume while the first event-driven Auto Calibrate run was still measuring. The stale run logged `calibration route context changed during measurement` and did not apply. The pending recovery calibration then applied a repeated large correction to `2262ms`, and post-apply validation trimmed to `2264ms`. A previous run of this same test exposed and fixed the AppModel cancellation race (`CancellationError()` instead of route-context invalidation).
- AirPlay is improved but still experimental until the multi-hour, multi-AirPlay interruption matrix passes. The proven scope today is single-AirPlay Xiaomi + one local display output under repeated live hardware runs.

### R5: Replace SCK For Capture-Dependent Paths

Acceptance:

- Process Tap starts without Screen Recording prompts.
- Tap feeds the existing `SystemAudioCapture -> RingBuffer` contract.
- Tap survives route changes and sleep/wake or fails over cleanly.
- Capture-dependent AirPlay/calibration routes work without SCK.
- DRM behavior under Tap is measured honestly, not assumed.

Current status:

- Research memo and compile-time prototype exist.
- `scripts/tap_capture_smoke_test.sh` requires `Process Tap capture`, Screen Recording not required, `router.start OK`, `backend=tap`, advancing `seen/written/ticks`, and non-zero audio peak. It no longer treats silent callback frames as enough. After user audibility feedback, it does not play any auxiliary sound by default; set `SYNCAST_TAP_SMOKE_PROBE=1` only for deliberate deterministic smoke.
- If `SYNCAST_CAPTURE_BACKEND=tap` is requested on unsupported macOS, Router now refuses to start rather than falling back to SCK.
- Runtime smoke passed on 2026-05-08 local time: `bash scripts/tap_capture_smoke_test.sh display,mbp 60` launched the installed app without Screen Recording, started `Process Tap capture`, and logged `backend=tap seen=114 written=114 ticks=114 peak=0.0653/0.0653`. This proves the no-screen-capture backend can capture non-silent system audio on this machine.
- Tap-backed `scripts/calibration_interrupt_test.sh` remains blocked/pending: with `SYNCAST_CAPTURE_BACKEND=tap` and no external program audio, diagnostics stayed at `backend=tap seen=0 written=0 ticks=0`; with the old helper sound enabled, the user could hear the probe. The route-interrupt SCK run remains the only clean installed pass for this harness.
- The Tap route-interrupt harness now refuses to report a Tap-specific pass unless `backend=tap` diagnostics show nonzero seen/written/tick counters, and opt-in helper audio cleanup kills the active `afplay` child instead of only killing the wrapper loop.
- DRM playback validation is still pending. Passing Tap smoke means the replacement backend is real; it does not yet prove Netflix / Prime Video behavior until those apps are tested under `SYNCAST_CAPTURE_BACKEND=tap` without SCK logs.
- Harness cleanup update on 2026-05-11: `event_resync_test.sh`, `tap_capture_smoke_test.sh`, and `direct_stereo_smoke_test.sh` now kill bundled sidecar and OwnTone children after quitting the app. This prevents orphaned sidecar/OwnTone processes from polluting later runs.
- Direct Stereo restore harness update on 2026-05-11: `scripts/coreaudio_default_output.c` reads the active CoreAudio default output UID. `direct_stereo_smoke_test.sh` records that UID before launch and fails if quitting the Direct path leaves macOS on a SyncCast Direct aggregate or a different default output. Live Direct/DRM smoke remains pending because it intentionally switches system output.
- Acoustic default-output guard update on 2026-05-11: `scripts/coreaudio_default_output_guard.sh` now protects `event_resync_test.sh` and `event_mutation_test.sh` before launch if the default output is a manual Multi-Output Device. It can auto-switch to an ordinary target-matching output for the duration of the run and restore the previous default afterward. The current machine starts with `54	~:AMS2_StackedOutput:0	多输出设备`; the latest hardware run automatically switched to `128	06B3F527-0000-0000-2723-0104B53B2178	PG27UCDM` and restored `多输出设备` during cleanup.
- Acoustic harness cleanup hardening on 2026-05-11: the event harnesses now quit a running SyncCast before touching the default output, refuse to continue if SyncCast cannot quit cleanly, restore launchd test environment variables, fail an otherwise passing run with exit `6` if CoreAudio default restore fails, compile the CoreAudio helper to a per-process temp path instead of reusing a shared `/tmp` binary, structurally reject CoreAudio aggregate devices via `class=aagg` / active subdevice metadata, and reject invalid/no-match scripted mutation actions instead of counting them as successful route changes.

## Verification Evidence

Passed on 2026-05-07:

- `git diff --check`
- `swift build --package-path core/router`
- `swift build --package-path apps/menubar`
- `bash scripts/package-app.sh`
- `bash scripts/install-app.sh`
- `bash -n scripts/event_resync_test.sh`
- `bash -n scripts/drift_test.sh`
- `bash -n scripts/direct_stereo_smoke_test.sh`
- `bash -n scripts/tap_capture_smoke_test.sh`
- `bash -n scripts/calibration_apply_test.sh`
- `bash -n scripts/calibration_test.sh`
- `PYTHONPYCACHEPREFIX=/private/tmp/syncast_pycache python3 -m py_compile scripts/drift_summary.py`
- `PYTHONPYCACHEPREFIX=/private/tmp/syncast_pycache python3 -m compileall -q sidecar/src`

Additional live evidence on 2026-05-08 through 2026-05-12 local time:

- `bash scripts/event_resync_test.sh display,xiaomi 900 6 60` exposed a single AirPlay group insufficient-confidence cycle while successful rows stayed stable; this is a useful failing baseline, not a pass.
- `swift build --package-path core/router`
- `bash scripts/event_resync_test.sh display,xiaomi 420 3 60`
- `bash -n scripts/tap_capture_smoke_test.sh`
- `bash scripts/tap_capture_smoke_test.sh display,mbp 60`
- `bash scripts/event_resync_test.sh display,xiaomi 420 3 60` after the event-trigger fallback, while user video/audio was playing in the room
- `bash scripts/event_resync_test.sh display,xiaomi 900 6 60`
- Failed regression fixture: installed `display,xiaomi 420 3 60` after control-loop/transport patches exited `5` because post-settle applied error reached `36ms`
- Fixed verification: installed `bash scripts/event_resync_test.sh display,xiaomi 760 3 60`
- Fixed volume-mutation verification: installed `bash scripts/event_mutation_test.sh display,xiaomi volume:xiaomi:0.70:260 1100 3 60`
- `bash -n scripts/direct_stereo_smoke_test.sh`
- `bash -n scripts/event_mutation_test.sh`
- `bash -n scripts/coreaudio_default_output_guard.sh`
- `cc scripts/coreaudio_default_output.c -framework CoreAudio -framework CoreFoundation -o /private/tmp/syncast-coreaudio-default-output-check`
- Guard negative controls before the auto-switch upgrade: `bash scripts/event_resync_test.sh display,xiaomi 130` and `bash scripts/event_mutation_test.sh display,xiaomi 'mute:xiaomi:on:260,mute:xiaomi:off:340' 900 0 60` both exited `4` before launching SyncCast while macOS default output was `多输出设备`. Current default behavior is auto-switch/restore; use `SYNCAST_ACOUSTIC_AUTO_DEFAULT=0` to keep fail-fast behavior for deliberate negative controls.
- Default-output auto-switch/restore: a user-session helper run switched from `多输出设备` to `PG27UCDM` for `display,xiaomi`, then restored `多输出设备`.
- `PYTHONPYCACHEPREFIX=/private/tmp/syncast-pycache python3 -m py_compile scripts/drift_summary.py`
- `bash scripts/package-app.sh`
- `bash scripts/install-app.sh`
- `bash scripts/event_mutation_test.sh display,xiaomi 'mute:xiaomi:on:260,mute:xiaomi:off:340' 1100 2 60`
- `bash scripts/event_resync_test.sh display,xiaomi 520 2 60`
- `bash scripts/event_resync_test.sh display,xiaomi 520 2 60` after route-epoch restore protection
- `bash -n scripts/calibration_interrupt_test.sh`
- `bash scripts/calibration_interrupt_test.sh display,xiaomi volume:xiaomi:0.37:40 300 0 60` after AppModel in-flight event deferral
- `swift build --package-path core/router` after mic pre-roll / capture-deadline hardening
- `bash scripts/package-app.sh`
- `bash scripts/install-app.sh`
- `bash -n scripts/calibration_interrupt_test.sh`
- `bash -n scripts/tap_capture_smoke_test.sh`
- `git diff --check`

Blocked:

- `swift test --package-path core/router` fails because this local toolchain cannot import `XCTest`.

Installed locally:

- `/Applications/SyncCast.app/Contents/MacOS/SyncCastMenuBar`
- Timestamp: `2026-05-12 19:03:05 CEST`
- Size: `3088064` bytes
- The install script stopped the prior app instance. No sidecar process was running at the latest status check.
- A user-session CoreAudio probe reported the current macOS default output as `多输出设备`. The acoustic harnesses now switch to an ordinary output automatically for tests and restore the user's previous output afterward; outside the harnesses, do not leave a separate Multi-Output Device active while judging live microphone calibration.

## Next Concrete Iterations

1. Add a long-session AirPlay matrix with explicit failure injections and health gates, including at least one two-AirPlay diagnostic run where automatic apply must remain disabled.
2. Validate post-apply settle behavior after receiver restart, sidecar/OwnTone restart, route switching, and multi-AirPlay diagnostic routes. Single Xiaomi volume-change and mute/unmute evidence now exists.
3. Remove audible helper probes from default Tap/AirPlay tests permanently; future deterministic probe generation must be high-band, low-amplitude, and explicitly enabled only for lab runs.
4. Runtime-test Direct Stereo default-output restore under quit, stop, failed router start, and user-changed default output, then run DRM playback only after that restore smoke passes.
5. Test DRM playback under Direct Stereo only after restore behavior is safe.
6. Runtime-test Process Tap sleep/wake and DRM behavior before deciding whether it can replace SCK for AirPlay/calibration paths.
