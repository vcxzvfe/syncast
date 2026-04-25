# CoreAudio HAL Brief for SyncCast

**Audience:** SyncCast macOS menubar app (capture BlackHole 2ch -> fan out to multiple physical outputs + AirPlay 2 via Python sidecar).
**Targets:** macOS 14 Sonoma / 15 Sequoia, Swift 5.9+, arm64 + x86_64.
**Scope:** CoreAudio HAL only. AirPlay 2 transport lives in the Python sidecar and is out of scope here except for the latency-matching consequence (Section 4).

---

## 1. Capturing from BlackHole 2ch

BlackHole presents itself as a normal CoreAudio aggregate-capable input device. Three viable capture paths exist, in increasing order of overhead:

| API | Latency | Format control | Verdict for SyncCast |
|---|---|---|---|
| `AudioDeviceCreateIOProcID` (HAL IOProc) | Lowest (~1 buffer) | Full | **Recommended** — we already need HAL for the multi-output fan-out; staying in one layer avoids format/clock impedance mismatches. |
| AUHAL (`kAudioUnitSubType_HALOutput` in input mode) | Low | Full, with built-in format converter | Good fallback if you want AU graph composition. |
| `AVAudioEngine.inputNode` + `installTap(onBus:)` | Higher, opinionated | Limited (engine picks format) | Avoid — `AVAudioEngine` does not let you bind input and output to different non-default devices cleanly, and tap callbacks are not real-time-safe. |

**Typical format BlackHole exposes:** 44.1 / 48 / 96 / 192 kHz, Float32, 2 ch, packed, non-interleaved. Frame size (IO buffer) is set per-device via `kAudioDevicePropertyBufferFrameSize`; valid range queried with `kAudioDevicePropertyBufferFrameSizeRange`. Use **512 frames @ 48 kHz** as the default (~10.6 ms) — this is BlackHole's configured default and matches what most apps render at.

### Snippet 1 — Open BlackHole as input via HAL IOProc

```swift
import CoreAudio
import AudioToolbox

func findDevice(named name: String) -> AudioDeviceID? {
    var size: UInt32 = 0
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    var ids = [AudioDeviceID](repeating: 0, count: count)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)

    for id in ids {
        var nameSize = UInt32(MemoryLayout<CFString?>.size)
        var cfName: CFString? = nil
        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nameSize, &cfName)
        if (cfName as String?)?.contains(name) == true { return id }
    }
    return nil
}

final class BlackHoleCapture {
    private var procID: AudioDeviceIOProcID?
    private let deviceID: AudioDeviceID

    init(deviceID: AudioDeviceID) { self.deviceID = deviceID }

    func start(onFrames: @escaping (UnsafePointer<Float>, Int, Int) -> Void) throws {
        // Pin buffer size to 512 frames.
        var frames: UInt32 = 512
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectSetPropertyData(deviceID, &addr, 0, nil,
                                   UInt32(MemoryLayout<UInt32>.size), &frames)

        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, nil) {
            _, inInputData, _, _, _ in
            let abl = inInputData.pointee
            guard abl.mNumberBuffers > 0 else { return }
            let buf = abl.mBuffers // first (input) buffer
            let nFrames = Int(buf.mDataByteSize) / MemoryLayout<Float>.size / Int(buf.mNumberChannels)
            onFrames(buf.mData!.assumingMemoryBound(to: Float.self),
                     nFrames, Int(buf.mNumberChannels))
        }
        guard status == noErr, let pid = procID else { throw NSError(domain: "HAL", code: Int(status)) }
        AudioDeviceStart(deviceID, pid)
    }
}
```

Refs: [HAL Services Reference](https://developer.apple.com/documentation/coreaudio/core_audio_hardware_services), [BlackHole README](https://github.com/ExistentialAudio/BlackHole#readme).

---

## 2. Programmatic Aggregate / Multi-Output Device

Use the **plug-in interface**: locate the HAL plug-in (`kAudioHardwarePropertyPlugInForBundleID` with `com.apple.audio.CoreAudio`), then `AudioObjectGetPropertyData` for the selector `kAudioPlugInCreateAggregateDevice`, passing a CFDictionary describing the device. The HAL returns the new `AudioObjectID` synchronously.

### Required dictionary keys

| Key constant | Type | Purpose |
|---|---|---|
| `kAudioAggregateDeviceNameKey` | CFString | Human-readable name |
| `kAudioAggregateDeviceUIDKey` | CFString | Stable UID (a UUID string) |
| `kAudioAggregateDeviceSubDeviceListKey` | CFArray of CFDict | Sub-device list, each with `kAudioSubDeviceUIDKey` |
| `kAudioAggregateDeviceMainSubDeviceKey` | CFString | UID of the **clock master** |
| `kAudioAggregateDeviceIsStackedKey` | CFNumber (Bool) | **`1` -> Multi-Output Device**; `0` -> ordinary Aggregate |
| `kAudioAggregateDeviceIsPrivateKey` | CFNumber (Bool) | `1` to hide from System Settings (recommended for SyncCast — we own it) |
| `kAudioAggregateDeviceClockDeviceKey` | CFString (optional) | Override clock domain |

Per-sub-device drift compensation is a property on the **sub-device** object, not in the create dict: `kAudioSubDevicePropertyDriftCompensation` (UInt32 0/1) and `kAudioSubDevicePropertyDriftCompensationQuality`.

### Snippet 2 — Create a private Multi-Output Device

```swift
import CoreAudio

func createMultiOutput(name: String, masterUID: String, subUIDs: [String]) throws -> AudioDeviceID {
    let dict: [String: Any] = [
        kAudioAggregateDeviceNameKey as String: name,
        kAudioAggregateDeviceUIDKey  as String: UUID().uuidString,
        kAudioAggregateDeviceMainSubDeviceKey as String: masterUID,
        kAudioAggregateDeviceIsPrivateKey as String: 1,
        kAudioAggregateDeviceIsStackedKey as String: 1,           // <- Multi-Output, not Aggregate
        kAudioAggregateDeviceSubDeviceListKey as String: subUIDs.map {
            [kAudioSubDeviceUIDKey as String: $0,
             kAudioSubDeviceDriftCompensationKey as String: ($0 == masterUID ? 0 : 1)]
        }
    ]

    var translation = AudioValueTranslation(
        mInputData: Unmanaged.passUnretained(dict as CFDictionary).toOpaque(),
        mInputDataSize: UInt32(MemoryLayout<CFDictionary>.size),
        mOutputData: nil, mOutputDataSize: 0)

    // Find the HAL plug-in object.
    var pluginID: AudioObjectID = 0
    var size: UInt32 = UInt32(MemoryLayout<AudioObjectID>.size)
    var bundleID = "com.apple.audio.CoreAudio" as CFString
    var pAddr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyTranslateBundleIDToPlugIn,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                               &pAddr, UInt32(MemoryLayout<CFString>.size), &bundleID,
                               &size, &pluginID)

    var newID: AudioDeviceID = 0
    var createAddr = AudioObjectPropertyAddress(
        mSelector: kAudioPlugInCreateAggregateDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var outSize = UInt32(MemoryLayout<AudioDeviceID>.size)
    let s = AudioObjectGetPropertyData(pluginID, &createAddr,
                                       UInt32(MemoryLayout<CFDictionary>.size),
                                       Unmanaged.passUnretained(dict as CFDictionary).toOpaque(),
                                       &outSize, &newID)
    guard s == noErr else { throw NSError(domain: "HAL.create", code: Int(s)) }
    return newID
}
```

To destroy at shutdown: `kAudioPlugInDestroyAggregateDevice` on the plug-in object with the device ID as input data.

Refs: [`AudioHardware.h`](https://developer.apple.com/documentation/coreaudio/audio_hardware_services), [TN2091](https://developer.apple.com/library/archive/technotes/tn2091/_index.html).

---

## 3. Fan-out to Multiple Physical Outputs

**Compared options:**

1. **Single Multi-Output Device (Section 2) + one IOProc.** Simplest; macOS handles drift compensation. **But:** per-device volume and per-device delay are *not* exposed — the OS sums everything into one buffer. Rejected for SyncCast.
2. **One AUHAL output unit per physical device, sharing a Float32 ring buffer.** Each AUHAL gets its own render callback; you apply per-device gain + delay (sample-shift on read pointer) in the callback. Drift between independent device clocks must be handled by you (asynchronous sample-rate converter, e.g. `AudioConverter` with `kAudioConverterSampleRateConverterComplexity_Mastering`). **Recommended.**
3. **Direct `AudioDeviceCreateIOProcID` per device.** Same shape as (2) but lower-level. Use this if you find AUHAL's format negotiation gets in the way; otherwise AUHAL's converter is worth it.
4. **`AVAudioEngine` with multiple output nodes.** Not supported — an engine binds to a single output device.

### Snippet 3 — One AUHAL per output, with per-device gain & sample-delay

```swift
import AudioToolbox

final class DeviceTap {
    let device: AudioDeviceID
    var gain: Float = 1.0          // 0..1, settable from UI thread
    var delaySamples: Int = 0      // settable from UI thread (atomic in real code)
    private var unit: AudioUnit?
    private let ring: SPSCRing      // your lock-free ring; not shown

    init(device: AudioDeviceID, ring: SPSCRing) {
        self.device = device; self.ring = ring
    }

    func start(format: AudioStreamBasicDescription) throws {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        let comp = AudioComponentFindNext(nil, &desc)!
        AudioComponentInstanceNew(comp, &unit)

        var dev = device
        AudioUnitSetProperty(unit!, kAudioOutputUnitProperty_CurrentDevice,
                             kAudioUnitScope_Global, 0, &dev, UInt32(MemoryLayout.size(ofValue: dev)))
        var fmt = format
        AudioUnitSetProperty(unit!, kAudioUnitProperty_StreamFormat,
                             kAudioUnitScope_Input, 0, &fmt, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))

        var cb = AURenderCallbackStruct(
            inputProc: { ctx, _, _, _, frames, ioData -> OSStatus in
                let me = Unmanaged<DeviceTap>.fromOpaque(ctx!).takeUnretainedValue()
                let abl = UnsafeMutableAudioBufferListPointer(ioData!)
                me.ring.read(into: abl, frames: Int(frames),
                             gain: me.gain, delay: me.delaySamples)
                return noErr
            },
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        AudioUnitSetProperty(unit!, kAudioUnitProperty_SetRenderCallback,
                             kAudioUnitScope_Input, 0, &cb, UInt32(MemoryLayout.size(ofValue: cb)))

        AudioUnitInitialize(unit!)
        AudioOutputUnitStart(unit!)
    }
}
```

The ring buffer is filled from the BlackHole IOProc (Section 1). Each `DeviceTap` reads at its own pace; per-device delay = sample-offset into the ring; gain = scalar multiply in the callback. **Real-time-safety rules apply** — no allocation, no locks, no Swift refcount churn in the callback.

---

## 4. Per-Device Latency, Safety Offset, AirPlay Matching

CoreAudio reports four numbers that must be summed to get total path latency:

```swift
func totalLatencySamples(_ dev: AudioDeviceID, scope: AudioObjectPropertyScope) -> UInt32 {
    func get(_ sel: AudioObjectPropertySelector) -> UInt32 {
        var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: scope,
                                              mElement: kAudioObjectPropertyElementMain)
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &v)
        return v
    }
    return get(kAudioDevicePropertyLatency)
         + get(kAudioDevicePropertySafetyOffset)
         + get(kAudioDevicePropertyBufferFrameSize)
         // + stream latency, queried per stream:
         // get(kAudioStreamPropertyLatency) summed over streams
}
```

`scope` is `kAudioObjectPropertyScopeOutput` for playback, `…ScopeInput` for capture. `kAudioDevicePropertyLatency` is the device-level hardware latency, `kAudioDevicePropertySafetyOffset` is the IO safety margin, the buffer size accounts for the IOProc cycle, and `kAudioStreamPropertyLatency` adds per-stream conversion latency.

**AirPlay 2 alignment.** AirPlay 2 receivers are reached via the Python sidecar (likely `pyatv` / RAOP), not as CoreAudio devices, so they will not appear in `kAudioHardwarePropertyDevices`. Their target playback offset is fixed by the protocol at **~2 s** (2,000 ms ± a few ms depending on receiver firmware; AirPort Express is the historical low end at ~1.95 s). The local-output strategy:

1. Compute per-local-device total latency `L_i` in samples.
2. Compute target offset `T = round(2.0 * sampleRate)` (or the value the sidecar reports back over the gRPC/IPC channel).
3. Set per-device `delaySamples = T − L_i` for each local `DeviceTap`.

Have the sidecar publish its actual achieved buffer (it can read it from the RTSP `Audio-Latency` response or from `pyatv`'s metadata) and re-tune `T` at session start. Hard-coding 2 s drifts on Sonos-via-AirPlay-2 and HomePod minis.

---

## 5. Permissions & Entitlements

Modern macOS gates audio capture even for system-virtual devices. For SyncCast (menubar app, Sonoma/Sequoia):

**Info.plist (required):**
- `NSMicrophoneUsageDescription` — yes, even though BlackHole is virtual. The TCC prompt fires the first time you `AudioDeviceStart` on any device with input streams.
- `LSUIElement = YES` — menubar (no Dock icon).

**Entitlements:**
- **Non-sandboxed (recommended for v1):** no entitlements needed for capture/route. You may still want `com.apple.security.device.audio-input` for clarity if you later notarize-and-staple with Hardened Runtime.
- **Sandboxed:** requires `com.apple.security.device.audio-input = true`. The sandbox does *not* block creating aggregate/multi-output devices, but it does block reading arbitrary preferences and writing to `/Library/Audio/Plug-Ins`. Aggregate-device creation via the HAL plug-in itself works inside the sandbox.
- **Hardened Runtime:** required for notarization. Add `com.apple.security.cs.disable-library-validation` only if you load 3rd-party AU plug-ins (you don't).
- **No special entitlement** for `kAudioPlugInCreateAggregateDevice` — it's a user-space HAL call.

You will *not* need ScreenCaptureKit's audio-tap entitlement unless you switch from BlackHole to the SCK system-audio API later (worth tracking — SCK system audio in Sequoia removes the BlackHole dependency entirely).

Refs: [Apple — Requesting Authorization for Media Capture on macOS](https://developer.apple.com/documentation/avfoundation/requesting_authorization_for_media_capture_on_macos), [Hardened Runtime entitlements](https://developer.apple.com/documentation/security/hardened_runtime).

---

## 6. BlackHole Gotchas

- **Sample-rate mismatch is silent.** If the source app renders at 44.1 kHz but BlackHole is set to 48 kHz, you get pitch/tempo skew, no error. Lock BlackHole to a known rate via `kAudioDevicePropertyNominalSampleRate` at app start, and reject startup if the rate doesn't match what your fan-out expects. ([BlackHole README — "Match Sample Rates"](https://github.com/ExistentialAudio/BlackHole#match-sample-rates))
- **No exclusive (hog) mode needed** — BlackHole is multi-client by design. Do *not* call `AudioDeviceSetProperty` for `kAudioDevicePropertyHogMode`; it will lock other apps out.
- **Channel count is fixed per variant.** BlackHole 2ch, 16ch, 64ch are separate kexts/drivers with hard-coded channel counts. SyncCast targets the 2ch variant; if a user has only 16ch installed, detect by channel-count probe (`kAudioDevicePropertyStreamConfiguration`) and surface a clear error rather than silently mixing down.
- **Float32 only.** BlackHole always advertises `kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved`. Don't try to negotiate Int16.
- **First-launch zero-buffer bug (older releases).** On BlackHole < 0.5, the first ~50 ms after `AudioDeviceStart` can be silence even when the source is playing. Workaround: start capture, wait 100 ms, then unmute the user-visible path.
- **System Settings > Sound > Output set to BlackHole creates a feedback loop** if SyncCast then routes one of its outputs back through BlackHole. Validate that no `DeviceTap.device` UID equals the BlackHole UID before starting.
- **macOS 14.4 regression** caused some aggregate-device IOProcs to stop firing after sleep/wake; fixed in 14.5. Register for `kAudioHardwarePropertyDevices` change notifications and rebuild the multi-output device on wake as a defensive measure.

---

## Citations

- Apple — Core Audio Hardware Services: <https://developer.apple.com/documentation/coreaudio/core_audio_hardware_services>
- Apple — `AudioHardware.h` constants (incl. aggregate keys): <https://developer.apple.com/documentation/coreaudio/1572145-audio_hardware_services_propertie>
- Apple — TN2091 "Device Input using HAL Output Audio Unit": <https://developer.apple.com/library/archive/technotes/tn2091/_index.html>
- Apple — Requesting Audio Capture Authorization (macOS): <https://developer.apple.com/documentation/avfoundation/requesting_authorization_for_media_capture_on_macos>
- Apple — Hardened Runtime entitlements: <https://developer.apple.com/documentation/security/hardened_runtime>
- BlackHole README (Existential Audio): <https://github.com/ExistentialAudio/BlackHole>
- Apple sample "MultiOutputDevice" (legacy but still illustrative): <https://developer.apple.com/library/archive/samplecode/MultiOutputDevice/>
