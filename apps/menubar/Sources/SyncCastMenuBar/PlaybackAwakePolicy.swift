import Foundation

/// Keep the rule's display awake while sound is actually coming out of it.
///
/// # Why this exists
///
/// A monitor's built-in (or attached) speakers are fed over DisplayPort or
/// HDMI. When macOS puts the display to sleep for idleness, the link drops and
/// so does the audio: music the user is listening to from the next room stops
/// mid-song because nobody touched the mouse. Video players already hold the
/// display awake while a video plays; a music player, or a video playing in a
/// background tab, does not.
///
/// # What it decides
///
/// Once a second the controller hands this policy the loudest sample that
/// reached the display in that second (already gated: nil when nothing feeds
/// the display, when the default output is muted, or when no audio was
/// delivered at all). The policy answers "hold" or "let go".
///
/// - Arming needs SUSTAINED sound: `armCount` of the last `armWindow`
///   seconds at or above `armDbfs`. A notification ding is one or two loud
///   seconds and must not buy a two-minute hold.
/// - Holding is kept alive by anything at or above the lower `sustainDbfs`
///   (hysteresis), so a quiet passage or a fade does not count as silence.
/// - Release needs `releaseAfterSeconds` with nothing at or above
///   `sustainDbfs`. Measured in wall time on a clock that keeps running while
///   the Mac sleeps, so a long sleep releases on the first quiet tick after
///   wake instead of resuming a countdown that never moved.
/// - Losing eligibility (the feature switched off, the display unplugged)
///   releases at once.
///
/// A paused player usually keeps its output stream open and renders exact
/// zeros, which is -inf dBFS: far below any threshold, so "paused" and
/// "stopped" look the same here, which is the point.
struct PlaybackAwakePolicy: Equatable, Sendable {

    struct Config: Equatable, Sendable {
        /// Level a second has to reach to count toward arming. Real music and
        /// speech peak far above this; dither and the near-silence some apps
        /// render while idle sit 30 dB or more below it.
        var armDbfs: Double = -50
        /// Level that keeps an existing hold alive. 10 dB under `armDbfs`.
        var sustainDbfs: Double = -60
        /// Arming looks at the loud ticks of the last this-many seconds of
        /// wall time (not the last N ticks: two loud ticks before a sleep and
        /// one after it are not "three of the last five seconds")...
        var armWindow: Int = 5
        /// ...and needs this many of them.
        var armCount: Int = 3
        /// Quiet time before letting go. The user tunes this per rule.
        var releaseAfterSeconds: TimeInterval = PlaybackAwakeDefaults.releaseSeconds
    }

    enum ReleaseReason: String, Equatable, Sendable {
        /// Nothing at or above `sustainDbfs` for `releaseAfterSeconds`.
        case quiet
        /// The feature was switched off or the display went away.
        case ineligible
    }

    enum Transition: Equatable, Sendable {
        case hold
        case release(ReleaseReason)
    }

    struct Tick: Equatable, Sendable {
        /// Seconds on a monotonic clock that includes sleep.
        var now: TimeInterval
        /// The feature is on and its display is present.
        var eligible: Bool
        /// Loudest sample that went out to the display this second, in dBFS,
        /// or nil when nothing audible could have (see the type comment).
        var levelDbfs: Double?
    }

    var config: Config
    private(set) var holding = false
    /// Last second that kept the hold alive; nil while not holding.
    private(set) var lastSustainAt: TimeInterval?
    /// `now` of the recent ticks that reached `armDbfs`.
    private var recentLoudAt: [TimeInterval] = []

    init(config: Config = Config()) {
        self.config = config
    }

    mutating func step(_ tick: Tick) -> Transition? {
        guard tick.eligible else {
            recentLoudAt.removeAll()
            return releaseIfHolding(.ineligible)
        }

        let level = tick.levelDbfs ?? -.infinity
        let window = TimeInterval(max(1, config.armWindow))
        recentLoudAt.removeAll { tick.now - $0 >= window }
        if level >= config.armDbfs { recentLoudAt.append(tick.now) }

        if holding {
            if level >= config.sustainDbfs {
                lastSustainAt = tick.now
                return nil
            }
            let since = tick.now - (lastSustainAt ?? tick.now)
            if since >= config.releaseAfterSeconds {
                recentLoudAt.removeAll()
                return releaseIfHolding(.quiet)
            }
            return nil
        }

        let needed = min(max(1, config.armCount), max(1, config.armWindow))
        guard recentLoudAt.count >= needed else { return nil }
        holding = true
        lastSustainAt = tick.now
        return .hold
    }

    private mutating func releaseIfHolding(_ reason: ReleaseReason) -> Transition? {
        guard holding else { return nil }
        holding = false
        lastSustainAt = nil
        return .release(reason)
    }
}

enum PlaybackAwakeDefaults {
    /// "Sound stopped for this long → let the display sleep again."
    static let releaseSeconds: TimeInterval = 120
    /// Range offered for the per-rule release delay, in seconds.
    static let releaseSecondsRange: ClosedRange<Int> = 60...1800
    /// The same range in whole minutes, for the stepper.
    static let releaseMinutesRange: ClosedRange<Int> =
        (releaseSecondsRange.lowerBound / 60)...(releaseSecondsRange.upperBound / 60)

    static func clampReleaseSeconds(_ seconds: Int) -> Int {
        min(releaseSecondsRange.upperBound, max(releaseSecondsRange.lowerBound, seconds))
    }
}

/// Who is rendering to the display right now, from CoreAudio's per-process
/// view (`kAudioProcessPropertyDevices`, which names the real sub-devices
/// behind an aggregate).
struct DisplayFeed: Equatable, Sendable {
    /// SyncCast itself renders to the display: whatever the router captured
    /// is what comes out of it.
    var bySyncCast: Bool
    /// CoreAudio process objects of every OTHER process rendering to the
    /// display (SyncCast idle with the display as the default output, Direct
    /// Stereo, an app with its own device picker), sorted. Only a tap on
    /// exactly these processes can say how loud that is.
    var otherProcesses: [UInt32]

    var byOthers: Bool { !otherProcesses.isEmpty }

    static let none = DisplayFeed(bySyncCast: false, otherProcesses: [])

    struct ProcessOutput: Equatable, Sendable {
        /// The CoreAudio process object (what a tap description takes).
        var objectID: UInt32
        var pid: Int32
        var runningOutput: Bool
        var outputDeviceUIDs: [String]
    }

    static func classify(
        _ processes: [ProcessOutput],
        ownPID: Int32,
        displayUID: String
    ) -> DisplayFeed {
        var bySyncCast = false
        var others: Set<UInt32> = []
        for process in processes where process.runningOutput
            && process.outputDeviceUIDs.contains(displayUID) {
            if process.pid == ownPID {
                bySyncCast = true
            } else {
                others.insert(process.objectID)
            }
        }
        return DisplayFeed(bySyncCast: bySyncCast, otherProcesses: others.sorted())
    }
}

enum PlaybackLevel {
    /// One measured source and whether its path to the display lets it be
    /// heard. Each source is gated by ITS OWN path: the router's by the
    /// display's routing row and the system volume the router owns, a
    /// process tap's by the display device's own controls. A muted laptop
    /// speaker says nothing about an app playing to the display by name.
    struct Source: Equatable, Sendable {
        var peak: Float
        var audible: Bool
    }

    /// Below this a device's volume scalar counts as off.
    static let mutedScalarCeiling: Float = 0.0001

    /// Whether a device's own mute / volume (nil: the device has no such
    /// control) let audio out.
    static func deviceLetsAudioOut(muted: Bool?, scalar: Float?) -> Bool {
        if muted == true { return false }
        if let scalar, scalar <= mutedScalarCeiling { return false }
        return true
    }

    /// The level the policy sees: the loudest audible source, or nil when
    /// none delivered audio or every one is silenced on its way out.
    static func effectiveDbfs(_ sources: [Source]) -> Double? {
        guard let loudest = sources.filter(\.audible).map(\.peak).max() else { return nil }
        return loudest > 0 && loudest.isFinite ? 20 * log10(Double(loudest)) : -.infinity
    }
}
