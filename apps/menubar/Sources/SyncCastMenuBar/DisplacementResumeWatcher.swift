import CoreAudio
import Foundation
import SyncCastRouter

/// The HAL half of `DisplacementResumePolicy`: a listener on the paused sink's
/// own volume and mute, plus one on the default output, alive only while a
/// displacement pause stands and the engine is idle.
///
/// The volume listener is `HardwareVolumeObserver`, the debounced listener the
/// running sink path already watches the system volume with, under a reserved
/// device id of its own. The two never watch at the same time (one needs the
/// engine idle, the other running), but a late callback from either cannot be
/// mistaken for the other's.
///
/// What it adds is the baseline every reading is compared with, kept honest
/// across the three things that move the level without a key press:
///
///   * the default output changing. macOS re-applies the sink's remembered
///     level the moment it becomes the default output again, so readings in
///     the settle window after a switch only become the new baseline, and the
///     baseline is re-read once the switch has settled;
///   * SyncCast's own full-scale nudge, adopted as the baseline the moment it
///     lands (`adoptOwnWrite`);
///   * the sink coming back as a new audio object (coreaudiod restarted, the
///     driver reloaded): the watch is restarted from a fresh reading.
///
/// Whether a reading resumes is the policy's call, made by `AppModel` with the
/// facts the watcher does not have (the pause, the engine state).
@MainActor
final class DisplacementResumeWatcher {
    typealias Sample = DisplacementResumePolicy.Sample

    /// Reserved observer key; never a discovery id.
    static let pseudoDeviceID = "__syncast.displacedSink__"

    /// Same short debounce as the running sink path: a held volume key
    /// repeats every ~33 ms, and the first press is the one that matters.
    private static let readDebounce: DispatchTimeInterval = .milliseconds(20)

    /// A reading to judge: the watched UID, the baseline it is compared with
    /// (nil when none could be taken), and the reading itself. Main actor.
    var onChange: ((String, Sample?, Sample) -> Void)?
    /// A new baseline was taken outside a key press: the watch started, or a
    /// default-output switch settled. Main actor.
    var onBaselineTaken: ((String, Sample) -> Void)?

    private(set) var watchedUID: String?
    /// The reading the next change is compared with.
    private(set) var lastSample: Sample?
    /// A default-output switch is still settling; its baseline is not taken
    /// yet, and a write now could land under macOS re-applying its own level.
    var isSettlingDefaultSwitch: Bool { settleTask != nil }

    private var watchedObjectID: AudioObjectID?
    private var observer: HardwareVolumeObserver?
    private var defaultOutputListener: AudioObjectPropertyListenerBlock?
    /// When the default output last changed, for the settle window.
    private var defaultSwitchedAt: Date?
    private var settleTask: Task<Void, Never>?
    /// Bumped on every start and stop, so a callback already on its way to
    /// the main actor from an earlier watch is dropped rather than compared
    /// against the wrong baseline.
    private var episode: UInt64 = 0

    /// Watch `uid`, or stop watching when nil.
    ///
    /// Called on every displacement poll. Repeating it for the same UID is
    /// cheap and deliberate: it restarts the watch when the sink came back as
    /// a new audio object, and re-reads the baseline if a default-output
    /// change slipped past the listener.
    func watch(uid: String?, reason: String) {
        // Unit tests construct AppModels in states that look paused. Never
        // let that attach a listener to the developer's real sink.
        if TestEnvironment.isRunningUnderXCTest { return }
        guard let uid else {
            stop(reason: reason)
            return
        }
        let objectID = Self.audioObjectID(forUID: uid)
        if watchedUID == uid, let observer, objectID == watchedObjectID {
            // Deduplicated by the observer: a no-op while its listener is in
            // place, a second chance when registering it failed (a driver
            // that was still coming up), which would otherwise leave the
            // whole pause deaf.
            observer.setWatchedDevices([Self.watched(uid)])
            rebaselineIfDefaultOutputMoved(uid: uid)
            return
        }
        let why: String
        if watchedUID != uid {
            why = reason
        } else if objectID == nil {
            why = "\(uid) is gone"
        } else {
            why = "\(uid) came back as a new audio object"
        }
        stop(reason: why)
        // Not present right now (coreaudiod restarting, driver missing):
        // nothing to listen to, and the next poll tries again.
        guard let objectID else { return }
        start(uid: uid, objectID: objectID, reason: reason)
    }

    /// Detach both listeners. Safe to call when nothing is watched.
    func stop(reason: String) {
        guard watchedUID != nil || observer != nil else { return }
        episode &+= 1
        settleTask?.cancel()
        settleTask = nil
        removeDefaultOutputListener()
        observer?.setWatchedDevices([])
        observer = nil
        if let uid = watchedUID {
            SyncCastLog.log(
                "systemSink: stopped watching \(uid) for a volume-up (\(reason))"
            )
        }
        watchedUID = nil
        watchedObjectID = nil
        lastSample = nil
        defaultSwitchedAt = nil
    }

    /// SyncCast is about to write the watched sink's level. Holds the
    /// listener read the write provokes until after the observer's
    /// suppression window, so it is read once, settled.
    func noteOwnWrite(uid: String) {
        guard uid == watchedUID else { return }
        observer?.noteAppInitiatedWrite(uid: uid)
    }

    /// The write landed: it is the new baseline. A press made before the
    /// write's echo is read then compares against the written level, not the
    /// one it replaced.
    func adoptOwnWrite(uid: String, volume: Float) {
        guard uid == watchedUID, let last = lastSample else { return }
        lastSample = Sample(
            volume: volume, muted: last.muted, sinkIsDefault: last.sinkIsDefault
        )
    }

    // MARK: - Internals

    private func start(uid: String, objectID: AudioObjectID, reason: String) {
        episode &+= 1
        let current = episode
        // A fresh observer per start: its callback carries the episode it was
        // created in, which a reused one would keep reporting under. The
        // callback is only a "something changed" signal; see `receive`.
        let observer = HardwareVolumeObserver(
            readDebounce: Self.readDebounce
        ) { [weak self] change in
            guard change.deviceID == Self.pseudoDeviceID else { return }
            Task { @MainActor [weak self] in
                self?.receive(episode: current)
            }
        }
        self.observer = observer
        watchedUID = uid
        watchedObjectID = objectID
        installDefaultOutputListener(episode: current)
        let baseline = Self.read(uid: uid)
        lastSample = baseline
        observer.setWatchedDevices([Self.watched(uid)])
        SyncCastLog.log(
            "systemSink: paused — a volume-up on \(uid) resumes (\(reason)); "
            + "baseline \(Self.describe(baseline))"
        )
        if baseline.sinkIsDefault {
            // Picked again while the engine was still stopping: the switch
            // may not have settled, and its notification came before this
            // listener existed.
            settleDefaultOutputSwitch(uid: uid, reason: "already the default output at start")
        } else {
            onBaselineTaken?(uid, baseline)
        }
    }

    /// The observer saw the level or mute move. Its readings are not used:
    /// each one reaches the main actor through its own task, in no
    /// guaranteed order, and two presses delivered backwards would read as
    /// the opposite direction. The current state is read here instead, so a
    /// late or duplicate notification just finds nothing new.
    private func receive(episode received: UInt64) {
        guard received == episode, let uid = watchedUID else { return }
        let current = Self.read(uid: uid)
        let previous = lastSample
        guard current != previous else { return }
        lastSample = current
        if DisplacementResumePolicy.isSettlingDefaultSwitch(
            switchedAt: defaultSwitchedAt, now: Date()
        ) {
            SyncCastLog.log(
                "systemSink: paused sink \(uid) level \(Self.describe(previous))→"
                + "\(Self.describe(current)) while the default output settles — baseline only"
            )
            return
        }
        if let previous, previous.sinkIsDefault != current.sinkIsDefault {
            // The default output moved and this reading heard of it before
            // the listener did. Same treatment as a reported switch: the
            // level macOS re-applies is not a press.
            SyncCastLog.log(
                "systemSink: paused sink \(uid) level \(Self.describe(previous))→"
                + "\(Self.describe(current)) across a default-output change — baseline only"
            )
            settleDefaultOutputSwitch(uid: uid, reason: "a reading saw the default output change")
            return
        }
        onChange?(uid, previous, current)
    }

    private static var defaultOutputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func installDefaultOutputListener(episode current: UInt64) {
        var address = Self.defaultOutputAddress
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.defaultOutputChanged(episode: current)
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
        )
        guard status == noErr else {
            SyncCastLog.log(
                "systemSink: could not listen for default-output changes "
                + "(OSStatus=\(status)); the once-a-second poll covers them"
            )
            return
        }
        defaultOutputListener = block
    }

    private func removeDefaultOutputListener() {
        guard let block = defaultOutputListener else { return }
        var address = Self.defaultOutputAddress
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
        )
        defaultOutputListener = nil
    }

    private func defaultOutputChanged(episode received: UInt64) {
        guard received == episode, let uid = watchedUID else { return }
        settleDefaultOutputSwitch(uid: uid, reason: "default output changed")
    }

    /// Backstop for a default-output change the listener did not report:
    /// the baseline says one thing about "is the sink the default", the HAL
    /// another.
    private func rebaselineIfDefaultOutputMoved(uid: String) {
        guard settleTask == nil, let last = lastSample else { return }
        let isDefault = SystemDefaultOutput.currentUID() == uid
        guard isDefault != last.sinkIsDefault else { return }
        settleDefaultOutputSwitch(uid: uid, reason: "poll saw the default output change")
    }

    /// Open the settle window now and take the baseline when it closes.
    private func settleDefaultOutputSwitch(uid: String, reason: String) {
        defaultSwitchedAt = Date()
        settleTask?.cancel()
        let current = episode
        settleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(DisplacementResumePolicy.defaultSwitchSettleSeconds * 1_000_000_000)
            )
            guard !Task.isCancelled, let self, current == self.episode,
                  self.watchedUID == uid
            else {
                return
            }
            self.settleTask = nil
            let baseline = Self.read(uid: uid)
            self.lastSample = baseline
            SyncCastLog.log(
                "systemSink: paused sink \(uid) baseline \(Self.describe(baseline)) (\(reason))"
            )
            self.onBaselineTaken?(uid, baseline)
        }
    }

    private static func watched(_ uid: String) -> HardwareVolumeObserver.WatchedDevice {
        HardwareVolumeObserver.WatchedDevice(deviceID: pseudoDeviceID, uid: uid)
    }

    private static func read(uid: String) -> Sample {
        Sample(
            volume: AggregateDevice.readHardwareVolume(uid: uid),
            muted: AggregateDevice.readHardwareMute(uid: uid),
            sinkIsDefault: SystemDefaultOutput.currentUID() == uid
        )
    }

    private static func audioObjectID(forUID uid: String) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var cfUID = uid as CFString
        let status = withUnsafeMutablePointer(to: &cfUID) { uidPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<CFString>.size),
                uidPointer,
                &size,
                &deviceID
            )
        }
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    static func describe(_ sample: Sample?) -> String {
        guard let sample else { return "unknown" }
        var text = sample.volume.map { String(format: "%.4f", $0) } ?? "?"
        if sample.muted == true { text += " muted" }
        if !sample.sinkIsDefault { text += " (not default)" }
        return text
    }
}
