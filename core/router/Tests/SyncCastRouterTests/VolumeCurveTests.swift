import XCTest
@testable import SyncCastRouter

/// Specification for the one volume law both output legs obey.
///
/// The whole point of `VolumeCurve` is that the local leg's linear multiplier
/// and OwnTone's per-output volume land on the SAME attenuation for the same
/// slider position. That equality is an external contract with OwnTone's
/// source, so these tests restate OwnTone's formula independently rather than
/// calling back into the implementation: if someone re-derives the curve, or
/// writes `max_volume` into `owntone.conf.template` and changes the slope,
/// these go red instead of the two legs silently drifting apart again.
///
/// Reference: `build/owntone-server/src/outputs/airplay.c:1805-1821`
///   airplay_volume = -30.0 + (max_volume · volume · 30.0)
///                            / (100.0 · AIRPLAY_CONFIG_MAX_VOLUME)
/// with AIRPLAY_CONFIG_MAX_VOLUME = 11 (airplay.c:116) and max_volume
/// defaulting to the same 11 (airplay.c:1786-1801), i.e. dB = -30 + 0.3·p.
final class VolumeCurveTests: XCTestCase {

    /// OwnTone's formula, transcribed from C with the constants spelled out.
    private func ownToneDecibels(percent: Int) -> Float {
        let maxVolume = Float(VolumeCurve.ownToneMaxVolumeReference)
        let configMax = Float(VolumeCurve.ownToneMaxVolumeReference)
        return -30.0 + (maxVolume * Float(percent) * 30.0) / (100.0 * configMax)
    }

    // MARK: - Agreement with OwnTone

    func test_decibels_match_owntone_formula_at_every_percent() {
        for p in 0...100 {
            XCTAssertEqual(
                VolumeCurve.decibels(forPercent: p),
                ownToneDecibels(percent: p),
                accuracy: 0.001,
                "dB mismatch at \(p)%"
            )
        }
    }

    /// The invariant the feature exists for: converting the local leg's linear
    /// amplitude back to dB must reproduce what the AirPlay receiver is told.
    func test_local_amplitude_reproduces_airplay_decibels_at_every_percent() {
        for p in 0...100 {
            let amplitude = VolumeCurve.amplitude(forPercent: p)
            let asDecibels = 20 * log10(amplitude)
            XCTAssertEqual(
                asDecibels,
                ownToneDecibels(percent: p),
                accuracy: 0.001,
                "leg mismatch at \(p)%"
            )
        }
    }

    // MARK: - Endpoints

    func test_full_scale_is_bit_transparent() {
        XCTAssertEqual(VolumeCurve.amplitude(forPercent: 100), 1.0, accuracy: 1e-6)
        XCTAssertEqual(VolumeCurve.decibels(forPercent: 100), 0.0, accuracy: 1e-6)
    }

    /// Zero percent is OwnTone's -30 dB floor, NOT silence. Pinned because the
    /// obvious "0 means off" assumption is exactly what made the legs diverge
    /// at the bottom of the slider.
    func test_zero_percent_is_the_minus_30_db_floor_not_silence() {
        XCTAssertEqual(VolumeCurve.decibels(forPercent: 0), -30.0, accuracy: 1e-6)
        XCTAssertEqual(
            VolumeCurve.amplitude(forPercent: 0),
            pow(10, -1.5),          // ≈ 0.0316
            accuracy: 1e-6
        )
        XCTAssertGreaterThan(VolumeCurve.amplitude(forPercent: 0), 0)
    }

    func test_curve_is_strictly_increasing() {
        for p in 1...100 {
            XCTAssertGreaterThan(
                VolumeCurve.amplitude(forPercent: p),
                VolumeCurve.amplitude(forPercent: p - 1),
                "not monotonic at \(p)%"
            )
        }
    }

    /// A halving of amplitude is 6.02 dB, i.e. ~20 percentage points on this
    /// scale. Sanity-checks the slope in a unit a listener can feel.
    func test_twenty_points_is_about_six_decibels() {
        XCTAssertEqual(
            VolumeCurve.decibels(forPercent: 80) - VolumeCurve.decibels(forPercent: 60),
            6.0,
            accuracy: 0.01
        )
    }

    // MARK: - Percent grid

    func test_percent_fraction_round_trip_is_stable() {
        for p in 0...100 {
            XCTAssertEqual(
                VolumeCurve.percent(forFraction: VolumeCurve.fraction(forPercent: p)),
                p
            )
        }
    }

    func test_fraction_rounds_to_nearest_percent() {
        XCTAssertEqual(VolumeCurve.percent(forFraction: 0.7449), 74)
        XCTAssertEqual(VolumeCurve.percent(forFraction: 0.7451), 75)
    }

    func test_out_of_range_input_is_clamped() {
        XCTAssertEqual(VolumeCurve.percent(forFraction: -3.0), 0)
        XCTAssertEqual(VolumeCurve.percent(forFraction: 12.0), 100)
        XCTAssertEqual(VolumeCurve.clampPercent(-1), 0)
        XCTAssertEqual(VolumeCurve.clampPercent(101), 100)
        XCTAssertEqual(
            VolumeCurve.amplitude(forPercent: -50),
            VolumeCurve.amplitude(forPercent: 0)
        )
    }

    /// A NaN slider position must not become a NaN gain multiplying every
    /// sample on a real-time thread.
    func test_non_finite_fraction_falls_back_to_full_scale() {
        XCTAssertEqual(VolumeCurve.percent(forFraction: .nan), 100)
        XCTAssertEqual(VolumeCurve.percent(forFraction: .infinity), 100)
    }

    // MARK: - Mute

    func test_device_mute_is_true_silence_on_the_local_leg() {
        XCTAssertEqual(
            VolumeCurve.deviceAmplitude(forPercent: 100, muted: true), 0
        )
        XCTAssertEqual(
            VolumeCurve.deviceAmplitude(forPercent: 0, muted: false),
            VolumeCurve.amplitude(forPercent: 0)
        )
    }

    /// The master is the only stage that can produce real silence on BOTH
    /// legs, because it acts upstream of OwnTone's -30 dB floor.
    func test_master_at_zero_is_true_silence() {
        XCTAssertEqual(VolumeCurve.masterAmplitude(forPercent: 0), 0)
        XCTAssertNil(
            VolumeCurve.effectiveAirPlayDecibels(masterPercent: 0, devicePercent: 100)
        )
    }

    func test_master_above_zero_follows_the_same_curve() {
        for p in 1...100 {
            XCTAssertEqual(
                VolumeCurve.masterAmplitude(forPercent: p),
                VolumeCurve.amplitude(forPercent: p),
                accuracy: 1e-6
            )
        }
    }

    // MARK: - Master × device composition

    func test_master_at_full_scale_leaves_the_device_stage_alone() {
        for p in stride(from: 0, through: 100, by: 5) {
            XCTAssertEqual(
                VolumeCurve.effectiveLocalAmplitude(
                    masterPercent: 100, devicePercent: p, deviceMuted: false
                ),
                VolumeCurve.amplitude(forPercent: p),
                accuracy: 1e-6
            )
        }
    }

    /// The composition is a product locally and a sum in dB on the AirPlay
    /// leg — which is the same thing. This is what keeps the two legs matched
    /// once BOTH faders are in play, and it is the reason the master is not
    /// folded into the per-output value (that would clamp at -30 dB on the
    /// AirPlay leg only).
    func test_both_legs_agree_for_every_master_device_combination() {
        for master in stride(from: 1, through: 100, by: 7) {
            for device in stride(from: 0, through: 100, by: 7) {
                let localAmplitude = VolumeCurve.effectiveLocalAmplitude(
                    masterPercent: master, devicePercent: device, deviceMuted: false
                )
                let airPlayDecibels = VolumeCurve.effectiveAirPlayDecibels(
                    masterPercent: master, devicePercent: device
                )
                XCTAssertNotNil(airPlayDecibels)
                XCTAssertEqual(
                    20 * log10(localAmplitude),
                    airPlayDecibels ?? .nan,
                    accuracy: 0.001,
                    "legs disagree at master=\(master)% device=\(device)%"
                )
            }
        }
    }

    /// The combination that proves the master could not have been implemented
    /// as per-output volume: 25 % × 25 % is -45 dB, well past the -30 dB floor
    /// OwnTone would have clamped it to.
    func test_combination_can_go_below_owntones_own_floor() {
        let decibels = VolumeCurve.effectiveAirPlayDecibels(
            masterPercent: 25, devicePercent: 25
        )
        XCTAssertEqual(decibels ?? .nan, -45.0, accuracy: 0.001)
        XCTAssertLessThan(decibels ?? .nan, VolumeCurve.minDb)
    }

    func test_device_mute_silences_regardless_of_master() {
        XCTAssertEqual(
            VolumeCurve.effectiveLocalAmplitude(
                masterPercent: 100, devicePercent: 100, deviceMuted: true
            ),
            0
        )
    }

    // MARK: - Router wiring

    /// The bridge gain the Router actually installs has to come off the curve,
    /// not off the raw slider position. Guards the exact regression this work
    /// fixed: `bridge.setVolume(r.volume)` was ~10.5 dB hot at mid-scale.
    func test_router_bridge_gain_uses_the_curve() {
        let routing = DeviceRouting(deviceID: "d", volume: 0.5)
        XCTAssertEqual(
            Router.localBridgeGain(for: routing),
            VolumeCurve.amplitude(forPercent: 50),
            accuracy: 1e-6
        )
        // The old behaviour, for contrast: 0.5 linear is -6.02 dB while the
        // AirPlay leg at the same slider position is -15 dB.
        XCTAssertNotEqual(Router.localBridgeGain(for: routing), 0.5, accuracy: 0.01)
    }

    func test_router_bridge_gain_honours_mute() {
        let routing = DeviceRouting(deviceID: "d", volume: 0.8, muted: true)
        XCTAssertEqual(Router.localBridgeGain(for: routing), 0)
    }

    func test_router_bridge_gain_is_unity_at_full_scale() {
        let routing = DeviceRouting(deviceID: "d", volume: 1.0)
        XCTAssertEqual(Router.localBridgeGain(for: routing), 1.0, accuracy: 1e-6)
    }

    // MARK: - Presentation

    func test_labels() {
        XCTAssertEqual(VolumeCurve.percentLabel(75), "75%")
        XCTAssertEqual(VolumeCurve.percentLabel(140), "100%")
        XCTAssertEqual(VolumeCurve.decibelLabel(0), "-30.0 dB")
        XCTAssertEqual(VolumeCurve.decibelLabel(100), "0.0 dB")
    }


    // MARK: - Master gain seeding

    /// A brand-new writer must START at the user's level, not ramp down to it.
    ///
    /// `Router.attachIpc` builds a fresh `AudioSocketWriter` on every sidecar
    /// (re)connection. Seeding it through `setMasterGain` moved only the ramp
    /// TARGET, leaving the ramp POSITION at unity — so the first packet after
    /// a sidecar restart began at full scale and ramped down over 480 frames:
    /// ~10 ms of full-volume audio onto every AirPlay receiver and every local
    /// bridge at exactly the moment the user had the system turned down.
    func test_seedMasterGain_moves_the_ramp_position_not_just_the_target() {
        let writer = AudioSocketWriter(
            ring: RingBuffer(channelCount: 2, capacityFrames: 4_096),
            socketPath: URL(fileURLWithPath: "/tmp/syncast-test-unused.sock")
        )
        let quiet = VolumeCurve.masterAmplitude(forPercent: 10)

        writer.seedMasterGain(quiet)
        XCTAssertEqual(writer.masterGain, quiet, accuracy: 1e-6)
        XCTAssertEqual(writer.masterGainRampPosition, quiet, accuracy: 1e-6)
    }

    /// Muting and reconnecting must not blip at full scale either — `0` is the
    /// worst case, since the ramp would sweep the entire range.
    func test_seedMasterGain_seeds_silence_exactly() {
        let writer = AudioSocketWriter(
            ring: RingBuffer(channelCount: 2, capacityFrames: 4_096),
            socketPath: URL(fileURLWithPath: "/tmp/syncast-test-unused.sock")
        )
        writer.seedMasterGain(VolumeCurve.silentAmplitude)
        XCTAssertEqual(writer.masterGainRampPosition, 0)
    }

    /// Live changes must keep ramping — that ramp is what stops a fader drag
    /// from clicking. Only the pre-first-packet seed skips it.
    func test_setMasterGain_leaves_the_ramp_position_alone() {
        let writer = AudioSocketWriter(
            ring: RingBuffer(channelCount: 2, capacityFrames: 4_096),
            socketPath: URL(fileURLWithPath: "/tmp/syncast-test-unused.sock")
        )
        writer.setMasterGain(0.25)
        XCTAssertEqual(writer.masterGain, 0.25, accuracy: 1e-6)
        XCTAssertEqual(
            writer.masterGainRampPosition,
            AudioSocketWriter.masterGainDefault,
            accuracy: 1e-6
        )
    }

    // MARK: - Headroom budget

    /// The s16 headroom note in `AudioSocketWriter` used to describe a LINEAR
    /// fader ("one bit per halving; 50 % is -6 dB"), which the master has not
    /// been since it moved onto this curve. Derived here rather than restated
    /// in prose so the comment cannot drift ~9 dB from the code again.
    func test_master_headroom_cost_is_derived_from_the_curve() {
        let bitsPerDb: Float = 1.0 / 6.0205999  // 20·log10(2)

        let halfway = VolumeCurve.decibels(forPercent: 50)
        XCTAssertEqual(halfway, -15.0, accuracy: 0.001)
        XCTAssertEqual(-halfway * bitsPerDb, 2.49, accuracy: 0.01)

        let quarter = VolumeCurve.decibels(forPercent: 25)
        XCTAssertEqual(quarter, -22.5, accuracy: 0.001)
        XCTAssertEqual(-quarter * bitsPerDb, 3.74, accuracy: 0.01)
    }
}
