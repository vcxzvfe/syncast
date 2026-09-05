# 2026-09-05 — Auto-connect profiles (Track B)

## Problem

Every time the laptop reaches the desk at home and the ASUS ExternalDisplay comes up,
the user opens SyncCast and ticks the same two boxes: MacBook Pro扬声器 and
ExternalDisplay, in local Stereo. The app already remembers *what* was selected inside
a session, but nothing acts on "the monitor is here again".

The mirror-image problem was raised earlier (2026-07-30): when the monitor goes
away, the useful behaviour is to fall back to the built-in speakers, and this
user wants their level forced to 0 % so that unplugging in a café does not turn
the laptop into a speaker.

Neither behaviour can be keyed on "an external display appeared": the office
display must never trigger any of it. The only identity that separates the two
panels is the CoreAudio device UID.

## What was built

A configurable **auto-connect rule**:

> 当 `<trigger>` 出现 → 切到本地 Stereo 并开启 `<members>`
> 断开时 → 停止播放，(可选) 切回内建扬声器，(可选) 把内建音量设为 N %

The pieces, none of which know about each other's internals (a sixth,
`AutoConnectPlan.swift`, is added by the review round below):

| File | Role |
|---|---|
| `apps/menubar/Sources/SyncCastMenuBar/AutoConnectProfile.swift` | The rule record (`Codable`), the versioned `UserDefaults` store, and the small pure helpers (`builtInOutputUID`, `hardwareScalar(forPercent:)`). |
| `apps/menubar/Sources/SyncCastMenuBar/AutoConnectCoordinator.swift` | Pure, clock-injected state machine. Takes a snapshot of the world, returns one action. |
| `apps/menubar/Sources/SyncCastMenuBar/AppModel+AutoConnect.swift` | Translates actions into the intents `AppModel` already exposes; owns all logging. |
| `apps/menubar/Sources/SyncCastMenuBar/AutoConnectSection.swift` | The 「自动连接」 block in the popover. |
| `apps/menubar/Sources/SyncCastMenuBar/SystemDefaultOutput.swift` | Sets the macOS default output by UID (the router's equivalent is private and tied to a live Direct Stereo session). |

`AppModel.swift` gains five stored properties and five call sites; every
decision lives outside it.

## Design decisions worth stating

**Rules are keyed on CoreAudio UIDs, never names or `Device.id`.** `Device.id`
is re-minted per process by `StableIDMap`; display names are not unique across
two panels from the same vendor. This is the same rule `WholeHomeMemberStore`
already follows for whole-home members, for the same "this laptop moves"
reason.

**Presence is debounced 1.5 s.** A DisplayPort monitor coming out of DPMS sleep
drops and re-adds its audio device several times inside about a second — the
same behaviour that made `RescanRemovalGate` necessary on the Bonjour side and
that `AppModel.handleWake` already waits 1.5 s for. Acting on the first edge
would start and stop the engine two or three times per wake. The debounce is
symmetric: a trigger that blinks out for under 1.5 s does not tear anything
down either.

**One activation per trigger-presence episode.** An episode opens when the
trigger UID becomes present and closes when it goes away. Re-firing inside an
episode would let the rule stamp on a selection the user made after it had
already done its job.

**Never fight the user.** Any manual device toggle or mode change while the
trigger is present suppresses the rule for the rest of that episode. Getting it
back is either unplug/replug or the explicit 「重新应用规则」 button. Auto-connect's
own writes are excluded by an `autoConnectApplying` flag around the apply path.

**Launching into the correct state is silent.** If SyncCast starts at login
with the monitor already connected and the right outputs already streaming, the
coordinator claims the episode without touching the audio path — so nothing
restarts, and a later manual change is still treated as the user's. (The claim
is reported as its own `.claimSatisfied` action rather than as "do nothing",
because it still owes the built-in speakers a level a previous disconnect may
have forced down — see the review-fixes section.)

**The disconnect volume is a LINEAR scalar, not `VolumeCurve`.** `VolumeCurve`'s
0 % is -30 dB (OwnTone's floor), which is quiet but audible — useless for the
requirement that prompted this. `builtInVolumePercent` is written straight to
`kAudioDevicePropertyVolumeScalar` as `percent / 100`, i.e. it *is* the macOS
output-slider position, so 0 % is genuinely silent. This is deliberately
independent of Track A's volume work, which owns the streaming volume law.

**Disconnect fires even after the user overrode the rule**, as long as the rule
did activate during that episode. It is a safety behaviour ("do not let the
laptop blast in public"), not a routing preference.

**Restoring the built-in output waits 0.8 s.** `DirectStereoOutput.stop()`
restores whatever the default output was *before* SyncCast took over — on a
disconnect that is the monitor which just left. Writing our own default first
would simply be undone by the teardown.

**Defaults for a new rule are conservative**: `restoreBuiltIn = false`,
`builtInVolumePercent = nil`. Silently re-pointing someone's system output, or
dropping their speaker level to a number they never chose, is not a reasonable
thing to do to a user who only asked for auto-connect. This machine's owner
turns both on and sets 0.

**Stored as an array under one versioned key** (`syncast.autoConnect.profiles.v1`,
JSON). v1's UI edits a single rule and the coordinator resolves ties as
first-match-wins, so multiple rules are a UI change later, not a migration.

## Persistence and validation

`UserDefaults` is external data. `AutoConnectProfileStore.decode` collapses
absent / unreadable / structurally-valid-but-nonsensical to "no rules" rather
than to a half-applied rule that would move the user's audio somewhere they
never asked for. `sanitize` drops rules with no trigger or no members, dedupes
member UIDs, clamps percents to 0…100, and drops duplicate rule ids (two rules
sharing an id would corrupt the coordinator's per-rule episode bookkeeping).

## Debug hatch

```
SYNCAST_AUTOCONNECT_SIMULATE_ABSENT=00000000-0000-0000-0000-000000000001
```

Comma-separated CoreAudio UIDs hidden **from the coordinator only** — discovery,
the popover and the engine still see the device. It exists so the disconnect
branch can be exercised on real hardware without physically unplugging the
monitor: launch with the variable set and the rule behaves as if the trigger had
just left (stop, restore built-in, force the level). Unset it and relaunch to
get the activation branch back.

Every decision is logged to `~/Library/Logs/SyncCast/launch.log` with the
`autoconnect:` prefix, including the reason each evaluation ran.

## Review fixes

An independent code review of the first cut found five defects and one
cleanliness item. All are fixed; the reasoning is recorded here because most of
them are only reachable by unplugging a monitor at the right moment.

A sixth file joins the table above:
`apps/menubar/Sources/SyncCastMenuBar/AutoConnectPlan.swift` — the pure
planning layer plus the versioned store for the pre-force built-in level.
`AppModel+AutoConnect.swift` is an extension on a `@MainActor @Observable`
class that owns a router, discovery and a live engine, so nothing in it is
constructible in a test and it had **zero coverage**. Every judgement it used to
make inline now lives in `AutoConnectPlan` as a value-in / value-out function
and is tested; the extension is left reading the world, calling the plan, and
executing the verdict.

**A rule may only undo what it did.** The teardown was
`for device in devices where routing[…].enabled`, i.e. *everything currently
switched on*. Scenario: the rule fires (built-in + ExternalDisplay, local stereo), the
user then switches to whole-home and enables the Mac mini and the Xiaomi, and
only then unplugs the monitor. The old code switched off both AirPlay
receivers, re-pointed the default output and zeroed the built-in — silencing a
room the rule never set up. `Action.deactivate` now carries `memberUIDs` and the
teardown walks only local CoreAudio devices in that set. **AirPlay routing is
never touched by a deactivation**, which is symmetrical with activation never
enabling an AirPlay receiver.

**The disconnect's built-in half is suspended during a whole-home session.**
`restoreBuiltIn` and `builtInVolumePercent` are safety behaviours for "the
laptop is being carried out of the room". Mid-whole-home they are not: the audio
is going to the house and the default output is the user's business. Both are
dropped **unless the built-in is itself one of the rule's members**, in which
case the rule really is the reason it is playing. The mode is never changed by a
deactivation in either direction — a rule that fired in stereo has no business
pulling the user out of whole-home.

**Forcing the built-in to 0 % used to be a one-way door.** This is the worst of
the six. Direct Stereo treats the hardware as the authority: enabling the
built-in as a member makes `refreshDirectStereoVolumeState` read its scalar and
`applyDirectStereoVolumeSnapshot` mirror it into `routing[*].volume` as though
the user had chosen it. A built-in still parked at the forced 0 % was therefore
*adopted* as the user's level, so after the first unplug every replug came back
silent with a slider that agreed — and nothing in the app ever wrote the level
back up. Now:

1. before forcing, the current scalar is stored under
   `syncast.autoConnect.builtInVolumeBeforeForce.v1` (scalar + UID + timestamp,
   JSON, same validate-on-decode discipline as the rules store);
2. the next `.activate` that includes that UID writes the snapshot back
   **before** enabling members — so the Direct Stereo snapshot reads the
   restored value — and then clears it;
3. an existing snapshot for the same device is never overwritten, so two
   unplugs with no plug-in between them cannot "remember" the 0 % the first one
   wrote;
4. with no snapshot and a built-in reading 0.0 at activation while it is a
   member, a 0.5 floor is written and logged. That covers the histories that
   never produced a snapshot: the feature switched on while the speakers were
   already at 0, cleared defaults, an older build. Coming back quiet is
   recoverable; coming back silent with no visible cause is the bug.

The UID is stored alongside the scalar because Apple ships both
`BuiltInSpeakerDevice` and `BuiltInHeadphoneDevice` — a level read from one is
never written into the other.

**An activation that could not be applied is retried.** The episode was marked
spent the moment the action was emitted, which is right for the normal path and
wrong for the failing one: `AppModel.setMode` is single-flight and drops a mode
switch while a previous transition is still stopping the engine, *returning
silently*. The members were then enabled in whole-home — the wrong mode for
every one of them — with the episode spent and nothing that could try again. The
apply path now returns a `Bool`, touches nothing at all when the mode switch is
refused, and a failure calls `markActivationFailed`, which returns the shot.
Retry after 1.0 s, at most 3 attempts per episode, then stand down with a log
line and a `lastError` rather than spin. The budget resets with the episode.

**The 0.8 s follow-up is stored and re-checked.** It was a fire-and-forget
`Task`, so two disconnects in quick succession raced each other and a monitor
that came straight back inside the window (DPMS blink, KVM switch) still got its
default output yanked away. It is now held in `autoConnectDeactivateTask`,
cancel-and-replaced like `autoConnectRecheckTask`, and on waking re-checks that
the trigger is still absent **and** that nothing is streaming before writing
anything.

**The "already satisfied" claim is kept, and made explicit.** Claiming the
episode without touching the audio path sets `activated`, which means the
following unplug runs the full disconnect action even though the rule never
moved anything. That is deliberate and is kept: the requirement is "unplug → the
laptop must not be audible", and a rule that verified the state was already what
it wanted is as entitled to that as one that built it. What the claim must not
do is skip the built-in level a previous disconnect forced down — on that path
no `.activate` will ever arrive to hand it back. So the coordinator now reports
`.claimSatisfied` rather than `.none`, and the owner runs the restore step and
nothing else. Both halves are tested.

**Cleanliness.** `autoConnectApplying` is released with `defer`.
`SystemDefaultOutput.setDefaultOutput` now requires the matched device to have
output channels (`kAudioDevicePropertyStreamConfiguration`, output scope): a
device's input and output halves are separate `AudioObjectID`s that can report
the same UID, and writing the capture half into
`kAudioHardwarePropertyDefaultOutputDevice` fails with an opaque `OSStatus`
while the real speakers sit right behind it in the list.

## Verification

- `swift build` and `swift test` in `apps/menubar`: **198 tests, 0 failures**
  (65 of them for auto-connect: `AutoConnectCoordinatorTests`,
  `AutoConnectProfileTests`, `AutoConnectPlanTests`). All four packages build;
  `core/router` (90) and `core/discovery` (21) stay green.
- Covered by tests: debounce (including a five-edge flapping burst), fire-once
  per episode, missing member, disabled rule, launch-already-correct,
  whole-home-with-same-members, user override, override does not touch absent
  triggers, `resetSuppression`, disconnect action + payload, brief dropout does
  not deactivate, deactivate once, first-match-wins (and the loser staying
  quiet), rule deletion, a rule switched off after firing not acting on the
  unplug, JSON round trip, garbage/wrong-shape/absent data,
  clamping, dedupe, duplicate ids, the `UserDefaults` round trip, the linear
  scalar law, and built-in lookup by UID / prefix / name.
- Added by the review round: the disconnect payload carrying the rule's own
  members and not the user's later selection, teardown scope, the whole-home
  carve-out in both directions (built-in a member / not a member), a disconnect
  action switched off inventing no skip reason, the delayed-fallback re-check in
  all four trigger/streaming combinations, snapshot capture (audible level,
  never overwriting a held snapshot, ignoring another device's, skipping silent
  and unreadable), restore (remembered level + clear, floor with no snapshot,
  floor for a silent snapshot, non-member and already-audible left alone, no
  built-in, unreadable level, wrong-UID snapshot), the full unplug → replug →
  replug cycle, snapshot JSON round trip and rejection of empty-UID /
  out-of-range / non-JSON records, the `UserDefaults` round trip and clear, the
  `.claimSatisfied` action, activation retry up to the cap then standing down,
  the retry budget resetting with the episode, and a failure reported for a
  rule that has already been deleted.
- **Not verified on hardware by this track**: the supervisor owns real-machine
  validation and the app was not reinstalled. Specifically unproven here:
  the actual DisplayPort flap pattern on ExternalDisplay wake against the 1.5 s
  window, whether 0.8 s is enough for the teardown to release the default
  output before the built-in write lands, whether a stopped engine leaves
  any `HardwareVolumeObserver` echo behind the forced built-in level, whether
  `AggregateDevice.readHardwareVolume` returns the pre-force level reliably at
  the moment of teardown (the snapshot is only as good as that read).
- **Verified against real CoreAudio on this machine**: the new output-scope
  channel test in `SystemDefaultOutput`. A standalone probe running the shipped
  `hasOutputChannels` over the live device list confirms it still resolves
  `BuiltInSpeakerDevice` (id 82) and passes ExternalDisplay, BlackHole and the stacked
  aggregate, while rejecting the input-only `BuiltInMicrophoneDevice` and the
  Logitech BRIO — i.e. it filters exactly what it was added to filter and does
  not break the default-output write it guards. Nothing was installed and the
  running app was not touched.

## Known limits

- One rule in the UI. The store and the coordinator already handle several.
- Local Stereo only. Whole-home automation is explicitly out of scope, and an
  activation always switches the app to `.stereo`.
- AirPlay routing is never touched by any of this — activation only enables
  local outputs, and a deactivation only switches off the rule's own members.
- The trigger picker offers local outputs only; an AirPlay receiver appearing
  cannot arm a rule.
- The rule matches on presence, not on which display is actually driving video,
  so a monitor connected purely for its USB hub still counts as present.
