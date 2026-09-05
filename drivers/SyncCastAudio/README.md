# SyncCastAudio.driver

A userland AudioServerPlugIn that publishes one ordinary-looking stereo output
device, "SyncCast", whose only reason to exist is that it HAS a volume and a
mute control. macOS gives no volume to an aggregate/multi-output device, so the
local Stereo path used to need a CGEventTap on the media keys; with this device
as the default output the system slider, F11/F12, the HUD and LinearMouse all
work natively, SyncCastRouter reads the scalar and re-applies it on the real
speakers.

The device discards all audio data. It is a control surface and a capture point
(a Process Tap pinned to it sees the mix before it arrives), never a loopback —
which is also why it deliberately has no input stream. Derived from Apple's
NullAudio sample.

Read `Source/SyncCastAudio.h` first: it carries the identity constants that must
stay in sync with `SystemSinkDevice.syncCastDriverUID` on the Swift side, the
measured volume law, and the mutex contract.

## Build, install, uninstall

```bash
bash drivers/SyncCastAudio/build.sh          # universal, -Wall -Wextra -Werror
sudo bash scripts/install-driver.sh          # rebuilds, installs, restarts coreaudiod
sudo bash scripts/install-driver.sh --uninstall
```

Installing restarts coreaudiod, which stops all audio on the machine for a
second or two — unavoidable, the HAL only scans the plug-in directory at
startup. `--uninstall` removes `/Library/Audio/Plug-Ins/HAL/SyncCastAudio.driver`
and restarts coreaudiod again; SyncCast then falls back to BlackHole if it is
installed, or to the legacy Direct Stereo path.

`build.sh` refuses to run as root (set `SYNCAST_ALLOW_ROOT_BUILD=1` to override,
for a CI image that genuinely is root) so a `sudo` install can never leave
root-owned artefacts in a developer checkout. `install-driver.sh` drops to
`SUDO_USER`, or to the console user when it was launched from the app through
`osascript ... with administrator privileges`, and refuses to build at all if
neither yields a non-root user.

## Tests

```bash
bash drivers/SyncCastAudio/tests/run_property_sweep.sh [io seconds]
```

`tests/property_sweep.c` dlopens a built bundle, calls `SyncCastAudio_Create`
and drives the interface the way the HAL does, with a stub host that implements
storage and answers `RequestDeviceConfigurationChange` by calling
`PerformDeviceConfigurationChange` back. The script runs it three ways: plain
against the real universal bundle, then with driver and harness recompiled under
`-fsanitize=address,undefined` and under `-fsanitize=thread`.

The harness was validated against two deliberate mutations before being trusted:
a one-word overrun in `PreferredChannelsForStereo` (ASan catches it) and an
unlocked read of `gVolume_Output_Scalar` (TSan catches it).

## Driver review 2026-09-05

An independent review found no crash paths and eight defects, all fixed on this
branch. What changed and what was verified:

| # | Fix |
|---|---|
| 1 | `GetZeroTimeStamp` ran on the real-time IO thread holding `gPlugIn_StateMutex`, the mutex the volume setter holds while allocating a CFNumber and writing it to storage. The timeline globals (`gDevice_HostTicksPerFrame`, `gDevice_NumberTimeStamps`, `gDevice_AnchorSampleTime`, `gDevice_AnchorHostTime`) moved to their own `gDevice_IOMutex`, as in NullAudio. No path holds both; where both are needed they are taken in sequence, state first. |
| 2 | `install-driver.sh` built only when `build/` was missing, so a stale bundle could be installed silently. It now rebuilds unconditionally whenever a source tree is present; bundled mode (a prebuilt driver inside the .app) is unchanged. |
| 3 | The `osascript … with administrator privileges` install path has no `SUDO_USER` and built as root. It now derives the console user, builds as them, and refuses rather than building as root; `build.sh` has the matching guard. |
| 4 | `WriteToStorage` ran on every volume step. Writes are coalesced behind a dirty flag to at most one per 500 ms, with an unconditional flush on the 1→0 StopIO transition. Mute still writes immediately — one discrete press, and the value whose loss is audible. No storage I/O happens on the IO thread. |
| 5 | `TranslateUIDToDevice` dereferenced `inQualifierData` after checking only its size; NULL is now rejected. |
| 6 | `kAudioStreamPropertyIsActive` claimed to be settable and then ignored the write. It now reports `settable = false` and returns `kAudioHardwareUnsupportedOperationError`. |
| 7 | The format setter accepted any framing. It now also validates `mBytesPerFrame`, `mBytesPerPacket`, `mFramesPerPacket == 1` and the interleaving flag against the advertised format. |
| 8 | An out-of-range rate in `PerformDeviceConfigurationChange` returned `kAudioHardwareBadObjectError` (the object was fine, the value was not) → `kAudioHardwareIllegalOperationError`; `SyncCastAudio_Create` NULL-guards the requested type UUID before `CFEqual`; the unused `<dispatch/dispatch.h>` include is gone.

Verified by `tests/run_property_sweep.sh` on 2026-09-05, macOS 26, Apple silicon:

- plain vs the universal bundle: 2477 checks, 0 failures
- ASan + UBSan: 2555 checks, 0 failures, no sanitizer reports
- TSan: 2571 checks, 0 failures, no data races (~3.9M `GetZeroTimeStamp` calls
  against ~230k property operations in the contention phase)
- timeline: 2 s of polling produced 4 steps of exactly 19200 frames, worst
  period error below the timer resolution
- persistence: 200 volume steps in one burst → 0–1 storage writes; one step
  after a 600 ms pause → exactly 1; StopIO flushes the final value

Known limits:

- The last value of a volume burst is not written to storage until the next
  step after the 500 ms window, or until StopIO. Worst case after a hard
  coreaudiod kill mid-drag is a level from ~500 ms earlier in the same gesture.
- The sweep runs the driver out of process, not inside coreaudiod. It proves
  the property and timeline contract and the locking; it does not prove how the
  HAL itself behaves with the device installed. That still needs the real
  install and a look at the Sound pane.
- Sanitized builds are single-arch (host). The universal build is covered by the
  plain pass only.
