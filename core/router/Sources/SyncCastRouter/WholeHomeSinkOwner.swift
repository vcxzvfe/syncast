import Foundation

/// Who owns the macOS default output while whole-home mode runs.
///
/// # Why there are two answers
///
/// Whole-home needs the default output to be a SILENT device: system audio is
/// captured by ScreenCaptureKit and re-emitted by OwnTone, so a real speaker
/// as the default would play every track twice at two different latencies.
///
/// The original implementation always wrapped that silent device in a public
/// aggregate (`WholeHomeSinkOutput`, shown as 「AirPlay 全屋」). The wrapper
/// existed for ONE reason: BlackHole cannot be renamed in place, so the Sound
/// menu would otherwise read "BlackHole 2ch" and look like a misconfiguration.
///
/// That reason disappears when SyncCast's own driver is installed: the device
/// is already called "SyncCast". And the wrapper has a real cost — an
/// aggregate exposes no `kAudioDevicePropertyVolumeScalar`, so while it is the
/// default output the macOS volume slider is greyed, F11/F12 raise the
/// "forbidden" HUD, and SyncCast has to intercept the media keys with a
/// `CGEventTap` to give the user any volume control at all.
///
/// So:
///
/// | installed sink        | owner     | system volume                      |
/// |-----------------------|-----------|------------------------------------|
/// | SyncCast's own driver | `.direct` | native — the device's own scalar   |
/// | BlackHole only        | `.wrapped`| panel fader + media-key event tap  |
///
/// `.direct` reuses `SystemSinkDevice` — the same type the stereo sink path
/// uses — so takeover, restore, the ownership claim and the stale-default
/// sweep have exactly one implementation rather than two that can drift.
///
/// # What `.direct` deliberately does NOT do
///
/// It does not pin the device to 48 kHz. Whole-home's capture is
/// ScreenCaptureKit, which taps system audio above the HAL and never opens the
/// sink; the sink's nominal rate is simply not in the signal path. Pinning it
/// would re-rate a device system-wide for every other app using it, for no
/// gain. (The stereo sink path DOES pin it, because its Process Tap reads the
/// device itself and refuses a non-48 kHz format.) See
/// `SystemSinkDevice.start(seedVolume:pinSampleRate:)`.
public enum WholeHomeSinkSelection: Equatable, Sendable {
    /// Make the sink device itself the default output — it carries a real
    /// volume control, so macOS's own volume UI works.
    case direct(SystemSinkDevice.Candidate)
    /// Wrap the silent device in the named public aggregate. The fallback for
    /// a machine that only has BlackHole.
    case wrapped

    /// Which owner to build.
    ///
    /// Pure, and deliberately conservative in both directions:
    ///
    ///   * only SyncCast's OWN driver qualifies for `.direct`. BlackHole would
    ///     technically work as a default output too — it has a volume control
    ///     — but it would show up in the Sound menu as "BlackHole 2ch", which
    ///     is the naming problem the wrapper was built to solve;
    ///   * the driver must actually expose a volume control. A driver build
    ///     that lost it would hand the user a greyed slider AND no event tap,
    ///     i.e. no volume control at all — strictly worse than the wrapper.
    public static func choose(
        resolved: SystemSinkDevice.Candidate?,
        exposesVolumeControl: (String) -> Bool
    ) -> WholeHomeSinkSelection {
        guard let resolved,
              resolved.uid == SystemSinkDevice.syncCastDriverUID,
              exposesVolumeControl(resolved.uid)
        else {
            return .wrapped
        }
        return .direct(resolved)
    }

    /// True when the default output's own `VolumeScalar` IS the whole-home
    /// master. The single fact the rest of the app keys on: the popover
    /// mirrors that scalar instead of its own percent fader, and the media-key
    /// event tap stands down because macOS handles the keys itself.
    public var drivesSystemVolume: Bool {
        if case .direct = self { return true }
        return false
    }

    /// For logs and the diagnostic string.
    public var label: String {
        switch self {
        case .direct(let candidate): return "direct(\(candidate.uid))"
        case .wrapped: return "wrapped(\(WholeHomeSinkOutput.displayName))"
        }
    }
}

/// One handle over whichever default-output owner whole-home picked.
///
/// Exists so the Router has a single `wholeHomeSink` to start, stop, poll for
/// displacement and print in the diagnostic, instead of two optionals and a
/// branch at every call site.
public final class WholeHomeSinkOwner {
    private enum Backing {
        case direct(SystemSinkDevice)
        case wrapped(WholeHomeSinkOutput)
    }

    private let backing: Backing
    public let selection: WholeHomeSinkSelection

    public init(selection: WholeHomeSinkSelection) {
        self.selection = selection
        switch selection {
        case .direct(let candidate):
            backing = .direct(SystemSinkDevice(candidate: candidate))
        case .wrapped:
            backing = .wrapped(WholeHomeSinkOutput())
        }
    }

    /// Whether the system volume drives the whole-home master on this owner.
    public var drivesSystemVolume: Bool { selection.drivesSystemVolume }

    public var isActive: Bool {
        switch backing {
        case .direct(let device): return device.isActive
        case .wrapped(let aggregate): return aggregate.isActive
        }
    }

    /// What the Sound menu shows while this owner holds the default output.
    public var displayName: String {
        switch backing {
        case .direct(let device): return device.displayName
        case .wrapped: return WholeHomeSinkOutput.displayName
        }
    }

    /// The CoreAudio UID whose volume scalar is the master, or nil when this
    /// owner has no watchable volume control (the aggregate wrapper).
    public var systemVolumeUID: String? {
        switch backing {
        case .direct(let device): return device.sinkUID
        case .wrapped: return nil
        }
    }

    /// False while active means macOS is rendering somewhere else — the
    /// double-playback condition. Polled, never observed; see
    /// `WholeHomeSinkOutput.isSystemDefaultOutput`.
    public var isSystemDefaultOutput: Bool {
        switch backing {
        case .direct(let device): return device.isSystemDefaultOutput
        case .wrapped(let aggregate): return aggregate.isSystemDefaultOutput
        }
    }

    public var lastStopStatusText: String? {
        switch backing {
        case .direct(let device): return device.lastStopStatusText
        case .wrapped(let aggregate): return aggregate.lastStopStatusText
        }
    }

    public var diagnostic: String {
        switch backing {
        case .direct(let device): return "wholeHomeSink=\(selection.label) \(device.diagnostic)"
        case .wrapped(let aggregate): return aggregate.diagnostic
        }
    }

    /// Install this owner as the macOS default output.
    ///
    /// `seedVolume` is only meaningful on the `.direct` path, where the
    /// device's own scalar becomes the system volume the instant macOS starts
    /// rendering into it: it must ADOPT the level the outgoing default output
    /// was at, or someone listening quietly on headphones gets full scale.
    /// Same CRITICAL lesson, same implementation, as the stereo sink path —
    /// and the seed is written AFTER the takeover, because macOS re-applies
    /// its own remembered level for a device at the moment that device becomes
    /// the default. The wrapper has no volume control to seed.
    public func start(seedVolume: Float?) throws {
        switch backing {
        case .direct(let device):
            // No sample-rate pin: SCK never opens this device (see the type
            // documentation).
            try device.start(seedVolume: seedVolume, pinSampleRate: false)
        case .wrapped(let aggregate):
            try aggregate.start()
        }
    }

    /// Give the user's default output back. False means it could NOT be
    /// restored, which the Router turns into a thrown error so app termination
    /// is blocked rather than leaving macOS pointed at a silent device.
    @discardableResult
    public func stop() -> Bool {
        switch backing {
        case .direct(let device): return device.stop()
        case .wrapped(let aggregate): return aggregate.stop()
        }
    }

    /// The device's current volume scalar / mute — the system volume — or
    /// `(nil, nil)` when this owner has none.
    public func readMaster() -> (volume: Float?, muted: Bool?) {
        switch backing {
        case .direct(let device): return device.readMaster()
        case .wrapped: return (nil, nil)
        }
    }
}
