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

Four pieces, none of which know about each other's internals:

| File | Role |
|---|---|
| `apps/menubar/Sources/SyncCastMenuBar/AutoConnectProfile.swift` | The rule record (`Codable`), the versioned `UserDefaults` store, and the small pure helpers (`builtInOutputUID`, `hardwareScalar(forPercent:)`). |
| `apps/menubar/Sources/SyncCastMenuBar/AutoConnectCoordinator.swift` | Pure, clock-injected state machine. Takes a snapshot of the world, returns one action. |
| `apps/menubar/Sources/SyncCastMenuBar/AppModel+AutoConnect.swift` | Translates actions into the intents `AppModel` already exposes; owns all logging. |
| `apps/menubar/Sources/SyncCastMenuBar/AutoConnectSection.swift` | The 「自动连接」 block in the popover. |
| `apps/menubar/Sources/SyncCastMenuBar/SystemDefaultOutput.swift` | Sets the macOS default output by UID (the router's equivalent is private and tied to a live Direct Stereo session). |

`AppModel.swift` gains four stored properties and five call sites; every
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
coordinator claims the episode without emitting an action — so nothing
restarts, and a later manual change is still treated as the user's.

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

## Verification

- `swift build` and `swift test` in `apps/menubar`: 172 tests, 0 failures
  (39 of them new: `AutoConnectCoordinatorTests`, `AutoConnectProfileTests`).
  All four packages build; `core/router` (90) and `core/discovery` (21) stay green.
- Covered by tests: debounce (including a five-edge flapping burst), fire-once
  per episode, missing member, disabled rule, launch-already-correct,
  whole-home-with-same-members, user override, override does not touch absent
  triggers, `resetSuppression`, disconnect action + payload, brief dropout does
  not deactivate, deactivate once, first-match-wins (and the loser staying
  quiet), rule deletion, a rule switched off after firing not acting on the
  unplug, JSON round trip, garbage/wrong-shape/absent data,
  clamping, dedupe, duplicate ids, the `UserDefaults` round trip, the linear
  scalar law, and built-in lookup by UID / prefix / name.
- **Not verified on hardware by this track**: the supervisor owns real-machine
  validation and the app was not reinstalled. Specifically unproven here:
  the actual DisplayPort flap pattern on ExternalDisplay wake against the 1.5 s
  window, whether 0.8 s is enough for the teardown to release the default
  output before the built-in write lands, and whether a stopped engine leaves
  any `HardwareVolumeObserver` echo behind the forced built-in level.

## Known limits

- One rule in the UI. The store and the coordinator already handle several.
- Local Stereo only. Whole-home automation is explicitly out of scope, and an
  activation always switches the app to `.stereo`.
- AirPlay routing is never touched by any of this.
- The trigger picker offers local outputs only; an AirPlay receiver appearing
  cannot arm a rule.
- The rule matches on presence, not on which display is actually driving video,
  so a monitor connected purely for its USB hub still counts as present.
