# ScreenCaptureKit System-Audio Capture — Implementation Brief

**Target**: SyncCast (`io.syncast.menubar`), macOS 13+ minimum, validated on macOS Tahoe 26.4, ad-hoc signed.
**Goal**: Replace BlackHole + HAL IOProc capture path with `ScreenCaptureKit` (SCK) audio-only capture, feeding the existing `RingBuffer` (Float32 non-interleaved planar, 48 kHz stereo).

---

## 1. Why pivot to SCK

The HAL IOProc path (`AudioDeviceCreateIOProcIDWithBlock` + `AudioDeviceStart` on BlackHole) requires the **Microphone** TCC class. On macOS Tahoe with ad-hoc signed apps, `AVCaptureDevice.requestAccess(for: .audio)` returning `granted = true` does not reliably propagate to the HAL layer — the IOProc never fires. SCK uses the **Screen Recording** TCC class via a different daemon path, has a working prompt flow on Tahoe, and is Apple's officially blessed loopback API. No kext, no default-output reroute, no user-visible audio device change.

References:
- [ScreenCaptureKit overview](https://developer.apple.com/documentation/screencapturekit/)
- [SCStreamConfiguration](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration)
- [WWDC22 — Take ScreenCaptureKit to the next level (10155)](https://developer.apple.com/videos/play/wwdc2022/10155/)
- [WWDC23 — What's new in ScreenCaptureKit (10136)](https://developer.apple.com/videos/play/wwdc2023/10136/)

---

## 2. Minimal `SCKSystemAudioCapture` (audio-only)

Place in `core/Sources/SyncCastCore/Capture/SCKSystemAudioCapture.swift`. Requires `import ScreenCaptureKit`, `import AVFoundation`, `import OSLog`.

```swift
import ScreenCaptureKit
import AVFoundation
import OSLog

@available(macOS 13.0, *)
public final class SCKSystemAudioCapture: NSObject, SCStreamDelegate, SCStreamOutput {

    public enum CaptureError: Error {
        case noDisplay, permissionDenied, alreadyRunning, formatMismatch(String)
    }

    private let log = Logger(subsystem: "io.syncast.menubar", category: "SCKAudio")
    private let ownBundleID: String
    private let sink: RingBufferSink             // wraps RingBuffer.write(channels:frames:)
    private let audioQueue = DispatchQueue(label: "io.syncast.sck.audio", qos: .userInteractive)

    private var stream: SCStream?
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private let targetFormat: AVAudioFormat = AVAudioFormat(
        standardFormatWithSampleRate: 48_000, channels: 2
    )!  // Float32, non-interleaved, 48 kHz, stereo — matches RingBuffer

    public init(ownBundleID: String = "io.syncast.menubar", sink: RingBufferSink) {
        self.ownBundleID = ownBundleID
        self.sink = sink
        super.init()
    }

    // MARK: - Lifecycle

    public func start() async throws {
        guard stream == nil else { throw CaptureError.alreadyRunning }

        // Force-trigger the Screen Recording prompt path on first call.
        // SCShareableContent fails with kSCStreamErrorUserDeclined (-3801) if denied.
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
        } catch {
            log.error("SCShareableContent failed: \(error.localizedDescription)")
            throw CaptureError.permissionDenied
        }
        guard let display = content.displays.first else { throw CaptureError.noDisplay }

        // Exclude SyncCast's own running app from the capture so the AUHAL output
        // we drive on the local speaker doesn't loop back into the SCK audio stream.
        let ownApps = content.applications.filter { $0.bundleIdentifier == ownBundleID }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: ownApps,
            exceptingWindows: []
        )

        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = true   // belt-and-suspenders with the filter
        cfg.sampleRate = 48_000
        cfg.channelCount = 2
        // Audio-only: still required to set a video size, but we won't add a .screen output.
        cfg.width = 2; cfg.height = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)  // ~1 fps, ignored
        cfg.queueDepth = 6

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        try await s.startCapture()
        self.stream = s
        log.info("SCK audio capture started (48k stereo, excl=\(self.ownBundleID))")
    }

    public func stop() async {
        guard let s = stream else { return }
        do { try await s.stopCapture() } catch { log.error("stopCapture: \(error.localizedDescription)") }
        stream = nil
        converter = nil
        sourceFormat = nil
    }

    // MARK: - SCStreamDelegate

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        log.error("stream stopped with error: \(error.localizedDescription)")
        self.stream = nil
    }

    // MARK: - SCStreamOutput

    public func stream(_ stream: SCStream,
                       didOutputSampleBuffer sb: CMSampleBuffer,
                       of type: SCStreamOutputType) {
        guard type == .audio, sb.isValid, sb.dataReadiness == .ready else { return }
        do { try forward(sampleBuffer: sb) }
        catch { log.error("forward: \(error.localizedDescription)") }
    }
}
```

---

## 3. CMSampleBuffer → RingBuffer conversion

SCK does **not** guarantee Float32 non-interleaved planar at 48 kHz on every macOS version. Empirically on Tahoe it is Float32, often 48 kHz, but interleaving and channel layout can shift if the user's default output device changes (e.g., a 96 kHz audio interface goes online). Treat the inbound format as opaque and let `AVAudioConverter` normalize.

```swift
@available(macOS 13.0, *)
extension SCKSystemAudioCapture {

    fileprivate func forward(sampleBuffer sb: CMSampleBuffer) throws {
        // 1. Build / cache source AVAudioFormat from the buffer's ASBD.
        guard let fd = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee
        else { throw CaptureError.formatMismatch("missing ASBD") }

        if sourceFormat == nil
            || sourceFormat?.streamDescription.pointee.mSampleRate != asbd.mSampleRate
            || sourceFormat?.streamDescription.pointee.mChannelsPerFrame != asbd.mChannelsPerFrame {
            var mutable = asbd
            guard let newFmt = AVAudioFormat(streamDescription: &mutable) else {
                throw CaptureError.formatMismatch("AVAudioFormat init failed")
            }
            sourceFormat = newFmt
            converter = AVAudioConverter(from: newFmt, to: targetFormat)
            converter?.primeMethod = .none
        }
        guard let srcFmt = sourceFormat, let conv = converter else { return }

        // 2. Pull AudioBufferList from the sample buffer.
        var ablSize = 0
        var blockBuffer: CMBlockBuffer?
        var abl = AudioBufferList()
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb,
            bufferListSizeNeededOut: &ablSize,
            bufferListOut: &abl,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, blockBuffer != nil else {
            throw CaptureError.formatMismatch("ABL fetch status=\(status)")
        }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
        guard let inPCM = AVAudioPCMBuffer(pcmFormat: srcFmt, frameCapacity: frameCount) else { return }
        inPCM.frameLength = frameCount
        // AVAudioPCMBuffer wraps an AudioBufferList — copy ours in.
        memcpy(inPCM.mutableAudioBufferList, &abl,
               MemoryLayout<AudioBufferList>.size + Int(abl.mNumberBuffers - 1) * MemoryLayout<AudioBuffer>.size)

        // 3. Convert to 48k stereo Float32 non-interleaved.
        guard let outPCM = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: AVAudioFrameCount(Double(frameCount) * 48_000.0 / srcFmt.sampleRate) + 32
        ) else { return }

        var consumed = false
        var convError: NSError?
        let result = conv.convert(to: outPCM, error: &convError) { _, status in
            if consumed { status.pointee = .endOfStream; return nil }
            consumed = true
            status.pointee = .haveData
            return inPCM
        }
        if result == .error, let e = convError {
            log.error("convert error: \(e.localizedDescription)")
            return
        }

        // 4. Hand to RingBuffer. Non-interleaved planar = one pointer per channel.
        guard let chData = outPCM.floatChannelData else { return }
        let frames = Int(outPCM.frameLength)
        // floatChannelData is UnsafeMutablePointer<UnsafeMutablePointer<Float>>;
        // RingBuffer.write expects UnsafePointer<UnsafePointer<Float>>.
        chData.withMemoryRebound(to: UnsafePointer<Float>.self, capacity: 2) { ptr in
            sink.write(channels: ptr, frames: frames)
        }
    }
}
```

`RingBufferSink` is a thin wrapper so tests can inject a mock:

```swift
public protocol RingBufferSink: AnyObject {
    func write(channels: UnsafePointer<UnsafePointer<Float>>, frames: Int)
}
```

---

## 4. TCC integration on ad-hoc signed Tahoe builds

The Screen Recording prompt is **not** triggered by importing the framework or by `SCShareableContent.current` alone in every case. The reliable trigger on Tahoe 26.x is: call **`CGRequestScreenCaptureAccess()`** (CoreGraphics) at app launch, and if it returns `false`, follow up with an `SCShareableContent` query — which itself attempts a capture and flips TCC into the prompted state.

```swift
import CoreGraphics
import ScreenCaptureKit

enum ScreenCapturePermission {
    case granted, denied, undetermined
}

@available(macOS 13.0, *)
final class ScreenRecordingTCC {
    static func current() -> ScreenCapturePermission {
        // Preflight is non-blocking and does not prompt.
        return CGPreflightScreenCaptureAccess() ? .granted : .undetermined
    }

    /// Call once at launch. If undetermined, this triggers the system prompt.
    /// If the user clicks Allow, macOS still requires a **process restart** before
    /// the grant takes effect — there is no in-process re-arm on Tahoe.
    @MainActor
    static func requestAndPoll(onGranted: @escaping () -> Void,
                               onDenied: @escaping () -> Void) async {
        if CGPreflightScreenCaptureAccess() { onGranted(); return }

        // 1. Request — shows the OS prompt directing user to System Settings.
        _ = CGRequestScreenCaptureAccess()

        // 2. Belt-and-suspenders: an SCK probe also nudges TCC on some builds.
        _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        // 3. Poll for up to ~60 s. If the user grants while we're alive, great;
        //    on Tahoe most often the user toggles the switch and is then asked
        //    by the OS to quit and reopen — handle that by detecting denied/timeout.
        for _ in 0..<60 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if CGPreflightScreenCaptureAccess() { onGranted(); return }
        }
        onDenied()
    }
}
```

**Tahoe-specific quirks:**

- **Bundle required.** macOS 26.x will not list a plain executable in System Settings → Privacy & Security → Screen Recording. SyncCast must launch as a `.app` bundle with a stable `CFBundleIdentifier`. Loose `swift run` binaries silently fail to register.
- **Ad-hoc CDHash churn.** Every clean build produces a new code directory hash, so TCC treats build N+1 as a new app and revokes the grant. Mitigation: ad-hoc-sign with a **stable identifier** (`codesign -s - --identifier io.syncast.menubar --force`) — TCC will still revoke on signature change, but identifier-stable builds at least re-prompt cleanly instead of going silent. For dev loops, sign once into `~/Applications/SyncCast.app` and rebuild **into** that bundle (no recreate).
- **Disappearing-grant bug.** On 26.0–26.1, occasionally the Screen Recording entry vanishes from System Settings; subsequent `CGRequestScreenCaptureAccess()` calls become no-ops until a reboot. Document this in the user-facing error path.
- **No entitlement gates this.** Screen Recording is purely TCC; there is no entitlement an ad-hoc-signed app is locked out of (unlike, say, the audio-tap entitlement that gates CoreAudio process taps on 14.4+).
- **Restart is mandatory** after first grant. SCK does not pick up a fresh grant in the running process. The cleanest UX is to detect denial, show a "click Allow then reopen SyncCast" sheet, and `NSApp.terminate(nil)`.

References:
- [CGRequestScreenCaptureAccess](https://developer.apple.com/documentation/coregraphics/3030271-cgrequestscreencaptureaccess)
- [Apple forum thread 732726 — Understanding CGRequestScreenCaptureAccess](https://developer.apple.com/forums/thread/732726)
- [TCC code signature and ad-hoc signing notes](https://developer.apple.com/forums/thread/695689)

---

## 5. Self-feedback prevention — does `excludesCurrentProcessAudio` work?

**Short answer: mostly, but not entirely reliably for AUHAL output.** Two layers of defense are needed.

`excludesCurrentProcessAudio` works by audio-unit-level tagging: SCK's audio engine subtracts buffers attributed to the calling pid before mixing the system-audio tap output. This works perfectly for app audio routed through `AVAudioEngine` / `AVPlayer` / `AudioQueueServices`, because those frameworks tag their output with the originating pid.

**AUHAL is the fragile case.** Output AUs configured against `kAudioUnitSubType_HALOutput` and started via `AudioOutputUnitStart` on the default output device sometimes bypass the per-process tag, especially when the AUHAL writes to the same device that SCK is tapping for system audio. Field reports on macOS 14–15 show intermittent leak-through; on Tahoe 26.4 the tagging is more consistent but still not guaranteed under high CPU load or when multiple AUHAL instances exist in the process.

**Defense in depth — recommended pattern:**

1. Set `excludesCurrentProcessAudio = true` (cheap, mostly works).
2. **Also** pass `excludingApplications:` to `SCContentFilter` with the `SCRunningApplication` matching SyncCast's own bundle id (shown in the snippet above). This excludes our app at the *content filter* layer, which is enforced earlier in SCK's pipeline than the per-process audio tag. Together with #1 this closes the AUHAL leak in practice.
3. **If feedback still appears** (verify by playing a known sine through AUHAL while capturing and looking for the same frequency in the captured stream), the next escalation is to *not* play to the local speaker through AUHAL while SCK is capturing — instead route the local renderer through `AVAudioEngine` output, which is reliably excluded. SyncCast's local-speaker path is one of N synchronized destinations, so swapping it from AUHAL to AVAudioEngine in the local-output sink is a localized change.
4. Last resort: capture system audio with SCK only when the user has at least one *remote* AirPlay endpoint and route the local MBP speakers through a separate, non-captured sink (e.g., output a silent track to the default device while AVAudioEngine plays to a specific `AVAudioEngine.outputNode` bound to the same device — still subject to the same leak risk).

Open question worth verifying with a sine-wave A/B on the actual hardware: whether `SCContentFilter(excludingApplications:)` reliably excludes audio from a process that also holds an open AUHAL on the captured device. WWDC22 session 10155 implies yes; Apple's docs are silent on the AUHAL-specific edge case.

---

## 6. Open questions / verify on hardware

1. **Inbound ASBD on Tahoe 26.4** — does SCK deliver Float32 interleaved or non-interleaved by default? The conversion code above handles either, but the converter allocation cost matters for low-latency sync.
2. **Latency budget.** SCK adds ~20–40 ms of buffering vs. ~10 ms for a HAL IOProc. Confirm SyncCast's sync algorithm tolerates this; if not, reduce `queueDepth` and benchmark.
3. **Multi-display setups.** `content.displays.first` is wrong if the user's audio plays from an app on display #2; SCK's audio capture is **per-display-filter** in API shape but in practice captures *system* audio regardless of which display is selected. Validate.
4. **Tahoe 26.5 beta.** Apple has been shipping TCC-related fixes in 26.x point releases; check release notes before each minor.

---

## 7. Wiring into SyncCast

- Replace `BlackHoleHALCapture` references in the capture-source factory with `SCKSystemAudioCapture` behind a feature flag (`SYNCAST_CAPTURE_BACKEND=sck|halproxy`).
- Keep `RingBuffer` and downstream sync/AirPlay code unchanged — `SCKSystemAudioCapture` produces the exact same Float32 non-interleaved 48 kHz stereo it expects.
- App-launch flow: `ScreenRecordingTCC.requestAndPoll` → on `granted`, build `SCKSystemAudioCapture` and `start()`; on `denied`, show modal sheet with deep link to System Settings (`x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`) and `terminate`.
- Ship as a signed `.app` bundle; do not run the binary loose in dev — TCC will not register it on Tahoe.

---

## Sources

- [ScreenCaptureKit — Apple Developer](https://developer.apple.com/documentation/screencapturekit/)
- [SCStreamConfiguration](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration)
- [SCContentFilter](https://developer.apple.com/documentation/screencapturekit/sccontentfilter)
- [WWDC22 session 10155 — Take ScreenCaptureKit to the next level](https://developer.apple.com/videos/play/wwdc2022/10155/)
- [WWDC23 session 10136 — What's new in ScreenCaptureKit](https://developer.apple.com/videos/play/wwdc2023/10136/)
- [CGRequestScreenCaptureAccess](https://developer.apple.com/documentation/coregraphics/3030271-cgrequestscreencaptureaccess)
- [Apple forum 732726 — CGRequestScreenCaptureAccess semantics](https://developer.apple.com/forums/thread/732726)
- [Apple forum 747303 — Mixing SCK audio with AVAudioEngine (feedback discussion)](https://developer.apple.com/forums/thread/747303)
- [Apple forum 718279 — Audio-only capture from ScreenCaptureKit](https://developer.apple.com/forums/thread/718279)
- [pyobjc issue 647 — SCStreamErrorDomain -3805 / no callbacks on macOS 15](https://github.com/ronaldoussoren/pyobjc/issues/647)
- [Capturing system audio with Core Audio taps (alternative path on 14.4+)](https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps)
