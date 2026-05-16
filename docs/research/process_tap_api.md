# Core Audio Process Tap API - SyncCast Research Memo

> Last updated: 2026-05-13
> Status: implementation memo for capture-dependent paths. Direct Stereo is preferred for default local Stereo because it avoids capture entirely; Process Tap remains the candidate non-SCK backend for paths that still need system-audio capture, and DRM/AirPlay-calibration behavior is not yet proven.

## Why this matters

ScreenCaptureKit solved the original BlackHole/TCC capture problem, but it uses Screen Recording semantics and can block DRM playback. SyncCast's always-on product path needs system audio capture without behaving like a screen recorder.

Core Audio Process Tap is the preferred next backend for macOS 14.2+. The target is not to redesign routing. The target is to feed the same `RingBuffer` contract that `SCKCapture` feeds today:

- 48 kHz
- stereo
- Float32
- planar/non-interleaved at the `RingBuffer` boundary

Stereo local mode must remain the stable product surface while this backend changes.

## SDK surface found locally

Local SDK inspected:

- `/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk`
- `/Library/Developer/CommandLineTools/SDKs/MacOSX26.4.sdk`

Relevant headers:

- `CoreAudio.framework/Headers/CATapDescription.h`
- `CoreAudio.framework/Headers/AudioHardwareTapping.h`
- `CoreAudio.framework/Headers/AudioHardware.h`
- Swift overlay: `usr/lib/swift/CoreAudio.swiftmodule/*-apple-macos.swiftinterface`

Primary Apple references:

- [Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)
- [AudioHardwareCreateProcessTap(_:_:)](https://developer.apple.com/documentation/coreaudio/audiohardwarecreateprocesstap%28_%3A_%3A%29)
- [CATapDescription](https://developer.apple.com/documentation/coreaudio/catapdescription)

Key facts:

- `AudioHardwareCreateProcessTap(CATapDescription*, AudioObjectID*)` is available on macOS 14.2+.
- `AudioHardwareDestroyProcessTap(AudioObjectID)` is available on macOS 14.2+.
- `CATapDescription` can describe global stereo/mono taps, process-specific taps, and device-stream-specific taps.
- The Swift overlay exposes convenience initializers such as `CATapDescription(stereoGlobalTapButExcludeProcesses:)`.
- Tap objects expose a UID, description, and format through `kAudioTapPropertyUID`, `kAudioTapPropertyDescription`, and `kAudioTapPropertyFormat`.
- Aggregate devices can include taps via `kAudioAggregateDeviceTapListKey`.
- Private aggregate devices can use `kAudioAggregateDeviceTapAutoStartKey`.
- Sub-tap objects have drift and latency properties, which may matter if the tap is hosted inside an aggregate device.

## Likely architecture

Process Tap does not look like SCK's callback model. The likely Core Audio shape is:

1. Create a `CATapDescription`.
2. Create a process tap with `AudioHardwareCreateProcessTap`.
3. Read `kAudioTapPropertyUID` and `kAudioTapPropertyFormat`.
4. Create a private aggregate device and attach the tap UID to its tap list. Apple's sample describes creating the aggregate first, then setting `kAudioAggregateDevicePropertyTapList`; the headers also expose `kAudioAggregateDeviceTapListKey` for aggregate composition dictionaries.
5. Create an input IOProc on that aggregate device.
6. In the IOProc, convert/copy input buffers into SyncCast's `RingBuffer`.
7. On stop, destroy IOProc, aggregate device, and process tap in that order.

This means `TapCapture` should mirror `SCKCapture` at the `SystemAudioCapture` protocol, not at the internal callback implementation.

## Recommended first implementation

Start narrow:

- Add `TapCapture.swift` as a new `SystemAudioCapture` implementation.
- Gate it behind `SYNCAST_CAPTURE_BACKEND=tap`.
- Use `CATapDescription(stereoGlobalTapButExcludeProcesses: [own process object id])` if the process object ID exclusion path is straightforward.
- If own-process AudioObjectID resolution is not straightforward in the first pass, create a global stereo tap and rely on local-output loop prevention tests before dogfooding. Do not ship that path as default.
- Use `CATapUnmuted`; SyncCast should capture audio while normal playback continues through hardware.
- Query the tap format and accept either Float32 interleaved or non-interleaved; add conversion when format differs from the `RingBuffer` contract.
- Keep SCK as default until Tap passes non-DRM audio, DRM playback, local Stereo, and sleep/wake smoke tests.

## Permission and plist notes

Apple documents `NSAudioCaptureUsageDescription` as the Info.plist usage string for apps that request access to capture system audio on macOS.

SyncCast should include:

```xml
<key>NSAudioCaptureUsageDescription</key>
<string>SyncCast captures system audio so it can play the same audio through the output devices you enable.</string>
```

Tap mode should not trigger Screen Recording prompts. If Screen Recording appears while `SYNCAST_CAPTURE_BACKEND=tap`, the implementation is still using SCK somewhere in the startup path.

## Validation matrix

Minimal local validation:

- `SYNCAST_CAPTURE_BACKEND=sck`: existing behavior unchanged.
- `SYNCAST_CAPTURE_BACKEND=tap`: app starts without Screen Recording prompt.
- Normal non-DRM audio increments `backend=tap ... ticks=...` in `~/Library/Logs/SyncCast/launch.log`.
- Stereo local output remains audible on two enabled local devices.
- Sleep/wake restart path logs `capture restart OK (tap)`.

DRM validation:

- Baseline: quit SyncCast and verify Netflix/Apple TV+/Disney+ playback starts.
- SCK negative control: launch SCK mode and confirm the known DRM block/rejection still reproduces.
- Tap positive control: launch Tap mode and verify DRM playback starts while SyncCast keeps capturing non-DRM audio before/after the DRM playback attempt.
- Record exact app, browser, macOS build, SyncCast commit, and log excerpt.

AirPlay validation:

- Do not use a quick AirPlay success as proof of reliability.
- Treat AirPlay as experimental until a 2+ receiver, 2+ hour drift/recovery protocol passes repeatedly.

## Open questions before defaulting Tap

- How to resolve and exclude SyncCast's own Core Audio process object reliably.
- Whether Tap permission requires signing/notarization beyond the plist key on this machine.
- Whether macOS 14.2, 14.4, 15.x, and 26.x differ in prompt behavior or tap format.
- Whether private aggregate device cleanup is reliable after crash or force quit.
- Whether Tap survives display sleep better than SCK or needs the same forced restart path.
