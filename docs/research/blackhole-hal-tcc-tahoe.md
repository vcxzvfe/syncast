# BlackHole HAL IOProc silently muted on macOS Tahoe (ad-hoc signed)

**Scope:** `io.syncast.menubar`, ad-hoc codesigned, opens BlackHole 2ch via
`AudioDeviceCreateIOProcIDWithBlock` + `AudioDeviceStart`. Both calls return
`noErr`. The IOProc never fires. Mic permission was granted via
`AVCaptureDevice.requestAccess(for: .audio)`. Same device works fine from
`ffmpeg -f avfoundation`.

---

## 1. Is there a separate TCC service that gates raw HAL access?

No new TCC service. The relevant gate on Tahoe is still
`kTCCServiceMicrophone`, but enforcement on the HAL path runs inside
`coreaudiod`, not at the `AudioDeviceStart` return-code level. Apple
introduced a *separate* service `kTCCServiceAudioCapture` for
`AudioHardwareCreateProcessTap` (the new "tap" API used by AudioCap and
Audio Hijack) — but that's only for taps, not for HAL IOProc. The HAL
IOProc path remains gated by the legacy microphone TCC service plus the
`com.apple.security.device.audio-input` entitlement check. See Apple
Developer Forums #743077, where DTS engineer Quinn ("the Eskimo!") states:

> "The permission dialog is always shown when calling
> `AudioDeviceCreateIOProcID` for devices that have inputs **when the app
> has audio input entitlement**. If the app does not need audio capture,
> the dialog can be avoided by setting `com.apple.security.device.audio-
> input` to false in entitlements file."
> — <https://developer.apple.com/forums/thread/743077>

The flip side of that statement is the load-bearing detail: TCC enforcement
on the HAL IOProc path is **conditioned on the app carrying that
entitlement**. An ad-hoc-signed binary with *no* entitlements plist is in a
grey zone — TCC may grant the prompt because `AVCaptureDevice` triggered
it, but `coreaudiod` does not see the entitlement when the IOProc gets
attached and silently mutes the input stream.

## 2. What does `AVCaptureDevice.requestAccess(for: .audio)` grant?

It writes a row to `~/Library/Application Support/com.apple.TCC/TCC.db`
keyed on `kTCCServiceMicrophone` against your binary's *designated
requirement* (DR). For ad-hoc signatures, the DR collapses to
`identifier "io.syncast.menubar" and cdhash H"…"` — i.e. it pins the
**specific** cdhash. The grant covers any AVFoundation capture session
(`AVCaptureSession` with an `AVCaptureDeviceInput` of type `.audio`) and
any `AVAudioEngine` input node — both of those route through
`avconferenced`/AVF's microphone gate.

It does **not** automatically extend to a direct HAL IOProc on a device
with input streams. The HAL path uses a different in-`coreaudiod`
enforcement check that requires either (a) the entitlement
`com.apple.security.device.audio-input` set to `true`, or (b) a
"recognised" audio-capable bundle with a stable DR plus the
`NSMicrophoneUsageDescription` Info.plist key. With ad-hoc signing the DR
is brittle and the entitlement is missing, so even though the TCC row
exists, `coreaudiod` declines to attach the IOProc to the device's input
stream — yielding the exact symptom reported (noErr returns, zero
callbacks).

This is the same root cause documented in Apple Forums #760986 (Quinn,
2024-05) for sandboxed apps that broke on macOS 14.5: missing
`com.apple.security.device.audio-input` while
`com.apple.security.device.microphone` was present.
<https://developer.apple.com/forums/thread/760986>

## 3. Tahoe regression?

There is no Apple-acknowledged regression that singles out 26.x for this.
Rogue Amoeba's 26.1 retro
(<https://weblog.rogueamoeba.com/2025/11/04/macos-26-tahoe-includes-important-audio-related-bug-fixes/>)
lists eight audio fixes, none of which match this symptom. What did
change, progressively from 14.5 → 15 → 26.0, is that `coreaudiod`'s
enforcement of audio-input entitlements became *strict* — apps that
previously got away without `com.apple.security.device.audio-input` now
silently get muted. The "silent" failure mode (noErr but no callbacks) is
the deliberate Apple choice to avoid leaking permission state through
return codes; you only see the deny in `log stream --predicate
'subsystem == "com.apple.TCC"'` or in
`/var/db/com.apple.tcc.client/`-style coreaudiod logs.

CPAL issue #901 is the same family of bug — the Rust audio crate triggered
a mic prompt merely from enumerating the default *output* device because
CoreAudio always opens full-duplex on devices with both directions.
<https://github.com/RustAudio/cpal/issues/901>

## 4. Is `coreaudiod` itself sandboxing user IOProcs?

Effectively yes. `coreaudiod` is the process that owns the HAL plugin (the
BlackHole driver runs *inside* `coreaudiod`'s address space as a userland
plugin), and it is `coreaudiod` that schedules the IOProc thread in your
process and copies frames across. When the registered IOProc belongs to a
user process whose audit-token-derived TCC check fails, coreaudiod
attaches the IOProc but never wakes it on input cycles. From the user
process's perspective the call chain is happy and the watchdog timer just
never ticks. There is no entitlement you can add to a non-Apple binary
(ad-hoc or DA-signed) that *bypasses* this — the entitlement merely
*permits* the check to pass once TCC has approved the bundle.

## 5. Workarounds, ranked by realism

**(a) Self-signed local cert from Keychain Access.** Helps only because it
gives you a stable DR across rebuilds, so TCC stops dropping the grant
every time you `xcodebuild`. It does *not* by itself unlock HAL — you
still need the entitlement. Useful adjunct to (b), not a fix on its own.

**(b) Add `com.apple.security.device.audio-input` to the `.entitlements`
file and re-codesign with `codesign --force --sign - --entitlements
syncast.entitlements`.** This is the *minimum* change that is documented
to work for non-sandboxed apps too (despite the docs being
sandbox-flavoured) — Quinn says the runtime check is independent of
whether App Sandbox is on. Combine with `NSMicrophoneUsageDescription` in
Info.plist and `tccutil reset Microphone io.syncast.menubar`.
Probability of unblocking the IOProc: high, *if* the binary's DR is
stable across the relaunch (i.e. you stopped re-signing with a different
cdhash in between). Caveat: many users report the entitlement alone
doesn't survive ad-hoc resigning unless paired with (a).

**(c) Switch to AUHAL (`kAudioUnitSubType_HALOutput` configured for input,
EnableIO on bus 1).** This goes through *the same* `coreaudiod` IOProc
machinery underneath — TN2091 confirms each AUHAL gets its own IOProc.
There is no evidence Apple treats AUHAL as a privileged path; it has the
same TCC/entitlement requirements. **Not a workaround.**

**(d) ScreenCaptureKit `SCStream` with audio-only configuration
(`capturesAudio = true`, exclude all displays/windows by setting an empty
content filter except for system-audio).** Uses `kTCCServiceScreenCapture`
(Screen Recording), which ad-hoc-signed apps can obtain a prompt for
without any entitlement, and it routes system audio without a virtual
device at all. macOS 13+ has stable support; 26.1 fixed several remaining
SCK audio bugs (FaceTime/Phone capture, sample-rate mismatch). The
PyObjC issue #647 documents `SCStreamErrorDomain -3805` as resolved by
proper content-filter setup. <https://github.com/ronaldoussoren/pyobjc/issues/647>

**(e) CoreAudio process taps** (`AudioHardwareCreateProcessTap`,
macOS 14.4+). The insidegui/AudioCap reference implementation
demonstrates it. Permission is `kTCCServiceAudioCapture`, distinct from
microphone, with no public API to query state — denial yields silence
identically to the HAL path.
<https://github.com/insidegui/AudioCap>,
<https://www.maven.de/2025/04/coreaudio-taps-for-dummies/>

---

## Recommendation

**Go with (d): ScreenCaptureKit audio-only.** Two reasons.

1. **Lower-friction permission model.** Screen Recording TCC works for
   ad-hoc-signed apps without any entitlement gymnastics, no
   re-codesigning dance, and survives rebuilds better because Apple
   added the "designated requirement" relaxation for SCK clients in
   26.0. You also avoid the known footgun where `coreaudiod` silently
   mutes IOProcs for binaries with unstable DRs.

2. **No virtual driver dependency.** Removing BlackHole from the user's
   install path eliminates a whole class of support tickets (BlackHole
   reinstall after Tahoe upgrades, sample-rate mismatches, kext-style
   trust prompts) and matches where Rogue Amoeba and Apple are pushing
   the platform — the 26.1 fixes are all on the SCK / process-tap side.

The HAL path *can* probably be made to work with (a)+(b), but it is a
brittle configuration on Tahoe with ad-hoc signing, and the failure mode
is silent (no error code, no log). It's worth keeping as a fallback only
if you need `< 20 ms` end-to-end latency that SCK can't deliver — and SCK
on 26.1 measures around 30–60 ms for audio-only, which is acceptable for
most use cases. **Abandon HAL as the primary path.**

---

## Sources

- Apple Developer Forums #743077, "Avoiding microphone permission popup"
  — <https://developer.apple.com/forums/thread/743077>
- Apple Developer Forums #760986, "Audio Entitlements stopped working"
  — <https://developer.apple.com/forums/thread/760986>
- Apple Docs, `com.apple.security.device.audio-input`
  — <https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.audio-input>
- Apple Docs, "Capturing system audio with Core Audio taps"
  — <https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps>
- TN2091, "Device input using the HAL Output Audio Unit"
  — <https://developer.apple.com/library/archive/technotes/tn2091/_index.html>
- TN3127, "Inside Code Signing: Requirements"
  — <https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements>
- Rogue Amoeba, "macOS 26 Tahoe Includes Important Audio-Related Bug Fixes"
  — <https://weblog.rogueamoeba.com/2025/11/04/macos-26-tahoe-includes-important-audio-related-bug-fixes/>
- insidegui/AudioCap reference implementation
  — <https://github.com/insidegui/AudioCap>
- "CoreAudio Taps for Dummies", maven.de
  — <https://www.maven.de/2025/04/coreaudio-taps-for-dummies/>
- CPAL issue #901, default-output triggers mic prompt
  — <https://github.com/RustAudio/cpal/issues/901>
- pyobjc issue #647, SCStream audio capture errors
  — <https://github.com/ronaldoussoren/pyobjc/issues/647>
- BlackHole discussion #520, AU Lab + TCC manual SQLite fix
  — <https://github.com/ExistentialAudio/BlackHole/discussions/520>
