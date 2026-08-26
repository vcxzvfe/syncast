import Foundation
import CoreAudio
import Darwin

/// The whole-home mode's *system sink*: a public CoreAudio aggregate device
/// named "AirPlay 全屋" whose only subdevice is BlackHole 2ch.
///
/// Why this exists
/// ---------------
/// Whole-home mode needs the macOS default output to be a SILENT device:
/// system audio is captured by ScreenCaptureKit and re-emitted by OwnTone
/// (the single clock domain) to both the AirPlay receivers and — via the
/// local FIFO bridge — the physical speakers. If the default output were a
/// real speaker, the same audio would play twice at two different latencies.
/// BlackHole 2ch is that silent device, and until now the user had to select
/// it by hand in System Settings → Sound, where it shows up under its driver
/// name ("BlackHole 2ch") with no hint that it is SyncCast's whole-home input.
///
/// Renaming BlackHole itself is not an option: `kAudioObjectPropertyName` is
/// not settable on it (`AudioObjectIsPropertySettable` returns false), and the
/// only other route is editing `/Library/Audio/Plug-Ins/HAL/BlackHole.driver`'s
/// Info.plist, which needs sudo plus App Management permission. So instead we
/// wrap BlackHole in an aggregate device we own, which we DO get to name, and
/// make that the default output. ScreenCaptureKit captures at the system
/// level and is indifferent to which device is default, so capture is
/// unaffected; the aggregate inherits BlackHole's loopback silence, so there
/// is no double playback.
///
/// Known trade-off (deliberate, see `enabled`)
/// -------------------------------------------
/// The aggregate does NOT forward `kAudioDevicePropertyVolumeScalar` to its
/// main subdevice — measured on this machine: after a 1.5 s settle the
/// property reports `has=false` (`kAudioHardwareUnknownPropertyError`) even
/// with `kAudioAggregateDeviceMainSubDeviceKey` set to BlackHole. So while
/// this sink is the default output, the macOS volume slider goes grey. That is
/// arguably more honest than today's behaviour (BlackHole exposes a settable
/// volume that does nothing to the samples, so the slider moves and is
/// inaudible), but it is a visible change. `enabled` is the single-constant
/// escape hatch back to the old "user picks BlackHole by hand" behaviour.
///
/// A greyed-out system slider is also exactly what sends a user into System
/// Settings → Sound to pick their real speakers again — which silently breaks
/// whole-home into double playback. `isSystemDefaultOutput` exists so that
/// condition is visible in the panel (and in `diagnostic`) instead of being
/// discovered by ear; `reassertDefaultOutput()` is the one-click way back.
///
/// Relationship to the other two aggregate flavours in this module
/// --------------------------------------------------------------
///   - `AggregateDevice`      — PRIVATE (invisible in Audio MIDI Setup),
///                              stereo-mode fan-out target for our own AUHAL.
///   - `DirectStereoOutput`   — PUBLIC, becomes the default output, fans out
///                              to the user's real speakers.
///   - `WholeHomeSinkOutput`  — PUBLIC, becomes the default output, wraps the
///                              silent BlackHole loopback.
/// Each has its own UID namespace because their orphan sweeps need different
/// protections; this one and `DirectStereoOutput` can be the live system
/// default, so their sweeps must move the default away before destroying.
public final class WholeHomeSinkOutput {
    public enum WholeHomeSinkError: Error, CustomStringConvertible {
        case blackHoleNotInstalled
        case readDefaultFailed(OSStatus)
        case setDefaultFailed(OSStatus)
        case createAggregateFailed(OSStatus)
        case unsafeAggregateChannelLayout(String)
        case stopFailed(String)

        public var description: String {
            switch self {
            case .blackHoleNotInstalled:
                return """
                whole-home mode needs the BlackHole 2ch virtual audio driver, \
                which is not installed. Install it with \
                `brew install --cask blackhole-2ch` (or run scripts/bootstrap.sh) \
                and try again.
                """
            case .readDefaultFailed(let status):
                return "read default output failed: OSStatus=\(status)"
            case .setDefaultFailed(let status):
                return "set default output failed: OSStatus=\(status)"
            case .createAggregateFailed(let status):
                return "create whole-home sink aggregate failed: OSStatus=\(status)"
            case .unsafeAggregateChannelLayout(let summary):
                return "whole-home sink exposes unsafe channel layout: \(summary)"
            case .stopFailed(let reason):
                return "whole-home sink stop failed: \(reason)"
            }
        }
    }

    /// Master switch for the rename behaviour. `false` restores the previous
    /// contract exactly: SyncCast never touches the default output in
    /// whole-home mode and the user selects "BlackHole 2ch" by hand.
    /// Flip this rather than reverting the feature if the greyed-out system
    /// volume slider (see the type docs) turns out to be unacceptable.
    public static let enabled = true

    /// Stable UID namespace. Kept SEPARATE from `AggregateDevice.uidPrefix`
    /// and `DirectStereoOutput.uidPrefix` — `sweepOrphans()` here must move
    /// the system default away before destroying, which the private
    /// aggregate's sweep deliberately does not do.
    public static let uidPrefix = "io.syncast.wholehomesink.v1."

    /// What the user sees in System Settings → Sound while whole-home mode
    /// is running. Mixed zh/en matches the existing panel copy (the popover
    /// has both Chinese and English strings); the project has no
    /// localization bundle, so a single constant is the whole story.
    public static let displayName = "AirPlay 全屋"

    /// Canonical UID of the BlackHole 2ch driver (verified on this machine:
    /// `id=60 out=2 name=BlackHole 2ch uid=BlackHole2ch_UID`).
    public static let blackHole2chUID = "BlackHole2ch_UID"

    /// Lower-cased needle for the fallback scan, for installs that only have
    /// a differently-packaged BlackHole (16ch build, renamed driver bundle).
    /// Same judgement the stereo/whole-home route filters already use.
    public static let blackHoleNameNeedle = "blackhole"

    /// The fallback scan only accepts a stereo BlackHole: whole-home's whole
    /// pipeline is 2-channel, and a 16ch loopback would hand the aggregate a
    /// layout the safety gate below rejects anyway.
    public static let blackHoleOutputChannelCount = 2

    /// Same gate as `DirectStereoOutput`: this device becomes the macOS
    /// default output, so ordinary apps must see a plain stereo surface.
    public static let maxSafeOutputChannels = 2

    /// Why this is NOT forced to 48 kHz the way `AggregateDevice` forces its
    /// private aggregate: setting the aggregate's nominal rate propagates to
    /// its main subdevice, which would silently re-rate BlackHole system-wide
    /// for every other app using it. This sink carries no samples we ever
    /// read — it exists to be a named, silent default output — so it simply
    /// inherits whatever rate BlackHole is already at (96 kHz on this
    /// machine).
    public static let inheritsSubdeviceSampleRate = true

    private var previousDefaultOutputID: AudioObjectID?
    private var previousDefaultOutputUID: String?
    private var aggregateID: AudioObjectID = 0
    private var aggregateUID: String = ""
    private var blackHoleUID: String = ""
    private var lastStopStatus: String?

    public var isActive: Bool { aggregateID != 0 }

    public var lastStopStatusText: String? { lastStopStatus }

    /// Whether macOS is still sending system audio into this sink.
    ///
    /// Polled (once a second, from the app's existing health loop) rather than
    /// observed with an `AudioObjectAddPropertyListenerBlock`. A listener would
    /// fire on an arbitrary dispatch queue into an object owned by the `Router`
    /// actor, which is a data race for the sake of sub-second detection of a
    /// condition whose only consequence is a UI banner. Polling also self-heals:
    /// there is no cached flag to go stale if the user puts the sink back.
    ///
    /// `false` while active is the double-playback condition: macOS renders to
    /// whatever the user picked AND ScreenCaptureKit still feeds OwnTone, so
    /// every track plays twice at two different latencies.
    public var isSystemDefaultOutput: Bool {
        guard isActive else { return false }
        guard let current = try? Self.readDefaultOutput() else {
            // Unreadable is not proof of displacement, and claiming it would
            // put a scary banner on screen for a transient HAL hiccup.
            return true
        }
        return Self.isSinkTheDefault(
            currentID: current,
            currentUID: Self.readDeviceUID(current),
            activeID: aggregateID,
            activeUID: aggregateUID
        )
    }

    /// Pure form of the "is our sink the current default?" comparison, shared
    /// by `isSystemDefaultOutput` and `stop()` so the running check and the
    /// teardown check can never disagree.
    ///
    /// Compares by BOTH id and UID: `AudioObjectID`s are transient, so a UID
    /// match is authoritative when it is available, while the id comparison
    /// still covers devices whose UID could not be read.
    static func isSinkTheDefault(
        currentID: AudioObjectID,
        currentUID: String?,
        activeID: AudioObjectID,
        activeUID: String
    ) -> Bool {
        if currentID == activeID { return true }
        return !activeUID.isEmpty && currentUID == activeUID
    }

    /// Put the sink back as the default output after the user (or macOS, on a
    /// headphone plug) moved it away.
    ///
    /// Explicitly NOT automatic. Whole-home cannot re-assert itself on a timer
    /// without fighting a deliberate choice — plugging in headphones while
    /// whole-home runs is a legitimate thing to do, and a self-healing sink
    /// would yank the default back every second. The app surfaces the
    /// condition and this is the button behind it.
    @discardableResult
    public func reassertDefaultOutput() -> Bool {
        guard isActive else { return false }
        return Self.setDefaultOutput(aggregateID) == noErr
    }

    public var diagnostic: String {
        guard isActive else {
            if let lastStopStatus {
                return "wholeHomeSink=inactive lastStop=\"\(lastStopStatus)\""
            }
            return "wholeHomeSink=inactive"
        }
        // `default=` is the double-playback tell: "no" means macOS is rendering
        // system audio somewhere else while the SCK tap still feeds OwnTone.
        return "wholeHomeSink=active id=\(aggregateID) sub=\(blackHoleUID)"
            + " previous=\(previousDefaultOutputUID ?? "?")"
            + " default=\(isSystemDefaultOutput ? "yes" : "no")"
    }

    public init() {}

    deinit {
        stop()
    }

    // MARK: - Lifecycle

    /// Create the named sink and make it the system default output.
    ///
    /// Idempotent: a second call while already active is a no-op, so the
    /// Router can call it from every whole-home start path without tracking
    /// whether a previous call already succeeded.
    public func start() throws {
        guard Self.enabled else { return }
        if isActive { return }

        let blackHole = try Self.resolveBlackHoleUID()

        // Snapshot the user's current default BEFORE we touch anything, by
        // both ID and UID: AudioObjectIDs are transient (a replug mints a new
        // one) while UIDs are stable, so `stop()` re-resolves by UID first.
        let rawPreviousID = try Self.readDefaultOutput()
        let rawPreviousUID = Self.readDeviceUID(rawPreviousID)
        let (previousID, previousUID) = Self.restorablePreviousDefault(
            id: rawPreviousID,
            uid: rawPreviousUID
        )

        let aggregate = try Self.createPublicSinkAggregate(blackHoleUID: blackHole)
        do {
            try Self.setDefaultOutputOrThrow(aggregate.id)
        } catch {
            // Never leave a half-built sink behind: if we could not become the
            // default output the aggregate has no reason to exist, and leaving
            // it would show the user a phantom "AirPlay 全屋" device that does
            // nothing.
            AudioHardwareDestroyAggregateDevice(aggregate.id)
            throw error
        }

        previousDefaultOutputID = previousID
        previousDefaultOutputUID = previousUID
        aggregateID = aggregate.id
        aggregateUID = aggregate.uid
        blackHoleUID = blackHole
        lastStopStatus = nil
    }

    /// Restore the user's previous default output and destroy the sink.
    ///
    /// Returns false when the default output could NOT be restored. In that
    /// case the aggregate is deliberately NOT destroyed — destroying the live
    /// system default leaves macOS with no output at all, which is a far worse
    /// failure than a leaked device that the next launch's `sweepOrphans()`
    /// reaps. The Router turns a false return into a thrown error so app
    /// termination is blocked and the user sees why.
    @discardableResult
    public func stop() -> Bool {
        guard aggregateID != 0 else {
            return true
        }
        let active = aggregateID
        let current = try? Self.readDefaultOutput()
        let currentUID = current.flatMap { Self.readDeviceUID($0) }
        let currentIsActiveDefault = current.map {
            Self.isSinkTheDefault(
                currentID: $0,
                currentUID: currentUID,
                activeID: active,
                activeUID: aggregateUID
            )
        } ?? false

        var canDestroyAggregate = true
        var fullyStopped = true

        if !currentIsActiveDefault {
            if current == nil {
                // We cannot prove the sink is no longer the default, so we
                // cannot prove destroying it is safe.
                lastStopStatus = "restore skipped: current default unreadable"
                canDestroyAggregate = false
                fullyStopped = false
            } else {
                // The user picked a different output while we were running.
                // Respect it — restoring our snapshot would yank the default
                // out from under a deliberate choice.
                lastStopStatus = "restore skipped: user changed default"
            }
        } else if let previous = Self.restoreTargetID(
            previousID: previousDefaultOutputID,
            previousUID: previousDefaultOutputUID
        ) {
            let status = Self.setDefaultOutput(previous)
            if status == noErr {
                lastStopStatus = "restored default \(previous)"
            } else if let fallback = Self.fallbackDefaultOutputID(excluding: [active]) {
                let fallbackStatus = Self.setDefaultOutput(fallback)
                if fallbackStatus == noErr {
                    lastStopStatus = "restore default failed OSStatus=\(status); fell back to \(fallback)"
                } else {
                    lastStopStatus = "restore default failed OSStatus=\(status); fallback failed OSStatus=\(fallbackStatus)"
                    canDestroyAggregate = false
                    fullyStopped = false
                }
            } else {
                lastStopStatus = "restore default failed OSStatus=\(status); no fallback"
                canDestroyAggregate = false
                fullyStopped = false
            }
        } else if let fallback = Self.fallbackDefaultOutputID(excluding: [active]) {
            // No usable snapshot (e.g. the previous default was itself a
            // leaked SyncCast device, or a raw BlackHole). Anything ordinary
            // beats leaving the default pointed at a device we are about to
            // destroy.
            let fallbackStatus = Self.setDefaultOutput(fallback)
            if fallbackStatus == noErr {
                lastStopStatus = "no restorable previous default; fell back to \(fallback)"
            } else {
                lastStopStatus = "no restorable previous default; fallback failed OSStatus=\(fallbackStatus)"
                canDestroyAggregate = false
                fullyStopped = false
            }
        } else {
            // The machine exposes no ordinary output at all (headless Mac
            // mini with nothing attached). Destroy anyway and let CoreAudio
            // pick a successor the way it does for any unplugged device —
            // refusing here would leave the sink installed forever and block
            // app termination with no action the user could take.
            lastStopStatus = "no restorable previous default and no fallback; destroyed, CoreAudio reselects"
        }

        if canDestroyAggregate {
            AudioHardwareDestroyAggregateDevice(active)
        }

        if fullyStopped {
            previousDefaultOutputID = nil
            previousDefaultOutputUID = nil
            aggregateID = 0
            aggregateUID = ""
            blackHoleUID = ""
        }
        return fullyStopped
    }

    // MARK: - Orphan sweep

    /// Outcome of the per-device sweep decision. Split out from the CoreAudio
    /// calls so the three protections are unit-testable without a HAL.
    public enum SweepDecision: Equatable, Sendable {
        /// Not one of ours — leave it alone.
        case skipForeign
        /// Created by THIS process; `stop()`/`deinit` owns its lifetime.
        case skipOwnProcess
        /// Another SyncCast instance is alive and still using it.
        case skipLiveOwner
        /// It is the live system default and we could not move the default
        /// somewhere real first. Destroying it would leave macOS mute.
        case skipUnmovableDefault
        case destroy
    }

    /// Pure decision for one candidate device.
    ///
    /// `ownerOwnsLiveSyncCast` and `moveDefaultAway` are closures because both
    /// are expensive (a process-path lookup and a default-output write
    /// respectively) and must only run when the cheaper checks have not
    /// already decided. `moveDefaultAway` in particular has a side effect and
    /// must never run for a device we are not about to destroy.
    static func sweepDecision(
        uid: String?,
        myPID: pid_t,
        isCurrentDefault: Bool,
        ownerOwnsLiveSyncCast: (pid_t) -> Bool,
        moveDefaultAway: () -> Bool
    ) -> SweepDecision {
        guard let uid, uid.hasPrefix(Self.uidPrefix) else {
            return .skipForeign
        }
        if let pid = processID(from: uid) {
            if pid == myPID { return .skipOwnProcess }
            if ownerOwnsLiveSyncCast(pid) { return .skipLiveOwner }
        }
        if isCurrentDefault, !moveDefaultAway() {
            return .skipUnmovableDefault
        }
        return .destroy
    }

    /// Reap whole-home sinks left behind by a crashed or SIGKILLed instance.
    /// Called once at Router init, before any sink is created.
    @discardableResult
    public static func sweepOrphans() -> Int {
        let currentDefault = try? readDefaultOutput()
        let myPID = ProcessInfo.processInfo.processIdentifier
        var destroyed = 0
        for id in DirectStereoOutput.enumerateAllDevices() {
            let uid = readDeviceUID(id)
            let decision = sweepDecision(
                uid: uid,
                myPID: myPID,
                isCurrentDefault: currentDefault == id,
                ownerOwnsLiveSyncCast: {
                    DirectStereoOutput.processOwnsLiveSyncCastAggregate($0)
                },
                moveDefaultAway: { moveDefaultAwayFromSink(id) }
            )
            guard decision == .destroy else { continue }
            if AudioHardwareDestroyAggregateDevice(id) == noErr {
                destroyed += 1
            }
        }
        return destroyed
    }

    // MARK: - BlackHole resolution

    /// True when a device looks like a usable BlackHole loopback sink.
    /// Pure so the fallback rule is testable without CoreAudio.
    static func matchesBlackHole(name: String?, outputChannels: Int) -> Bool {
        guard let name else { return false }
        guard outputChannels == Self.blackHoleOutputChannelCount else { return false }
        return name.lowercased().contains(Self.blackHoleNameNeedle)
    }

    /// Resolve the BlackHole UID: exact UID first (the overwhelmingly common
    /// `brew install --cask blackhole-2ch` case), then a name+channel-count
    /// scan for differently-packaged installs. Throws a user-actionable error
    /// rather than failing silently — before this existed, a missing BlackHole
    /// meant whole-home mode came up with the real speakers still as default
    /// output, i.e. every track played twice at different latencies with no
    /// message anywhere.
    static func resolveBlackHoleUID() throws -> String {
        if let id = try? DirectStereoOutput.deviceID(forUID: Self.blackHole2chUID),
           id != AudioObjectID(kAudioObjectUnknown) {
            return Self.blackHole2chUID
        }
        for id in DirectStereoOutput.enumerateAllDevices() {
            let (_, _, channels) = AggregateDevice.readStreamChannels(id)
            guard matchesBlackHole(name: readDeviceName(id), outputChannels: channels),
                  let uid = readDeviceUID(id) else {
                continue
            }
            return uid
        }
        throw WholeHomeSinkError.blackHoleNotInstalled
    }

    // MARK: - Aggregate construction

    /// Build the UID for a sink owned by `pid`. PID keeps two concurrent
    /// SyncCast instances from colliding and lets `sweepOrphans()` tell a live
    /// owner from a dead one; the UUID keeps a rapid stop/start from reusing a
    /// UID coreaudiod has not finished releasing.
    static func makeUID(pid: pid_t, uuid: String) -> String {
        "\(Self.uidPrefix)\(pid).\(uuid)"
    }

    static func processID(from uid: String) -> pid_t? {
        guard uid.hasPrefix(Self.uidPrefix) else { return nil }
        let suffix = uid.dropFirst(Self.uidPrefix.count)
        guard let pidPart = suffix.split(separator: ".", maxSplits: 1).first,
              let pid = Int32(pidPart),
              pid > 0 else {
            return nil
        }
        return pid_t(pid)
    }

    private static func createPublicSinkAggregate(
        blackHoleUID: String
    ) throws -> (id: AudioObjectID, uid: String) {
        let uid = makeUID(
            pid: ProcessInfo.processInfo.processIdentifier,
            uuid: UUID().uuidString
        )
        let subdevices: [[String: Any]] = [[
            kAudioSubDeviceUIDKey as String: blackHoleUID,
            // 0 = no drift compensation. BlackHole is the main (and only)
            // subdevice, so it IS the clock; correcting it against itself
            // would just burn CPU in the kernel SRC.
            kAudioSubDeviceDriftCompensationKey as String: UInt32(0),
        ]]
        let composition: [String: Any] = [
            kAudioAggregateDeviceUIDKey as String: uid,
            kAudioAggregateDeviceNameKey as String: Self.displayName,
            // private = 0 is load-bearing: the whole point is that the user
            // sees this device in System Settings → Sound. The private
            // aggregate in `AggregateDevice` is scoped to our process and
            // would be invisible there.
            kAudioAggregateDeviceIsPrivateKey as String: 0,
            kAudioAggregateDeviceIsStackedKey as String: 1,
            kAudioAggregateDeviceMainSubDeviceKey as String: blackHoleUID,
            kAudioAggregateDeviceSubDeviceListKey as String: subdevices,
        ]

        var newID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(
            composition as CFDictionary,
            &newID
        )
        guard status == noErr, newID != AudioObjectID(kAudioObjectUnknown) else {
            throw WholeHomeSinkError.createAggregateFailed(status)
        }
        let (streamCount, perStream, totalChannels) =
            AggregateDevice.readStreamChannels(newID)
        guard streamCount > 0,
              totalChannels > 0,
              totalChannels <= Self.maxSafeOutputChannels else {
            AudioHardwareDestroyAggregateDevice(newID)
            let summary = "streams=\(streamCount) ch=[\(perStream.map(String.init).joined(separator: ","))] total=\(totalChannels)"
            throw WholeHomeSinkError.unsafeAggregateChannelLayout(summary)
        }
        return (newID, uid)
    }

    // MARK: - Default-output plumbing
    //
    // These wrap `DirectStereoOutput`'s CoreAudio helpers rather than
    // duplicating them; the error type is the only thing that differs.

    static func readDefaultOutput() throws -> AudioObjectID {
        do {
            return try DirectStereoOutput.readDefaultOutput()
        } catch {
            let status: OSStatus
            if case DirectStereoOutput.DirectStereoError.readDefaultFailed(let s) = error {
                status = s
            } else {
                status = OSStatus(kAudioHardwareUnspecifiedError)
            }
            throw WholeHomeSinkError.readDefaultFailed(status)
        }
    }

    static func setDefaultOutput(_ id: AudioObjectID) -> OSStatus {
        DirectStereoOutput.setDefaultOutput(id)
    }

    static func setDefaultOutputOrThrow(_ id: AudioObjectID) throws {
        let status = setDefaultOutput(id)
        guard status == noErr else {
            throw WholeHomeSinkError.setDefaultFailed(status)
        }
    }

    static func readDeviceUID(_ id: AudioObjectID) -> String? {
        DirectStereoOutput.readDeviceUID(id)
    }

    static func readDeviceName(_ id: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, ptr)
        }
        guard status == noErr else { return nil }
        return value as String?
    }

    /// Pick any ordinary physical output. `ordinaryOutputScore` rejects
    /// aggregates outright, so this can never hand back another SyncCast
    /// device.
    static func fallbackDefaultOutputID(
        excluding excludedIDs: Set<AudioObjectID>
    ) -> AudioObjectID? {
        DirectStereoOutput.fallbackDefaultOutputID(
            coveredUIDs: [],
            excluding: excludedIDs
        )
    }

    private static func moveDefaultAwayFromSink(_ sinkID: AudioObjectID) -> Bool {
        guard let fallback = fallbackDefaultOutputID(excluding: [sinkID]) else {
            return false
        }
        return setDefaultOutput(fallback) == noErr
    }

    private static func restoreTargetID(
        previousID: AudioObjectID?,
        previousUID: String?
    ) -> AudioObjectID? {
        if let previousUID, let id = try? DirectStereoOutput.deviceID(forUID: previousUID) {
            return id
        }
        return previousID
    }

    /// Whether a device is a sane thing to hand the user back when whole-home
    /// mode ends. Two classes are refused:
    ///
    ///   - SyncCast-owned devices. A crash can leave one behind with macOS
    ///     still pointed at it, and a mode switch can briefly overlap two of
    ///     our paths. Restoring to one later points the system at a device
    ///     that no longer exists — total silence, no error anywhere.
    ///   - Raw BlackHole. This is the common case for existing users: they
    ///     already selected "BlackHole 2ch" by hand to make whole-home work,
    ///     so that is what we would snapshot on the very first run with this
    ///     feature — and "restoring" it on quit would leave their Mac silent
    ///     for every other app. The whole point of the sink is that nobody has
    ///     to live with a loopback as their default output.
    ///
    /// A user-created aggregate (Audio MIDI Setup's "多输出设备" and friends)
    /// IS restorable: it is a legitimate destination we must not second-guess.
    static func isRestorableDefault(uid: String?, name: String?) -> Bool {
        if let uid,
           uid.hasPrefix(Self.uidPrefix)
            || uid.hasPrefix(DirectStereoOutput.uidPrefix)
            || uid.hasPrefix(AggregateDevice.uidPrefix) {
            return false
        }
        if let name, name.lowercased().contains(Self.blackHoleNameNeedle) {
            return false
        }
        return true
    }

    private static func restorablePreviousDefault(
        id: AudioObjectID,
        uid: String?
    ) -> (AudioObjectID?, String?) {
        if isRestorableDefault(uid: uid, name: readDeviceName(id)) {
            return (id, uid)
        }
        if let fallback = fallbackDefaultOutputID(excluding: [id]) {
            return (fallback, readDeviceUID(fallback))
        }
        return (nil, nil)
    }
}
