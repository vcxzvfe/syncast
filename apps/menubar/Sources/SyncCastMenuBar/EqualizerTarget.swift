import Foundation
import SyncCastRouter

/// What one equalizer editor is editing.
///
/// Two things can hold a curve, and they are not the same kind of thing:
///
///   * a physical output, keyed by CoreAudio UID — the case the feature was
///     built for, and the only one in Local Stereo;
///   * the whole-home AirPlay GROUP, keyed by a reserved pseudo-UID. OwnTone
///     sends one stream to every receiver, so "this receiver's curve" is not a
///     thing the pipeline can express; one curve for all of them is.
///
/// Both resolve to a UID, which is why they can share one store, one push, and
/// one editor view rather than growing a parallel set of each.
enum EqualizerTarget: Hashable, Sendable {
    /// A row in the device list, addressed by `Device.id` (never by UID: the
    /// row's device may disappear, and the UI binds by id everywhere else).
    case device(String)
    /// The single curve applied to every AirPlay receiver together.
    case airPlayGroup

    /// Suffix for accessibility identifiers, so a UI test can address the
    /// group's controls the same way it addresses a device's.
    var accessibilityKey: String {
        switch self {
        case .device(let deviceID): return deviceID
        case .airPlayGroup: return "airPlayGroup"
        }
    }
}
