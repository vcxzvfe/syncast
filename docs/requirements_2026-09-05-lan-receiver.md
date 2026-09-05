# LAN receiver output (sender side) — 2026-09-05

## The problem

A second Mac in the same room has speakers, and there is no way to use them as
one leg of a stereo pair.

AirPlay exists and does not solve it. Whole-home mode already sends to AirPlay
receivers, but AirPlay 2 buffers ~1.8 s: everything on that path plays nearly
two seconds behind the machine the user is sitting at. That is exactly right
for music in another room and unusable for "the left speaker is on that desk".

So the requirement is a second transport: **a machine on the LAN that plays in
time with this machine's own outputs**, target ≤ 100 ms end to end with one
side on Wi-Fi, sample-accurately rate-locked to the same capture ring the local
AUHALs read.

The receiver daemon lives in its own public repository
(`SyncCastReceiver`); this document covers the sender half, which lives here.
The wire format both halves implement is [`proto/lan-pcm-link.md`](../proto/lan-pcm-link.md).

## Design

### The leg is an output, not a receiver

`LanReceiverOutput` is deliberately the structural sibling of `LocalOutput`: it
reads the same `RingBuffer` at its own cursor, runs the same per-device chain
(equalizer → stereo image → channel matrix → balance), and hands the result to
an output. The output is a UDP socket rather than an AUHAL, which changes two
things and nothing else:

- **There is no hardware clock to be driven by.** A `DispatchSourceTimer` wakes
  every 5 ms and asks `LanSendPlanner` how many whole packets have become
  available. The timer sets the *pacing*; the ring sets the *rate*.
- **It is not a real-time thread.** Allocation is allowed (each packet becomes
  a `Data` for the socket). The three DSP banks are shared with the RT paths
  and keep their own no-allocation guarantees regardless.

The UI follows the same principle: a receiver is an ordinary device row with
the ordinary toggle, fader and EQ / 声场 / 声道 buttons, plus the two things
that are genuinely its own — a pairing token and a latency target.

### Timing model

This is the part worth reading twice.

**What we need.** The receiver must play frame *N* of the capture ring at the
same wall-clock instant as this machine's own speakers, and it must consume
frames at exactly the rate the ring produces them — otherwise its buffer drifts
and it eventually skips or stalls, however good its own clock is.

**What is available.** Neither capture backend records a host time per written
block. `SCKCapture` and `TapCapture` both call `RingBuffer.write` and publish a
frame cursor, and nothing downstream has ever needed more: the local AUHALs are
driven by the same hardware clock domain, so they stay locked by construction.
The LAN leg is the first consumer that has to state a time out loud, to a
machine with its own DAC clock.

**What we do.** `RingWriteClock` reconstructs the time base from the only two
things there are — the published write cursor and `Clock.nowNs()`, sampled
together on the producer timer:

- The pair is noisy in **one direction**: `now` is taken some unknown time
  *after* the last block was written, never before. That is the shape a
  **minimum filter** is for. Over a window of 200 observations (one second) the
  smallest `observed − predicted` is the one taken closest to a block boundary,
  and it is treated as the truth; the rest are discarded as scheduling delay.
- A window's minimum error drives a small phase correction on the anchor and a
  much smaller one on `nsPerFrame`. A **deadband** of 250 µs sits under both,
  so a producer running at exactly nominal rate produces exactly nominal
  timestamps rather than dithering the estimate forever.
- The anchor step is **capped at 50 µs per window** (1 % of a packet). The
  anchor is the packet timeline's origin, so moving it puts a step in
  `play_at_ns`; capping it keeps that step far below anything the receiver's
  water-level loop reacts to while still letting a large error walk itself out.
- The phase term exists for damping, not for accuracy: a rate-only (pure
  integral) correction of a phase error has a state matrix with determinant 1,
  which oscillates forever instead of settling.
- Beyond ±100 ms the model is discarded and re-anchored, and the event is
  counted. Non-zero during playback means the producer is stalling.

`play_at_ns = ringTime(frame) + target_ms`. Because the cursor advances only in
whole packets and never backwards, the timestamps are monotonic by
construction; a `max(previous + 5 ms, …)` guard covers the two seams where they
would not be (the handover out of a silence stretch, and a cursor re-anchor).

**Constant distance behind the producer.** `LanSendPlanner` holds the cursor
`ringFloor + 240` frames behind the write cursor and sends however many whole
packets have become available. At 48 kHz on a 5 ms timer that is one packet per
tick on average, occasionally zero or two as the timer and producer beat
against each other — and because the timestamps come from the frame number, a
tick that sends zero or two still produces a sequence that advances at exactly
the producer's rate. Bursts are capped at 4 packets per tick, and a cursor that
has fallen more than 250 ms behind is discarded rather than caught up (playing
a quarter second of stale audio is worse than a skip).

**Silence.** The system-sink path's Process Tap only fires while something is
rendering, so during silence the ring does not advance at all. Rather than let
the receiver's jitter buffer drain — an underrun burst the moment music
resumes, and nothing for its clock loop to lock to meanwhile — the producer
sends silence packets paced off the previous packet's play time. This is
distinguished from "the tick simply arrived a millisecond early", which must
NOT inject silence.

### Alignment with the local legs

Two budgets:

- A local AUHAL presents ring frame *F* at roughly
  `ringTime(F) + ringFloor + renderBlock + hardwareLatency`.
  `LocalOutput.render()` already equalises the hardware term across the enabled
  set (`compensation = maxLatency − myLatency`), so the whole local set shares
  one budget, built from the worst device.
- The LAN leg presents *F* at `ringTime(F) + target_ms`, by construction.

So when the target exceeds the local budget, every local leg is held back by
the difference. `LanAlignmentPlanner.localHoldFrames` computes it and
`LocalDelayTrimPlanner.offsetFrames` applies it as an `extraHoldFrames` term
**after** normalisation — it cannot be folded into the per-device seeds,
because normalisation subtracts the minimum and a constant added to every seed
would cancel to nothing.

The other direction is not correctable: nothing can be played early, so a
target *below* the local budget leaves the receiver late and the fix is a
larger target. Several receivers with different targets align to the largest,
for the same reason.

`LocalDelayTrim.maxOffsetMs` went from 500 ms to 800 ms as part of this. The
old ceiling was exactly the user range plus an honest hardware seed and left
the alignment hold with nothing, so a user at the top of the target slider
would have silently lost alignment to the clamp. 800 ms covers all three with
room to spare and is still far below what the ring can serve (~2.6 s).

### Honest latency expectations

The number the UI reports is `max(target_ms, local presentation lag)` — every
leg is aligned to whichever is slower — and it says so in the popover.

What that number does **not** include, stated plainly because it is the gap
between this figure and what a user measures with a clap test:

- the capture stage's own latency (the Process Tap or ScreenCaptureKit getting
  the application's audio into the ring), a handful of milliseconds;
- the application's own output buffering upstream of that;
- the receiver's DAC latency *beyond* what it compensates for — it adds
  `kAudioDevicePropertyLatency` + safety offset + buffer size to honour
  `play_at_ns` at the DAC, so this term should be near zero, but a device that
  misreports its latency misreports it here too.

At the 90 ms default on a wired LAN the local legs are held back by ~30-60 ms,
which is a visible lip-sync offset on video. That is the trade the slider
exists for, and it is why the range goes down to 30 ms.

### Security model

- **LAN only.** The sender refuses any peer outside RFC1918, link-local,
  loopback and their IPv6 equivalents, checked on the ready control connection
  before a single audio byte is sent. The link carries unencrypted PCM
  authenticated by a shared secret; that is a reasonable trade inside a home
  network and not one to make across the internet.
- **Shared token.** The receiver generates it, prints it in its log, and
  advertises only an 8-hex hint in its TXT record. The sender must send the
  full token in `hello`; a wrong one gets `error` and a close, which the row
  reports rather than retrying silently forever.
- **The token lives in the keychain**, one generic-password item per receiver
  under service `syncast.lanReceiverTokens.v1`, `kSecAttrAccessible` =
  `AfterFirstUnlockThisDeviceOnly`, never synchronised. It is never written to
  `UserDefaults`, never logged, and never put in the diagnostics line. The
  entry window sets `isRestorable = false` so AppKit state restoration cannot
  archive the field editor's contents to disk.
- Every inbound control field is validated at the boundary
  (`LanControlCodec`), the control read buffer is capped, and an unparseable
  line is logged and skipped rather than dropping a playing link.
- The TXT `token` hint is validated as exactly 8 hex characters before it is
  rendered — it comes from an unauthenticated LAN service and goes straight
  into the UI.
- `hello` carries a fixed sender name (`"SyncCast"`), not the machine's host
  name: it is transmitted to another machine and shown in its log.

### Failure policy

A dead receiver must never stall the local outputs, and nothing in the link
blocks. The connect is asynchronous, sends are fire-and-forget
(`.idempotent`, so Network framework does not even allocate a completion
continuation per packet), and a failure schedules a retry on the link's own
queue with 0.5/1/2/4/8 s backoff. The producer keeps running and keeps dropping
packets into a socket that is not ready, which is what a UDP leg should do.

`bye` is the one message worth waiting for — it stops the receiver immediately
instead of after its 5 s keep-alive timeout — so `stop()` tears down from that
send's completion rather than cancelling underneath it.

## Where it is not offered

- **Whole-home**: the LAN link is a different protocol on a different clock
  model. Whole-home fans OwnTone's single stream out to AirPlay receivers and
  has nothing to do with this.
- **Direct Stereo**: there is no capture ring — the HAL renders straight into a
  public aggregate and this process never sees the samples — so there is
  nothing to packetise. The row says so instead of offering a toggle that would
  do nothing.

## What was verified

By test, on this machine:

- Packet header against hand-assembled bytes, both directions, including the
  magic's on-wire byte order and the rejection of a wrong magic, a wrong frame
  count and a short buffer.
- Control JSON encode and decode for every message in both directions,
  including missing fields, unknown types, an over-long line, and the
  `NSNumber` bridging that a receiver writing `90.0` instead of `90` would
  produce.
- The NTP reduction, including rejection of quadruples that cannot be physical,
  and the estimator's minimum-RTT selection and EMA.
- `RingWriteClock`: exact 5 ms spacing at nominal rate, no movement inside the
  deadband, correct tracking direction for a 100 ppm producer, the rate clamp,
  the re-anchor threshold, and the minimum filter ignoring delayed
  observations.
- `LanSendPlanner`: first-tick anchoring, zero/one/two packets per tick, the
  burst cap, the stalled-timer re-anchor, an overwritten cursor, and that the
  cursor never moves backwards.
- `LanAlignmentPlanner`: the hold arithmetic, the non-negative floor, the
  reported lag, and that the worst case the UI can produce does not reach
  `LocalDelayTrim`'s ceiling.
- Peer validation across the IPv4 and IPv6 private ranges, including
  IPv4-mapped IPv6 and the boundary at `172.32.0.0`.
- End to end against an in-process fake receiver on loopback: the handshake and
  its token, a rejected token surfacing as an error rather than a silent retry,
  two seconds of synthetic ring audio arriving with contiguous sequence numbers
  and monotonic playout times one packet apart, the audio being the ring's
  audio rather than silence, the channel matrix and balance taking effect
  before packetising, `gain` and `latency` being sent on change and NOT on
  every re-push, pings producing a round-trip figure, and `bye` on stop.

**Not verified — the supervisor's job**: two real Macs, a real Wi-Fi hop, the
receiver daemon, its hardware-volume path, and whether 90 ms is actually the
right default on this network. Everything above is loopback and arithmetic.

## Known limits

- The end-to-end spacing assertion is a bounded tolerance rather than an exact
  5 000 000 ns, because the sender deliberately tracks the producer's real
  rate. The exact-nominal property is pinned on the model itself instead.
- `LanAlignmentPlanner.assumedRenderBlockFrames` is 512 rather than the AUHAL's
  real quantum, which the Router does not learn until it renders. An error of
  one block is ~10 ms of alignment error — at the edge of audibility for two
  speakers in one room, and far below the target's own tuning range.
- Several receivers with different targets align to the slowest; the faster
  ones are then early by the difference. The UI does not yet say which one is
  setting the pace.
- The producer sends silence packets while the tap is idle: ~197 kB/s of
  constant traffic while nothing is playing. Cheap on a LAN, but it is traffic.
- Discovery does not resolve the receiver's address itself; the link does, via
  the Bonjour endpoint, and only then checks that it is private. A receiver
  that resolves to a routable address is refused *after* the TCP connect, not
  before it.
