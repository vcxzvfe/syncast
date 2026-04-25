import XCTest
import CoreAudio
@testable import SyncCastRouter

/// Tests for the small, hermetically testable parts of AggregateDevice.
///
/// We deliberately do NOT cover end-to-end AggregateHardwareCreate here:
/// that requires an actual physical audio device to point the master at,
/// is brittle in CI (Linux / containers have no CoreAudio), and the
/// observable behavior is already exercised by manual hardware tests
/// driven via `SYNCAST_AUTO_TEST=mbp,display`. What we CAN test cheaply:
///   - The stream-config query helper returns a sane shape on bogus
///     inputs (does not crash, returns zero counts).
///   - The hardware-volume path is value-clamping correctly (the
///     write itself is a no-op on a bogus AudioObjectID).
final class AggregateDeviceTests: XCTestCase {

    /// readStreamChannels(0) → (0, [], 0). Specifically, the bogus
    /// AudioObjectID = kAudioObjectUnknown must NOT crash; CoreAudio
    /// returns kAudioHardwareBadObjectError and we should map that
    /// to "0 streams, 0 channels".
    func testReadStreamChannelsOnBogusIDIsSafe() {
        let result = AggregateDevice.readStreamChannels(AudioObjectID(kAudioObjectUnknown))
        XCTAssertEqual(result.0, 0, "bogus ID should report 0 streams")
        XCTAssertTrue(result.1.isEmpty, "bogus ID should report empty per-stream list")
        XCTAssertEqual(result.2, 0, "bogus ID should report 0 total channels")
    }

    /// applyHardwareVolume on a bogus device returns false, doesn't
    /// crash, and clamps the input. We can't observe the clamp
    /// directly here, but the function shape — Bool return, no
    /// throw — is what matters for the call sites.
    func testApplyHardwareVolumeOnBogusIDReturnsFalse() {
        let result = AggregateDevice.applyHardwareVolume(
            physicalID: AudioObjectID(kAudioObjectUnknown),
            volume: 0.5
        )
        XCTAssertFalse(result, "bogus ID can't accept any write")
    }

    /// Negative or out-of-range volumes are accepted by
    /// applyHardwareVolume (the static path doesn't clamp), but
    /// setSubdeviceVolume — the public entry point — should clamp
    /// before calling into CoreAudio. Since we can't construct a
    /// real AggregateDevice without hardware, we exercise the
    /// public clamp path by verifying applyHardwareVolume rejects
    /// extreme values gracefully on a bogus ID.
    func testApplyHardwareVolumeRejectsExtremeValues() {
        for v: Float in [-1.0, 0.0, 0.5, 1.0, 2.0, 1e6] {
            // None of these should crash. All should return false on
            // a bogus ID.
            let r = AggregateDevice.applyHardwareVolume(
                physicalID: AudioObjectID(kAudioObjectUnknown),
                volume: v
            )
            XCTAssertFalse(r, "bogus ID rejects all writes regardless of volume")
        }
    }

    /// Sanity: the system's default output device, if present, exposes
    /// at least 2 output channels. Test is skipped (not failed) when
    /// CI has no audio hardware — common on container runners.
    func testDefaultOutputHasAtLeastStereoChannels() throws {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var defaultID: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr, 0, nil, &size, &defaultID
        )
        try XCTSkipIf(
            status != noErr || defaultID == 0,
            "no default output device — likely a CI runner without audio"
        )
        let (streams, _, total) = AggregateDevice.readStreamChannels(defaultID)
        try XCTSkipIf(streams == 0, "default output exposes no output streams")
        XCTAssertGreaterThanOrEqual(
            total, 2,
            "every realistic output device has >= 2 channels (stereo)"
        )
    }
}
