# SyncCast Calibration v2 Design — TDMA Mute-Dip with Music-Aware Probe

**Status**: Draft for review
**Author**: architect (SyncCast)
**Date**: 2026-04-25
**Supersedes**: calibration_v1 (sequential per-device tone)

---

## 1. Problem Statement

Whole-home mode broadcasts a single PCM stream to N output devices simultaneously: a mix of local CoreAudio bridges (~10–50 ms latency) and AirPlay 2 receivers (~1.8 s buffered latency). To achieve perceptual wall-clock alignment, the broadcaster must apply a per-device delay-line correction `Δ_d = max(τ) − τ_d`. This requires measuring each device's end-to-end latency `τ_d` to ≤10 ms accuracy.

We have a single room microphone and four playback devices in arbitrary acoustic positions. The user expects calibration to take ≤5 s and produce no audible disruption while music is playing.

## 2. Architecture Constraints

The constraint that drives the entire design:

> **All devices receive the same PCM bytes.** We cannot inject a per-device probe waveform. The only per-device control we have is **volume**, exposed via `Router.setRouting` → bridge volume for CoreAudio devices, and the sidecar's `device.set_volume` → OwnTone REST for AirPlay devices.

This rules out classical signal-engineering approaches:
- **FDM (one tone per device)** — impossible; we cannot put a 1 kHz tone into MBP and a 2 kHz tone into Xiaomi simultaneously when the source bytes are identical.
- **Orthogonal codes (Gold / Hadamard sequences per device)** — same problem; the codes would have to live in the source stream, but the source stream is a single shared buffer.
- **Ultrasonic chirps per device** — same problem.

What we **can** do per device is **gate audibility** via volume. This converts the problem from FDM to **TDMA**: in any given time slot, only one device contributes meaningful energy to the room, and we read the per-device latency by watching when its energy contribution actually appears at the mic.

## 3. Algorithm: Probe Generation

### 3.1 Probe Pattern

Define a TDMA cycle of N devices, each with a "solo window" of `T_solo = 200 ms` and a guard interval of `T_guard = 50 ms`. One cycle period is `T_cycle = N · (T_solo + T_guard) = 1000 ms` for N=4.

For device `d ∈ {0, …, N−1}`, define the **logical probe pattern**:

```
              ⎧ 1   if t mod T_cycle ∈ [d·(T_solo+T_guard),  d·(T_solo+T_guard)+T_solo]
p_d(t)   =    ⎨
              ⎩ 0.3 otherwise   (background level — device is "ducked", not silenced)
```

The "off" level is **0.3, not 0**. We never fully mute non-soloed devices because:
- Hard mutes are perceptually disruptive even with ramps.
- A non-zero floor preserves the broadcast feel.
- The cross-correlation only needs **modulation depth**, not on/off.

### 3.2 Volume Ramping (Anti-Click)

Each step of `p_d` is replaced by a 50 ms half-cosine ramp:

```
ramp(t, t₀) = 0.5 · (1 − cos(π · (t − t₀) / 0.05))   for t ∈ [t₀, t₀ + 0.05]
```

This bandlimits the volume envelope to ~20 Hz, well below the music's spectrum, so listeners perceive only a faint "tremolo" effect and no clicks. The broadcaster issues volume commands at the timestamp of ramp **start**, not at the discontinuity, so the rendered volume curve is C¹-continuous.

### 3.3 AirPlay Latency-Aware Scheduling

Each device has a known **command-to-audible latency** `λ_d`:
- Local CoreAudio bridges: `λ_local ≈ 30 ms` (CoreAudio scheduling jitter).
- AirPlay 2 receivers: `λ_airplay ≈ 1800 ms` (the standard AirPlay buffer; this is also the user-visible "lag").

The broadcaster schedules volume commands at `t_command = t_audible − λ_d`, so the **audible** ramp boundaries land in the intended TDMA slots regardless of device class. Concretely, AirPlay volume changes for slot `k` must be issued ~1.8 s before slot `k` is supposed to be heard.

This means the **probe cycle starts ~λ_max in advance**. With λ_max = 1.8 s, the broadcaster begins issuing volume commands at `t = 0`, the mic begins capturing at `t = 0`, but the first audible solo window appears at the mic at `t ≈ 1.8 s + τ_AirPlay`. Total wall-clock: ~1.8 s pre-roll + 1 cycle + 0.5 s post-roll = **3.3 s**. Under the 5 s budget.

### 3.4 Cycle Repetition

We run the cycle **2×** by default. Two cycles give us:
- A consistency check (per-device latency must be reproducible across cycles to within ±5 ms).
- Averaging to reduce mic noise.
- Detection of a transient interferer (user speech, AC unit kicking on) that corrupts one cycle but not the other.

Total wall-clock: ~3.3 s + 1 cycle = **4.3 s**, still inside the budget.

## 4. Algorithm: Mic Processing

### 4.1 Capture

Continuous mono mic capture at 48 kHz, 16-bit, throughout the probe window. Begin capturing 100 ms before the first volume command and end 200 ms after the last expected audible window. Buffer in memory; total ~6 s of audio = ~580 KB.

### 4.2 Envelope Extraction

Compute a sliding-window RMS envelope at 10 ms hop, 20 ms window:

```
env[k] = sqrt( (1/W) · Σ_{i=0}^{W−1} mic[k·H + i]² )
```

with `W = 960 samples (20 ms)`, `H = 480 samples (10 ms)`. This downsamples from 48 kHz mic → 100 Hz envelope, giving us a 1D signal of ~600 samples for a 6 s window. Cheap to FFT.

vDSP plan: `vDSP_rmsqv` for window RMS in a strided loop, or `vDSP_vsq + vDSP_meanv` if we want explicit control over alignment.

### 4.3 Whitening (Music-Aware)

Music produces large, slow-varying envelope content of its own. To extract the **modulation imposed by our probe** from the envelope dominated by music dynamics, we high-pass the envelope at ~1 Hz and normalize by a slow-moving baseline:

```
env_baseline[k]  = moving_avg(env, 500 ms)[k]
env_modulation[k] = (env[k] − env_baseline[k]) / (env_baseline[k] + ε)
```

`env_modulation[k]` is the **fractional modulation** induced by our probe — dimensionless, music-amplitude-invariant. If the music goes loud, both `env` and `env_baseline` rise together and the ratio is preserved. Empirically, our 0.3↔1.0 volume swing produces ~30–50% modulation on the soloed device's contribution, which against quiet background is detectable down to SNR ≈ 6 dB.

### 4.4 Cross-Correlation per Device

For each device d, construct the **expected modulation pattern** `m_d(t)` — the same 0.3↔1.0 ramped square wave used to generate the probe, downsampled to the envelope's 100 Hz rate, mean-removed.

Cross-correlate `env_modulation` against `m_d`:

```
C_d[k] = Σ_n env_modulation[n] · m_d[n − k]
```

Implemented via FFT (vDSP `vDSP_DFT_Execute`): take FFT of both signals, multiply by the conjugate of `m_d`'s spectrum, IFFT. ~10 µs for 600-point sequences on Apple silicon.

The peak of `C_d[k]` over the search window gives `τ_d` (in 10 ms units).

### 4.5 Search Window per Device

The search window depends on device class:
- **Local devices**: peak should land within `[0, 200] ms` post nominal. Search `k ∈ [0, 20]` (200 ms / 10 ms hop).
- **AirPlay devices**: peak should land near 1.8 s. Search `k ∈ [150, 200]` (1.5–2.0 s).

We do **not** search across the whole window per device — that would invite false peaks from neighboring solo windows aliased through reverb. The narrow search per device class is part of the design's robustness.

## 5. Algorithm: Latency Extraction (Math)

### 5.1 Signal Model

Let `s(t)` be the (unknown but observable through the mic) source music. Each device plays `v_d(t) · s(t − λ_d − ε_d)` where `v_d(t) = p_d(t)` is the volume envelope we control and `ε_d` is the **electroacoustic-plus-acoustic** propagation latency we want to measure.

The mic observes:

```
mic(t) = Σ_d  h_d(t) ⊛ [ v_d(t − τ_d) · s(t − τ_d) ]  +  n(t)
```

where:
- `τ_d = λ_d + ε_d` is the total latency from the broadcaster's wall clock to mic capture.
- `h_d(t)` is the device→mic room impulse response (~50 ms tail typically).
- `n(t)` is mic noise plus user speech plus appliance noise.

### 5.2 Why Envelope Cross-Correlation Works

The envelope operator `ENV[·]` is roughly insensitive to the carrier `s(t)` and primarily reflects the slow-varying volume pattern `v_d`. With music spectrum dominated by 100 Hz–4 kHz content and our envelope LPF at ~50 Hz, the fast carrier averages out and:

```
ENV[mic](t) ≈ Σ_d  α_d · v_d(t − τ_d) + ENV[n](t)  +  music_dynamics(t)
```

where `α_d` is the device's effective room gain (depends on speaker SPL, distance to mic, room absorption). After whitening (§4.3), `music_dynamics(t)` is suppressed by ~20 dB, leaving a near-additive mix of time-shifted `v_d` patterns.

Cross-correlating with mean-removed `m_d = v_d − ⟨v_d⟩`:

```
C_d(τ) = ⟨ ENV_whitened[mic](t) · m_d(t − τ) ⟩
       ≈ α_d · ⟨ m_d(t − τ_d) · m_d(t − τ) ⟩  +  cross-talk + noise
       = α_d · R_{m_d}(τ − τ_d) + cross-talk + noise
```

`R_{m_d}` is the autocorrelation of the probe pattern, which peaks at zero. Therefore `C_d(τ)` peaks at `τ = τ_d`. The cross-talk between devices is `Σ_{d'≠d} α_{d'} · ⟨m_{d'}(t − τ_{d'}) · m_d(t − τ)⟩`, which is small because the m_d patterns are designed to be **orthogonal in time** (TDMA — each m_d is non-zero in disjoint slots).

### 5.3 vDSP / FFT Plan

```
1. mic_buf = AVAudioEngine tap → 48 kHz mono, 6 s buffer
2. env[600] = vDSP_rmsqv strided over mic_buf at 10 ms hop, 20 ms window
3. env_baseline[600] = vDSP_vswsmean over env, 500 ms window
4. env_mod[600] = (env − env_baseline) / (env_baseline + ε)   via vDSP_vsub, vDSP_vdiv
5. For each d in 0..N-1:
   a. m_d[600] = expected pattern, mean-removed
   b. FFT(env_mod) × conj(FFT(m_d)) via vDSP_DFT_Execute (size 1024, zero-padded)
   c. IFFT → C_d[1024]
   d. argmax(C_d) within [k_min_d, k_max_d] → τ_d
   e. peak_value, second_peak_value → confidence
```

Total CPU: ~4 FFTs × 1024 points × N=4 devices ≈ 200 µs. Negligible.

## 6. Edge Cases

### 6.1 Reverb Spreading Across Slots

A 200 ms solo window followed by 50 ms guard means the reverb tail of slot `k` partially overlaps slot `k+1`. We handle this two ways:
1. **Guard intervals at 50 ms** — covers the bulk of room reverb (RT60 typically <300 ms in living rooms, but the early tail decays in ~50 ms).
2. **Cross-correlation peaks robustly** even with cross-talk because the autocorrelation lobe of `m_d` is wider (200 ms) than the typical reverb tail.

If RT60 is pathologically long (>500 ms — bathroom, large open kitchen), confidence drops; we report the result with a flag and recommend retest.

### 6.2 Wide Latency Spread (Local 10 ms, AirPlay 1800 ms)

Handled by per-device-class search windows (§4.5). The probe cycle is short (1 s) compared to AirPlay latency (1.8 s), so an AirPlay device's response to slot 0 arrives at the mic during what would be slot 7 of nominal time. We search the AirPlay window `[1.5, 2.0] s` after slot 0's command time — there the AirPlay slot-0 response sits cleanly.

### 6.3 Low SNR (Mic Far From Speakers)

If `α_d` is small for some d (e.g. device behind a wall, or volume below mic noise floor), `C_d` peak is buried in noise. We detect this via the **confidence metric** (§7) and:
1. Boost the modulation depth: drop the off-level from 0.3 to 0.1 for retry.
2. Run additional cycles (3 instead of 2) and average.
3. If still below threshold, report `τ_d = unknown` and ask user to move closer or retry.

### 6.4 User Speaks During Calibration

Speech energy lives 100–4000 Hz and produces large envelope spikes. Two defenses:
1. **Two-cycle consistency check**: a transient (speech, door slam, fridge compressor) corrupts at most one cycle. If `|τ_d^(cycle1) − τ_d^(cycle2)| > 20 ms`, we flag the cycle with lower confidence as compromised and run a third.
2. **Median filter on env_mod** prior to cross-correlation removes single-bin spikes. We use a 3-tap median filter; preserves the 200 ms square wave shape, kills 10–30 ms transients.

### 6.5 Single-Device Case (N=1)

The TDMA collapses to a single ramp-up / ramp-down pulse. Math is unchanged; we just have one `m_d` and search across the full window. A single 200 ms pulse at known `t_command` + cross-correlation gives `τ_d` directly.

## 7. Confidence Metric

For each device d:

```
confidence_d = (peak_d − background_d) / noise_floor_d
```

where:
- `peak_d` = max value of `C_d` within search window.
- `background_d` = median of `C_d` outside the ±50 ms peak vicinity.
- `noise_floor_d` = MAD (median absolute deviation) of `C_d` outside the peak vicinity.

Interpretation thresholds:
- `confidence > 8` → high confidence, accept.
- `confidence ∈ [4, 8]` → marginal, run another cycle.
- `confidence < 4` → reject, flag for retry.

This is essentially a **prominence-vs-local-noise** SNR measured in the correlation domain. Empirically, a quiet living room with 0.3↔1.0 modulation gives confidence > 15.

## 8. Comparison vs. Failed Sequential Approach (v1)

The v1 calibration had each device play a known tone burst sequentially while others were silent.

| Property | v1 Sequential | v2 TDMA Mute-Dip |
|---|---|---|
| Music keeps playing | No (silence between bursts) | Yes |
| Audible artifact | Tone burst clearly audible | Faint tremolo |
| Time per device | ~500 ms | 250 ms |
| AirPlay handling | Required serial 1.8 s waits | Cycle absorbs latency once |
| Total time (4 devices) | ~10–12 s | ~4 s |
| Robustness to user speech | Single-shot, fragile | Two-cycle consistency |
| Per-device probe waveform | Required (FDM-style) | Not required (volume only) |
| Fits architecture | No (couldn't inject per-device) | Yes |

The fundamental fix: v1 tried to apply textbook FDM signal engineering to an architecture that only exposes per-device volume. v2 reframes the same signal-engineering primitives (orthogonal codes, cross-correlation) in the dimension we actually control — **time × volume** — yielding TDMA.

## 9. Open Questions / Risks

1. **AirPlay volume command rate-limit**: OwnTone's REST API may rate-limit volume changes. With 2 cycles × 4 devices × 2 transitions per slot = 16 volume calls per AirPlay device in 4 s. Confirm tolerable.
2. **Volume ramping at OwnTone level**: AirPlay 2 may apply its own volume crossfade (~50 ms). This compounds with our ramp and shifts the effective `τ_d` by ~25 ms. We accept this as a per-device-class **constant offset** and characterize it once at integration.
3. **Mic AGC**: macOS mic may apply auto-gain. Need to disable AGC on the mic input or use an external mic with fixed gain. Otherwise the envelope baseline drifts and whitening gets unstable.
4. **Multi-mic future**: If we eventually use the iPhone mic plus the MBP mic, we get spatial diversity and can localize devices in 3D. Out of scope for v2 but the algorithm extends naturally.
5. **Two-mic mode for cross-validation**: If the user has a second device with a mic (their phone), we could run the same algorithm on both mics simultaneously and validate that `τ_d^(mic1) − τ_d^(mic2)` matches the geometric expectation.

## 10. Reference Implementation Pseudocode

```
function calibrate(devices: [Device], cycles: Int = 2) -> [Device: Latency] {
    let cycle_pattern = build_tdma_pattern(devices, T_solo: 200ms, T_guard: 50ms)
    let total_duration = preroll(λ_max) + cycles * cycle_pattern.duration + postroll

    let mic_capture_task = async start_mic_capture(48kHz, total_duration)
    for cycle in 0..<cycles {
        for slot in cycle_pattern.slots {
            for device in devices {
                let target_volume = slot.solo_device == device ? 1.0 : 0.3
                let t_command = slot.t_audible - device.command_latency
                schedule_volume_ramp(device, target_volume, at: t_command, ramp: 50ms)
            }
        }
    }
    let mic_buf = await mic_capture_task

    let env = sliding_rms(mic_buf, window: 20ms, hop: 10ms)
    let env_baseline = moving_avg(env, window: 500ms)
    let env_mod = (env - env_baseline) / (env_baseline + 1e-6)
    env_mod = median_filter(env_mod, taps: 3)

    var results: [Device: Latency] = [:]
    for device in devices {
        let m_d = build_expected_pattern(device, cycle_pattern, mean_removed: true)
        let c_d = fft_cross_correlate(env_mod, m_d)
        let (peak_idx, peak_val) = argmax(c_d, in: device.search_window)
        let τ_d = peak_idx * 10ms
        let conf = compute_confidence(c_d, peak_idx)

        if conf < 4 { results[device] = .unknown }
        else        { results[device] = Latency(value: τ_d, confidence: conf) }
    }

    if !consistency_check(results, across_cycles: cycles) {
        return calibrate(devices, cycles: cycles + 1)   // retry with more averaging
    }
    return results
}
```
