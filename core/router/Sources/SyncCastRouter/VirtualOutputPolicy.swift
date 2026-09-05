import Foundation
import CoreAudio

/// Whether a CoreAudio output device is a **userland plug-in** (an
/// `AudioServerPlugIn` loaded into `coreaudiod`: BlackHole, Zoom, Teams,
/// SyncCast's own driver) rather than something with a speaker on the end of
/// it.
///
/// # Why the system-sink path must refuse these as OUTPUTS
///
/// Measured on this machine on 2026-09-05 (macOS 26.6.2), with the only
/// enabled output being `ZoomAudioDevice` (transport `virt`) while the sink
/// path tapped BlackHole 2ch:
///
///   * `Router.start` took **108 s** to return;
///   * `afplay` into the sink failed with `AudioQueueStart -66681`;
///   * quitting the app hung **forever** in `TapCapture.stop()` →
///     `AudioDeviceDestroyIOProcID` → `HALC_ProxyIOContext::
///     _TellServerAboutStreamUsage` — an IPC to `coreaudiod` that never came
///     back;
///   * afterwards **every** userland virtual device on the machine (BlackHole,
///     Zoom, Teams) delivered zero IO callbacks until `sudo killall
///     coreaudiod`. Built-in speakers kept working throughout.
///
/// Isolation runs that did NOT reproduce it: re-rating BlackHole on its own;
/// tapping BlackHole with the probe doing the sink takeover; and the whole app
/// with MacBook Pro speakers as the output (start in <1 s, tap delivering,
/// volume law correct). The one ingredient the failing run adds is *rendering
/// into a second userland plug-in device while tapping a first one*, which
/// deadlocks the shared plug-in host they both live in.
///
/// We cannot fix `coreaudiod`. What we can do is never build that
/// configuration: a virtual device is not a speaker, so refusing it as a sink
/// output costs the user nothing real.
///
/// # Scope
///
/// This is a rule for the **sink path only**. The other paths do not tap a
/// plug-in device, have never shown the deadlock, and their existing filters
/// (`AppModel.isUserSelectableOutput`, `Router.reconcileLocalDriver`) already
/// drop BlackHole and every SyncCast-owned device by UID. Widening the rule to
/// them would remove destinations that work today.
public enum VirtualOutputPolicy {
    /// Pure classification of a `kAudioDevicePropertyTransportType` value.
    ///
    /// Only `kAudioDeviceTransportTypeVirtual` counts. Aggregates
    /// (`kAudioDeviceTransportTypeAggregate`) are deliberately NOT included:
    /// an aggregate is a kernel-side composition of real endpoints, it is not
    /// hosted by the plug-in that deadlocked, and Direct Stereo's own
    /// fan-out target is one.
    public static func isVirtualTransport(_ transportType: UInt32) -> Bool {
        transportType == kAudioDeviceTransportTypeVirtual
    }

    /// Does the device with this UID report the virtual transport?
    ///
    /// A UID we cannot resolve, or a device with no readable transport type,
    /// answers `false`: this gate exists to remove a known-bad configuration,
    /// not to reject everything it cannot classify. The `Router` guard is what
    /// makes a slip-through loud rather than silent.
    ///
    /// Cached because `AppModel.isUserSelectableOutput` runs inside SwiftUI
    /// body evaluation, and because a device's transport type is a fixed
    /// property of the driver that publishes it — it does not change while the
    /// device exists.
    public static func isVirtualOutput(uid: String) -> Bool {
        if let cached = cacheLock.withLock({ cache[uid] }) { return cached }
        let verdict = probeVirtualOutput(uid: uid)
        cacheLock.withLock { cache[uid] = verdict }
        return verdict
    }

    /// Drop the memoised verdicts. For tests and for anything that has just
    /// restarted `coreaudiod` (a driver install), after which a UID can be
    /// served by a different device.
    public static func resetCache() {
        cacheLock.withLock { cache.removeAll() }
    }

    /// The error text for a virtual device that reached the sink path anyway.
    /// Names the device, because "the sink path failed" with no name is what
    /// made the 108 s stall take a second run to understand.
    public static func rejectionMessage(names: [String]) -> String {
        let listed = names.joined(separator: ", ")
        return """
            refusing to run the system-volume Stereo path into virtual audio \
            device(s): \(listed). Rendering into a userland audio plug-in while \
            tapping another one wedges coreaudiod on this machine (measured \
            2026-09-05: 108 s start, a teardown that never returns, and every \
            virtual device dead until `sudo killall coreaudiod`). Pick a real \
            output device, or use SYNCAST_STEREO_PATH=direct.
            """
    }

    // MARK: - Implementation

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Bool] = [:]

    private static func probeVirtualOutput(uid: String) -> Bool {
        guard let id = try? DirectStereoOutput.deviceID(forUID: uid),
              let transport = DirectStereoOutput.readUInt32(
                  id, kAudioDevicePropertyTransportType
              )
        else {
            return false
        }
        return isVirtualTransport(transport)
    }
}
