# LAN link timing — what the first two-machine run found (2026-09-05)

## Problem

The LAN PCM leg was exercised for the first time between two Macs over Wi-Fi,
playing music. The local speakers were clean; the receiver clicked or
stuttered continuously.

The counters said what was happening. At a 90 ms target the receiver reported:

| figure | observed | meaning |
|---|---|---|
| `buffer` | 75–86 ms (setpoint ≈ 76) | the level itself was fine |
| `trim` | −107…+17 ppm within seconds | the playout rate was being swung hard |
| `reanchor` | ~3 per second (86 in 30 s) | the playout cursor was being SPLICED |
| `underrun` | 20 in 30 s | the ring genuinely ran dry sometimes |
| `late` / `lost` | 3–14 per minute | ordinary Wi-Fi delivery |
| `clip` | negligible (0.06 % of samples) | not a level problem |

The sender's own health line showed `ppm:-131.8` and then `ppm:-185.7` — its
`RingWriteClock` trimming its idea of the ring's rate by over 100 ppm, and
moving.

A re-anchor is a discontinuity in the played audio: the read cursor is thrown
to a new position and playback resumes from a different sample. Three of them
a second is the clicking, exactly. Everything else in the table is a symptom
of the same thing.

## Diagnosis

**Two independent servos, each correcting the other's corrections.**

The sender inferred "when was ring frame N captured" from `(write cursor,
now())` pairs sampled on its own 5 ms timer, then servo'd that estimate with a
phase-and-rate loop. The receiver independently servo'd its playout rate from
the buffer level. Neither could see the other. The sender's rate corrections
moved `play_at_ns`; the receiver read that as a level change and trimmed; the
trim moved the level again.

**And the receiver spliced on transients.** Two triggers, both firing on
things that are not faults:

* a single render block that found the ring empty was treated as starvation.
  A link that delivers in bursts empties the ring for one block at the end of
  most burst gaps, with the audio for the very next block already in flight.
* a level error past ±20 ms spliced on the first tick that saw it. A burst of
  late packets looks exactly like that for one tick.

## What changed

### Sender: stamp from the hardware, do not infer

`TapCapture`'s IOProc is handed an `AudioTimeStamp` with every block it
receives. That stamp comes from the same clock that produced the samples. So
the IOProc now records, per delivered block, a `CaptureAnchor`: the ring write
position the block landed at, paired with the host time of its first frame
(`inInputTime.mHostTime` converted through the mach timebase; `inNow` minus
one block duration if a device does not fill it in; nothing published at all
if neither is valid, because a made-up stamp is worse than no stamp).

`CaptureAnchorPublisher` hands the newest anchor to the LAN producer through a
seqlock in the C atomics shim — wait-free on the writer, which is a real-time
thread. Only the latest anchor is kept; a consumer that misses one has lost
nothing, because each anchor carries its own time.

`HostAnchoredRingClock` then answers `timeNs(forFrame:)` as
`anchorNs + (frame − anchorFrame) · nsPerFrame`, with `nsPerFrame` fitted by
least squares over the last ten seconds of anchors (centred coordinates; the
raw magnitudes lose the slope to cancellation) and the phase taken from the
fitted line at the newest anchor's frame. There is no servo and no `now()`
sampling anywhere in it. Bursty delivery — several blocks back to back after a
gap — needs no special handling: each anchor carries its own host time.

`RingWriteClock` stays exactly as it was, as the fallback for a backend that
publishes no timestamps (`SCKCapture`). Which one is driving the wire is
logged when a leg opens and whenever it changes hands, and shows in the
diagnostics line as `clk:hal` / `clk:est`. A leg falls back automatically if
anchors stop arriving for a second.

### Receiver: splice only on a fault that has proved itself

* Starvation now needs `starvedBlockLimit` (2) consecutive starved render
  blocks AND a smoothed level that agrees the buffer is short by at least
  `starvationConfirmMs` (10 ms). A lone empty block renders zeros and counts
  an underrun, which is what it is.
* A block is recognised as starved when the ring holds less than the callback
  is about to consume (`dt · rate`), not only when the fill goes negative —
  the old test missed the common case entirely.
* A level error past `reanchorErrorMs` (20 ms) must persist for
  `reanchorHoldSeconds` (0.5 s).
* The PI loop moved off the 1.5 s EMA it reports onto a separate 3 s EMA, at
  half the natural frequency (0.3 → 0.15 rad/s). The slower filter costs phase
  margin at the old bandwidth, so the two changes belong together. Settling
  takes about twice as long; nothing but the self-test's warm-up notices.
* Every re-anchor is logged at INFO with its reason and numbers (level error,
  ring fill, consecutive starved blocks), rate limited to one per second, and
  `stats` carries `reanchor_starved` / `reanchor_error`.
* `stats` also carries `p95_jitter_ms` — the spread between the best packet of
  the last few seconds and the 95th percentile — and the receiver uses it:
  a requested `target_ms` is treated as a floor it may RAISE to at least
  `p95 + 2 render blocks` (capped at 300 ms), because a target below the
  measured spread asks the buffer to hold less audio than the network
  routinely withholds. The effective value is reported in
  `hello_ack.buffer_ms` and `stats.target_ms`.
* `--selftest` gained a second scenario: bursts of six packets every 30 ms
  plus an 80 ms delivery stall about once a second, contract **zero hard
  re-anchors** after warm-up with underruns budgeted against the injected
  stalls. A test runs the same scenario under the OLD starvation rule and
  asserts that it does splice, so the scenario cannot quietly stop testing
  anything.

## What was verified

By test, on one machine:

* `HostAnchoredRingClock` tracks a regular device, a 100 ppm device and a
  bursty delivery pattern to better than 50 µs at the frames the producer
  actually asks about, over a minute of simulated capture; a discontinuity
  re-anchors instead of dragging the fit through it; the retained history
  stays bounded over two minutes.
* The seqlock survives 200 000 publishes against a concurrent reader with no
  torn pair.
* End to end against the in-process fake receiver, with the synthetic producer
  publishing hardware-style anchors: `play_at_ns` spacing is exactly 5 ms to
  the nanosecond for every packet (the previous assertion had to allow a
  bounded phase step per second plus a 500 ppm band on the median — that slack
  WAS the servo's corrections). Without anchors the leg still works on the
  fallback timeline.
* The receiver's bursty self-test ends with zero re-anchors; the same run
  under the old rule splices six times in the measured window.

Not verified here: the two-machine run itself. Whether the clicking is gone on
real hardware over real Wi-Fi is for the supervisor's session with the owner.

## Known limits

* The hardware timeline only exists on the Process Tap backend.
  `SCKCapture` delivers `CMSampleBuffer`s that do carry presentation
  timestamps; wiring those up is a follow-up, and until then the SCK path
  keeps the old servo.
* `p95_jitter_ms` is a percentile, so it is blind to rare events by
  construction: a stall that hits one packet in two hundred never reaches p95.
  That is the right trade for choosing a steady-state target — a maximum would
  size the buffer for the worst hiccup of the day and add its latency to every
  second — but it means p95 is a floor and not a guarantee, and the underrun
  counter is what reports the tail.
* Raising the target splices once, deliberately: the level has to jump because
  a ±200 ppm trim would take minutes to walk it 30 ms. It is rate limited to
  one change per 10 s with a 5 ms deadband.
