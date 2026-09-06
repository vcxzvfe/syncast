# LAN link — one timeline, and what to do when there is nothing to send (2026-09-06)

Follows `requirements_2026-09-05-lan-timing.md`, which moved the packet
timeline onto the capture hardware's own clock. The link was still wrong
afterwards, and this is what was left.

## Problem

Second two-machine run, music playing continuously. The receiver reported:

| figure | observed | meaning |
|---|---|---|
| `buffer` / `target` | 330 ms against a 300 ms target | the level was above the setpoint |
| ring fill | 812 ms | and the ring behind it was far worse |
| `p95jitter` | 840 ms | the arrival spread was not a network number |
| `trim` | pinned at −200 ppm | the loop was at its stop, draining as hard as it could |
| `reanchor` | error +77 ms, once a second | and still losing |

The sender's health line: `pkts:386437 silence:134069`. **35 % of everything
put on the wire was a synthesised silence packet, while music was playing
without interruption.** The audio was garbled at every latency target, which
is the signature of a timeline fault rather than a tuning one.

## Diagnosis

`LanReceiverOutput.tick()` sent a silence packet whenever the send plan
produced no packets and the ring's write cursor had not advanced *since the
previous tick*.

That test is wrong by construction. The capture backend writes a 512-frame
block every 10.67 ms; the producer wakes every 5 ms. Roughly every second tick
legitimately finds the write cursor exactly where it left it, and the audio
for that slot is a millisecond away. So the "producer is idle" branch fired
about half the time, and once the cursor had caught up to `writePosition − lag`
it injected a 5 ms packet stamped `lastPlayAt + 5 ms` — **from wall clock**.

Real packets are stamped `timeOf(frame) + target` from the capture hardware's
clock. So two timelines went down the same socket, interleaved, overlapping in
time. The receiver scheduled both. It therefore received about 8 % more audio
per second than the sender's ring produced; the level ran away; the PI loop
saturated at its −200 ppm stop trying to drain it; the level error crossed the
re-anchor threshold once a second; and the two streams played on top of each
other.

## What changed — sender

**One timeline, no exceptions.** Every packet's `play_at_ns` is derived from a
ring frame index through the host-anchor clock, and the cursor advances by
whole packets for every packet sent. `sendSilencePacket()` is gone entirely —
not kept in a variant — because the receiver already renders what it does not
have as silence, and that needs no packet to say it.

**Idleness is a property of the ring, not of a tick.** `ProducerIdleDetector`
(new, pure, unit-tested) reports `running` / `idle` / `resumed` from
`(writePosition, now)`: the producer is idle once the write cursor has stood
still for `idleThresholdMs` (100 ms — ten capture blocks, an order of magnitude
above the beat between the two rates, and well inside the receiver's buffer).
While idle the sender sends nothing at all and counts the tick.

**The resume edge.** `LanSendPlanner.resumeCursor` jumps the cursor to
`writePosition − lag` on the tick where the producer starts again, if it is
more than `lag + 2 packets` behind. A ring that simply froze leaves no stale
frames, so the common pause costs nothing; the guard is for a backend that
flushes a backlog on resume, where replaying it would be a burst of stale
timestamps ahead of the audio about to arrive. Counted as `gapSkips`, kept
separate from the planner's own 250 ms drift `resync`.

**The fallback estimator is no longer fed noise.** `RingWriteClock` used to be
handed a frozen write cursor paired with an advancing `now` on every idle tick.
That pair carries no rate information at all, only phase error, and it made the
estimator re-anchor every 100 ms for the whole of a silent stretch. Observations
are now skipped while idle; the single re-anchor on resume is the honest one.

**Tick timing is unchanged and deliberately so.** A tick may land before the
next block; it emits however many whole packets exist (0, 1 or 2) and never
infers anything from a single tick.

**Diagnostics.** `silence:` is kept but repurposed: it now counts packets whose
payload came out of the per-device chain digitally silent — a fact about the
programme rather than an invention of this layer — and must be 0 during
playback. Added: `idle:` (ticks spent while the producer was judged idle) and
`gapSkips:`. Also `refused:<overlap>/<far_future>`, echoed back from the
receiver, because both of those faults are the sender's.

## What changed — receiver (defensive)

The receiver could not have been expected to play that stream, but it should
have said so rather than trying.

* **`overlap`**: a packet whose frames overlap audio the ring already holds is
  refused and counted, not written over the first copy. Telling that apart from
  legitimate reordering needs an occupancy mark per ring frame: a hole is
  zero-filled and left unmarked, so a late packet still fills the hole left for
  it, while a second timeline claiming an occupied slot is refused.
* **`far_future`**: a play time more than 2 s past the newest buffered frame is
  refused rather than re-anchored onto. The existing one-ring discontinuity
  recovery is untouched; this only catches timestamps no schedule can absorb.
* Both go out in `stats` (decoded leniently, so mixed builds still talk) and
  are logged at WARN, rate-limited to the 1 Hz stats tick, saying which side
  the fault is on.
* **Idle**: after 500 ms with no packets the engine renders silence without
  counting underruns, without running the clock loop and without re-anchoring.
  The first packet back resets the stream and re-anchors once, silently, primed
  to the target — so a paused programme costs no splice on resume, and the
  resumed audio is not measured against a schedule that stopped seconds ago.
* **A starvation splice is suppressed on a render block that brought no new
  audio.** Delivery has stopped, so re-anchoring lands the cursor on the same
  empty ring having thrown away loop state that was tracking the sender's clock
  correctly.

## What was verified

Sender (`core/router`, 423 tests, plus `apps/menubar`, 338):

* A new `.bursty` synthetic producer writes whole 512-frame blocks, each held a
  random 0–4 ms before release, with the block's anchor still carrying its
  nominal device time. The old harness wrote whatever was due every 2 ms, so
  the write cursor never stood still and the fault could not be reproduced.
* Ten seconds of that: packets sent match the ring's frames to within the
  partial packet at each end, **zero** silent packets, strictly monotonic
  `play_at_ns` exactly 5 ms apart, contiguous sequence numbers, and a lead that
  drifts less than 5 ms over the window. (The old fault grew it by tens of
  milliseconds a second.)
* A two-second stall: nothing goes on the wire, the sender notices, the
  resumed stream leaves exactly one hole and no overlapping timestamps, and the
  level is back within 10 ms of where it belongs.

Receiver (`swift test`, 143 tests; `--selftest`, four scenarios, PASS):

* "sender idles 2 s then resumes" and "duplicate/overlapping timeline" are new
  `--selftest` scenarios and also run under XCTest.
* The overlap guard is checked both ways: a second timeline is counted and
  never reaches the DAC, and reordering still fills its hole.

**Not verified on hardware.** Everything above is simulated. The two-machine
run that produced the numbers at the top has not been repeated; the field
check is `silence:` and `idle:` on the sender's line (silence 0 during
playback) and `overlap`/`far_future` staying 0 on the receiver's.

## Known limits

* The 100 ms sender idle threshold and the 500 ms receiver idle threshold are
  independent. A pause between 100 ms and 500 ms stops the sender but is read
  by the receiver as ordinary starvation, so it drains and counts underruns
  until the buffer empties. That is correct — the audio really is missing — but
  it means a rapid pause/resume cycle still costs underruns.
* `far_future` at 2 s is looser than the ring (1.365 s), so a discontinuity
  between those two figures is still recovered by re-anchoring rather than
  refused. That is deliberate; the refusal is only for timestamps that no
  buffer could hold.
* The lead figure the sender-side tests assert on is a proxy for the receiver's
  buffer level, not the level itself: the fake receiver has no jitter buffer.
  The buffer's own behaviour is pinned on the receiver side instead.
