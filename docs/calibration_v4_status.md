# SyncCast Calibration v4 — Current Status

**Status**: Shipping (active manual calibration) + WIP (continuous calibration on parallel agent branch).
**Author**: engineering management (SyncCast).
**Date**: 2026-04-26.
**Supersedes**: `calibration_v2_design.md` (kept as historical record with inline reality-check annotations).

This is the canonical "what's actually in the codebase right now" document
for the calibration subsystem. Read this first; read v2 only for the
algorithmic reasoning behind specific design choices, with the inline
annotations as the diff against reality.

---

## 1. Architecture (text diagram)

```
                ┌────────────────────────────────────┐
                │       SCK system-audio capture     │
                │  (ScreenCaptureKit → 48 kHz mono)  │
                └──────────────────┬─────────────────┘
                                   │ shared ring buffer
              ┌────────────────────┴──────────────────┐
              │                                       │
              ▼                                       ▼
     ┌─────────────────┐                 ┌───────────────────────┐
     │  Local CoreAudio│                 │  Sidecar broadcaster  │
     │  bridges        │                 │  → OwnTone fifo path  │
     │  (per-device    │                 │  → AirPlay 2 PTP fan- │
     │   AUHAL render) │                 │     out               │
     └────────┬────────┘                 └───────────┬───────────┘
              │                                      │
              │  per-bridge volume + tone injection  │  global PCM stream
              │  (FDM-friendly)                      │  (TDMA-only)
              ▼                                      ▼
       speakers (local)                       AirPlay receivers
              \                                      /
               \                                    /
                \                                  /
                 ▼                                ▼
                ┌──────────────────────────────────┐
                │         Room microphone          │
                │  (Logitech BRIO @ 48 kHz mono)   │
                └────────────────┬─────────────────┘
                                 │
            ┌────────────────────┴────────────────────┐
            │                                         │
            ▼                                         ▼
   ┌──────────────────┐                     ┌────────────────────┐
   │ ActiveCalibrator │                     │ PassiveCalibrator  │
   │   (manual / on-  │                     │   (background,     │
   │    demand, v3)   │                     │    cross-corr,     │
   │                  │                     │    drift detector) │
   └────────┬─────────┘                     └─────────┬──────────┘
            │ per-device τ + delta_ms                 │ measured drift / suggested
            ▼                                         ▼
       ┌──────────────────────────────────────────────────┐
       │              airplayDelayMs (delay-line)         │
       │   delays LOCAL audio so it lines up with the     │
       │   slowest AirPlay receiver. Persisted in         │
       │   UserDefaults (io.syncast.menubar).             │
       └──────────────────────────────────────────────────┘
                              │
                              ▼ pushed via JSON-RPC
                    `local_fifo.set_delay_ms`
                    to sidecar's LocalFifoBroadcaster
```

The two calibrators write to the same delay-line via different paths but
do not coordinate directly — `PassiveCalibrator` emits a "suggestion"
that the menubar applies on a heuristic, while `ActiveCalibrator` is
triggered explicitly (UI button or `scripts/calibration_test.sh`).

The continuous calibrator (parallel WIP, log tag `[ContActiveCalib]`)
will be a control loop that re-runs `ActiveCalibrator` on a schedule and
applies the resulting delta directly, replacing the manual button as
the primary update path during long-running playback.

---

## 2. Component Status Matrix

| Component | Source | Status | Notes |
|---|---|---|---|
| `ActiveCalibrator` (v4 mixed FDM-local + TDMA-airplay) | `core/router/Sources/SyncCastRouter/ActiveCalibrator.swift` | **Stable** | Default for whole-home calibration. Single-pass ~5–10 s. |
| `MuteDipCalibrator` (v2 TDMA mute-dip) | `core/router/Sources/SyncCastRouter/MuteDipCalibrator.swift` | **Deprecated, kept** | Fallback when active calibration cannot run (single-device, no mic permission yet). Not on the default path. |
| `PassiveCalibrator` (cross-correlation drift detector) | `core/router/Sources/SyncCastRouter/PassiveCalibrator.swift` | **Stable** | Runs every 30 s when `bgCalibrationEnabled = 1`. Source of background drift samples. |
| Continuous calibration controller (`[ContActiveCalib]`) | parallel agent branch | **Experimental** | Wraps `ActiveCalibrator` in a periodic loop. Currently being merged. |
| `CalibrationDiagnosticServer` (UNIX socket) | `core/router/Sources/SyncCastRouter/CalibrationDiagnosticServer.swift` | **Stable** | Exposes `calibrate`, `freqresponse`, `ping` over `/tmp/syncast-$UID.calibration.sock`. Single-flight. |
| `freqresponse` SNR sweep | `ActiveCalibrator.runFrequencyResponseTest` | **Stable, occasional use** | Used once on each new mic+room combo to pick local probe frequencies. Drove the choice of 18/19/18.5/16 kHz over 17 kHz. |
| Manual UI calibrate button | `apps/menubar/Sources/SyncCastMenuBar/AppModel.swift` | **Stable** | Calls `Router.runCalibration` and applies returned delta to `airplayDelayMs`. |
| `airplayDelayMs` slider (manual override) | `apps/menubar/Sources/SyncCastMenuBar/MainPopover.swift` | **Stable** | 0–5000 ms range; persisted to UserDefaults. |
| `local_fifo.diagnostics` JSON-RPC | `sidecar/src/syncast_sidecar/server.py` | **Stable, single-client** | Reports `delay_ms`, `bytes_broadcast`, `pending_packets`, etc. The Router is the only client at runtime — scripts MUST NOT connect or they will steal the Router's connection. Use `defaults read io.syncast.menubar syncast.airplayDelayMs` instead. |

---

## 3. Algorithm Summary (current shipping code)

`ActiveCalibrator.run(localProbes:, airplayProbes:, …)` executes three
phases in series:

```
Phase 1 — local FDM (parallel, ~5 s)
  Assign each local bridge a unique frequency from
    [18000, 19000, 18500, 16000] Hz.
  All bridges call startCalibrationTone simultaneously.
  Single mic capture covers the whole tone window + tail.
  For each bridge: bandpass mic at f_i ± 100 Hz → 5 ms RMS envelope
                   → first-rise threshold → onset_time = τ_local.

Phase 2 — AirPlay TDMA (sequential, ~3 s per device)
  Silence ALL local bridges (set volume 0, snapshot the previous values).
  For each AirPlay device j:
    Set every other AirPlay device to volume 0 (snapshot first).
    Synthesize 200–800 Hz linear chirp, duration 100 ms, with a
      per-device start-frequency offset so templates are spectrally
      distinguishable.
    Inject chirp into SCK ring at known wall-clock anchor.
    Wait airplayCaptureDurationMs (4000) for the chirp to land + tail.
    Cross-correlate mic vs. chirp template → peak idx → τ_airplay.
    Restore snapshotted volumes.
  Restore local bridge volumes from snapshot.

Phase 3 — delta computation
  delta = max(τ_airplay) − max(τ_local).
  Return Result(perDeviceTauMs, perDeviceConfidence, deltaMs).
  Caller adds delta to airplayDelayMs.
```

Why not the v2 mute-dip with active probes:
- Volume-based modulation is intrinsically narrowband (the ramp envelope sits at <50 Hz). Music dynamics live in the same band, so whitening is fragile.
- Active sines/chirps put the probe energy in a known, narrow spectral region we can isolate via bandpass — orders of magnitude better SNR for the same probe duration.
- Local FDM in parallel is faster than AirPlay-style TDMA whenever the architecture supports it, which it does for CoreAudio bridges but not for AirPlay 2 multi-room.

---

## 4. Open Issues / Known Limitations

### 4.1 Drift threshold tuning (drives this validation harness)

`ActiveCalibrator` reports `deltaMs`, but no policy says "if |delta| <
N then it's not worth re-applying". Without a deadband:

- Every continuous-calibration cycle pushes a tiny delta to the delay-line.
- Frequent `local_fifo.set_delay_ms` calls trigger LocalFifoBroadcaster
  queue resync, which is a brief audible artifact on the local path.
- The system can oscillate around the optimum.

Action: `drift_test.sh` measures the natural per-cycle variance under
quiet conditions. Once we know the noise floor (we expect ~5 ms after
v3) we'll set the deadband 2–3× above it.

### 4.2 MBP speaker pop on tone start

Local probe injection on the MacBook Pro's built-in speakers produces
an audible click at the tone-start boundary. The tone amplitude is 0.15
(well below clipping), but the sudden onset of an 18 kHz sine is enough
to excite a brief mechanical-resonance pop in the MBP transducer.

Mitigation candidates (not yet implemented):
- 5–10 ms cosine ramp at tone start/stop.
- Lower amplitude with longer integration window.
- Probe scheduling that hides the pop under existing audio.

### 4.3 Per-AirPlay-device frequency selection is impossible

The OwnTone path produces a single PCM stream that fans out to all
enabled AirPlay receivers. We cannot sweep a frequency-response per
AirPlay device because the source bytes are identical. Consequence:
the `freqresponse` sweep gives us one global curve for the whole
AirPlay 2 fleet, not per-device. We compensate by using chirps (which
are robust across AirPlay codec variants) instead of sines for the
AirPlay path, but a single bad-acoustics AirPlay receiver can drag the
aggregate confidence down without a way to detect "this specific
device sees the probe poorly".

### 4.4 Ultrasonic probe inaudibility is age-dependent

The 18/19 kHz local probes are inaudible to most adults but well within
the hearing range of children and many adults under 25. We accept this
trade-off: an audibly whisper-thin tone for a small fraction of users
beats v2's distinctly tremolo-y mute-dip for everyone.

### 4.5 PassiveCalibrator gate failures dominate when source is quiet

Field log shows long runs of `gate=FAIL_SOURCE_BELOW_-60dBFS` between
useful samples — the cross-correlation gate refuses to compute when
the source signal is too quiet. This is correct behaviour (low-SNR
samples would mislead the controller) but it means continuous drift
correction effectively stops during quiet passages of music. Acceptable
for now; the active calibrator can fill the gap when the user notices
drift.

### 4.6 Volume command race during AirPlay TDMA

On the user's setup we observed one run where the AirPlay peak landed at
473 ms (instead of the usual ~2700 ms) because the local bridge
re-radiated the chirp before the AirPlay path delivered it, and the
xcorr locked on the wrong peak. v3 added explicit local-bridge
silencing before AirPlay phase (see `ActiveCalibrator.swift` §282–298)
which has eliminated the false-peak path in subsequent runs. We monitor
for regressions via `drift_test.sh`.

---

## 5. How to Validate (manual playbook)

### One-shot status snapshot

```bash
bash scripts/calibration_status.sh
```

Reports:
- Process running, calibration socket present
- Mode (`wholeHome` / `stereo` / unknown)
- Persisted UserDefaults (`airplayDelayMs`, `bgCalibrationEnabled`, etc.)
- Last 5 calibrator log lines from `~/Library/Logs/SyncCast/launch.log`.

Quick smoke test: "is SyncCast in the right mode and have we run any
calibration recently?" Takes <0.5 s.

### Single calibration cycle

```bash
bash scripts/calibration_test.sh
```

Triggers one `ActiveCalibrator.run` via the diagnostic socket. Prints
per-device offsets, recommended deltaMs, and confidence. Does not
modify `airplayDelayMs` — that's the menubar's job. Use
`calibration_watch.sh` in a side terminal to see the trace.

### Long-running drift validation

```bash
bash scripts/drift_test.sh                 # 10 cycles × 60 s = ~10 min
bash scripts/drift_test.sh 30 120          # 30 cycles × 120 s = ~1 hour
bash scripts/drift_test.sh --help          # all options
```

Loops `calibrate` and records each result to a CSV plus a summary at
the end:
- Total drift over the window (cycle 1 vs. cycle N).
- Per-cycle drift mean + stdev (is the system converged or chasing?).
- Confidence stability.
- Per-device τ trajectory.

A STABLE verdict means continuous calibration (or the user's static
delay) is keeping things aligned. UNSTABLE with monotone growth means
drift is real and not being corrected — either the continuous
calibrator is silent or it's mis-tuned.

### Frequency response sweep (rare)

```bash
bash scripts/freqresponse_test.sh
```

One-time use when adding a new mic or moving to a new room. Picks the
ultrasonic probe frequencies for that hardware combo. Output guides
the constants in `ActiveCalibrator.localFrequencies`.

---

## 6. Where the Authoritative State Lives

When debugging "what does SyncCast think is happening right now?":

| Question | Where to look |
|---|---|
| Is calibration running? | `pgrep -fl SyncCastMenuBar` + check `/tmp/syncast-$UID.calibration.sock` |
| What's the current `airplayDelayMs`? | `defaults read io.syncast.menubar syncast.airplayDelayMs` |
| Is background calibration on? | `defaults read io.syncast.menubar syncast.bgCalibrationEnabled` |
| Last calibration result? | `grep '\[ActiveCalib\] DONE' ~/Library/Logs/SyncCast/launch.log \| tail -1` |
| Last passive sample? | `grep 'bgCalib sample' ~/Library/Logs/SyncCast/launch.log \| tail -1` |
| Sidecar broadcaster diagnostics? | `local_fifo.diagnostics` over `/tmp/syncast-$UID.sock` — but **only** the Router can connect (single-client). Don't run `nc` against this socket while SyncCast is running. |

---

## 7. Open Questions for the Next Iteration

1. **Where should the deadband live?** In `ActiveCalibrator.run` (drop
   the delta if too small) or in the continuous-calibration controller
   (apply, but with hysteresis)? Latter is more explicit but adds a
   layer.
2. **Should manual calibrate auto-disable continuous?** Right now
   manual + continuous can fight each other (manual applies a one-shot
   delta, continuous's next cycle reverts it). UI currently hides
   continuous toggling while manual is in flight; we may want a longer
   debounce on continuous post-manual.
3. **Should we promote `local_fifo.diagnostics` to a multi-client
   read-only endpoint?** The single-client constraint forces tooling
   to read state via launch.log + UserDefaults instead of a clean RPC.
   A second listening socket with a `state.snapshot` method would make
   `calibration_status.sh` significantly more accurate.
