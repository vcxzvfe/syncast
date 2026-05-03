# SyncCast — Handoff Document

> **Last updated**: 2026-04-29 00:35 local · **HEAD**: `cd8b8df` (origin/main)
> **Audience**: next agent / engineer (specifically Codex Desktop) picking up review and forward iteration
> **Status**: shippable alpha. Most user-reported bugs through Round 12 fixed and pushed. Open question: replace ScreenCaptureKit with a non-screen-capture audio source (DRM-friendly).

---

## 1. What SyncCast is

macOS open-source menubar app. Captures system audio (currently via Apple ScreenCaptureKit) and routes it to multiple synchronized outputs:

- **Stereo (local) mode** — multiple local CoreAudio outputs (built-in speaker, USB DAC, HDMI monitor speakers) via private AggregateDevice + AUHAL render. ~50 ms target latency.
- **Whole-home (AirPlay) mode** — local CoreAudio + AirPlay 2 receivers via OwnTone broadcaster + RTSP-anchored PTP. ~1.8–2.5 s target latency, accepts video sync loss.

Modes are mutually exclusive. Switching tears down + rebuilds the local driver stack.

---

## 2. Architecture (file:line map)

### Core router (`core/router/Sources/SyncCastRouter/`)
- `Router.swift` — top-level actor. `start(devices:)` / `stop()` / `setRouting(...)` / `forceLocalDriverRebuild(devices:)` / `runCalibration(...)`. Owns `sckCapture`, `aggregate`, `audioSocketWriter`, `ownToneBroadcaster`.
- `SCKCapture.swift` — SCStream system audio capture. Writes into `RingBuffer`. Has `onUnexpectedStop` callback the Router wires up.
- `AggregateDevice.swift` — private CoreAudio aggregate device (UID `io.syncast.aggregate.v1.<pid>.<uuid>`). `pickMaster()` always picks built-in (transportType=BuiltIn=score 0) over HDMI (=50).
- `LocalOutput.swift` / individual AUHAL render path.
- `LocalAirPlayBridge.swift` — local CoreAudio bridges that consume from sidecar's audio socket (whole-home mode).
- `Capture.swift:137-159` — `deviceID(forUID:)` resolves UID → AudioDeviceID at runtime via `kAudioHardwarePropertyTranslateUIDToDevice`.
- `ActiveCalibrator.swift` — chirp-based calibration (Round 11 deprecated for menubar UX, kept as Estimate fallback).

### Discovery (`core/discovery/Sources/SyncCastDiscovery/`)
- `CoreAudioDiscovery.swift:37-90` — enumerates CoreAudio outputs, listens to `kAudioHardwarePropertyDevices`, emits `.appeared / .updated / .disappeared`.
- `Device.swift:20` — `coreAudioUID: String?` is the stable identifier across sleep/replug. NEVER use `AudioDeviceID` (UInt32) for persistence.
- `StableIDMap` — process-internal `"ca:<UID>"` → SyncCast UUID hash.

### Sidecar (`sidecar/`)
- Python (PyInstaller-bundled). RTSP/AirPlay glue around `pyatv`. JSON-RPC over Unix socket.
- `audio_socket.py` — `LocalFifoBroadcaster` with 30 ms ramped delay (Round 11).

### Menubar app (`apps/menubar/Sources/SyncCastMenuBar/`)
- `SyncCastApp.swift` — `MenuBarExtra`. `statusIcon(name:)` helper unifies SF Symbol vs Bundle.module loose-PNG (Round 11).
- `AppModel.swift` — `@Observable @MainActor`. Owns `routing`, `mode`, `streamingState`, sleep/wake observer (Round 12). Critical methods: `bootstrap()`, `reconcileEngine()`, `handleWake(notification:)`, `startPowerEventWatch()`, `applyEvent(_:)`.
- `MainPopover.swift` — SwiftUI popover. AirPlay manual delay slider (Round 11).
- `Resources/MenubarIcon.png` (+@2x +@3x) — flat PNGs (no xcassets, codex caught the build problem in Round 11).
- `Resources/AppIcon.icns` — 612 KB built from `assets/branding/app-icon-1024.png`.

### Build & deploy
- `scripts/package-app.sh` — assembles `dist/SyncCast.app`. Copies Swift binary, SwiftPM resource bundle (with manual `Info.plist` for codesign), `.icns`, sidecar PyInstaller binary, OwnTone, dylib closure.
- `scripts/install-app.sh` — codesigns with `SyncCast Dev` self-signed cert (TCC-stable across rebuilds), copies to `/Applications/SyncCast.app`.
- `scripts/release.sh` — single-command release. Reads `VERSION`, syncs `Info.plist CFBundleShortVersionString`, tags, pushes, `gh release create`.

### Logging
- `~/Library/Logs/SyncCast/launch.log` — `SyncCastLog.log(...)` writes here. **Read this first** when debugging anything.
- stderr from Router goes to system log (`log show --predicate 'process == "SyncCastMenuBar"'`).

---

## 3. Recent rounds — what was fixed

### Round 11 (2026-04-26 → 04-27) — UI / branding / packaging
- Manual-first calibration UX (menubar UI redesign with delay slider)
- Liquid Glass white-base app icon: AppIcon.icns + menubar template + favicon + GitHub OG image
- Bilingual READMEs (zh-CN + en)
- v0.1.0-alpha GitHub release with `SyncCast.app.zip`
- Release infrastructure: `VERSION` + `scripts/release.sh` + `.github/workflows/release.yml` (build verify on tag push)

### Round 12 (2026-04-28 → 04-29) — sleep/wake audio recovery
**Bug**: stereo mode after monitor DPMS sleep → audio silent, user must deselect+reselect both outputs to recover.

**Root causes** (3 layered, found across 5 codex review cycles):
1. **HDMI device identity flip** — display sleep → HDMI subdevice disappears from `kAudioHardwarePropertyDevices`; on wake reappears with same UID but new `AudioDeviceID`. Existing AggregateDevice points at dead ID → silent underrun.
2. **`reconcileLocalDriver` short-circuit** — `alreadyCorrect` returns early when enabled UID set didn't change (which it didn't on transient wake), skipping the rebuild that would fix #1.
3. **SCK stream death** — display sleep also breaks SCStream (`connectionInvalid -3805`). Even after aggregate rebuild, no source feeds the new ringBuffer → silent.

**Fix chain** (commits in order):
- `2126923` v1: NSWorkspace `didWakeNotification` + `screensDidWakeNotification` double-listen + `forceLocalDriverRebuild` bypassing short-circuit. **Insufficient — only rebuilt local driver, not SCK.**
- `fec46d1`, `a95e45b`, `ba2934c` — hardening (retry-backoff, observer dedup, single-flight task, shadow set for transiently-missing-but-user-enabled UIDs, off-by-one fix).
- `5be9206` v2: SCK `stop()` + `start()` inside `forceLocalDriverRebuild` + `onUnexpectedStop` callback hook. **Codex caught 3 races.**
- `e1175c3` v3 (post Codex Cycle 1): same-stream identity guard in `didStopWithError`, assignment-before-`startCapture()`, `forceLocalDriverRebuild` returns Bool; AppModel wake loop requires `sckOK && allResolved`. **Codex caught 2 more deeper races.**
- `cd8b8df` v4 (post Codex Cycle 2): post-`startCapture()` verify-then-act guard (throws on stream race), per-attempt device snapshot inside retry loop. **CURRENT HEAD.**

**Status**: deployed at `/Applications/SyncCast.app` (00:29 today). Awaiting user real-world DPMS-sleep verification with stereo + 2 enabled outputs. Latest log evidence (`21:25:27` previous build) showed wake handler firing but SCK was the missing piece — that's now fixed in `cd8b8df`.

---

## 4. Open issues — prioritized for Codex Review takeover

### A. Verify Round 12 v4 fix in real-world (high)
- Need user to enable MacBook + HDMI in stereo mode, play audio, let display sleep naturally (not just `pmset displaysleepnow` — codex flagged that 5 s sleep ≠ 20 min deep DPMS), wake, observe.
- Expected log sequence at `~/Library/Logs/SyncCast/launch.log`:
  ```
  AppModel: wake event NSWorkspaceScreensDidWakeNotification
  AppModel: post-wake force rebuild local driver (live=2, transient=0 UIDs)
  [Router] forceLocalDriverRebuild: tearing down + rebuilding (incl. SCK)
  [Router] forceLocalDriverRebuild: SCK restart OK
  AppModel: post-wake rebuild succeeded first try (sck=ok, uids=live)
  SCK report @ 1s: seen=... peak=...
  ```
- If `sck=FAIL` or `uids=stale` repeats 4× → look at error in `[SCKCapture] stream stopped with error: ...` and address that specific failure mode.

### B. ScreenCaptureKit + DRM incompatibility (HIGH — user-reported)
- **User feedback (2026-04-29)**: when SyncCast is running, DRM-protected playback fails (Netflix, Apple TV+, Disney+ refuse to play because SCK = "screen recording active"). Movies don't play; some apps degrade.
- This is the SCK trade-off — system audio capture currently piggybacks on `SCStream` which requires Screen Recording permission and signals to playback DRM systems that the screen is being captured.
- **The right fix is to leave SCK and adopt one of these**:
  - **Audio Process Tap API** (macOS 14.2+) — `CATapDescription` lets you tap audio per-process or system-wide WITHOUT screen recording permission. This is Apple's intended replacement for the SCK-for-audio-only pattern. **PRIMARY recommendation.**
  - **AudioServerPlugIn** (kernel-level virtual driver, BlackHole-style) — install kext / DriverKit driver. macOS routes audio through it. Pros: most robust, DRM-invisible. Cons: requires user system extension permission, DriverKit complexity, signing.
  - **Loopback / Rogue Amoeba ARK** — only if licensable, not a DIY path.

- See § 5 for the recommended exploration plan.

### C. Sync quality / latency residual (medium)
- Manual delay slider (Round 11) lets user dial-in AirPlay alignment but cross-device drift may still exist over long sessions. Drift tracker / closed-loop calibration was deprecated in Round 11 because GCC-PHAT in audible band fights DRM/AGC.
- If staying with current sources after the SCK migration, revisit per-device drift (Phase 2 of Round 11 design).

### D. Hot-plug / device rename (low)
- `applyEvent(.appeared)` migrates routing on UID match. Robust enough for normal use but `.disappeared` deletion is "hard" — Round 12 added `transientlyMissingEnabledCoreAudioUIDs` shadow set as a workaround. Long-term: persist desired routing by UID across restarts (currently in-memory only, mic config does this already).

### E. AirPlay mode wake handler (low)
- Round 12 wake handler skips whole-home mode (`mode != .stereo`). Comment says "AirPlay self-heals via OwnTone RTSP retry". Codex Cycle 1 flagged this as a follow-up — verify whole-home actually self-heals, or extend the wake handler to AirPlay too.

### F. Codex Cycle 2 follow-ups not blocking (low)
- Optional sample-output stream-identity guard for symmetry (`SCKCapture.swift:469-473`).
- `removeStreamOutput` in `stop()` (currently only on throw path).

---

## 5. New direction — replacing ScreenCaptureKit (top priority for Codex Review)

### 5.1 Why
SCK forces Screen Recording permission AND triggers DRM playback blocks. User reported Netflix/Apple TV+ refusing to play with SyncCast running. This kills the "always-on" use case.

### 5.2 Recommended primary path: Audio Process Tap API (`CATapDescription` / `AudioHardwareCreateProcessTap`)

Available in macOS 14.2+. Lets a process tap system-wide audio (or per-process audio) **without screen recording permission**. Apple specifically introduced this for audio-only capture clients.

Key APIs:
- `CATapDescription` — describes what to tap (process list, mute behavior, mono/stereo).
- `AudioHardwareCreateProcessTap(...)` — returns an `AudioObjectID` you can read from like a normal CoreAudio device.
- Composes with AggregateDevice — you can include the tap as a sub-device of an aggregate.

Caveats to research:
- Permissions model — does it require any user grant beyond microphone? (early reports say no, but verify on Sequoia/Tahoe)
- Latency vs SCK (SCK is ~10-20 ms; tap API likely lower since it's HAL-level)
- Mute behavior — `CATapMuteBehavior` controls whether the tapped process keeps hearing its own output
- Signing entitlements — confirm what's needed in `Info.plist` / code sign

Reference / exploration order:
1. Apple WWDC23/24 sessions on CoreAudio
2. `BackgroundMusic` and `eqMac` open-source projects (both moved off SCK, study their CATapDescription wiring)
3. `AudioCap` sample code if Apple ships one
4. Test reproduction of DRM playback under the new path

### 5.3 Fallback: AudioServerPlugIn / DriverKit virtual device

If the tap API doesn't deliver (DRM bypass not perfect, latency too high, or hits a Sequoia regression), fall back to a virtual audio driver:
- BlackHole-style approach: ship a lightweight DriverKit driver (or kext on older macOS) that appears as an output device. User selects it in System Settings as their default output. SyncCast reads from it.
- Pros: zero permissions UI, DRM completely invisible (just an audio device).
- Cons: significant new component, DriverKit signing, install/uninstall UX.

### 5.4 Migration plan sketch
- Phase 1: keep SCK as default. Add a feature flag `useTapAPI: Bool` in `Configuration`. Implement `TapCapture.swift` mirroring `SCKCapture.swift`'s `RingBuffer` interface.
- Phase 2: dogfood with feature flag on. Verify: latency, DRM apps work, all the same SyncCast features (calibration, multi-output sync) still work.
- Phase 3: flip default. Keep SCK as a fallback for macOS <14.2.
- Phase 4: deprecate SCK path.

### 5.5 Suggested first-week deliverables for Codex Review
1. Read Apple's `CATapDescription` headers + sample. Output: 1-page memo `docs/research/process_tap_api.md` covering API surface + permissions + entitlements + known caveats.
2. Repro the DRM block currently — install SyncCast, try Netflix, document exact failure mode.
3. Prototype `TapCapture.swift` skeleton matching `SCKCapture` interface (start/stop/`ringBuffer`).
4. Wire feature flag through `Router` → `AppModel` settings.
5. End-to-end test: Netflix plays + SyncCast captures + multi-device output.

---

## 6. GitHub repo management

### Repo
`https://github.com/vcxzvfe/syncast` — main + (currently) one feature branch `claude/pensive-merkle-5ab344` (worktree-bound, ignore).

### Recent main commits (newest first)
```
cd8b8df fix(audio): codex cycle-2 review must-fixes (verify-then-act + per-attempt snapshot)
e1175c3 fix(audio): codex cycle-1 review must-fixes (3 race bugs in SCK restart)
5be9206 fix(audio): restart SCK capture in forceLocalDriverRebuild + wire didStopWithError callback
ba2934c fix(audio): codex must-fix hardening — disappearance race + retry off-by-one + nonisolated UID probe + single-flight
a95e45b fix(audio): differentiate post-wake skip reasons in log
fec46d1 fix(audio): harden wake recovery with retry-backoff + observer dedup + AirPlay log
63eed7a fix(audio): auto-recover from display-sleep / system-wake breaking local driver
9466d6f chore: ignore .claude/worktrees/ + drop accidentally-added submodule pointers
921226d fix(ui): unify menubar + popover header icon loader (statusIcon helper)
41994c5 fix(menubar): flat PNG + Bundle.module.image to bypass uncompiled xcassets
```

### Branch policy
- All Round 11/12 work shipped directly to `main` (small project, single maintainer).
- Worktree-based agents created branches like `round12-fixer-X` then cherry-picked to `main`. The worktree branches stay around in the local clone (`git worktree list`) but are not pushed.

### Tag / release flow
- Latest tag: `v0.1.0-alpha` (`SyncCast.app.zip` 25 MB asset).
- To cut a new release:
  ```bash
  bash scripts/release.sh --bump alpha-rev   # 0.1.0-alpha → 0.1.0-alpha.1
  bash scripts/release.sh --bump patch       # 0.1.0-alpha → 0.1.1-alpha
  bash scripts/release.sh                    # republish current VERSION (with --draft if testing)
  ```
- The script: dirty-tree guard → bump VERSION → sync `Info.plist` → tag → push → swift build → package-app.sh → ditto zip → `gh release create --prerelease`.

### CI
- `.github/workflows/release.yml` — on `v*` tag push: macos-14 runner runs `swift build -c release` for both `core/router` and `apps/menubar`, asserts `apps/menubar/Resources/AppIcon.icns` exists, warns if `VERSION` mismatches the tag. **Verify-only, doesn't upload artifacts.**

### Social preview
- `.github/og-image.png` (1280×640) — must be uploaded manually via repo Settings → Social preview. See `.github/SOCIAL_PREVIEW.md`.

---

## 7. Local management

### Build / install loop
```bash
# 1. Edit code in apps/menubar/ or core/

# 2. Build (release config; SwiftPM CLI; takes ~10 s incremental, 50 s clean)
cd /Users/zifan/syncast/apps/menubar && swift build -c release

# 3. Package + install
cd /Users/zifan/syncast
bash scripts/package-app.sh
bash scripts/install-app.sh

# 4. Restart app
pkill -f SyncCastMenuBar; sleep 1; open /Applications/SyncCast.app

# 5. Tail log
tail -f ~/Library/Logs/SyncCast/launch.log
```

### Worktree convention
- Long-running agents work in `/Users/zifan/syncast/.claude/worktrees/agent-<id>/`.
- After cherry-picking their commit to `main` the worktree directory can be left in place or removed via `git worktree remove`.
- `.claude/worktrees/` is gitignored (added in commit `9466d6f`).

### Sidecar venv
- `sidecar/.venv/` lives only in the main checkout — fresh worktrees lack it. `package-app.sh` requires it to PyInstaller-bundle the sidecar. If a worktree-spawned agent tries to package, it'll fail; package from `/Users/zifan/syncast` instead.

### Useful one-liners
```bash
# Check installed binary timestamp
ls -la /Applications/SyncCast.app/Contents/MacOS/SyncCastMenuBar

# Check what's in the SwiftPM resource bundle
find /Applications/SyncCast.app/Contents/MacOS/SyncCastMenuBar_SyncCastMenuBar.bundle

# Repro display sleep (short — caveat: doesn't reproduce 20-min deep DPMS state)
pmset displaysleepnow ; sleep 6 ; caffeinate -u -t 1

# Repro coreaudiod hang (closer simulation of "device gone" state)
sudo killall coreaudiod

# Check current sleep/wake observer activity
log show --predicate 'process == "SyncCastMenuBar"' --info --last 5m | grep -iE 'wake event|force rebuild|sck restart'
```

---

## 8. Codex Desktop handoff prompt

Copy-paste the block below into a new Codex Desktop session. Codex Desktop has full repo read access on this machine; the prompt assumes that.

```
You're picking up SyncCast (https://github.com/vcxzvfe/syncast — local clone at /Users/zifan/syncast). Read /Users/zifan/syncast/docs/HANDOFF.md FIRST — it's an authoritative briefing.

Current HEAD on main: cd8b8df (Round 12 v4 — sleep/wake audio recovery fix, awaiting real-world verification).

Your priorities, in order:

(P0) Confirm Round 12 v4 actually fixes the user's display-sleep audio break. The user is testing now with stereo mode + 2 enabled outputs. They'll send the log if it still breaks. The diagnostic log lines to look for are documented in HANDOFF.md §4.A.

(P1) THE BIG ONE — replace ScreenCaptureKit as the audio source. SCK triggers DRM playback blocks (Netflix/Apple TV+/Disney+ refuse to play when SyncCast runs). See HANDOFF.md §5 for the recommended path: Apple's CATapDescription / AudioHardwareCreateProcessTap (macOS 14.2+ Audio Process Tap API). First deliverable: docs/research/process_tap_api.md memo + a reproducible DRM-block test. Then prototype TapCapture.swift behind a feature flag.

(P2) Open issues §4.B-F as time permits.

Repo conventions:
- Build/install/test loop: HANDOFF.md §7
- Release: bash scripts/release.sh --bump alpha-rev (HANDOFF.md §6)
- Always tail ~/Library/Logs/SyncCast/launch.log when debugging
- Cache by coreAudioUID, never AudioDeviceID (lessons from Round 12)
- For SwiftPM resources prefer flat PNGs in Resources/ over Assets.xcassets unless you can run actool (we can't on Command Line Tools-only — see Round 11 menubar icon saga, commit 41994c5)

When you write code: small commits, descriptive messages following the existing format ("fix(audio): ...", "feat(...)"); update HANDOFF.md if you change priorities or invalidate any §3-7 content.
```

---

## 9. Quick state sanity check (run anytime)

```bash
# Where main is
cd /Users/zifan/syncast && git log --oneline -5 main

# Whether install matches main
git -C /Users/zifan/syncast rev-parse HEAD ; \
  ls -la /Applications/SyncCast.app/Contents/MacOS/SyncCastMenuBar | awk '{print $6, $7, $8}'

# Latest log activity
tail -30 ~/Library/Logs/SyncCast/launch.log
```

If those don't match what HANDOFF.md says, something diverged — investigate before making changes.

---

*This document supersedes all prior HANDOFF.md / hand-off notes in this repo.*
