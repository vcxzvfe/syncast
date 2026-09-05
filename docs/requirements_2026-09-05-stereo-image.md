# Per-device stereo image (2026-09-05)

Track G of the 2026-09-05 round. Branch `feat/stereo-image`.

## 1. Problem

The target is a compact stereo speaker: two tweeters roughly 15–20 cm apart
above a single shared mono woofer, listened to from about 65 cm, head-on, from
a fixed seat. Two things follow from that geometry, and they are the whole
brief:

1. **There is stereo information only in the tweeter band.** The cabinet sums
   L+R into the woofer, so below the internal crossover (call it 1.5–2 kHz)
   there is no left/right difference to work with at all. Anything that claims
   to "widen the bass" on such a speaker is moving a signal that does not
   exist, or is lifting room-coupled energy under the guise of width.
2. **The two tweeters subtend a very small angle at the listening position.**
   Each ear hears both of them at almost the same level, only tens of
   microseconds apart. That acoustic crosstalk is what collapses the image to a
   point between the drivers; a level-only "wider" control cannot undo it.

So: a per-device module with two stages, each individually switchable, plus one
A/B bypass for the whole thing. Applied per physical output, remembered against
that output's CoreAudio UID, re-applied on every connect — the same contract the
per-device equalizer already established.

## 2. Design

### 2.1 Where it runs

Immediately **after** the equalizer and **before** the gain stage, in both
render paths that SyncCast owns:

```
ring read → splat per pair → [EqualizerBank] → [StereoImageProcessor] → gain/mute → AUHAL
```

- After the equalizer, so the mid/side split works on the signal the user has
  already tone-shaped. The other order would re-widen into the side channel
  whatever a bass cut had just removed from it.
- Before the gain stage, so the volume slider stays the last attenuator — the
  same rule the equalizer follows, and for the same reason.

**Coverage**, stated plainly:

| Path | Imaged | Why |
|---|---|---|
| Local Stereo, system-sink leg | yes | samples pass through `LocalOutput.render()` |
| Local Stereo, ScreenCaptureKit leg | yes | same render path |
| Local Stereo, **Direct Stereo** leg | **no** | the HAL renders straight into the public aggregate; SyncCast never sees a buffer |
| Whole-home, local outputs | yes | each has a `LocalAirPlayBridge` running the same processor on the same UID-keyed setting |
| Whole-home, **AirPlay receivers** | **no** | see below |

The equalizer offers a single *group* curve for all AirPlay receivers, applied
upstream of OwnTone's fan-out. This module deliberately does **not**. "Less
bass" survives being shared across a house; "cancel the path from the left
driver to my right ear" does not — it is a statement about one cabinet and one
seat, and imposing one room's numbers on every receiver would be worse than
offering nothing. The UI therefore hides the control on the one local path that
cannot carry it, and never shows it on a receiver row at all.

### 2.2 Stage 1 — mid/side width

`M = (L+R)/2`, `S = (L−R)/2`. The side signal is passed through a second-order
Butterworth high-pass at the user's corner (default 1500 Hz), and the
**high-passed part** is scaled:

```
S' = S + (width − 1)·HP(S)
L' = midGain·M + S'      R' = midGain·M − S'
```

- Below the corner `HP(S) ≈ 0`, so `S' ≈ S`: the side signal is left alone,
  which is exactly what §1.1 asks for.
- Well above the corner `HP(S) ≈ S`, so `S' ≈ width·S`.
- At `width = 1` the expression is *identically* `S`, at every frequency, with
  no phase shift. That matters: it means the control is continuous through
  unity rather than jumping from "no processing" to "allpass-filtered side
  channel" the moment the slider leaves 1.00. A conventional crossover-based
  width control cannot say that.
- **Mono-compatible by construction.** `L' + R' = 2·midGain·M` for any width,
  so no amount of widening can cancel when a downstream device sums to mono.
  Asserted at the sample level in `testPureMidSignalIsUnchangedAtAnyWidth`.

Cost: in the transition region the achieved gain is short of `width`, because
one octave above a second-order corner the high-pass is at 0.97 with 43° of
phase, so the sum `1 + (width−1)·H` is a little under `width`. Measured, at
corner 1500 Hz and width 1.4: **−0.58 dB** short at 3 kHz, **−0.05 dB** short at
9.6 kHz. That is the price of "untouched below the corner" and it is deliberate.

`midTrimDb` (−1…0 dB, default 0) attenuates the mid only, as loudness
compensation for a widened side signal. It cannot change the mono sum's
*balance*, only its level.

Ranges: width 0…2 (step 0.05, default 1.4), corner 200…6000 Hz (step 50,
default 1500), mid trim −1…0 dB (step 0.1, default 0).

### 2.3 Stage 2 — recursive crosstalk cancellation (RACE)

For each output channel, subtract the opposite channel's **own output**,
delayed by τ and attenuated by `a`:

```
L' = L − a·z^(−τ)·R'
R' = R − a·z^(−τ)·L'
```

Recursive rather than a single feed-forward subtraction, because the correction
itself crosses to the far ear and needs correcting in turn. The closed form is

```
L' = (L − a·z^(−τ)·R) / (1 − a²·z^(−2τ))
```

whose poles sit strictly inside the unit circle iff `|a| < 1`. That is why `a`
is *clamped* there (`StereoImageLimits.maxFeedbackAmplitude = 0.95`) rather than
merely documented as "should be" — the render thread must not be able to run an
unstable structure whatever a corrupt store hands it.

**τ from geometry.** With the head facing the cabinet, the extra distance from
one driver to the far ear over the near ear is `span · earSpacing / distance`
(small-angle), and

```
τ = span · earSpacing / (distance · c),   earSpacing = 0.15 m, c = 343 m/s
```

At the defaults (span 0.17 m, distance 0.65 m) that is **114 µs ≈ 5.5 samples at
48 kHz**. Exposed read-only in the panel as `计算延迟 114 µs（5.5 采样 @48 kHz）`,
because it is the one number the user does not set directly and watching it move
is what makes the two geometry sliders legible. The model is good to a few
percent for a narrow cabinet at desk distance; it is the *scale* of τ that
matters, and either slider trims it.

τ is clamped to **at least one whole sample**. This is load-bearing, not
cosmetic: the recursion reads its own past output, so a delay below one sample
would need the sample being computed. Extreme geometry (a very narrow cabinet
very far away) is held at one sample and the UI reports what is actually in
force.

**Fractional delay: linear (first-order Lagrange) interpolation.** τ is not a
whole number of samples, so the recursion reads its delay line through
`(1−d)·x[n−k] + d·x[n−k−1]`.

Chosen over a Thiran allpass deliberately. A first-order allpass has magnitude
exactly 1, which is nicer for accuracy but leaves loop stability resting on the
allpass's own pole placement as well as on `|a| < 1`. Linear interpolation has
magnitude **≤ 1 at every frequency**, so the loop gain is bounded by `a²` and
stability needs no argument beyond `|a| < 1` — a stronger guarantee for a
structure the user can push to `a = 0.89`.

The price is a first-order lowpass on the crosstalk path. Its magnitude is
`sqrt(1 − 2d(1−d)(1−cos ω))`; worst case (`d = 0.5`) that is **−0.25 dB at
3.5 kHz and −0.95 dB at 7 kHz**. The effect is to *under*-cancel slightly at the
top of the band rather than overshoot, which is the conservative direction for
an effect whose failure mode is a phasey, unstable image. It is measurable and
is measured: `testCorrelatedContentSeesTheDocumentedColourationPeak` predicts
the resulting peak from the interpolator's magnitude and matches within 0.4 dB.

**Band limiting.** Below `lowHz` there is no usable interaural difference to
correct (and on this cabinet no stereo content at all); above `highHz` head
shadowing and pinna effects make the simple two-tap model wrong. The band is
split off with matched second-order Butterworth sections and the remainder
carried around the stage:

```
band = LP(HP(x));   rest = x − band;   out = rest + RACE(band)
```

`rest = x − band` rather than a second filter chain, so the two sum back to the
input **exactly** when the recursion is a no-op — no crossover phase error, no
summing dip at the band edges. What the out-of-band signal does see is the
recursion's effect leaking through the filters' skirts, falling at 12 dB/octave
away from each edge; measured within 0.1 dB at 60 Hz below a 1500 Hz low edge
and at 20 kHz above a 2 kHz high edge.

Two configurations skip a half of the split entirely, because there is nothing
to separate: the low edge at its minimum (20 Hz) means "no low edge", and a high
edge at or above 45 % of the sample rate cannot be realised as a meaningful
second-order section. Both are real user settings, not test hooks — and they are
what lets the impulse-response test observe the recursion on its own.

Ranges: attenuation −6…−1 dB (step 0.1, default −2.5), strength 0…1 (step 0.05,
default 0.6), span 5…60 cm (default 17), distance 20…300 cm (default 65), low
edge 20…4000 Hz (default 1500), high edge 2000…24000 Hz (default 7000). The high
edge is pushed up if the low edge is dragged past it, so the band can never
collapse or invert.

### 2.4 The colouration this structure inherently has

`strength` scales the **linear** `a` (so 0 is a true bypass; scaling the dB
value would make 0 dB the *strongest* setting). It is the dial the user is
expected to move, and it is there because of this:

For content common to both channels, the recursion's transfer is
`1/(1 + a·z^(−τ))`, which peaks at `1/(1−a)` at `f = 1/(2τ)` — **4.4 kHz** at
the default geometry, right in the middle of the processed band. At `a = 0.75`
(−2.5 dB, full strength) that is **+12 dB on centred material**. That is not a
bug; it is what RACE does, and it is the reason the default strength is 0.6
rather than 1.0 (+5.2 dB instead) and the reason the panel prints
`中置内容在 4.4 kHz 附近最多 +X dB` next to the sliders. It is also what drives
the output limiter.

The panel's figure is computed from the closed form and is therefore very
slightly **pessimistic** relative to what is heard (the interpolator shaves
about 1 dB off it at the peak). Erring towards over-warning is the right
direction; `testCorrelatedContentSeesTheDocumentedColourationPeak` asserts the
sign of that error so it cannot silently flip.

### 2.5 Sweet-spot sensitivity

Crosstalk cancellation only works from the position it was computed for. Moving
one ear-width off axis, or turning the head, replaces cancellation with a comb
filter. That is inherent to the technique and is why:

- the control is per-device and per-listener geometry, not a global preset;
- `strength` exists at all, as a way to trade image width for robustness;
- the A/B bypass is prominent — the only instrument that can judge this is the
  listener, from their actual seat.

The width stage has no such restriction: it is position-independent and
mono-safe, which is why it is the first stage and why it is usable on its own.

### 2.6 Real-time safety

`StereoImageProcessor` mirrors `EqualizerBank` exactly, because the constraints
are identical:

- **No allocation.** Parameters, filter state, delay lines and two
  double-precision working buffers are heap-allocated once at `init` and indexed
  directly. Swift arrays would be copy-on-write, and a COW copy on the render
  thread is a heap allocation in an audio callback.
- **No locking in steady state.** One atomic load per pair per block. The
  `paramLock` is taken only on the block that adopts a publish, for a fixed-size
  copy.
- **All transcendental work on the app thread.** `setSettings()` computes the
  Butterworth coefficients and the derived delay; `process()` does arithmetic
  only.
- **Two parameter banks + a 20 ms crossfade** on every change, with the incoming
  bank's filter state *and delay line* seeded from the audible one so a slider
  drag is continuous rather than a restart of a recursion.
- **Bit-identical bypass.** A neutral pair — both stages off, or width exactly 1
  and strength 0, or the whole module bypassed — exits on the flag check and
  leaves the buffer byte-for-byte as it found it.
- **Clamp + counter.** Output is hard-limited to ±1 with a NaN backstop, and
  clamped samples are counted for the panel's clip indicator. The feedback path
  additionally has a per-sample finite check, denormal flush and a ±32 ceiling —
  a per-sample guard is worth it in a recursion in a way it is not in a
  feed-forward chain, because anything that gets into the delay line stays in it.
- **Stereo only.** Both stages are statements about a left/right pair; a pair
  that is not stereo is left alone rather than half-processed.

### 2.7 Persistence and re-application

- `UserDefaults` key **`syncast.deviceStereoImage.v1`**, JSON array of
  `DeviceStereoImageProfile`, keyed by CoreAudio UID. Separate from
  `syncast.deviceEqualizer.v1`: the two are edited, reset and bypassed
  independently.
- Load boundary validates everything: clamp into range, snap to the UI grids,
  drop non-finite values, drop empty/duplicate UIDs, drop records that say
  nothing. Unreadable data collapses to "no settings". A **bypassed** record is
  kept — losing the setting behind the A/B switch would defeat the switch.
- `Router` holds the whole UID → setting map and re-applies it in
  `applyStereoImages()` on every `reconcileLocalDriver`, every `replan`, and
  every bridge rebuild. Idempotent, so it rides along with existing reconciles
  rather than needing its own trigger.
- `AppModel` pushes the full map (debounced 50 ms) after every edit, and again
  on engine start and on every local-output reconcile.

## 3. UI

A `声场` button on each eligible device row, next to the EQ button, opening an
inline panel (not a nested popover — the whole UI is a `MenuBarExtra(.window)`).

- Header: `声场` + a prominent **A/B 旁路** switch that bypasses the whole module
  without losing anything.
- `宽度` section: on/off, plus 展宽 / 起始 / 中置补偿 sliders.
- `串扰消除` section: on/off, plus 听距 / 单元间距, the read-only 计算延迟 line,
  then 衰减 / 强度 / 频段下限 / 频段上限, and the colouration warning.
- Footer: `重置` (both stages off, values back to default — this deletes the
  stored record), the clip indicator, `收起`.

Turning a stage on moves it off its no-op value (width → 1.4, strength → 60 %),
because a switch that visibly turns on and changes nothing is the worst possible
first impression of the feature.

A row whose stored setting the current path cannot apply says so
(`stereoImageInactiveHint`) rather than looking as if it were in effect.

## 4. What is verified

**By test** (`StereoImageProcessorTests`, 24 cases;
`DeviceStereoImagePersistenceTests`, 23 cases):

- neutral and bypassed settings are **bit-identical** pass-throughs, including
  the "both stages on but at no-op values" case;
- a pure mid signal (L == R) is unchanged at width 0, 0.5, 1.4 and 2.0 — the
  mono-compatibility claim, at the sample level;
- side gain at 9.6 kHz is `width` within 0.2 dB, at 3 kHz within 0.7 dB, and at
  300 Hz is unity within 0.3 dB;
- the mid trim moves the mid by −1 dB and the side by 0 dB;
- an impulse in L alone produces `−a` at τ in R and `+a²` at 2τ back in L, by
  tap area, within 1e-5, with nothing arriving before τ;
- 10 s of noise at the strongest legal setting (`a = 0.891`) stays finite and in
  range, and decays below 1e-5 within a second of silence;
- out-of-band tones pass within 0.1 dB on both edges;
- the colouration peak matches the closed form corrected for the interpolator's
  magnitude, within 0.4 dB, and never exceeds what the UI warns;
- the limiter counts and the output stays inside ±1;
- a parameter change mid-stream stays below twice the signal's own maximum
  sample-to-sample step (i.e. it is crossfaded, not stepped);
- re-publishing identical settings is a no-op; out-of-range pairs and oversized
  blocks are refused rather than fatal;
- persistence round-trips, clamps garbage, snaps to the UI grid, keeps a
  bypassed record, deletes on reset, refuses AirPlay rows, and survives a new
  `Device.id` for the same UID.

Build/test: `swift build` + `swift test` clean in `core/router` (298 XCTest +
11 swift-testing) and `apps/menubar` (279 XCTest).

**Not verified — the user's ear.** Whether the image actually widens, whether
the crosstalk stage helps or just sounds phasey, and what strength is right for
a given seat are listening questions. Nothing here was auditioned; the defaults
are the conservative end of the published ranges for this technique, and the A/B
bypass exists so the judgement can be made in one click.

## 5. Known limits

- Sweet-spot only, by construction (§2.5). Off-axis, the crosstalk stage combs.
- The recursion colours centred content near `1/(2τ)` (§2.4). Band-limiting
  keeps it out of the bass but not out of the midrange; `strength` is the
  control for it.
- The width stage's transition band falls short of the set width by up to
  ~0.6 dB an octave above the corner (§2.2).
- The path-difference model is small-angle and assumes a head-on listener with
  an average ear spacing. It is a starting point the two geometry sliders are
  expected to trim by ear, not a measurement.
- No AirPlay group setting, deliberately (§2.1).
- Not available on Direct Stereo, like the equalizer, because SyncCast never
  sees those samples.
- Blocks longer than 4096 frames are passed through unprocessed rather than
  served from a short scratch buffer. Device quanta are 512–2048 in practice.
