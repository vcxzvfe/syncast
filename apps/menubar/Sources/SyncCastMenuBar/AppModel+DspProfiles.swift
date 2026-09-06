import Foundation
import SyncCastRouter

/// Saving and recalling whole DSP configurations. State lives in
/// `AppModel.dspProfiles`; this file is the behaviour.
extension AppModel {

    /// The saved profile the live settings currently equal, if any. Computed,
    /// not remembered: the moment the user nudges one slider the live state no
    /// longer IS that profile, and a badge that said otherwise would lie.
    var activeDspProfileID: String? {
        dspProfiles.first {
            $0.matches(equalizers: deviceEqualizers,
                       stereoImages: deviceStereoImages,
                       channelMatrices: deviceChannelMatrices,
                       delayTrims: localDelayTrims)
        }?.id
    }

    var canSaveMoreDspProfiles: Bool { dspProfiles.count < DspProfileStore.maximumCount }

    /// Snapshot everything as it is now.
    @discardableResult
    func saveCurrentDspProfile(named name: String? = nil) -> DspProfile? {
        reloadDspProfilesFromStore()
        guard canSaveMoreDspProfiles else { return nil }
        let profile = DspProfile(
            name: name ?? DspProfileStore.defaultName(existing: dspProfiles),
            equalizers: Array(deviceEqualizers.values),
            stereoImages: Array(deviceStereoImages.values),
            channelMatrices: Array(deviceChannelMatrices.values),
            delayTrims: Array(localDelayTrims.values)
        )
        dspProfiles.append(profile)
        DspProfileStore.save(dspProfiles)
        SyncCastLog.log("dspProfiles: saved \"\(profile.name)\" (\(profile.equalizers.count) EQ, "
                        + "\(profile.channelMatrices.count) matrix, \(profile.stereoImages.count) image, "
                        + "\(profile.delayTrims.count) trim)")
        return profile
    }

    /// Replace every live setting with the profile's and push all four maps.
    ///
    /// Whole maps, on purpose: a device the profile does not mention goes back
    /// to flat / neutral / stereo / 0, because "this profile" means "this and
    /// nothing else" — otherwise two profiles could only ever be compared if
    /// they touched the same devices.
    func applyDspProfile(_ profile: DspProfile) {
        deviceEqualizers = DspProfile.keyed(profile.equalizers)
        deviceStereoImages = DspProfile.keyed(profile.stereoImages)
        deviceChannelMatrices = DspProfile.keyed(profile.channelMatrices)
        localDelayTrims = DspProfile.keyed(profile.delayTrims)
        DeviceEqualizerStore.save(deviceEqualizers)
        DeviceStereoImageStore.save(deviceStereoImages)
        DeviceChannelMatrixStore.save(deviceChannelMatrices)
        LocalDelayTrimStore.save(localDelayTrims)
        SyncCastLog.log("dspProfiles: applied \"\(profile.name)\"")
        Task { @MainActor in
            await pushDeviceEqualizers()
            await pushDeviceStereoImages()
            await pushDeviceChannelMatrices()
            await pushLocalDelayTrims()
        }
    }

    /// Re-read the saved list. Called when the section comes on screen, so a
    /// profile written to the defaults from outside the app (a snapshot taken
    /// by a script, say) shows up without a relaunch — and is not clobbered
    /// by the next save, which writes the whole list.
    func reloadDspProfilesFromStore() {
        let stored = DspProfileStore.load()
        if stored != dspProfiles { dspProfiles = stored }
    }

    func deleteDspProfile(_ profile: DspProfile) {
        reloadDspProfilesFromStore()
        dspProfiles.removeAll { $0.id == profile.id }
        DspProfileStore.save(dspProfiles)
    }
}
