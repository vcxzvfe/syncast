import XCTest
@testable import SyncCastRouter

/// The channel-assignment feature's specification.
///
/// Two halves: the pure settings→matrix mapping (presets, decibel round-trip,
/// load-boundary validation) and the real-time bank's behaviour on actual
/// sample buffers, driven through the SHIPPING `process()` entry point with a
/// hand-built channel pointer table and no CoreAudio device.
final class ChannelMatrixTests: XCTestCase {

    // MARK: - Helpers

    /// Run one block through a bank and return the two output channels.
    private func render(
        bank: ChannelMatrixBank,
        left: [Float],
        right: [Float],
        pair: Int = 0,
        blocks: Int = 1
    ) -> (left: [Float], right: [Float]) {
        let frames = left.count
        XCTAssertEqual(right.count, frames)
        var outLeft = left
        var outRight = right
        for _ in 0..<blocks {
            outLeft = left
            outRight = right
            outLeft.withUnsafeMutableBufferPointer { l in
                outRight.withUnsafeMutableBufferPointer { r in
                    let table = UnsafeMutablePointer<UnsafeMutablePointer<Float>>
                        .allocate(capacity: 2)
                    defer { table.deallocate() }
                    table[0] = l.baseAddress!
                    table[1] = r.baseAddress!
                    bank.process(
                        pair: pair,
                        channels: table,
                        channelOffset: 0,
                        channelCount: 2,
                        frames: frames
                    )
                }
            }
        }
        return (outLeft, outRight)
    }

    /// A bank whose ramp is already finished, so a preset's steady-state
    /// coefficients are what the block sees. One 20 ms block at 48 kHz is
    /// exactly `fadeFrames`, so a single 960-frame block retires the ramp.
    private func settledBank(_ settings: ChannelMatrixSettings) -> ChannelMatrixBank {
        let bank = ChannelMatrixBank(pairCount: 1, channelsPerPair: 2, sampleRate: 48_000)
        bank.setSettings(settings, pair: 0)
        _ = render(
            bank: bank,
            left: [Float](repeating: 0, count: 960),
            right: [Float](repeating: 0, count: 960)
        )
        return bank
    }

    // MARK: - Presets

    func testStereoPresetIsTheIdentityMatrix() {
        let matrix = ChannelMatrixSettings(preset: .stereo).matrix
        XCTAssertEqual(matrix.leftToLeft, 1)
        XCTAssertEqual(matrix.rightToLeft, 0)
        XCTAssertEqual(matrix.leftToRight, 0)
        XCTAssertEqual(matrix.rightToRight, 1)
        XCTAssertTrue(matrix.isIdentity)
        XCTAssertTrue(ChannelMatrixSettings(preset: .stereo).isNeutral)
    }

    func testLeftPresetPutsTheLeftChannelOnBothOutputs() {
        let bank = settledBank(ChannelMatrixSettings(preset: .left))
        let out = render(bank: bank, left: [0.5, -0.25], right: [-0.75, 0.125])
        XCTAssertEqual(out.left, [0.5, -0.25])
        XCTAssertEqual(out.right, [0.5, -0.25])
    }

    func testRightPresetPutsTheRightChannelOnBothOutputs() {
        let bank = settledBank(ChannelMatrixSettings(preset: .right))
        let out = render(bank: bank, left: [0.5, -0.25], right: [-0.75, 0.125])
        XCTAssertEqual(out.left, [-0.75, 0.125])
        XCTAssertEqual(out.right, [-0.75, 0.125])
    }

    func testMonoPresetSumsAtMinusSixDecibelsOnBothOutputs() {
        let bank = settledBank(ChannelMatrixSettings(preset: .mono))
        let out = render(bank: bank, left: [1.0, 0.4], right: [1.0, -0.2])
        // Correlated full scale sums to exactly full scale, not past it.
        XCTAssertEqual(out.left[0], 1.0, accuracy: 1e-6)
        XCTAssertEqual(out.right[0], 1.0, accuracy: 1e-6)
        XCTAssertEqual(out.left[1], 0.1, accuracy: 1e-6)
        XCTAssertEqual(out.right[1], 0.1, accuracy: 1e-6)
    }

    func testMonoPresetDoesNotClipCorrelatedFullScale() {
        let bank = settledBank(ChannelMatrixSettings(preset: .mono))
        _ = render(
            bank: bank,
            left: [Float](repeating: 1, count: 128),
            right: [Float](repeating: 1, count: 128)
        )
        XCTAssertEqual(bank.clipCount, 0)
    }

    // MARK: - Pass-through

    func testStereoPassThroughIsBitIdentical() {
        let bank = ChannelMatrixBank(pairCount: 1, channelsPerPair: 2, sampleRate: 48_000)
        // Values chosen so any multiply-by-1.0f round trip would still pass;
        // what this pins is that the fast path does not touch the buffer at
        // all, which the odd exponents below would expose if it did.
        let left: [Float] = [0.1, -0.3333333, 0.7071068, 1, -1, 1e-8]
        let right: [Float] = [-0.2, 0.6666667, -0.5000001, -1, 1, -1e-8]
        let out = render(bank: bank, left: left, right: right)
        XCTAssertEqual(out.left, left)
        XCTAssertEqual(out.right, right)
        XCTAssertEqual(bank.clipCount, 0)
        XCTAssertFalse(bank.isEngaged)
    }

    func testRePublishingTheSameSettingsIsANoOp() {
        let bank = ChannelMatrixBank(pairCount: 1, channelsPerPair: 2, sampleRate: 48_000)
        XCTAssertTrue(bank.setSettings(ChannelMatrixSettings(preset: .mono), pair: 0))
        XCTAssertFalse(bank.setSettings(ChannelMatrixSettings(preset: .mono), pair: 0))
    }

    func testPairsAreIndependent() {
        let bank = ChannelMatrixBank(pairCount: 2, channelsPerPair: 2, sampleRate: 48_000)
        bank.setSettings(ChannelMatrixSettings(preset: .left), pair: 1)
        // Settle both pairs.
        let silence = [Float](repeating: 0, count: 960)
        _ = render(bank: bank, left: silence, right: silence, pair: 0)
        _ = render(bank: bank, left: silence, right: silence, pair: 1)

        let untouched = render(bank: bank, left: [0.5], right: [-0.5], pair: 0)
        XCTAssertEqual(untouched.left, [0.5])
        XCTAssertEqual(untouched.right, [-0.5])

        let assigned = render(bank: bank, left: [0.5], right: [-0.5], pair: 1)
        XCTAssertEqual(assigned.left, [0.5])
        XCTAssertEqual(assigned.right, [0.5])
    }

    // MARK: - Custom decibels

    func testCustomDecibelsRoundTripThroughAmplitude() {
        for db in stride(from: -60.0, through: 6.0, by: 0.5) {
            let amplitude = ChannelMatrixLimits.amplitude(forDecibels: db)
            let back = ChannelMatrixLimits.decibels(forAmplitude: amplitude)
            if db <= ChannelMatrixLimits.silentDb {
                XCTAssertEqual(amplitude, 0)
                XCTAssertEqual(back, ChannelMatrixLimits.silentDb)
            } else {
                XCTAssertEqual(back, db, accuracy: 1e-9, "round trip failed at \(db) dB")
            }
        }
    }

    func testCustomSettingsProduceTheExpectedAmplitudes() {
        let settings = ChannelMatrixSettings(
            preset: .custom,
            leftToLeftDb: 0,
            rightToLeftDb: -6,
            leftToRightDb: ChannelMatrixLimits.silentDb,
            rightToRightDb: 6
        )
        let matrix = settings.matrix
        XCTAssertEqual(matrix.leftToLeft, 1, accuracy: 1e-9)
        XCTAssertEqual(matrix.rightToLeft, 0.501187, accuracy: 1e-5)
        XCTAssertEqual(matrix.leftToRight, 0)
        XCTAssertEqual(matrix.rightToRight, 1.995262, accuracy: 1e-5)
    }

    func testCustomSeededFromAPresetReproducesIt() {
        for preset in [ChannelMatrixPreset.stereo, .left, .right, .mono] {
            let seeded = ChannelMatrixSettings.custom(seededFrom: preset)
            XCTAssertEqual(seeded.preset, .custom)
            let expected = ChannelMatrixSettings(preset: preset).matrix
            let actual = seeded.matrix
            XCTAssertEqual(actual.leftToLeft, expected.leftToLeft, accuracy: 1e-6)
            XCTAssertEqual(actual.rightToLeft, expected.rightToLeft, accuracy: 1e-6)
            XCTAssertEqual(actual.leftToRight, expected.leftToRight, accuracy: 1e-6)
            XCTAssertEqual(actual.rightToRight, expected.rightToRight, accuracy: 1e-6)
        }
    }

    func testCustomAtUnityIsRecognisedAsNeutral() {
        let settings = ChannelMatrixSettings(
            preset: .custom,
            leftToLeftDb: 0,
            rightToLeftDb: ChannelMatrixLimits.silentDb,
            leftToRightDb: ChannelMatrixLimits.silentDb,
            rightToRightDb: 0
        )
        XCTAssertTrue(settings.isNeutral)
        XCTAssertFalse(settings.hasUserSetting)
    }

    // MARK: - Load-boundary validation

    func testNonFiniteDecibelsFailQuiet() {
        let settings = ChannelMatrixSettings(
            preset: .custom,
            leftToLeftDb: .nan,
            rightToLeftDb: .infinity,
            leftToRightDb: -.infinity,
            rightToRightDb: 999
        ).sanitized()
        XCTAssertEqual(settings.leftToLeftDb, ChannelMatrixLimits.silentDb)
        XCTAssertEqual(settings.rightToLeftDb, ChannelMatrixLimits.silentDb)
        XCTAssertEqual(settings.leftToRightDb, ChannelMatrixLimits.silentDb)
        XCTAssertEqual(settings.rightToRightDb, ChannelMatrixLimits.maximumDb)
        for value in [settings.matrix.leftToLeft, settings.matrix.rightToLeft,
                      settings.matrix.leftToRight, settings.matrix.rightToRight] {
            XCTAssertTrue(value.isFinite)
        }
    }

    func testAnUnknownPresetDecodesAsStereo() throws {
        let json = Data(#"{"preset":"quadraphonic","leftToLeftDb":3}"#.utf8)
        let decoded = try JSONDecoder().decode(ChannelMatrixSettings.self, from: json)
        XCTAssertEqual(decoded.preset, .stereo)
        XCTAssertTrue(decoded.isNeutral)
    }

    func testAMissingFieldDecodesToItsDefault() throws {
        let json = Data(#"{"preset":"custom"}"#.utf8)
        let decoded = try JSONDecoder().decode(ChannelMatrixSettings.self, from: json)
        XCTAssertEqual(decoded.leftToLeftDb, 0)
        XCTAssertEqual(decoded.rightToRightDb, 0)
        XCTAssertEqual(decoded.rightToLeftDb, ChannelMatrixLimits.silentDb)
        XCTAssertTrue(decoded.isNeutral)
    }

    func testSettingsSurviveAJSONRoundTrip() throws {
        let original = ChannelMatrixSettings(
            preset: .custom,
            leftToLeftDb: -1.5,
            rightToLeftDb: -12,
            leftToRightDb: 4.5,
            rightToRightDb: 0
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChannelMatrixSettings.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - Limiter

    func testABoostedMatrixClampsAndCounts() {
        let bank = settledBank(
            ChannelMatrixSettings(
                preset: .custom,
                leftToLeftDb: 6,
                rightToLeftDb: 6,
                leftToRightDb: 6,
                rightToRightDb: 6
            )
        )
        let out = render(bank: bank, left: [0.9], right: [0.9])
        XCTAssertEqual(out.left, [1])
        XCTAssertEqual(out.right, [1])
        XCTAssertEqual(bank.clipCount, 2)
    }

    func testNonFiniteInputIsZeroedRatherThanPropagated() {
        let bank = settledBank(ChannelMatrixSettings(preset: .mono))
        let out = render(bank: bank, left: [.nan], right: [0.5])
        XCTAssertEqual(out.left, [0])
        XCTAssertEqual(out.right, [0])
        XCTAssertEqual(bank.clipCount, 2)
    }

    // MARK: - Ramp

    func testAChangeIsRampedRatherThanStepped() {
        let bank = ChannelMatrixBank(pairCount: 1, channelsPerPair: 2, sampleRate: 48_000)
        bank.setSettings(ChannelMatrixSettings(preset: .mono), pair: 0)
        // A block far shorter than the 960-frame ramp: the first sample must
        // still be (almost) the old matrix and the last must have moved.
        let frames = 480
        let out = render(
            bank: bank,
            left: [Float](repeating: 1, count: frames),
            right: [Float](repeating: -1, count: frames)
        )
        // Old matrix: left stays 1. New matrix: (1 + −1)/2 = 0.
        XCTAssertEqual(out.left[0], 1, accuracy: 1e-3)
        XCTAssertLessThan(out.left[frames - 1], 0.55)
        XCTAssertGreaterThan(out.left[frames - 1], 0.45)
        // Halfway through the ramp, so half of it is still owed.
        let rest = render(
            bank: bank,
            left: [Float](repeating: 1, count: frames),
            right: [Float](repeating: -1, count: frames)
        )
        XCTAssertEqual(rest.left[frames - 1], 0, accuracy: 1e-3)
    }

    func testTheRampRetiresAndTheSteadyStateHolds() {
        let bank = settledBank(ChannelMatrixSettings(preset: .right))
        for _ in 0..<4 {
            let out = render(bank: bank, left: [0.25], right: [-0.75])
            XCTAssertEqual(out.left, [-0.75])
            XCTAssertEqual(out.right, [-0.75])
        }
    }

    func testResetAllReturnsToPassThrough() {
        let bank = settledBank(ChannelMatrixSettings(preset: .mono))
        bank.resetAll()
        let silence = [Float](repeating: 0, count: 960)
        _ = render(bank: bank, left: silence, right: silence)
        let out = render(bank: bank, left: [0.3], right: [-0.6])
        XCTAssertEqual(out.left, [0.3])
        XCTAssertEqual(out.right, [-0.6])
        XCTAssertFalse(bank.isEngaged)
    }

    // MARK: - Guards

    func testOutOfRangePairIsIgnored() {
        let bank = ChannelMatrixBank(pairCount: 1, channelsPerPair: 2, sampleRate: 48_000)
        XCTAssertFalse(bank.setSettings(ChannelMatrixSettings(preset: .mono), pair: 7))
        XCTAssertFalse(bank.setSettings(ChannelMatrixSettings(preset: .mono), pair: -1))
    }

    func testABlockLongerThanTheCapIsLeftAlone() {
        let bank = settledBank(ChannelMatrixSettings(preset: .mono))
        let frames = ChannelMatrixBank.maxFramesPerBlock + 1
        let left = [Float](repeating: 0.5, count: frames)
        let right = [Float](repeating: -0.5, count: frames)
        let out = render(bank: bank, left: left, right: right)
        XCTAssertEqual(out.left, left)
        XCTAssertEqual(out.right, right)
    }
}
