import Foundation
import SyncCastRouter

/// The AirPlay **group** tone curve, and the target-keyed façade the editor
/// uses so one view can serve both a speaker and the group.
///
/// # Why a group curve and not per-receiver ones
///
/// In whole-home mode the sidecar hands OwnTone ONE stream and OwnTone fans it
/// out to every receiver. Nothing downstream of that split is ours to touch —
/// the receiver is another vendor's device on the other end of a network — so
/// "this receiver's bass, that receiver's treble" is not a setting this
/// architecture can honour, at any amount of UI work. What it can do is shape
/// the single stream before the fan-out, which is what this is: one curve,
/// every receiver, applied in `AudioSocketWriter` upstream of the master
/// fader.
///
/// The local speakers are unaffected by it. They each render their own copy of
/// the broadcast through their own `LocalAirPlayBridge`, so they keep their own
/// per-device curves in this mode — see `AppModel+Equalizer`.
///
/// # Why it lives in the device store
///
/// Under a reserved pseudo-UID (`Router.airPlayGroupEqualizerUID`), in the same
/// `syncast.deviceEqualizer.v1` record and the same UID → curve map that is
/// pushed to the Router. One store means the group curve is remembered,
/// re-applied on reconnect, and normalised on load exactly like a device's,
/// with no second persistence path to keep in step. The key is namespaced, so
/// it cannot collide with a real CoreAudio UID.
@MainActor
extension AppModel {

    /// Reserved key for the group curve. Owned by the Router, mirrored here so
    /// the UI never spells it out a second time.
    static var airPlayGroupEqualizerUID: String { Router.airPlayGroupEqualizerUID }

    /// Label shown wherever the group curve is named.
    static let airPlayGroupEqualizerName = "AirPlay 组"

    // MARK: - Target → UID

    /// The store key behind an editor target, or nil when the target cannot
    /// hold a curve (an AirPlay receiver row, or a device discovery has
    /// already dropped).
    func equalizerUID(for target: EqualizerTarget) -> String? {
        switch target {
        case .device(let deviceID): return coreAudioUID(forDeviceID: deviceID)
        case .airPlayGroup: return AppModel.airPlayGroupEqualizerUID
        }
    }

    // MARK: - Availability

    /// Whether the AirPlay group row should be offered.
    ///
    /// Whole-home only: in Local Stereo the receivers are not part of the
    /// output at all, so the control would shape nothing. Rendering nothing
    /// (rather than a disabled control) follows the same rule as the
    /// whole-home delay trim.
    var airPlayGroupEqualizerIsAvailable: Bool {
        mode == .wholeHome && !remoteAirPlayDevices.isEmpty
    }

    /// The one-line explanation that always sits with the group control, so
    /// nobody has to discover by experiment that it is not per-receiver.
    static let airPlayGroupEqualizerHint =
        "一条曲线同时作用于所有 AirPlay 接收端（OwnTone 只发一路流）"
            + " · one curve for every AirPlay receiver together"

    /// Whether the group's chain is currently hitting the limiter.
    var airPlayGroupEqualizerIsClipping: Bool {
        (equalizerClipCounts[AppModel.airPlayGroupEqualizerUID] ?? 0) > 0
    }

    // MARK: - Target-keyed façade
    //
    // Thin wrappers so `EqualizerEditor` can be written once. A device target
    // goes through the row-keyed path (which resolves the UID and caches the
    // display name); the group goes straight to the UID-keyed core.

    func equalizerIsAvailable(target: EqualizerTarget) -> Bool {
        switch target {
        case .device(let deviceID): return equalizerIsAvailable(for: deviceID)
        case .airPlayGroup: return airPlayGroupEqualizerIsAvailable
        }
    }

    func hasEqualizerCurve(target: EqualizerTarget) -> Bool {
        guard let uid = equalizerUID(for: target) else { return false }
        return deviceEqualizers[uid]?.settings.hasUserCurve ?? false
    }

    func equalizerSummary(target: EqualizerTarget) -> String? {
        guard hasEqualizerCurve(target: target) else { return nil }
        return AppModel.equalizerSummary(of: equalizerSettings(target: target))
    }

    func equalizerIsBypassed(target: EqualizerTarget) -> Bool {
        equalizerSettings(target: target).bypassed
    }

    func equalizerIsClipping(target: EqualizerTarget) -> Bool {
        guard let uid = equalizerUID(for: target) else { return false }
        return (equalizerClipCounts[uid] ?? 0) > 0
    }

    func setEqualizerBandGain(_ db: Double, bandIndex: Int, target: EqualizerTarget) {
        switch target {
        case .device(let deviceID):
            setEqualizerBandGain(db, bandIndex: bandIndex, for: deviceID)
        case .airPlayGroup:
            updateGroupEqualizer { settings in
                guard settings.bands.indices.contains(bandIndex) else { return }
                settings.bands[bandIndex].gainDb =
                    EqualizerLimits.snapToStep(EqualizerLimits.clampBandGainDb(db))
            }
        }
    }

    func setEqualizerTrim(_ db: Double, target: EqualizerTarget) {
        switch target {
        case .device(let deviceID):
            setEqualizerTrim(db, for: deviceID)
        case .airPlayGroup:
            updateGroupEqualizer { settings in
                settings.trimDb =
                    EqualizerLimits.snapToStep(EqualizerLimits.clampTrimDb(db))
            }
        }
    }

    func setEqualizerBypassed(_ bypassed: Bool, target: EqualizerTarget) {
        switch target {
        case .device(let deviceID):
            setEqualizerBypassed(bypassed, for: deviceID)
        case .airPlayGroup:
            updateGroupEqualizer { $0.bypassed = bypassed }
        }
    }

    func resetEqualizer(target: EqualizerTarget) {
        switch target {
        case .device(let deviceID):
            resetEqualizer(for: deviceID)
        case .airPlayGroup:
            updateGroupEqualizer { $0 = .graphicFlat }
        }
    }

    /// Every group edit goes through here, so the display name stored beside
    /// the curve is one string in one place.
    private func updateGroupEqualizer(_ transform: (inout EqualizerSettings) -> Void) {
        updateEqualizer(
            uid: AppModel.airPlayGroupEqualizerUID,
            displayName: AppModel.airPlayGroupEqualizerName,
            transform
        )
    }
}
