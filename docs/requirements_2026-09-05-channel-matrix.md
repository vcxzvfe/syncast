# Per-device channel assignment (声道分配) — 2026-09-05

## The problem

A stereo program played on two independent outputs is not always wanted as a
stereo pair.

- A speaker sitting alone on the left of a desk should carry the **left**
  channel — on both of its own drivers, because it is one cabinet, not one half
  of a pair.
- A bedside speaker with one usable driver wants **L+R summed**, not whichever
  half of the mix the HAL happens to hand it.
- A display whose panel speakers exist for dialogue wants the whole program,
  summed and attenuated.

Nothing in the app expressed any of that. The per-device fader sets how loud an
output is; nothing set *what it plays*. With the LAN receiver landing in the
same round — a second Mac's speakers becoming one leg of the local pair — the
gap became the obvious one: the entire point of putting a receiver on the other
side of the room is to give it one channel.

## Design

One 2×2 gain matrix per output, applied per output channel pair:

```
out.L = m[0][0]·in.L + m[0][1]·in.R
out.R = m[1][0]·in.L + m[1][1]·in.R
```

| Preset | Matrix | Meaning |
|---|---|---|
| 立体声 | `[[1,0],[0,1]]` | untouched — the default, and a bit-identical pass-through |
| 左 | `[[1,0],[1,0]]` | both output channels carry the source's left channel |
| 右 | `[[0,1],[0,1]]` | both carry the right channel |
| 单声道 | `[[.5,.5],[.5,.5]]` | L+R summed at −6.02 dB each |
| 自定义 | four decibel sliders | −∞…+6 dB per cell |

**左 is not `[[1,0],[0,0]]`.** The target is one cabinet with two drivers;
silencing one of them would make it quieter and lopsided rather than "playing
the left channel".

**单声道 sums at exactly 0.5, not at 1/√2.** Correlated full-scale content then
lands at exactly full scale rather than clipping, which matters because that is
precisely the content people sum to mono.

**The bottom of the custom slider is −60 dB and means exact silence.** A real
number rather than `-inf` because `JSONEncoder` refuses infinity by default, and
far enough down that treating it as silence is inaudible rather than a lie.

### Where it sits on the signal

After the equalizer, after the stereo image, **before** the gain stage — in
`LocalOutput.render()` (per channel pair), `LocalAirPlayBridge.render()` (one
pair) and `LanReceiverOutput`'s producer (one pair).

Order matters both ways round: the matrix routes what the tone curve and the
imager produced, so "this speaker plays the left channel" means the *processed*
left channel; and the volume slider stays the last thing on the signal, so a
boosted coefficient that would clip at unity does not clip once the user turns
it down.

### Real-time behaviour

`ChannelMatrixBank` follows `EqualizerBank`'s contract — no allocation, no
CoreAudio calls, a generation-counted publish read under a lock only on the
block that adopts it — with one deliberate simplification.

The other two banks run **two parallel chains** during a change and crossfade
their outputs, because a biquad and a recursive delay line carry state: you
cannot interpolate their parameters without interpolating a filter into
something that is not the filter you wanted.

A channel matrix is memoryless and linear, so the two are identical here:
crossfading `A·x` with `B·x` by weight `w` gives `((1−w)A + wB)·x`, which is
exactly the interpolated matrix applied once. One multiply-add chain, no second
bank, no state to seed — and the same 20 ms feel as the other two panels, which
is what the user actually perceives. A publish that lands mid-ramp glides on
from wherever the interpolation currently is, so dragging a slider is one
continuous move rather than a step back to the previous matrix.

Output is hard-clamped to ±1 with a lock-free count, surfaced as `matClip:<n>`
in the diagnostic line — a matrix can sum two full-scale channels or boost by
up to +6 dB, and handing CoreAudio a value outside ±1 is far worse than
clamping.

At 立体声 the bank exits on one atomic load plus four float compares and leaves
the buffer byte-identical, so a user who never opens the panel gets the
pre-feature render path bit for bit.

### Scope

Every leg whose samples this process renders — which is one leg **wider** than
the stereo imager's:

- Local Stereo on the system-sink and ScreenCaptureKit legs (`localOutputs`),
  individual or aggregate;
- the LAN receiver legs, whose producer applies the matrix before packetising,
  because the receiver plays what it is sent;
- whole-home local outputs (`localBridges`), under the same UID key, so a
  speaker assigned in Stereo stays assigned in whole-home.

**Not** the whole-home AirPlay leg: OwnTone's fan-out sends one stream to every
receiver, so a matrix applied upstream would put the same channel assignment on
the whole house. **Not** Direct Stereo, where the HAL renders straight into a
public aggregate and we never see the samples — the row says so rather than
offering a control that would silently do nothing.

### Persistence

`syncast.deviceChannelMatrix.v1`, JSON in `UserDefaults`, keyed by output UID —
a *cabinet*'s property, not a session's, so `Device.id` (re-minted every
process) cannot carry it.

The UID space is wider than the equalizer's and the imager's: a LAN receiver's
`lan:<bonjour instance name>` is a legal key. The `lan:` and `ca:` namespaces
are what keep the two from colliding in the one map the Router holds.

Unlike the other two stores there is no bypass to keep alive behind a
"says nothing" record: a channel assignment has no A/B switch, because 立体声
IS the A. So a record that normalises to 立体声 is dropped.

`Router.applyChannelMatrices()` re-pushes the whole map at the end of every
`reconcileLocalDriver` and every `replan()`, both idempotent, which is what
makes a re-plug, a re-enable or an aggregate rebuild pick the assignment
straight back up.

### UI

A 声道 button in the device row next to EQ and 声场, under the same rule: shown
only where the assignment would actually be applied, because a control that
silently changes nothing is worse than no control. The panel is a segmented
preset picker, and the four decibel sliders appear only for 自定义 — the named
presets cover every case anyone has asked for, and four coefficients is a
question most people never ask. Choosing 自定义 seeds the sliders from whatever
the user was hearing, so it is a continuation rather than a jump to silence.

## What was verified

By test, on this machine (23 cases in `ChannelMatrixTests`, 18 in
`DeviceChannelMatrixPersistenceTests`):

- Each preset produces the expected samples through the shipping `process()`
  entry point with a hand-built channel pointer table and no CoreAudio device.
- 单声道 does not clip correlated full scale.
- 立体声 is bit-identical, including for values a stray multiply-by-1.0 would
  perturb.
- The custom decibel ↔ amplitude round trip across the whole slider range, and
  that seeding 自定义 from a preset reproduces that preset's matrix.
- Non-finite and out-of-range decibels fail quiet (silence, never a boost); an
  unknown preset string decodes as 立体声; a missing field decodes to its
  default; settings survive a JSON round trip.
- The limiter clamps and counts; NaN input is zeroed and counted.
- A change is ramped rather than stepped, the ramp retires, and pairs are
  independent.
- The store: round trip, stable sorted blob, absent/unreadable data, clamping
  and snapping on load, presets NOT snapped (which would lose the exact
  constants), empty and duplicate UIDs, records that say nothing, and that a
  `lan:` UID is a legal key that cannot collide with a `ca:` one.

**Not verified**: how any of it sounds. That is the listener's job, and the
whole reason the control exists.

## Known limits

- The clip counter belongs to the AUHAL, not to the pair, so in aggregate mode
  every member device reports the aggregate's total. The UI says "输出链"
  rather than claiming a per-speaker figure that does not exist.
- There is no A/B bypass. 立体声 is the comparison, and it is one click away.
- The custom sliders are per-cell decibels, not a rotation or a width control.
  Anyone wanting mid/side manipulation has the stereo-image panel for it.
