import CoreAudio
import Foundation
import SyncCastRouter

/// Watches the HARDWARE volume / mute of Direct Stereo's covered output
/// devices (CoreAudio-hardware backend only) so external changes — System
/// Settings' sound slider, Audio MIDI Setup, the device's own buttons —
/// are reflected back into `AppModel.routing` and the popover sliders
/// stay truthful. Without this, the UI slider and the real hardware
/// volume drift apart, and the next media-key press "jumps" the volume
/// to wherever the stale slider was.
///
/// Loop safety: SyncCast's own writes (media keys, popover slider) also
/// fire these listeners. Callers announce their writes via
/// `noteAppInitiatedWrite(uid:)`, which opens a short suppression window;
/// reads landing inside the window are deferred (NOT dropped — a real
/// external change inside the window must survive) until just after it
/// closes. The deferred value is then filtered by AppModel through the
/// pure `DirectStereoVolumeLogic.externalHardwareChange` decision: tiny
/// deltas (≤0.004) are our write echoing back, and a ≈0 volume while the
/// route stays muted is the expected mute artifact (emulated-mute scalar
/// write, or a driver zeroing the scalar) — neither re-enters the write
/// path or overwrites the saved route volume.
///
/// Threading: all mutable state is confined to `queue`, which is also the
/// dispatch queue handed to CoreAudio for listener callbacks. The
/// `onExternalChange` closure is invoked ON `queue`; the AppModel wrapper
/// hops to the main actor.
final class HardwareVolumeObserver {
    struct WatchedDevice: Equatable {
        /// SyncCast device id — key into `AppModel.routing`.
        let deviceID: String
        /// kAudioDevicePropertyDeviceUID — stable across replug.
        let uid: String
    }

    struct ExternalChange {
        let deviceID: String
        let volume: Float?
        let muted: Bool?
    }

    /// How long our own writes suppress listener reads. Media keys repeat
    /// every ~33 ms while held, each extending the window, so a held key
    /// never fights its own echo.
    private static let suppressionWindow: TimeInterval = 0.35
    /// Listener debounce — CoreAudio fires once per channel element for a
    /// single user action; coalesce before reading.
    private static let readDebounce: DispatchTimeInterval = .milliseconds(120)

    private final class Entry {
        /// `var`: a `.retarget` rewatch (same UID + HAL device, new
        /// SyncCast device id) updates this in place instead of paying
        /// listener re-registration. Queue-confined like the rest.
        var device: WatchedDevice
        let audioDeviceID: AudioDeviceID
        var addresses: [AudioObjectPropertyAddress] = []
        var listenerBlock: AudioObjectPropertyListenerBlock?
        var pendingRead: DispatchWorkItem?

        init(device: WatchedDevice, audioDeviceID: AudioDeviceID) {
            self.device = device
            self.audioDeviceID = audioDeviceID
        }
    }

    private let queue = DispatchQueue(label: "io.syncast.hw-volume-observer")
    private let onExternalChange: (ExternalChange) -> Void
    /// Keyed by device UID. Queue-confined.
    private var entries: [String: Entry] = [:]
    /// uid → suppression deadline. Queue-confined.
    private var suppressedUntil: [String: Date] = [:]

    init(onExternalChange: @escaping (ExternalChange) -> Void) {
        self.onExternalChange = onExternalChange
    }

    deinit {
        // No other reference exists once deinit runs, so direct access to
        // queue-confined state is safe here (removal API itself is
        // thread-agnostic as long as queue+block match the registration).
        for entry in entries.values {
            removeListeners(for: entry)
        }
        entries = [:]
    }

    // MARK: Public API (callable from any thread)

    /// Replace the watched set. Diffs against the current set so stable
    /// devices keep their listeners (no re-registration churn on every
    /// reconcile pass).
    func setWatchedDevices(_ devices: [WatchedDevice]) {
        queue.async { [weak self] in
            self?.setWatchedDevicesOnQueue(devices)
        }
    }

    /// Open the self-write suppression window for `uid`. Call IMMEDIATELY
    /// before any app-initiated hardware volume/mute write.
    func noteAppInitiatedWrite(uid: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.suppressedUntil[uid] = Date()
                .addingTimeInterval(Self.suppressionWindow)
        }
    }

    // MARK: Queue-confined implementation

    private func setWatchedDevicesOnQueue(_ devices: [WatchedDevice]) {
        let wantedUIDs = Set(devices.map(\.uid))
        for (uid, entry) in entries where !wantedUIDs.contains(uid) {
            removeListeners(for: entry)
            entries[uid] = nil
            suppressedUntil[uid] = nil
            SyncCastLog.log("systemVolumeKey: hw observer stopped watching \(uid.prefix(20))")
        }
        for device in devices {
            guard let existing = entries[device.uid] else {
                addWatchOnQueue(device)
                continue
            }
            // Two stale-identity cases (decision is pure, see
            // HardwareVolumeRewatchLogic):
            //   - Display sleep/wake reissues a FRESH AudioDeviceID for
            //     the same UID (see Router.forceLocalDriverRebuild docs);
            //     listeners registered on the dead ID never fire again.
            //     Re-resolve on every set update and re-register if the
            //     ID moved — wake recovery reconciles the covered set,
            //     which lands here and heals the watch.
            //   - Discovery republishes the same UID under a NEW SyncCast
            //     device id (routing migration keeps playback). The HAL
            //     listeners stay valid, but the entry must report the new
            //     id or AppModel drops the change (routing[old id] no
            //     longer exists).
            switch HardwareVolumeRewatchLogic.action(
                watchedDeviceID: existing.device.deviceID,
                watchedAudioDeviceID: existing.audioDeviceID,
                wantedDeviceID: device.deviceID,
                resolvedAudioDeviceID: Self.audioDeviceID(forUID: device.uid)
            ) {
            case .rebuild:
                removeListeners(for: existing)
                entries[device.uid] = nil
                addWatchOnQueue(device)
            case .retarget:
                existing.device = device
                SyncCastLog.log(
                    "systemVolumeKey: hw observer retargeted \(device.uid.prefix(20)) to device id \(device.deviceID.prefix(8))"
                )
            case .keep:
                break
            }
        }
    }

    private func addWatchOnQueue(_ device: WatchedDevice) {
        guard let audioDeviceID = Self.audioDeviceID(forUID: device.uid) else {
            SyncCastLog.log(
                "systemVolumeKey: hw observer cannot resolve AudioDeviceID for \(device.uid.prefix(20)) — external changes will not sync"
            )
            return
        }
        let entry = Entry(device: device, audioDeviceID: audioDeviceID)
        entry.addresses = Self.listenableAddresses(for: audioDeviceID)
        guard !entry.addresses.isEmpty else {
            SyncCastLog.log(
                "systemVolumeKey: hw observer found no volume/mute properties on \(device.uid.prefix(20)) — nothing to watch"
            )
            return
        }
        let uid = device.uid
        // CoreAudio invokes the block on `queue` (the queue we register
        // with), so the schedule call below is already queue-confined.
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleReadOnQueue(uid: uid)
        }
        entry.listenerBlock = block
        var installed = 0
        for var address in entry.addresses {
            let status = AudioObjectAddPropertyListenerBlock(
                audioDeviceID, &address, queue, block
            )
            if status == noErr { installed += 1 }
        }
        guard installed > 0 else {
            SyncCastLog.log(
                "systemVolumeKey: hw observer listener install FAILED for \(device.uid.prefix(20))"
            )
            return
        }
        entries[device.uid] = entry
        SyncCastLog.log(
            "systemVolumeKey: hw observer watching \(device.uid.prefix(20)) (\(installed) properties)"
        )
    }

    private func removeListeners(for entry: Entry) {
        guard let block = entry.listenerBlock else { return }
        entry.pendingRead?.cancel()
        entry.pendingRead = nil
        for var address in entry.addresses {
            AudioObjectRemovePropertyListenerBlock(
                entry.audioDeviceID, &address, queue, block
            )
        }
        entry.listenerBlock = nil
    }

    private func scheduleReadOnQueue(uid: String) {
        guard let entry = entries[uid] else { return }
        entry.pendingRead?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.performReadOnQueue(uid: uid)
        }
        entry.pendingRead = item
        queue.asyncAfter(deadline: .now() + Self.readDebounce, execute: item)
    }

    private func performReadOnQueue(uid: String) {
        guard let entry = entries[uid] else { return }
        if let until = suppressedUntil[uid], until > Date() {
            // Likely our own write echoing back. Defer the read to just
            // after the window: a REAL external change is still visible
            // then, while our echo collapses to a no-op in AppModel's
            // delta comparison.
            let item = DispatchWorkItem { [weak self] in
                self?.performReadOnQueue(uid: uid)
            }
            entry.pendingRead = item
            queue.asyncAfter(
                deadline: .now() + until.timeIntervalSinceNow + 0.05,
                execute: item
            )
            return
        }
        entry.pendingRead = nil
        let volume = AggregateDevice.readHardwareVolume(uid: uid)
        let muted = AggregateDevice.readHardwareMute(uid: uid)
        guard volume != nil || muted != nil else { return }
        onExternalChange(ExternalChange(
            deviceID: entry.device.deviceID,
            volume: volume,
            muted: muted
        ))
    }

    // MARK: HAL helpers

    private static func audioDeviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var cfUID = uid as CFString
        let status = withUnsafeMutablePointer(to: &cfUID) { uidPtr in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<CFString>.size),
                uidPtr,
                &size,
                &deviceID
            )
        }
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    /// Volume scalar on the main element plus channels 1/2 (devices
    /// without a virtual main volume expose per-channel only), and mute
    /// on the main element. Only properties the device actually has.
    private static func listenableAddresses(
        for id: AudioDeviceID
    ) -> [AudioObjectPropertyAddress] {
        var result: [AudioObjectPropertyAddress] = []
        let volumeElements: [AudioObjectPropertyElement] = [
            kAudioObjectPropertyElementMain, 1, 2,
        ]
        for element in volumeElements {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            if AudioObjectHasProperty(id, &address) {
                result.append(address)
            }
        }
        var muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(id, &muteAddress) {
            result.append(muteAddress)
        }
        return result
    }
}
