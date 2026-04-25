# SyncCast — Cross-Transport Audio Synchronization Brief

> Audience: SyncCast core engineers (Scheduler, AirPlay sidecar, CoreAudio tap).
> Goal: align playback between local CoreAudio (5–20 ms HW latency) and AirPlay 2
> (≈1.5–2 s buffered) within an audible-tolerance budget of **≤30 ms**.

---

## 1. How existing systems solve heterogeneous-transport sync

### 1.1 AirPlay 2 (Apple)

AirPlay 2 abandoned the AirPlay-1 NTP-style scheme in favour of **IEEE 1588 PTPv2**
across the LAN. Every AirPlay 2 receiver and the sender run a `ptp4l`-equivalent
that converges to a shared grandmaster (the Apple TV / HomePod or the Mac).
Apple's stated multi-room accuracy is **≤1 ms between receivers** in the same
PTP domain.

The wire trick: every audio chunk shipped over the RTSP/RTP control channel
carries an **`rtptime` plus an absolute PTP "anchor" timestamp** (delivered via the
`SETPEER`/`SETRATEANCHORTIME` RTSP verbs). Receivers buffer until the local PTP
clock reaches that anchor, then play. The buffer is large (~2 s) precisely so
that PTP convergence and Wi-Fi retransmits can absorb jitter without underrun.

**What we steal:** the *anchor-time* model. Every sample SyncCast emits gets a
target wall-clock playback time, not a "play now" command. Pyatv's
`SetRateWithAnchorTime` exposes this for senders that don't need the full 1588
stack.

### 1.2 Sonos / SonosNet

Sonos uses a proprietary mesh ("SonosNet") with a **master-elected clock** and
audio frames stamped with a 32-bit play-at timestamp (units of 1/44100 s). The
master broadcasts periodic time-sync packets (~250 ms cadence) and slaves
PI-control their DAC sample-rate to track. Reported drift between zones <5 ms.

**Steal:** the slow-PI-loop sample-rate trim (Section 4) is straight Sonos.

### 1.3 Snapcast (open source — most relevant prior art)

Snapcast's design doc (badaix/snapcast) is the cleanest blueprint:

- Server timestamps every PCM chunk with `server_time` derived from
  `CLOCK_MONOTONIC`.
- Clients run a continuous **time-sync probe**: each client periodically sends
  `Time` messages, server replies, client computes `(t1−t0+t2−t3)/2` Cristian
  offset. Smoothed in a bounded ring (median + low-pass).
- Each chunk has a `play_at = server_time + buffer_ms` stamp; client converts
  to local clock via the offset and feeds ALSA/CoreAudio at that instant.
- Drift correction: client measures buffer fill; if it slides, it inserts or
  drops a single sample silently (sub-ms granularity).

**Steal:** essentially the entire local-output thread design. SyncCast's
local-CoreAudio path can use the Snapcast-style scheduler verbatim. The novelty
in SyncCast is bridging this with the **opaque** AirPlay 2 buffer.

### 1.4 Roon / RAAT

RAAT (Roon Advanced Audio Transport) keeps the bit-perfect stream and pushes
sync into the endpoint. Every endpoint reports `latency_min/max/current` back
over the control channel; Roon delays *all other endpoints* to match the
slowest. This is the **delay-pad-the-fast-path** pattern, exactly what SyncCast
needs.

**Steal:** the architectural decision — pad faster paths up to the slowest
declared latency, never try to speed up the slow one.

### 1.5 Squeezebox / SLIMP3 / Slim Protocol

LMS (Logitech Media Server) sends a `strm` start command with an `output_time`
field. Each player reports buffer fullness and elapsed samples back at ~1 Hz;
the server computes drift and issues `pause`/`unpause` of single-sample
granularity to retrim. Decentralised but server-authoritative.

**Steal:** the **per-receiver buffer-fill telemetry** idea. AirPlay 2 doesn't
expose this directly, but our local sidecar can synthesise it.

---

## 2. Strategy for SyncCast

### 2.1 Master clock

`mach_absolute_time()` (which is `CLOCK_MONOTONIC` on macOS) is the master.
We do **not** require NTP discipline because both endpoints derive their
schedule from the same Mac; absolute wall time is irrelevant, monotonic
progression is what matters. (NTP-disciplined wall clock is only required if we
later add a second sender host.)

### 2.2 Pad-the-fast-path

AirPlay 2 latency is **fixed ceiling** for the playback group. Measure it once
per session, then schedule local CoreAudio to fire `D_airplay − D_local` later.
With `D_airplay ≈ 1.8 s` and `D_local ≈ 12 ms`, we insert ~1.79 s of ring buffer
ahead of the CoreAudio HAL.

### 2.3 Measuring AirPlay 2's *actual* delivered latency at runtime

It is not constant — it depends on receiver model (HomePod gen-2 vs AirPort
Express vs third-party MFi), Wi-Fi RTT, and Apple's adaptive jitter buffer.
Three options, ranked by practicality:

| Option | Pros | Cons | Verdict |
|---|---|---|---|
| (a) Acoustic loopback (silent click + Mac mic) | Real end-to-end, captures speaker latency too | Needs mic, ambient noise, user friction | **Optional "precision mode"** |
| (b) RTSP `RTP-Info` + `SETRATEANCHORTIME` parse via pyatv | No user action, deterministic, captures network+buffer | Misses the receiver's analog stage (~1–5 ms) | **Default** |
| (c) Static per-model lookup table | Zero runtime cost | Brittle, breaks on firmware updates | **Fallback only** |

**Decision:** ship (b) as default — pyatv exposes `anchor_time` and
`anchor_rtp_time` on the `RaopStream`, giving us the receiver's intended play
instant relative to PTP. Difference vs the wall-clock instant we *handed* the
chunk = delivered latency. Offer (a) behind a "Calibrate precisely" button for
audiophiles. (c) only as a cold-start guess (1800 ms) before the first
RTSP exchange completes.

---

## 3. Per-device delay calibration UX (no microphone)

The mic-free path has to be human-in-the-loop but cheap:

1. SyncCast plays a **3-second mono click train** (1 click / 200 ms) on the
   target device only.
2. UI shows a single big button: **"Tap in time with the clicks"**.
3. Capture 8–12 user taps (`mach_absolute_time()` per tap).
4. Cross-correlate tap times against the *intended* click times (already
   known). The lag of the correlation peak = perceived device delay − human
   reaction time.
5. Subtract a fixed human-reaction constant (≈230 ms median, well-studied);
   what remains is the device delay.

This is good to ±15 ms after a dozen taps, which is inside the 30 ms budget.
Persist per-receiver UUID in `~/Library/Application Support/SyncCast/calib.json`.

The mic-based "precision mode" simply replaces step 2–4 with an FFT
cross-correlation against the input from the built-in mic — same maths, no
human reaction subtraction. Worth the extra path because audiophile users will
ask for it on day one.

---

## 4. Drift over time

Within a single Mac's CoreAudio graph, all local outputs share `kAudioClockSourceID`
and do **not** drift relative to each other. AirPlay 2 receivers run their
**own** crystal disciplined to the PTP grandmaster. If the Mac is the
grandmaster the relative drift is bounded (≈ ±1 ppm = 60 ms/hour worst-case
between Mac and a HomePod whose PTP loop hasn't fully settled).

Two complementary mitigations:

**4a. Asynchronous Sample-Rate Conversion (ASRC) on the local path.**
Use Apple's `AudioConverter` with `kAudioConverterSampleRateConverterComplexity_Mastering`
and a slowly-varying `kAudioConverterSampleRate` ratio. Update the ratio every
10 s based on the running mean of the AirPlay anchor-time deltas. The ratio
delta is in the 1e-6 range — completely inaudible.

**4b. Buffer-fill PI controller** (Snapcast-style). Cheaper, no resampler
needed: every ~30 s, compare measured AirPlay anchor-progress against
local-clock progress; if it has slid by >2 ms, insert/drop a single sample
in the local ring buffer. Sub-ms granularity, energetically zero.

**Aggressiveness recommendation:** ship 4b only. ASRC is overkill for ≤30 ms
budget at session lengths typical of desktop use (2–4 hours). Add 4a behind
a flag if/when SyncCast targets multi-day deployments (kiosks, retail).

---

## 5. Concrete `Scheduler` algorithm

```text
# Inputs:
#   blackhole_in: 256-frame chunks @ 48 kHz from BlackHole tap
#   local_sink:   CoreAudio AUHAL, reports D_local (~12 ms)
#   airplay_ipc:  Unix-domain socket to pyatv sidecar
#   D_airplay:    measured AirPlay anchor delay (default 1800 ms,
#                 refined via RTSP within first 200 ms of stream)
#   SEND_OVERHEAD: IPC + RAOP encode budget (≈ 25 ms p99)

state:
    delivery_target_ms = max(D_local, D_airplay)  # always = D_airplay in practice
    local_ring  = RingBuffer(capacity = 2.5 s)
    airplay_q   = BoundedQueue(capacity = 64 chunks)

on_chunk(pcm_chunk):                          # called per BlackHole frame
    t_capture = mach_absolute_time()           # ns, monotonic
    t_play    = t_capture + delivery_target_ms # common wall-clock target

    # --- Local path: delay-pad to match slow path ---
    local_deadline = t_play - D_local
    local_ring.push(pcm_chunk, deadline = local_deadline)

    # --- AirPlay path: emit early enough to clear the pipe ---
    airplay_send_at = t_play - D_airplay - SEND_OVERHEAD
    airplay_q.push(Frame(
        pcm        = pcm_chunk,
        anchor_ts  = t_play,           # absolute wall-clock target
        send_after = airplay_send_at,
    ))

# --- Local CoreAudio render thread (pull model) ---
on_coreaudio_render_callback(out_buffer, num_frames):
    now = mach_absolute_time()
    chunk = local_ring.pop_due(now)            # returns silence if early
    out_buffer <- chunk

# --- AirPlay sidecar dispatcher ---
loop:
    frame = airplay_q.peek()
    sleep_until(frame.send_after)
    pyatv.send_audio(frame.pcm,
                     anchor_rtp_time = frame.anchor_ts)
    airplay_q.pop()

# --- Drift PI loop (every 30 s) ---
every 30 s:
    err = airplay_anchor_progress - local_clock_progress  # ms
    if abs(err) > 2 ms:
        local_ring.adjust_phase(sign(err) * 1 sample)     # insert/drop one
```

Notes on the loop:

- `local_ring.pop_due()` returns the chunk whose `deadline ≤ now`; if the ring
  is empty (cold start) it emits silence rather than block — the first ~1.8 s
  of every session is intentionally silent on local outputs while AirPlay
  fills its buffer. UX should show a "warming up" indicator.
- `SEND_OVERHEAD` should be measured, not guessed: timestamp `pyatv.send_audio`
  entry/exit and EWMA the result.
- `airplay_q` must be bounded; if pyatv stalls, we drop oldest and log — never
  block the BlackHole capture thread.

---

## Open questions for next iteration

1. Multi-receiver AirPlay groups — do we get one anchor or one per device?
   (pyatv source suggests one per group; verify on HomePod stereo pair.)
2. What happens on Wi-Fi roam mid-stream? PTP re-converges in ~3 s; we may
   need a "graceful re-pad" that ramps `delivery_target_ms` instead of
   stepping it.
3. Bluetooth output as a third class — it has its own ~150 ms variable buffer
   and no anchor mechanism. Probably out of scope for v1.
