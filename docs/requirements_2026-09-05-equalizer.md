# Per-device equalizer (2026-09-05)

Track C of the 2026-09-05 round. Branch `feat/per-device-eq`.

## 1. Problem

Verbatim ask:

> 能不能实现针对各个设备（音响的）的调音器？（就是各个 dB 的调节）比方说我有一个音响的低音太厉害了我想调节，这个东西长期记忆在这个设备上，每次连接都默认这样。

Three requirements fall out of that sentence:

1. **Per device, not global.** One speaker in the group is bass-heavy; the
   others must not move. SyncCast already renders each physical output from its
   own channel pair, so the shaping has to happen there, not on the shared
   source.
2. **In decibels, per band.** The user's mental model is a graphic equalizer —
   a row of dB sliders — not a parametric filter designer.
3. **Remembered on the device, applied on every connect.** Not "for this
   session", not "for this window": plug the speaker in tomorrow and the curve
   is already there.

## 2. Design

### 2.1 Where it runs

Inside `LocalOutput.render()`, per output channel pair, **after** the ring read
and the stereo splat and **before** the gain/mute stage.

```
ring.read → splat into every channel pair → [EqualizerBank per pair] → gain/mute → AUHAL
```

- After the splat, because that is where each physical device first has its own
  copy of the samples. In aggregate mode, pair `p` is subdevice `p`.
- Before the gain stage, so the user's volume slider stays the last attenuator.
  A boost that would clip at unity therefore stops clipping when they turn
  down, which is what people expect.

**Coverage**, stated plainly because a hidden control is only acceptable if the
reason is:

| Path | Equalised | Why |
|---|---|---|
| Local Stereo, system-sink leg | yes | samples pass through `LocalOutput.render()` |
| Local Stereo, ScreenCaptureKit leg | yes | same render path |
| Local Stereo, **Direct Stereo** leg | **no** | the HAL renders straight into the public aggregate; SyncCast never sees a buffer |
| **Whole-home** (AirPlay 全屋) | **no** | audio flows OwnTone → `LocalAirPlayBridge`, a different render path, deliberately out of scope |
| AirPlay receivers | **no** | their audio is produced by OwnTone, not by us |

The UI hides the control on those paths rather than showing an inert one, and a
row that HAS a stored curve which is not currently being applied says so
(`AppModel.equalizerInactiveHint`).

### 2.2 Filters

`EqualizerSettings.swift` — pure model plus RBJ ("Audio EQ Cookbook")
coefficient math, Q form for all three shapes:

- `EqualizerBand` = kind (`peaking` / `lowShelf` / `highShelf`) + frequency + Q
  + gain in dB. Fully parametric, so a later parametric editor needs no store
  migration.
- `EqualizerSettings` = `bypassed` + `trimDb` (pre-gain) + `[EqualizerBand]`.
- **Default layout** (`EqualizerSettings.graphicFlat`): ten ISO octave centres
  31.5 / 63 / 125 / 250 / 500 / 1k / 2k / 4k / 8k / 16k Hz, all peaking,
  Q = 1.41 (constant-Q, about one octave between the −3 dB points), range
  ±12 dB in 0.5 dB steps. Trim range ±12 dB.
- Every coefficient set is checked for stability at construction (Jury test for
  a second-order section: `|a2| < 1` and `|a1| < 1 + a2`). Anything the
  formulas are not defined on — non-finite input, a corner at or above Nyquist,
  a degenerate Q, a non-positive sample rate — collapses to identity rather
  than producing NaN, because a NaN section poisons the filter state
  permanently.

### 2.3 Real-time safety

`EqualizerBank.swift` runs on the CoreAudio render thread.

- **No allocation.** All storage (coefficients, TDF-II state, two
  double-precision working buffers) is heap-allocated once at `init` and
  indexed through raw pointers, for the same reason `LocalOutput._softwareGains`
  is: a Swift `Array` is copy-on-write, and a COW copy in an audio callback is
  a heap allocation.
- **Coefficients are computed on the app thread.** `BiquadCoefficients.make`
  uses `pow`/`sin`/`cos`; those are called in `setSettings()` and the results
  are handed over through a staging buffer.
- **Publication is generation-counted.** `setSettings` fills the staging slot
  under an `OSAllocatedUnfairLock`, then bumps a release-ordered atomic. The
  render thread loads that atomic (acquire) per pair per block and takes the
  lock **only** on the block where it differs — so steady state is two atomic
  loads per pair per block and no lock at all. `os_unfair_lock` is the
  priority-inheriting Darwin lock, and it is already the pattern the render
  callback uses for `_gain` / `_softwareGains`.
- **Fast path.** A pair whose curve is flat or bypassed returns immediately and
  leaves the buffer byte-identical to what the splat wrote. Verified by
  `testFlatBankLeavesTheBufferBitIdentical`. Installing the feature costs a
  user who never touches it nothing measurable.
- **Denormals** in the stored state are flushed at 1e-15 (≈ 300 dB below full
  scale, i.e. inaudible by construction) so a resonant low band does not fall
  off a performance cliff when the track goes quiet.

### 2.4 Smoothing (why two banks, not interpolated coefficients)

Swapping biquad coefficients under a running filter puts a step discontinuity
in the output — the classic tick when a slider is dragged. Linearly
interpolating between two coefficient vectors is the cheap fix but has no
stability guarantee in general, so instead each pair owns **two** coefficient
banks:

1. a publish lands in the idle bank;
2. its filter state is seeded from the audible bank's state when the chain
   shape is unchanged (the normal case — the graphic layout keeps a fixed band
   list and only a gain moved), so a one-slider edit keeps nine settled
   filters and only the moved band has anything to converge;
3. both chains run for 20 ms and their outputs are linearly crossfaded;
4. the incoming bank becomes audible.

Both chains are independently stable by construction, which is exactly the
property interpolation would not give. Cost is 2× filter CPU for 20 ms per
edit. `testCurveChangeIsSmoothed` asserts the largest sample-to-sample jump
across a flat → (−12 dB × 2 bands, −12 dB trim) switch stays within 3× the
source sine's own maximum step.

Sections sit at their band's index with an identity section for a band at
0 dB. An identity RBJ section is `y = x` with permanently zero state, so it is
skipped in the inner loop and costs nothing — while the stable indexing is what
makes state carry-over legal.

### 2.5 Clip protection

After the chain, the double-precision result is converted back to Float32 with
a hard clamp to ±1.0 and a lock-free count of the clamped samples
(`sc_atomic_fetch_add`). Non-finite samples become silence, so one bad block
cannot become permanent noise. The count is surfaced two ways:

- `LocalOutput.glitchSummary()` appends ` eqClip:<n>` **only when non-zero** — a
  permanent `eqClip:0` in every diagnostic line would train the reader to skip
  the column that matters;
- the editor shows 「输出削波，建议降低总量」 live, sampled by the existing 1 Hz
  poll.

In aggregate mode the counter belongs to the single AUHAL on top of the
aggregate, so every member reports the same figure. The UI says "输出链" rather
than claiming a per-speaker number we do not have.

### 2.6 Persistence and re-application

- `DeviceEqualizerStore` — versioned `UserDefaults` key
  `syncast.deviceEqualizer.v1`, JSON array of `DeviceEqualizerProfile`
  (`uid` + cached `displayName` + `settings`).
- **Keyed by CoreAudio UID**, never by `Device.id` (re-minted every process and
  every reappearance) and never by name (two ASUS panels report the same
  product string; the office display must not inherit the home display's
  curve). Same rule as `AutoConnectProfile` and `WholeHomeMemberStore`.
- Validated at the load boundary: clamp gains and trim, drop non-finite and
  out-of-range bands, cap the chain at 16 sections, drop duplicate UIDs, drop
  records that cannot change anything. Unreadable data collapses to "no
  curves". A bypassed record that HOLDS a curve is kept — bypass is the A/B
  switch and losing the curve behind it would defeat it.
- Values are snapped to the 0.5 dB UI grid on the way in, so a value read back
  from JSON always lands exactly on a slider detent.

**"每次连接都默认这样" is implemented in the Router, not in the UI.** The
menubar pushes the whole UID → curve map (`Router.setEqualizers`); the Router
keeps it and calls `applyEqualizers()` at the end of every
`reconcileLocalDriver` and every `replan()`. Both are idempotent — the bank
early-returns on an unchanged curve, so no crossfade is spent — so a re-plug, a
re-enable, or an aggregate rebuild re-seeds the curve without the menubar
having to notice the transition, which is the class of event it has
historically missed.

A subdevice whose channel offset cannot be resolved is **skipped**, not
defaulted to pair 0: unlike a volume, putting device B's tone curve on device A
is silent and confusing.

### 2.7 UI

`EqualizerSection.swift`:

- `EqualizerToggleButton` — a slider icon in the device row, tinted with an
  "EQ" badge when a curve is loaded and active. Rendered only where
  `AppModel.equalizerIsAvailable(for:)` is true.
- `EqualizerEditor` — inline panel under the row: ten rotated vertical sliders
  (−12…+12 dB, 0.5 dB step) with dB and frequency labels, a 「总量」 trim
  slider, a 「旁路」 switch, 「重置」, the clip indicator, and 「收起」.

Inline rather than a nested `.popover`: the whole UI is a
`MenuBarExtra(.window)`, where a second floating window is an unverified AppKit
interaction and a dismissal of the parent could take the editor with it. Which
row is open is `AppModel` state, not `@State`, because SwiftUI recycles
`DeviceRow` (the same reason the row binds by `deviceID` and never by a
captured `Device`).

Edits are written to `UserDefaults` immediately (so a crash mid-tuning loses
nothing) and pushed to the Router on a 50 ms debounce; the bank's own 20 ms
crossfade is what makes the change audible without a click.

## 3. Verified

Offline, on this machine, 2026-09-05.

`core/router`: `swift build` clean, `swift test` **216 tests, 0 failures**
(25 of them new `EqualizerBankTests`).
`apps/menubar`: `swift build` clean, `swift test` **227 tests, 0 failures**
(21 of them new `DeviceEqualizerPersistenceTests`).

### 3.1 Measured response through the shipping render path

`testTenBandTableThroughTheShippingRenderPath` pushes an impulse through
`EqualizerBank.process()` — the same call `LocalOutput.render()` makes — and
evaluates a DFT of the response at every band centre. One band boosted +6 dB at
a time, 48 kHz, gain in dB:

```
band           31.5    63.0   125.0   250.0   500.0  1000.0  2000.0  4000.0  8000.0 16000.0
31.5           6.00    1.14    0.23    0.05    0.01    0.00    0.00    0.00    0.00    0.00
63.0           1.14    6.00    1.16    0.23    0.05    0.01    0.00    0.00    0.00    0.00
125.0          0.23    1.16    6.00    1.14    0.22    0.05    0.01    0.00    0.00    0.00
250.0          0.05    0.23    1.14    6.00    1.14    0.22    0.05    0.01    0.00    0.00
500.0          0.01    0.05    0.22    1.14    6.00    1.14    0.22    0.05    0.01    0.00
1000.0         0.00    0.01    0.05    0.22    1.14    6.00    1.13    0.21    0.04    0.00
2000.0         0.00    0.00    0.01    0.05    0.22    1.13    6.00    1.09    0.18    0.02
4000.0         0.00    0.00    0.00    0.01    0.05    0.21    1.09    6.00    0.94    0.08
8000.0         0.00    0.00    0.00    0.00    0.01    0.04    0.18    0.94    6.00    0.42
16000.0        0.00    0.00    0.00    0.00    0.00    0.00    0.02    0.08    0.42    6.00
```

Diagonal is exactly the dialled 6.00 dB. The ~1.14 dB shoulder on the immediate
neighbour is the expected overlap of adjacent constant-Q octave bands (not an
error): two neighbouring sliders at −6 dB therefore produce about −7.1 dB
between them, which the tests assert against the analytic response rather than
against −6.

Other measured properties, all through `process()`:

- a flat or bypassed curve leaves the buffer **bit-identical**;
- trim is flat within 0.05 dB from 100 Hz to 8 kHz;
- pairs are independent (pair 0 boosted, pair 1 measures 0 dB ± 0.01);
- +12 dB on a −0.4 dBFS sine clips, is clamped inside ±1, and is counted;
- a NaN input sample never reaches the output;
- a block longer than 4096 frames is refused, not truncated;
- 240 coefficient sets across every kind × frequency × Q × ±12 dB corner are
  stable or identity.

### 3.2 Not verified (needs the supervisor / real hardware)

- **Audible** behaviour on real speakers: that a bass cut sounds like a bass
  cut, that a drag is click-free by ear, that the 20 ms crossfade is enough for
  a full-scale reset.
- CPU cost measured on the live render thread. Estimated ~20 biquads × 512
  frames per pair per block; not profiled.
- The rotated-`Slider` layout inside `MenuBarExtra(.window)` has not been seen
  on screen. Ten 29 pt columns fit the 340 pt popover on paper.
- Interaction with the sink path's per-device software gain when a display has
  no hardware volume: both stages are in the same render callback (EQ first,
  gain second) and were reasoned about, not measured together.
- Whether a stored curve survives an actual replug of the ExternalDisplay. The code
  path (`reconcileLocalDriver` → `applyEqualizers`) is exercised by unit tests
  at the model level only.

## 4. Known limits

- Direct Stereo and whole-home are not equalised (§2.1). On those paths the
  control is hidden and a stored curve is annotated rather than silently
  ignored.
- Digital attenuation: a large cut loses effective bit depth, the same trade-off
  the existing per-pair software gain documents.
- The graphic layout is fixed at ten bands. The store and the DSP are
  parametric already; only the editor would need work to expose it.
- One editor open at a time, by design (a 340 pt popover has room for one
  ten-band panel).
- No global/output-chain EQ, no crossover, no room correction, no import of
  third-party curves.

## 5. Files

New:

- `core/router/Sources/SyncCastRouter/EqualizerSettings.swift`
- `core/router/Sources/SyncCastRouter/EqualizerBank.swift`
- `core/router/Tests/SyncCastRouterTests/EqualizerBankTests.swift`
- `apps/menubar/Sources/SyncCastMenuBar/DeviceEqualizerStore.swift`
- `apps/menubar/Sources/SyncCastMenuBar/AppModel+Equalizer.swift`
- `apps/menubar/Sources/SyncCastMenuBar/EqualizerSection.swift`
- `apps/menubar/Tests/SyncCastMenuBarTests/DeviceEqualizerPersistenceTests.swift`

Changed:

- `core/router/Sources/SyncCastRouter/LocalOutput.swift` — owns an
  `EqualizerBank`, applies it per pair in `render()`, reports clips.
- `core/router/Sources/SyncCastRouter/Router.swift` — UID → curve map,
  `setEqualizers` / `setEqualizer` / `equalizerClipCounts`, re-application on
  reconcile and replan.
- `apps/menubar/Sources/SyncCastMenuBar/AppModel.swift` — four stored
  properties and three push points (engine start, stereo reconcile, 1 Hz poll).
- `apps/menubar/Sources/SyncCastMenuBar/MainPopover.swift` — the row button,
  the inline editor, the inactive hint, the accessibility summary.
