import Foundation

/// When SyncCast may capture the media volume keys with its `CGEventTap`.
///
/// # Why this is a separate, pure type
///
/// The event tap is the thing every volume feature here is trying to get rid
/// of: it needs Accessibility permission, it takes the three media keys away
/// from every other app, and it breaks third-party volume HUDs while SyncCast
/// runs. It is only justified where macOS itself CANNOT do the job — i.e.
/// where the default output is a device with no `VolumeScalar` and the keys
/// would otherwise raise the "forbidden" HUD and do nothing.
///
/// That is now a three-way decision (mode × which sink × which path), and it
/// used to live inline in two computed properties on a 3000-line
/// `@MainActor` class where it could not be tested. The rules are small and
/// consequential enough to be worth pinning as a matrix.
enum SystemVolumeKeyEligibility {

    /// Legacy Direct Stereo: a public aggregate of the real speakers is the
    /// default output, and aggregates expose no volume control. Nothing else
    /// can carry the keys, so the tap stays.
    static func directStereo(
        modeIsStereo: Bool,
        pathIsDirect: Bool,
        running: Bool
    ) -> Bool {
        modeIsStereo && pathIsDirect && running
    }

    /// Whole-home.
    ///
    /// `sinkDrivesSystemVolume` is the whole rule: when the default output is
    /// SyncCast's own sink device, macOS owns the keys natively — the HUD
    /// works, LinearMouse works, Siri works — and every one of those changes
    /// reaches the master through the device's own scalar. Capturing the keys
    /// there would be strictly worse than doing nothing: it would suppress the
    /// HUD the user can see and re-implement, badly, what already works.
    ///
    /// The tap survives only on the wrapped-aggregate fallback (BlackHole
    /// installed, SyncCast's driver not), where the default output has no
    /// volume control at all.
    static func wholeHome(
        modeIsWholeHome: Bool,
        running: Bool,
        sinkDrivesSystemVolume: Bool
    ) -> Bool {
        modeIsWholeHome && running && !sinkDrivesSystemVolume
    }
}
