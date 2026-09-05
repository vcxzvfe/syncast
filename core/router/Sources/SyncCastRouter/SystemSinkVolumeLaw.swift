import Foundation
import CoreAudio

/// How the sink's `kAudioDevicePropertyVolumeScalar` — which IS the macOS
/// system volume while the sink path runs — is turned into an actual level on
/// each real output.
///
/// # The measured law
///
/// A HAL volume scalar is perceptual, not linear amplitude. Measured on this
/// machine (2026-09-05, `dbprobe`):
///
/// ```
/// MacBook Pro扬声器  rangeDb=[-63.50, 0.00]
///                    scalar→dB: 0.00→-63.5  0.25→-47.6  0.50→-31.8
///                               0.75→-15.9  0.90→ -6.4  1.00→  0.0
/// BlackHole 2ch      rangeDb=[-64.00, 0.00]  (no ScalarToDecibels property)
/// ```
///
/// Apple's built-in curve is therefore **linear in decibels**:
/// `dB(s) = minDb · (1 − s)`. BlackHole's own attenuation matches it within
/// 0.5 dB (SHARED_CONTEXT's measurement — scalar 0.5 → −32 dB — is exactly
/// `−64 · 0.5`). One law covers both, and it is the law SyncCast's own driver
/// advertises, so the slider feels native wherever the master comes from.
///
/// # Why each backend gets a different quantity
///
///   * **CoreAudio hardware** (MacBook Pro speakers): write the SCALAR. The
///     target device applies its own curve, which is the same curve, so
///     copying the scalar 1:1 reproduces exactly what macOS would have done
///     natively. Converting to amplitude here and back there would double the
///     taper and make everything far too quiet — the mistake that makes
///     BlackHole's loopback sound broken.
///   * **DDC/CI display** (ExternalDisplay): VCP 0x62 is a 0…100 percent knob whose
///     internal taper belongs to the panel's firmware. Percent = scalar × 100
///     is the only mapping we can justify without measuring that firmware.
///   * **Software gain** (anything with no volume control at all): the render
///     path multiplies linear amplitude, so the scalar MUST be converted
///     through the dB law first: `a = 10^(dB(s)/20)`.
///
/// # Per-device balance
///
/// The popover's per-device slider is a *balance* on top of the master, and it
/// composes in the dB domain: `dB_effective = dB(master) + dB(balance)`. At
/// balance = 1.0 that is exactly `dB(master)`, so the hardware path stays
/// bit-for-bit "copy the scalar" and the common case is untouched.
public enum SystemSinkVolumeLaw {

    /// The scalar↔decibel mapping of a volume control. `minDb` is the
    /// attenuation at scalar 0; the curve is linear in dB from there to 0 dB
    /// at scalar 1.
    public struct ScalarDecibelLaw: Equatable, Sendable {
        public let minDb: Float

        public init(minDb: Float) {
            // A positive or zero minDb would make the law degenerate
            // (division by zero in `scalar(forDecibels:)`), so clamp to a
            // sane attenuating range rather than trusting a driver's claim.
            self.minDb = min(-1, minDb)
        }

        public func decibels(forScalar scalar: Float) -> Float {
            let s = max(0, min(1, scalar))
            return minDb * (1 - s)
        }

        public func scalar(forDecibels db: Float) -> Float {
            let s = 1 + db / (-minDb)
            return max(0, min(1, s))
        }

        public func amplitude(forScalar scalar: Float) -> Float {
            let s = max(0, min(1, scalar))
            // Scalar 0 is silence, not −63.5 dB. macOS's own slider at the
            // bottom is silent (the built-in driver mutes there), and a system
            // volume of zero that is still faintly audible reads as a bug.
            guard s > 0 else { return 0 }
            return pow(10, decibels(forScalar: s) / 20)
        }
    }

    /// Apple's measured built-in-speaker range (2026-09-05). Used when a sink
    /// exposes no dB metadata of its own, and advertised by SyncCast's driver.
    public static let appleBuiltInLaw = ScalarDecibelLaw(minDb: -63.5)

    /// Which mechanism carries the level on one output device.
    public enum Backend: String, Equatable, Sendable, CaseIterable {
        /// Device exposes a writable `kAudioDevicePropertyVolumeScalar`.
        case coreAudioHardware
        /// No CoreAudio volume, but the display answers DDC/CI VCP 0x62.
        case ddc
        /// Nothing controllable — attenuate the samples we render instead.
        case softwareGain
    }

    /// What to write, per backend, for one device.
    ///
    /// Exactly one of the three payloads is non-nil, matching `backend`. The
    /// mute flag rides along with all of them because every backend has some
    /// way to be silent (hardware mute, VCP 0x8D, or amplitude 0).
    public struct Plan: Equatable, Sendable {
        public let backend: Backend
        /// `.coreAudioHardware`: the scalar to write.
        public let hardwareScalar: Float?
        /// `.ddc`: the 0…100 percent to enqueue on VCP 0x62.
        public let ddcPercent: Int?
        /// `.softwareGain`: the linear amplitude for the render path.
        public let softwareAmplitude: Float?
        public let muted: Bool

        public init(
            backend: Backend,
            hardwareScalar: Float? = nil,
            ddcPercent: Int? = nil,
            softwareAmplitude: Float? = nil,
            muted: Bool
        ) {
            self.backend = backend
            self.hardwareScalar = hardwareScalar
            self.ddcPercent = ddcPercent
            self.softwareAmplitude = softwareAmplitude
            self.muted = muted
        }
    }

    /// Balance value that means "no offset from the master".
    public static let unityBalance: Float = 1.0

    /// Compose master and balance into the scalar this device should behave as
    /// if it were set to.
    ///
    /// dB-domain composition, so a balance of 1.0 returns the master scalar
    /// unchanged (bit-identical, no rounding drift) and lower balances are the
    /// same perceptual steps the system slider uses.
    public static func effectiveScalar(
        masterScalar: Float,
        balance: Float,
        law: ScalarDecibelLaw = appleBuiltInLaw
    ) -> Float {
        let master = max(0, min(1, masterScalar))
        let bal = max(0, min(1, balance))
        if bal >= unityBalance { return master }
        if master <= 0 || bal <= 0 { return 0 }
        let db = law.decibels(forScalar: master) + law.decibels(forScalar: bal)
        return law.scalar(forDecibels: db)
    }

    /// The full per-device decision.
    ///
    /// `muted` is the OR of the system mute and the device's own mute toggle:
    /// muting the system must silence every output, and a per-device mute must
    /// survive the master moving.
    public static func plan(
        masterScalar: Float,
        masterMuted: Bool,
        balance: Float,
        deviceMuted: Bool,
        backend: Backend,
        law: ScalarDecibelLaw = appleBuiltInLaw
    ) -> Plan {
        let muted = masterMuted || deviceMuted
        let scalar = effectiveScalar(
            masterScalar: masterScalar, balance: balance, law: law
        )
        switch backend {
        case .coreAudioHardware:
            // The scalar carries the level even while muted: the device's own
            // Mute property does the silencing, and parking the scalar at 0
            // destroys the level that unmute has to restore (the Codex P1
            // lesson from the Direct Stereo path). Devices whose mute write
            // fails degrade to scalar 0 — that decision belongs to the
            // applier, which is the only place that learns the write failed.
            return Plan(
                backend: backend, hardwareScalar: scalar, muted: muted
            )
        case .ddc:
            return Plan(
                backend: backend,
                ddcPercent: Int((scalar * 100).rounded()),
                muted: muted
            )
        case .softwareGain:
            return Plan(
                backend: backend,
                softwareAmplitude: muted ? 0 : law.amplitude(forScalar: scalar),
                muted: muted
            )
        }
    }

    // MARK: - Whole-home master

    /// The whole-home MASTER amplitude for a sink scalar.
    ///
    /// Whole-home's master is a multiply on the samples entering OwnTone
    /// (`AudioSocketWriter.setMasterGain`), so it can attenuate by any amount
    /// the sink's own law asks for — which is why the scalar is converted
    /// through THAT law, not through `VolumeCurve`.
    ///
    /// `VolumeCurve`'s −30 dB floor is not a bug to work around here: it
    /// exists because OwnTone's PER-OUTPUT volume cannot go below −30 dB, so
    /// the two legs have to agree on that floor to stay matched. The master
    /// stage sits upstream of OwnTone entirely and has no such floor. Pushing
    /// the system volume through the −30 dB curve would compress macOS's
    /// ~64 dB of travel into 30 dB — the bottom half of the system slider
    /// would barely change anything, and its zero would still be audible.
    ///
    /// Two endpoints are exact by construction:
    ///   * `muted` → `0`. Muting the system must be silence everywhere,
    ///     including on AirPlay receivers whose own volume floors at −30 dB.
    ///   * `scalar == 0` → `0` (via `amplitude(forScalar:)`), for the same
    ///     reason macOS's own slider is silent at the bottom.
    public static func wholeHomeMasterAmplitude(
        scalar: Float,
        muted: Bool,
        law: ScalarDecibelLaw = appleBuiltInLaw
    ) -> Float {
        guard !muted else { return 0 }
        return law.amplitude(forScalar: scalar)
    }

    // MARK: - Reading a device's own law

    /// Read a device's real scalar↔dB mapping, falling back to Apple's
    /// measured built-in curve.
    ///
    /// Order matters. `kAudioDevicePropertyVolumeScalarToDecibels` is the
    /// authoritative transfer function when the driver implements it (the
    /// built-in speakers do). `kAudioDevicePropertyVolumeRangeDecibels` only
    /// gives the endpoints, which pins the dB-linear law we measured — that is
    /// how BlackHole (range [-64, 0], no transfer property) is handled. A
    /// device with neither gets the Apple default, which is within 0.5 dB of
    /// every control measured on this machine.
    public static func law(forDeviceUID uid: String) -> ScalarDecibelLaw {
        guard let id = try? Capture.deviceID(forUID: uid) else {
            return appleBuiltInLaw
        }
        if let db = scalarToDecibels(id, scalar: 0), db < 0 {
            return ScalarDecibelLaw(minDb: db)
        }
        if let range = volumeRangeDecibels(id), range.mMinimum < 0 {
            return ScalarDecibelLaw(minDb: Float(range.mMinimum))
        }
        return appleBuiltInLaw
    }

    private static func scalarToDecibels(
        _ id: AudioObjectID,
        scalar: Float
    ) -> Float? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalarToDecibels,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var value = scalar
        var size = UInt32(MemoryLayout<Float>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr
        else {
            return nil
        }
        return value
    }

    private static func volumeRangeDecibels(
        _ id: AudioObjectID
    ) -> AudioValueRange? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeRangeDecibels,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var range = AudioValueRange()
        var size = UInt32(MemoryLayout<AudioValueRange>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &range) == noErr
        else {
            return nil
        }
        return range
    }
}
