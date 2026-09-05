# Per-device delay compensation, local Stereo (2026-09-05)

Track D of the 2026-09-05 round. Branch `feat/local-delay-trim`.

## 1. Problem

When the built-in speakers and an external DisplayPort display play the same
stream together on the local Stereo path, they are audibly out of step by a
small, fixed amount — tens of milliseconds, well under 100 ms.

The cause is that the display's panel applies its own audio processing
*after* the HAL has handed the samples over, and it does not declare that
processing anywhere: `kAudioDevicePropertyLatency` and
`kAudioDevicePropertySafetyOffset` describe the transport, not the panel's
internal DSP. Nothing in the system knows the offset is there, so no amount of
clock work removes it — the aggregate's drift correction locks the *rate* of
every subdevice to the master, which is a different quantity from *phase*.

So the only instrument that can measure it is the listener, and the feature is
a control: a small per-device slider, remembered on the device, applied
automatically the next time it is enabled.

Explicitly rejected by the user: any microphone / acoustic calibration.

## 2. Design

### 2.1 Where it runs

Inside `LocalOutput.render()`, as a per-channel-pair **read offset** into the
shared capture ring.

```
ring.read(at: startFrame + lead(pair)) → splat/copy into that pair → EQ → gain/mute → AUHAL
```

In aggregate mode one output channel pair is one physical device (the same
addressing the per-device equalizer and the per-device software gain use), so
giving pair `p` its own read position delays exactly one speaker.

Offsets are **non-negative holds**: nothing can be played early, because the
render callback cannot receive a frame the producer has not written. A user who
thinks "that speaker is early" therefore expresses the same intent as "the
other one is late", and `LocalDelayTrimPlanner` slides the whole set up until
the earliest pair sits at exactly 0 — preserving every pairwise difference,
which is the only physically meaningful part, and costing the earliest speaker
no added latency at all. (Same reasoning as `DelayTrimNormalizer`; see §2.6 for
why they are not the same code.)

**Coverage**, stated plainly because a hidden control is only acceptable if the
reason is:

| Path | Compensated | Why |
|---|---|---|
| Local Stereo, system-sink leg | yes | samples pass through `LocalOutput.render()` |
| Local Stereo, ScreenCaptureKit leg | yes | same render path |
| Local Stereo, **Direct Stereo** leg | **no** | the HAL renders straight into the public aggregate; SyncCast never sees a buffer |
| **Whole-home** (AirPlay 全屋) | **no** | that path has its own per-output trim (`DeviceDelayTrim`) on a different leg |
| AirPlay receivers | **no** | their audio is produced by OwnTone, not by us |

The UI hides the control on those paths rather than showing an inert one, and a
row that HAS a stored value which is not currently being applied says so
(`AppModel.localDelayTrimInactiveHint`).

### 2.2 The read window, and why the cursor moves with it

The render cursor is one number shared by every pair, so `PairDelayBank`
publishes a **window** = the largest offset in play, and pair `p` reads at
`cursor + window − offset(p)`. The most-delayed pair reads at the cursor
itself; the least-delayed one reads `window` frames above it.

Two consequences, both load-bearing:

1. **The floor is deepened by the window, not borrowed from.**
   `RingReadPlanner.plan` takes a `readWindowFrames` parameter and subtracts it
   when computing the target, so the pair reading highest still has exactly
   `floor + block` frames of written audio ahead of it. Underrun and water
   level are judged at the top of the window for the same reason. The
   most-delayed pair reads *older* audio, which the ring already holds
   (capacity is 2<sup>18</sup> frames ≈ 5.5 s), and the cursor's
   lower-bound check is unchanged because the cursor *is* the lowest read
   point.
2. **A window change is paid for by the cursor.** When the window moves,
   every pair's absolute read position would otherwise jump by the same amount
   — including pairs the user did not touch. `adoptPublishedChanges()` reports
   `cursorShift = oldWindow − newWindow`, which `render()` adds to the cursor
   before planning, so untouched pairs land on exactly the sample they would
   have read anyway. `testDelayingOnePairLeavesTheOtherWhereItWas` measures
   this end to end.

Setting `readWindowFrames: 0` (the default, and the value whenever nothing is
dialled in) reproduces the original arithmetic exactly —
`testZeroWindowIsExactlyTheOriginalPlan` pins that.

### 2.3 Real-time safety

`PairDelayBank` runs on the CoreAudio render thread and follows the pattern
`EqualizerBank` and `LocalOutput._softwareGains` already set:

- **No allocation.** Offsets, fade counters and the outgoing positions are
  heap-allocated once at `init` and indexed through raw pointers, because a
  Swift `Array`'s copy-on-write copy in an audio callback is a heap allocation.
  The second staging buffer the crossfade reads into (32 KB) is allocated with
  the first, not on demand — otherwise the first touch of the slider would
  allocate on the render thread.
- **Publication is generation-counted.** The app thread fills a staging slot
  under an `OSAllocatedUnfairLock` and bumps a release-ordered atomic; the
  render thread loads that atomic (acquire) once per block and takes the lock
  **only** on the block where it differs. Steady state is one atomic load per
  block and no lock.
- **Fast path.** While every offset is 0 and no fade is running, `render()`
  keeps its original single ring read plus splat — the delayed path's extra
  per-pair read does not exist for a user who never touches the control, and
  the output is bit-identical to the pre-feature build.
- **Bounded work when engaged.** One extra `RingBuffer.read` per pair (a
  bounded memcpy of `frames × channelCount` floats), plus a second read and a
  multiply-add loop for the ~20 ms a pair is crossfading.

### 2.4 Smoothing: crossfade, not a resync

A moved offset is a step discontinuity in the read position — an audible click.
The alternative the brief allowed (accept a one-time resync, counted as
expected) was rejected because the control is a **slider**: with a 50 ms commit
debounce, a drag would emit a click every 50 ms for the whole sweep, which is
exactly the interaction the feature exists for.

So a pair that changes offset runs both read positions for 20 ms and
crossfades between them, the same length and the same idea as
`EqualizerBank`'s coefficient crossfade. Once the fade completes the outgoing
position collapses onto the audible one, which is what lets the window shrink
again.

The crossfade is **linear**, deliberately. For a small offset change the two
windows are strongly correlated and linear is exactly right; for a large one
they are effectively decorrelated and the midpoint dips ~3 dB for 10 ms. An
equal-power law would fix the large case and put a matching +3 dB bump on the
small one, which is the more common edit.

A second change arriving mid-fade restarts the fade from the pair's current
nominal position rather than crossfading three positions at once. The dropped
tail is a partial-amplitude step, far smaller than the position jump it is
replacing, and it takes two changes inside 20 ms to happen at all.

### 2.5 Automatic seed

Before the user touches anything, each device's offset is seeded from the
latency it **does** report: `kAudioDevicePropertyLatency` +
`kAudioDevicePropertySafetyOffset` (output scope) + the largest output-stream
latency — i.e. `LocalOutput.outputLatencyFrames`, the same probe
`LocalAirPlayBridge` uses for its own budget — plus the aggregate's
`kAudioSubDevicePropertyExtraLatency` for that subdevice.

The seed enters the planner as the **negative** of that number: a device that
reports more latency already presents later and therefore needs *less* hold.
After normalisation the honest devices line up, and the user's slider only has
to cover what nothing reports. Getting this sign backwards would double the
skew instead of removing it, so it is pinned by
`testHonestlyReportedLatencyLinesUpWithoutUserInput`.

Seeds are probed when the covered UID set changes (not on every replan —
probing walks CoreAudio properties) and logged once per distinct value:

```
[Router] delay seed: <uid-prefix> reports 12.3 ms output latency
```

A UID that cannot be resolved gets no seed rather than a guessed one. A device
reporting nonsense is capped: the normalised offset is clamped to
`LocalDelayTrim.maxOffsetMs` (500 ms) and to the ring's own headroom
(`capacity/2 − floor`), so a broken latency probe cannot park the read cursor
seconds behind the producer — which would present as that speaker going silent.

### 2.6 Persistence and re-application

- `LocalDelayTrimStore` — versioned `UserDefaults` key
  `syncast.localDelayTrimMs.v1`, JSON array of `LocalDelayTrimProfile`
  (`uid` + cached `displayName` + `delayMs`).
- **Keyed by CoreAudio UID**, never by `Device.id` (re-minted every process and
  every reappearance) and never by name (two panels of the same model report
  the same product string, and a second display must not inherit the first
  one's value). Same rule as `DeviceEqualizerProfile`, `AutoConnectProfile` and
  `WholeHomeMemberStore`.
- Validated at the load boundary: trim the UID, drop blanks and duplicates,
  clamp into ±100 ms, drop zeros (the default needs no record). Unreadable data
  collapses to "no trims".

**Why this is not `DeviceRouting.manualDelayMs`.** That field exists and it is
also a per-output millisecond delay, but it is a different quantity:

| | whole-home trim (`DeviceDelayTrim`) | local delay (`LocalDelayTrim`) |
|---|---|---|
| corrects | where the listener sits relative to each speaker | latency a device adds and never declares |
| applied on | `LocalAirPlayBridge` + OwnTone `offset_ms` | `LocalOutput.render()` |
| covers | CoreAudio outputs **and** AirPlay receivers | CoreAudio outputs only |
| keyed by | `Device.persistenceKey` (`ca:` / `ap:`) | CoreAudio UID |
| range | ±200 ms | ±100 ms |
| store | `syncast.deviceDelayTrimMs` | `syncast.localDelayTrimMs.v1` |

`Router.replan()` has always handed the Scheduler an empty trim map for the
stereo path on purpose. Folding the two into one number would make each mode
silently retune the other, and the whole-home range is twice what the local
ring budgets for. `test_local_and_whole_home_trims_are_separate_settings` pins
the separation.

**Re-application lives in the Router, not in the UI.** The menubar pushes the
whole UID → milliseconds map (`Router.setLocalDelayTrims`); the Router keeps it
and calls `applyLocalPairDelays()` at the end of every `reconcileLocalDriver`
and every `replan()`. Both are idempotent (`PairDelayBank.setOffsets`
early-returns on an unchanged map, so no crossfade is spent), so a re-plug, a
re-enable or an aggregate rebuild re-seeds the value without the menubar having
to notice the transition — the class of event it has historically missed. A
teardown clears the probed-UID set so the next reconcile re-reads latency from
the freshly minted AudioObjectIDs.

A subdevice whose channel offset cannot be resolved is **skipped**, not
defaulted to pair 0, for the same reason the equalizer skips it: putting device
B's delay on device A is silent and confusing.

### 2.7 UI

`LocalDelayTrimControl.swift`, one compact row under each enabled device in
local Stereo: a `timer` icon, − / + buttons, a slider (−100…+100 ms, 1 ms
step), the signed value, and 「重置」 once the value is non-zero. The sign
convention line (`正值 = 让这台晚出声（相对最早的那台）· 1 ms ≈ 34 cm`) appears
under the control once a value is dialled in, and is the icon's tooltip before
that — rendering the same sentence under every speaker in the list would be
noise.

A **slider**, where the whole-home trim row is a stepper. That row is a stepper
because every commit relatches an AirPlay receiver (~0.4 s of silence), so a
drag would be a stutter stream. Here a commit is a memcpy plus a 20 ms
crossfade, and the user is hunting for a value they can only recognise by ear —
which is a sweep, not a series of guesses. The ± buttons cover the last
millisecond, where 201 detents across a popover-width track are too coarse.

Edits are live during the drag (pushed to the Router on a 50 ms debounce) and
written to `UserDefaults` on release, so a drag costs one defaults write rather
than one per pixel and what is playing never disagrees with what is shown.

## 3. Verified

Offline, on this machine, 2026-09-05.

`core/router`: `swift build` clean, `swift test` **266 tests, 0 failures**
(42 of them new: `LocalDelayTrimTests`, `PairDelayBankTests`,
`LocalOutputDelayRenderTests`, `RingReadWindowTests`).
`apps/menubar`: `swift build` clean, `swift test` **248 tests, 0 failures**
(21 of them new `LocalDelayTrimPersistenceTests`).

### 3.1 Measured through the shipping render path

`LocalOutputDelayRenderTests` builds an `AudioBufferList` by hand and calls
`LocalOutput.render()` — the same function the AUHAL callback invokes — with no
CoreAudio device, driving a two-pair (four-channel) output from a synthetic
producer block by block.

- An impulse through pairs at 0 and 480 frames (10 ms) comes out of the second
  pair **exactly 480 samples later**; both channels of each pair agree.
- With no offsets the two pairs play the identical sample index.
- Delaying pair 1 leaves pair 0 on the sample it would have played anyway (the
  cursor-shift invariant, §2.2).
- A 4800-frame (100 ms) offset sustained over 200 blocks produces **0 underruns,
  0 resyncs, 0 idle blocks** in steady state, with the minimum water level
  still at least one block — i.e. the delay came out of the ring's backlog, not
  out of the floor. (Warm-up underruns before the producer has written
  `floor + window + block` frames are expected and excluded, the same reading
  `LocalOutput`'s own documentation gives those counters.)
- An offset change under a constant full-scale input keeps every sample inside
  the signal range — a botched mix (double-applied gain, uninitialised scratch)
  would not.

### 3.2 Not verified (needs the supervisor / real hardware)

- **Audible** behaviour: that a display's offset actually disappears at some
  slider position, and that a drag is click-free by ear. The 20 ms crossfade is
  reasoned about and measured for range, not listened to.
- The magnitude of the automatic seed on real devices — what a built-in output
  and a DisplayPort display actually report — has not been read off this
  machine. The direction and the arithmetic are tested; the numbers are not.
- Whether a stored value survives an actual re-plug. The code path
  (`reconcileLocalDriver` → `applyLocalPairDelays`) is exercised at the model
  level only.
- CPU cost of the delayed path on the live render thread (one extra ring read
  per pair). Not profiled.
- The control's layout inside `MenuBarExtra(.window)` has not been seen on
  screen.
- Interaction with the sink path's per-device software gain and with the
  equalizer when all three are engaged on the same pair. All three are in the
  same render callback in a fixed order (delay → EQ → gain) and were reasoned
  about, not measured together.

## 4. Known limits

- Direct Stereo and whole-home are not compensated (§2.1). On those paths the
  control is hidden and a stored value is annotated rather than silently
  ignored.
- The delay is added latency: the most-delayed device plays its offset later
  than it otherwise would, on top of the ring floor. That is inherent — the
  alternative would be playing the other devices early, which is impossible.
- Whole-integer milliseconds only. Sub-millisecond alignment would need
  fractional-delay interpolation (`FractionalTrimResampler` exists for the
  whole-home leg); 1 ms ≈ 34 cm is already finer than a listener resolves on a
  fixed pair of speakers.
- One AUHAL's pairs are normalised together, which in aggregate mode is every
  physical device — the set the user is comparing by ear. Individual mode has
  one pair and therefore always resolves to 0.
- No automatic measurement, by explicit request.

## 5. Files

New:

- `core/router/Sources/SyncCastRouter/LocalDelayTrim.swift`
- `core/router/Sources/SyncCastRouter/PairDelayBank.swift`
- `core/router/Tests/SyncCastRouterTests/LocalDelayTrimTests.swift`
- `core/router/Tests/SyncCastRouterTests/PairDelayBankTests.swift`
- `core/router/Tests/SyncCastRouterTests/LocalOutputDelayRenderTests.swift`
- `apps/menubar/Sources/SyncCastMenuBar/LocalDelayTrimStore.swift`
- `apps/menubar/Sources/SyncCastMenuBar/AppModel+LocalDelayTrim.swift`
- `apps/menubar/Sources/SyncCastMenuBar/LocalDelayTrimControl.swift`
- `apps/menubar/Tests/SyncCastMenuBarTests/LocalDelayTrimPersistenceTests.swift`

Changed:

- `core/router/Sources/SyncCastRouter/RingReadPolicy.swift` — `readWindowFrames`
  on the planner and the sequencer (default 0 = the original arithmetic).
- `core/router/Sources/SyncCastRouter/LocalOutput.swift` — owns a
  `PairDelayBank`, applies the cursor shift, per-pair read + crossfade path,
  second staging buffer.
- `core/router/Sources/SyncCastRouter/Router.swift` — UID → milliseconds map,
  `setLocalDelayTrims` / `setLocalDelayTrim` / `localDelaySeedMs`, seed probing,
  re-application on reconcile and replan; `equalizerTargets()` renamed to
  `localPairTargets()` now that two features share the addressing.
- `core/router/Sources/SyncCastRouter/AggregateDevice.swift` —
  `subdeviceExtraLatencyFrames()`.
- `core/router/Tests/SyncCastRouterTests/RingReadPolicyTests.swift` —
  `RingReadWindowTests`.
- `apps/menubar/Sources/SyncCastMenuBar/AppModel.swift` — two stored properties
  and two push points (engine start, stereo reconcile).
- `apps/menubar/Sources/SyncCastMenuBar/MainPopover.swift` — the row control,
  the inactive hint, the accessibility summary.
