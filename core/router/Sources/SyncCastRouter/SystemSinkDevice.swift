import Foundation
import CoreAudio
import Darwin

/// The **system sink**: a virtual HAL output device that owns the macOS
/// system volume while SyncCast's local Stereo path is running.
///
/// # Why this exists
///
/// Direct Stereo makes a public *aggregate* the default output. Aggregates
/// expose no `kAudioDevicePropertyVolumeScalar` (measured 2026-09-05 on this
/// machine: both the SyncCast Direct Stereo aggregate and the user's own
/// Audio MIDI Setup multi-output device report `has=false`), so macOS greys
/// out the menu-bar slider, shows the "forbidden" HUD for F11/F12, and
/// LinearMouse's scroll-to-change-volume has nothing to drive. SyncCast worked
/// around that with a `CGEventTap` on the media keys — which needs
/// Accessibility permission, swallows the keys from every other app, and
/// breaks LinearMouse's own volume HUD while SyncCast runs.
///
/// A *virtual HAL device* does have a volume control, and macOS treats every
/// such device as fully volume-controllable (menu-bar slider, keys, HUD,
/// third-party scroll wheels). So instead of publishing an aggregate, the sink
/// path makes one of those devices the default output, captures what macOS
/// renders into it with a Core Audio Process Tap pinned to that device, and
/// fans the captured audio out to the real speakers. The device's own
/// `VolumeScalar` becomes the master volume, read through a property listener.
///
/// # Which device
///
/// Two sinks are accepted, in preference order (see `detect`):
///
///   1. `SyncCastAudio_UID` — our own driver (`drivers/SyncCastAudio`),
///      output-only, 2 ch, named "SyncCast" so the Sound menu reads sensibly.
///   2. `BlackHole2ch_UID` — the widely installed BlackHole 2ch loopback,
///      used as a fallback so the feature works before the (sudo-requiring)
///      driver install.
///
/// Neither device's *own* attenuation matters: the tap sits BEFORE the driver,
/// verified by measurement on 2026-09-05 (`docs/requirements_2026-09-05-system-sink.md`
/// records the run: captured RMS 0.35355 at sink scalar 1.0, 0.5 and 0.0 —
/// identical to 4 decimal places). The scalar is pure *intent*; SyncCast is
/// what turns it into loudness on the real outputs.
///
/// # Relationship to the other default-output owners in this module
///
///   - `DirectStereoOutput`  — PUBLIC aggregate of the real speakers, legacy
///     Stereo path. Needs the event tap for volume.
///   - `WholeHomeSinkOutput` — PUBLIC aggregate wrapping BlackHole, whole-home
///     mode's silent default output.
///   - `SystemSinkDevice`    — an EXISTING HAL device (we create nothing), made
///     default output *and* default system output for the sink Stereo path.
///
/// Because we create no device here, there is nothing to orphan-sweep: a crash
/// leaves the default output pointed at a real, still-present device. What a
/// crash *can* leave behind is the default pointed at a silent sink; the
/// `sweepStaleDefault()` entry point handles that at launch.
public final class SystemSinkDevice {
    public enum SystemSinkError: Error, CustomStringConvertible {
        case noSinkInstalled
        case deviceNotFound(String)
        case readDefaultFailed(OSStatus)
        case setDefaultFailed(OSStatus)
        case stopFailed(String)

        public var description: String {
            switch self {
            case .noSinkInstalled:
                return """
                the system-volume Stereo path needs a virtual audio sink. \
                Install SyncCast's own driver (menu: 安装 SyncCast 音频驱动, or \
                `sudo bash scripts/install-driver.sh`), or install BlackHole 2ch \
                (`brew install --cask blackhole-2ch`).
                """
            case .deviceNotFound(let uid):
                return "system sink device not found: \(uid)"
            case .readDefaultFailed(let status):
                return "read default output failed: OSStatus=\(status)"
            case .setDefaultFailed(let status):
                return "set default output failed: OSStatus=\(status)"
            case .stopFailed(let reason):
                return "system sink stop failed: \(reason)"
            }
        }
    }

    // MARK: - Known sinks

    /// One installable sink flavour, in preference order.
    public struct Candidate: Equatable, Sendable {
        public let uid: String
        /// Lower is preferred.
        public let rank: Int
        /// What the Sound menu shows while this sink is the default output.
        public let displayName: String

        public init(uid: String, rank: Int, displayName: String) {
            self.uid = uid
            self.rank = rank
            self.displayName = displayName
        }
    }

    /// UID of SyncCast's own AudioServerPlugIn (`drivers/SyncCastAudio`).
    /// Must match `kDevice_UID` in the driver source.
    public static let syncCastDriverUID = "SyncCastAudio_UID"
    /// Name the driver publishes; also what the Sound menu shows.
    public static let syncCastDriverName = "SyncCast"
    /// BlackHole 2ch — the fallback sink, already present on many machines.
    public static let blackHole2chUID = "BlackHole2ch_UID"
    public static let blackHole2chName = "BlackHole 2ch"

    /// Every sink we accept, best first. A machine with both installed uses
    /// SyncCast's own driver: it is output-only (no input stream, so no
    /// microphone-shaped TCC prompt anywhere), it is named for what it does,
    /// and it cannot be repurposed by another app mid-session the way a shared
    /// BlackHole can.
    public static let candidates: [Candidate] = [
        Candidate(uid: syncCastDriverUID, rank: 0, displayName: syncCastDriverName),
        Candidate(uid: blackHole2chUID, rank: 1, displayName: blackHole2chName),
    ]

    /// Pure preference decision — which of the installed UIDs to use.
    ///
    /// Separated from the HAL lookup so the ordering is unit-testable: the
    /// rule is "lowest rank among the candidates that are actually present",
    /// never "first one we happened to enumerate".
    public static func preferredSink(
        installedUIDs: Set<String>,
        candidates: [Candidate] = SystemSinkDevice.candidates
    ) -> Candidate? {
        candidates
            .filter { installedUIDs.contains($0.uid) }
            .min { $0.rank < $1.rank }
    }

    /// The sink this PROCESS will use, resolved once.
    ///
    /// Cached because the Router, the AppModel and the launch log all have to
    /// agree on which path is running; re-probing could disagree if a driver
    /// appears mid-session. Installing a driver restarts coreaudiod anyway, so
    /// "takes effect on next launch" is the honest contract.
    public static let resolved: Candidate? = detect()

    /// Resolve the sink to use on this machine right now, or nil when neither
    /// driver is installed (the caller then keeps the legacy Direct Stereo
    /// path, event tap and all).
    public static func detect() -> Candidate? {
        var installed = Set<String>()
        for candidate in candidates
        where (try? Capture.deviceID(forUID: candidate.uid)) != nil {
            installed.insert(candidate.uid)
        }
        return preferredSink(installedUIDs: installed)
    }

    /// Whether a UID is one of our sinks. Used by the route filters so the
    /// sink can never be selected as a playback *target* (that would be a
    /// capture loop: we tap the sink and would render back into it).
    public static func isSinkUID(_ uid: String) -> Bool {
        candidates.contains { $0.uid == uid }
    }

    // MARK: - Live state

    private let candidate: Candidate
    private var deviceID: AudioObjectID = 0
    private var previousDefaultOutputID: AudioObjectID?
    private var previousDefaultOutputUID: String?
    private var previousSystemOutputID: AudioObjectID?
    private var previousSystemOutputUID: String?
    private var previousNominalSampleRate: Float64?
    private var lastStopStatus: String?

    /// The whole SyncCast pipeline is 48 kHz Float32 stereo, and `TapCapture`
    /// refuses any other tap format rather than silently resampling. The sink
    /// is therefore pinned to 48 kHz for the duration of the path and put back
    /// afterwards — BlackHole in particular sits at 96 kHz by default on this
    /// machine, and it is shared with whatever else the user runs.
    public static let requiredSampleRate: Float64 = 48_000

    public var isActive: Bool { deviceID != 0 }
    public var sinkUID: String { candidate.uid }
    public var displayName: String { candidate.displayName }
    public var lastStopStatusText: String? { lastStopStatus }
    public var audioDeviceID: AudioObjectID { deviceID }

    public init(candidate: Candidate) {
        self.candidate = candidate
    }

    deinit {
        _ = stop()
    }

    public var diagnostic: String {
        guard isActive else {
            if let lastStopStatus {
                return "systemSink=inactive lastStop=\"\(lastStopStatus)\""
            }
            return "systemSink=inactive"
        }
        return "systemSink=active uid=\(candidate.uid) id=\(deviceID)"
            + " previous=\(previousDefaultOutputUID ?? "?")"
            + " default=\(isSystemDefaultOutput ? "yes" : "no")"
    }

    /// Is the sink still the macOS default output?
    ///
    /// `false` while active means the user picked another output in the Sound
    /// menu. That is treated as intent (stop routing) rather than something to
    /// fight — see `Router.systemSinkDisplaced`. Polled, not observed, for the
    /// same reason `WholeHomeSinkOutput.isSystemDefaultOutput` is: a HAL
    /// listener would fire on an arbitrary queue into actor-owned state.
    public var isSystemDefaultOutput: Bool {
        guard isActive else { return false }
        guard let current = try? DirectStereoOutput.readDefaultOutput() else {
            // Unreadable is not proof of displacement.
            return true
        }
        if current == deviceID { return true }
        return DirectStereoOutput.readDeviceUID(current) == candidate.uid
    }

    // MARK: - Lifecycle

    /// Make the sink the default output AND the default *system* output.
    ///
    /// Both properties matter. `kAudioHardwarePropertyDefaultOutputDevice` is
    /// where apps render; `kAudioHardwarePropertyDefaultSystemOutputDevice` is
    /// where macOS plays alerts and — critically — is what the volume HUD and
    /// the menu-bar slider follow on some releases. Setting only the first
    /// leaves alert sounds going straight to the old speaker (bypassing our
    /// fan-out at a random volume) and can leave the HUD pointed elsewhere.
    ///
    /// Idempotent: a second call while active is a no-op.
    ///
    /// `seedVolume` is the level the system volume should ADOPT as we take
    /// over — normally the level the outgoing default output is sitting at.
    /// It is not a nicety: the sink's own scalar is 1.0 on a first activation
    /// (a fresh driver, or a BlackHole nobody has touched), and the Router
    /// copies the master straight onto the physical devices' hardware volume.
    /// Without seeding, a user listening at 10 % on headphones gets full scale
    /// the instant the path starts. Seeding makes the switch continuous: the
    /// value we then push back to that device is the value it already had.
    public func start(seedVolume: Float? = nil) throws {
        if isActive { return }
        // Sub-phases of the Router's "sink takeover" phase. The sample-rate
        // settle below polls for up to a second and the seed retries for up to
        // ~360 ms, so a slow takeover has three different plausible causes;
        // these marks say which one it was rather than leaving it to guesswork.
        var phases = PhaseTimer(scope: "[SystemSink] start")
        let id = try Self.deviceID(forUID: candidate.uid)

        let rawDefaultID = try Self.readDefault(Self.defaultOutputSelector)
        let rawDefaultUID = DirectStereoOutput.readDeviceUID(rawDefaultID)
        let (defaultID, defaultUID) = Self.restorablePrevious(
            id: rawDefaultID, uid: rawDefaultUID
        )
        // The SYSTEM output is a separate property that legitimately points at
        // a different device (measured on this machine: default output =
        // built-in speakers, system output = the user's multi-output device).
        // If we cannot read its current value we must NOT take it over:
        // substituting the ordinary default as "the previous system output"
        // would have teardown restore a fabricated value over the user's real
        // sound-effects destination. Failing to read it costs us alert routing,
        // which is the cheaper loss.
        let rawSystemID = try? Self.readDefault(Self.systemOutputSelector)
        let systemSnapshot = rawSystemID.map { id in
            Self.restorablePrevious(id: id, uid: DirectStereoOutput.readDeviceUID(id))
        }
        phases.mark("snapshot previous defaults")

        // Pin the sample rate BEFORE macOS starts rendering into the sink, so
        // no app opens it at the old rate and gets re-rated underneath.
        //
        // A successful WRITE is not a rate change: the HAL turns it into a
        // device configuration change that the driver applies asynchronously
        // (our own driver does it in PerformDeviceConfigurationChange, and the
        // host may defer it). Tapping before it lands hands `TapCapture` the
        // old ASBD, which it rejects — a start failure that looks like a bug in
        // the tap. So we wait for the readback, bounded.
        let originalRate = Self.nominalSampleRate(id)
        if let originalRate, originalRate != Self.requiredSampleRate {
            if Self.setNominalSampleRate(id, rate: Self.requiredSampleRate) {
                previousNominalSampleRate = originalRate
                if !Self.waitForSampleRate(id, rate: Self.requiredSampleRate) {
                    let observed = Self.nominalSampleRate(id).map { "\($0)" } ?? "?"
                    let message = "[SystemSink] \(candidate.uid) did not reach 48 kHz within \(Self.sampleRateSettleTimeoutMs) ms (still \(observed)); the process tap will refuse the format\n"
                    RouterLog.write(message)
                }
            } else {
                RouterLog.write(
                    "[SystemSink] could not set \(candidate.uid) to 48 kHz (currently \(originalRate)); the process tap will refuse a non-48 kHz format\n"
                )
            }
        }
        phases.mark("sample-rate settle")

        do {
            try Self.setDefaultOrThrow(Self.defaultOutputSelector, id)
        } catch {
            // We never acquired the device, so nothing else will roll the rate
            // back: `stop()` returns early while `deviceID` is still 0. Undo it
            // here or a failed start leaves BlackHole (a SHARED device)
            // globally re-rated behind the user's back.
            if let rate = previousNominalSampleRate {
                _ = Self.setNominalSampleRate(id, rate: rate)
                previousNominalSampleRate = nil
            }
            phases.mark("default-output write (failed)")
            throw error
        }
        phases.mark("default-output write")
        // The system-output write is best effort: a machine that refuses it
        // still gets a working master volume from the main default output, and
        // failing the whole path over alert routing would be a bad trade.
        var systemTakenOver = false
        if let systemSnapshot {
            let systemStatus = Self.setDefault(Self.systemOutputSelector, id)
            if systemStatus == noErr {
                systemTakenOver = true
            } else {
                RouterLog.write(
                    "[SystemSink] default SYSTEM output write failed OSStatus=\(systemStatus); alerts stay on the previous device\n"
                )
            }
            previousSystemOutputID = systemTakenOver ? systemSnapshot.0 : nil
            previousSystemOutputUID = systemTakenOver ? systemSnapshot.1 : nil
        } else {
            RouterLog.write(
                "[SystemSink] could not read the previous default SYSTEM output; leaving it alone rather than restoring a guess later\n"
            )
            previousSystemOutputID = nil
            previousSystemOutputUID = nil
        }

        // Seed AFTER the takeover, not before. macOS re-applies its own
        // remembered level for a device at the moment that device becomes the
        // default output, so a seed written first is simply overwritten —
        // measured on this machine: seed 0.125 -> read back 0.4375, the sink's
        // remembered level. Writing after (and verifying) is the only ordering
        // that holds. Nothing is audible during the gap: the sink discards
        // audio and our own outputs do not start until `start()` returns.
        phases.mark("system-output write")
        if let seedVolume {
            Self.seedVolumeAfterTakeover(
                uid: candidate.uid, target: max(0, min(1, seedVolume))
            )
            phases.mark("volume seed")
        }

        deviceID = id
        previousDefaultOutputID = defaultID
        previousDefaultOutputUID = defaultUID
        lastStopStatus = nil
        // From here on, a crash leaves the default output on a silent device.
        // The claim is what lets the NEXT launch prove that and fix it.
        Self.writeOwnershipClaim(uid: candidate.uid)
    }

    /// Restore both default-output properties.
    ///
    /// Same policy as `DirectStereoOutput.stop()`:
    ///   - if the sink is no longer the default, the user moved it — do NOT
    ///     fight them, just forget our snapshot;
    ///   - if the current default is unreadable we cannot prove anything, so
    ///     we report failure rather than writing over an unknown state;
    ///   - a failed restore falls back to any ordinary output rather than
    ///     leaving macOS pointed at a silent sink.
    ///
    /// Returns false when the default output could not be restored; the Router
    /// turns that into a thrown error so app termination is blocked and the
    /// user is told, exactly like the other two default-output owners.
    @discardableResult
    public func stop() -> Bool {
        guard deviceID != 0 else { return true }
        let active = deviceID
        let outcome = Self.restoreDefault(
            selector: Self.defaultOutputSelector,
            activeID: active,
            activeUID: candidate.uid,
            previousID: previousDefaultOutputID,
            previousUID: previousDefaultOutputUID
        )
        // The system-output property gets the same treatment but never blocks
        // teardown: it carries alert sounds, not the audio path.
        _ = Self.restoreDefault(
            selector: Self.systemOutputSelector,
            activeID: active,
            activeUID: candidate.uid,
            previousID: previousSystemOutputID,
            previousUID: previousSystemOutputUID
        )
        if let previousNominalSampleRate {
            _ = Self.setNominalSampleRate(active, rate: previousNominalSampleRate)
        }
        lastStopStatus = outcome.status
        if outcome.fullyStopped {
            // Only a clean stop retires the claim. A stop that could NOT give
            // the default output back leaves it standing, so the next launch
            // still recognises the situation.
            Self.clearOwnershipClaim()
            previousNominalSampleRate = nil
            deviceID = 0
            previousDefaultOutputID = nil
            previousDefaultOutputUID = nil
            previousSystemOutputID = nil
            previousSystemOutputUID = nil
        }
        return outcome.fullyStopped
    }

    // MARK: - Restore state machine (pure)

    /// What `stop()` should do about one default-output property.
    ///
    /// Pure so the four branches are unit-testable without a HAL — this is the
    /// logic that decides whether the user is left with working audio.
    public enum RestoreAction: Equatable, Sendable {
        /// The sink is still the default; write `previous` back.
        case restorePrevious
        /// The sink is still the default but we have no usable snapshot;
        /// write any ordinary output.
        case fallback
        /// Someone moved the default away while we ran. Leave it alone.
        case userMoved
        /// The current default is unreadable, so nothing can be proven.
        case unknownCurrent
    }

    public static func restoreAction(
        currentID: AudioObjectID?,
        currentUID: String?,
        activeID: AudioObjectID,
        activeUID: String,
        hasPrevious: Bool
    ) -> RestoreAction {
        guard let currentID else { return .unknownCurrent }
        let stillOurs = currentID == activeID
            || (currentUID != nil && currentUID == activeUID)
        guard stillOurs else { return .userMoved }
        return hasPrevious ? .restorePrevious : .fallback
    }

    private struct RestoreOutcome {
        let fullyStopped: Bool
        let status: String
    }

    private static func restoreDefault(
        selector: AudioObjectPropertySelector,
        activeID: AudioObjectID,
        activeUID: String,
        previousID: AudioObjectID?,
        previousUID: String?
    ) -> RestoreOutcome {
        let current = try? readDefault(selector)
        let currentUID = current.flatMap { DirectStereoOutput.readDeviceUID($0) }
        let target = restoreTargetID(previousID: previousID, previousUID: previousUID)
        switch restoreAction(
            currentID: current,
            currentUID: currentUID,
            activeID: activeID,
            activeUID: activeUID,
            hasPrevious: target != nil
        ) {
        case .unknownCurrent:
            return RestoreOutcome(
                fullyStopped: false,
                status: "restore skipped: current default unreadable"
            )
        case .userMoved:
            return RestoreOutcome(
                fullyStopped: true,
                status: "restore skipped: user changed default"
            )
        case .restorePrevious:
            guard let target else {
                return RestoreOutcome(fullyStopped: false, status: "restore target vanished")
            }
            let status = setDefault(selector, target)
            if status == noErr {
                return RestoreOutcome(fullyStopped: true, status: "restored default \(target)")
            }
            return fallbackRestore(
                selector: selector, activeID: activeID,
                reason: "restore default failed OSStatus=\(status)"
            )
        case .fallback:
            return fallbackRestore(
                selector: selector, activeID: activeID,
                reason: "no restorable previous default"
            )
        }
    }

    private static func fallbackRestore(
        selector: AudioObjectPropertySelector,
        activeID: AudioObjectID,
        reason: String
    ) -> RestoreOutcome {
        guard let fallback = DirectStereoOutput.fallbackDefaultOutputID(
            coveredUIDs: [], excluding: [activeID]
        ) else {
            // No ordinary output exists at all. Leaving the default on a
            // silent sink is the only remaining state; say so loudly.
            return RestoreOutcome(
                fullyStopped: false,
                status: "\(reason); no fallback output exists"
            )
        }
        let status = setDefault(selector, fallback)
        if status == noErr {
            return RestoreOutcome(
                fullyStopped: true,
                status: "\(reason); fell back to \(fallback)"
            )
        }
        return RestoreOutcome(
            fullyStopped: false,
            status: "\(reason); fallback failed OSStatus=\(status)"
        )
    }

    // MARK: - Ownership claim
    //
    // BlackHole is a SHARED device. A user may deliberately have it selected
    // as the system default for their own recording setup, and SyncCast
    // launching must not disturb that. So the crash-recovery sweep below is
    // not allowed to reason from "the default is a sink, and I am the kind of
    // app that uses sinks" — it needs PROOF that a previous SyncCast session
    // took that default and never gave it back.
    //
    // The proof is this claim: written when `start()` succeeds, removed on a
    // clean `stop()`. A claim left behind by a dead process is exactly the
    // SIGKILL case the sweep exists for.

    static let claimDefaultsKey = "syncast.systemSink.ownershipClaim"
    private static let claimPIDKey = "pid"
    private static let claimUIDKey = "uid"

    static func writeOwnershipClaim(uid: String, defaults: UserDefaults = .standard) {
        defaults.set(
            [
                claimPIDKey: Int(ProcessInfo.processInfo.processIdentifier),
                claimUIDKey: uid,
            ],
            forKey: claimDefaultsKey
        )
    }

    static func clearOwnershipClaim(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: claimDefaultsKey)
    }

    /// A stale claim: one written by a process that is no longer alive.
    ///
    /// Validated at the boundary — UserDefaults is external input, so a
    /// hand-edited or half-written plist entry reads as "no claim" rather than
    /// as licence to move the user's default output.
    static func staleOwnershipClaimUID(
        defaults: UserDefaults = .standard,
        isProcessAlive: (pid_t) -> Bool = { DirectStereoOutput.processIsAlive($0) }
    ) -> String? {
        guard let raw = defaults.dictionary(forKey: claimDefaultsKey),
              let pid = raw[claimPIDKey] as? Int,
              pid > 0,
              let uid = raw[claimUIDKey] as? String,
              isSinkUID(uid)
        else {
            return nil
        }
        if pid == Int(ProcessInfo.processInfo.processIdentifier) { return nil }
        return isProcessAlive(pid_t(pid)) ? nil : uid
    }

    /// Launch-time recovery: if a previous run was SIGKILLed while a sink was
    /// the default output, macOS is left rendering into a silent device — the
    /// user hears nothing and the Sound menu looks perfectly fine.
    ///
    /// Fires ONLY when all of these hold:
    ///   * a claim from a dead process names a sink (see above),
    ///   * the current default output really is that same sink,
    ///   * an ordinary output exists to move to.
    /// Anything less and we leave the user's chosen output alone.
    /// The claim is the ONLY evidence a later launch has. It is retired in
    /// exactly two cases: the recovery worked, or the default output is
    /// provably not the claimed sink any more (someone already fixed it). Every
    /// other path — HAL unreadable, no fallback device, a refused write —
    /// leaves it standing so the next launch retries. Clearing it there would
    /// silently retire the machine's only chance of getting its audio back.
    @discardableResult
    public static func sweepStaleDefault(defaults: UserDefaults = .standard) -> String? {
        guard let claimedUID = staleOwnershipClaimUID(defaults: defaults) else {
            return nil
        }
        guard let current = try? readDefault(defaultOutputSelector) else {
            // Cannot read the default at all: prove nothing, retire nothing.
            return nil
        }
        guard let uid = DirectStereoOutput.readDeviceUID(current),
              uid == claimedUID
        else {
            // The default is something else — either the user fixed it or the
            // previous run did after all. Nothing to recover; retire the claim.
            clearOwnershipClaim(defaults: defaults)
            return nil
        }
        guard let fallback = DirectStereoOutput.fallbackDefaultOutputID(
            coveredUIDs: [], excluding: [current]
        ) else {
            return nil
        }
        guard setDefault(defaultOutputSelector, fallback) == noErr else {
            return nil
        }
        _ = setDefault(systemOutputSelector, fallback)
        clearOwnershipClaim(defaults: defaults)
        return "moved stale default output off \(uid) to \(fallback) (claim left by a dead SyncCast)"
    }

    // MARK: - HAL helpers

    static let defaultOutputSelector = kAudioHardwarePropertyDefaultOutputDevice
    static let systemOutputSelector = kAudioHardwarePropertyDefaultSystemOutputDevice

    private static func restoreTargetID(
        previousID: AudioObjectID?,
        previousUID: String?
    ) -> AudioObjectID? {
        if let previousUID, let id = try? Capture.deviceID(forUID: previousUID) {
            return id
        }
        return previousID
    }

    /// Never remember one of OUR OWN devices as "the previous default": the
    /// sinks are silent and the aggregates are destroyed on teardown, so
    /// restoring one leaves the user with no audio and no error anywhere.
    private static func restorablePrevious(
        id: AudioObjectID,
        uid: String?
    ) -> (AudioObjectID?, String?) {
        guard let uid else { return (id, nil) }
        let isOurs = isSinkUID(uid)
            || uid.hasPrefix(DirectStereoOutput.uidPrefix)
            || uid.hasPrefix(WholeHomeSinkOutput.uidPrefix)
            || uid.hasPrefix(AggregateDevice.uidPrefix)
        guard isOurs else { return (id, uid) }
        if let fallback = DirectStereoOutput.fallbackDefaultOutputID(coveredUIDs: []) {
            return (fallback, DirectStereoOutput.readDeviceUID(fallback))
        }
        return (nil, nil)
    }

    static func nominalSampleRate(_ id: AudioObjectID) -> Float64? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr
        else {
            return nil
        }
        return value
    }

    /// Write the seed level onto the sink once macOS has finished installing
    /// it as the default output, retrying while the switch settles.
    ///
    /// The retry is not defensive padding: a write issued while CoreAudio is
    /// mid-switch is accepted and then discarded (the same effect that made a
    /// pre-takeover seed useless, and that the probe hit when restoring the
    /// sink's level before handing the default back).
    private static func seedVolumeAfterTakeover(uid: String, target: Float) {
        for attempt in 0..<seedAttempts {
            usleep(seedRetryIntervalMs * 1000)
            _ = AggregateDevice.applyHardwareVolume(uid: uid, volume: target)
            if let now = AggregateDevice.readHardwareVolume(uid: uid),
               abs(now - target) <= seedTolerance {
                return
            }
            _ = attempt
        }
        let observed = AggregateDevice.readHardwareVolume(uid: uid)
            .map { String(format: "%.4f", $0) } ?? "?"
        RouterLog.write(
            "[SystemSink] could not seed \(uid) to \(target) (still \(observed)); the system volume may jump on takeover\n"
        )
    }

    private static let seedAttempts = 6
    private static let seedRetryIntervalMs: UInt32 = 60
    /// A scalar grid is quantised (the built-in speakers step in 1/16), so an
    /// exact match is not a fair test of "did the write land".
    private static let seedTolerance: Float = 0.02

    /// How long to let a requested sample-rate change land. Generous enough
    /// for a driver that routes it through a configuration change, short
    /// enough that a refusing device does not stall app start.
    static let sampleRateSettleTimeoutMs = 1_000
    private static let sampleRatePollIntervalMs: UInt32 = 25

    /// Poll the nominal rate until it matches, or the timeout expires.
    /// Returns whether it landed.
    static func waitForSampleRate(_ id: AudioObjectID, rate: Float64) -> Bool {
        let deadline = Date().addingTimeInterval(
            Double(sampleRateSettleTimeoutMs) / 1000
        )
        repeat {
            if let current = nominalSampleRate(id), current == rate { return true }
            usleep(sampleRatePollIntervalMs * 1000)
        } while Date() < deadline
        return nominalSampleRate(id) == rate
    }

    @discardableResult
    static func setNominalSampleRate(_ id: AudioObjectID, rate: Float64) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = rate
        return AudioObjectSetPropertyData(
            id, &address, 0, nil, UInt32(MemoryLayout<Float64>.size), &value
        ) == noErr
    }

    static func deviceID(forUID uid: String) throws -> AudioObjectID {
        do {
            return try Capture.deviceID(forUID: uid)
        } catch {
            throw SystemSinkError.deviceNotFound(uid)
        }
    }

    static func readDefault(
        _ selector: AudioObjectPropertySelector
    ) throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id
        )
        guard status == noErr, id != kAudioObjectUnknown else {
            throw SystemSinkError.readDefaultFailed(status)
        }
        return id
    }

    static func setDefault(
        _ selector: AudioObjectPropertySelector,
        _ id: AudioObjectID
    ) -> OSStatus {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var mutableID = id
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil,
            UInt32(MemoryLayout<AudioObjectID>.size),
            &mutableID
        )
    }

    static func setDefaultOrThrow(
        _ selector: AudioObjectPropertySelector,
        _ id: AudioObjectID
    ) throws {
        let status = setDefault(selector, id)
        guard status == noErr else {
            throw SystemSinkError.setDefaultFailed(status)
        }
    }

    // MARK: - Master volume readback

    /// Read the sink's current volume scalar / mute — the system volume.
    ///
    /// Returns nil for a property the device does not expose. A sink with no
    /// readable VolumeScalar is a broken sink (it would give the user a greyed
    /// slider, which is the whole thing this path exists to avoid), and the
    /// Router refuses to run the sink path on one.
    public func readMaster() -> (volume: Float?, muted: Bool?) {
        guard isActive else { return (nil, nil) }
        return (
            AggregateDevice.readHardwareVolume(uid: candidate.uid),
            AggregateDevice.readHardwareMute(uid: candidate.uid)
        )
    }

    /// Does this device expose the volume control the whole path depends on?
    /// Checked before we hand macOS the sink, so an unsuitable driver fails
    /// loudly at start instead of silently greying the slider.
    public static func exposesVolumeControl(uid: String) -> Bool {
        AggregateDevice.readHardwareVolume(uid: uid) != nil
    }
}
