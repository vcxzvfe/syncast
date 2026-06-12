import CoreAudio

/// What `HardwareVolumeObserver.setWatchedDevices` must do with one
/// already-watched UID on a refresh pass.
enum HardwareVolumeRewatchAction: Equatable {
    /// HAL AudioDeviceID and SyncCast device id both unchanged — keep the
    /// installed listeners untouched (no re-registration churn).
    case keep
    /// Same HAL device, NEW SyncCast device id: discovery republished the
    /// UID mid-run (routing migration keeps playback). The HAL listeners
    /// stay valid, but the entry must report the new id — AppModel looks
    /// up `routing[deviceID]` and silently drops external volume/mute
    /// changes attributed to the dead id.
    case retarget
    /// The HAL AudioDeviceID moved (display sleep/wake reissues a fresh
    /// id for the same UID) or no longer resolves. Listeners registered
    /// on the dead id never fire again — tear down and re-register.
    case rebuild
}

/// Pure rebinding decision, kept free of CoreAudio listener plumbing so
/// the same-UID/new-deviceID and sleep-wake cases are unit checkable.
enum HardwareVolumeRewatchLogic {
    static func action(
        watchedDeviceID: String,
        watchedAudioDeviceID: AudioDeviceID,
        wantedDeviceID: String,
        resolvedAudioDeviceID: AudioDeviceID?
    ) -> HardwareVolumeRewatchAction {
        if resolvedAudioDeviceID != watchedAudioDeviceID {
            return .rebuild
        }
        if wantedDeviceID != watchedDeviceID {
            return .retarget
        }
        return .keep
    }
}
