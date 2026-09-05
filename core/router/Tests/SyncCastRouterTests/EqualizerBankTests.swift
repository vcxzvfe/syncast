import XCTest
@testable import SyncCastRouter

/// Coefficient math, settings validation, and the real-time bank's observable
/// behaviour (fast path, measured band gain, crossfade continuity, limiter).
///
/// Everything here is offline: buffers are pushed through `EqualizerBank`
/// exactly the way `LocalOutput.render()` does, so a regression in the DSP
/// shows up without a CoreAudio device.
final class EqualizerBankTests: XCTestCase {

    private let sampleRate: Double = 48_000

    // MARK: - Helpers

    /// Steady-state gain of the bank at one frequency, in dB.
    ///
    /// Feeds a sine, discards a settling prefix, and compares output RMS to
    /// input RMS over an integer number of periods. This measures the SHIPPING
    /// code path (`process`), not the coefficient formula, which is the point.
    private func measuredGainDb(
        bank: EqualizerBank,
        hz: Double,
        pair: Int = 0,
        settleFrames: Int = 48_000,
        measureFrames: Int = 48_000
    ) -> Double {
        var inputSquares = 0.0
        var outputSquares = 0.0
        var phase = 0.0
        let increment = 2 * Double.pi * hz / sampleRate
        let block = 512
        let amplitude = 0.25
        var produced = 0
        let total = settleFrames + measureFrames

        var left = [Float](repeating: 0, count: block)
        var right = [Float](repeating: 0, count: block)
        var reference = [Double](repeating: 0, count: block)

        while produced < total {
            let frames = min(block, total - produced)
            for index in 0..<frames {
                let sample = amplitude * sin(phase)
                phase += increment
                reference[index] = sample
                left[index] = Float(sample)
                right[index] = Float(sample)
            }
            left.withUnsafeMutableBufferPointer { leftBuffer in
                right.withUnsafeMutableBufferPointer { rightBuffer in
                    var pointers = [leftBuffer.baseAddress!, rightBuffer.baseAddress!]
                    pointers.withUnsafeMutableBufferPointer { table in
                        bank.process(
                            pair: pair,
                            channels: table.baseAddress!,
                            channelOffset: 0,
                            channelCount: 2,
                            frames: frames
                        )
                    }
                }
            }
            if produced >= settleFrames {
                for index in 0..<frames {
                    inputSquares += reference[index] * reference[index]
                    outputSquares += Double(left[index]) * Double(left[index])
                }
            }
            produced += frames
        }
        guard inputSquares > 0 else { return 0 }
        return 10 * log10(max(outputSquares / inputSquares, 1e-18))
    }

    private func graphic(_ gains: [Double: Double], trimDb: Double = 0) -> EqualizerSettings {
        var settings = EqualizerSettings.graphicFlat
        settings.trimDb = trimDb
        for index in settings.bands.indices {
            if let gain = gains[settings.bands[index].frequency] {
                settings.bands[index].gainDb = gain
            }
        }
        return settings
    }

    private func makeBank(pairs: Int = 1) -> EqualizerBank {
        EqualizerBank(pairCount: pairs, channelsPerPair: 2, sampleRate: sampleRate)
    }

    // MARK: - Coefficient sanity

    func testZeroDbBandIsIdentityCoefficients() {
        for kind in EqualizerBandKind.allCases {
            let band = EqualizerBand(kind: kind, frequency: 1_000, q: 1.41, gainDb: 0)
            let coefficients = BiquadCoefficients.make(band: band, sampleRate: sampleRate)
            XCTAssertEqual(coefficients, .identity, "\(kind) at 0 dB must be identity")
            XCTAssertEqual(
                coefficients.magnitude(atHz: 1_000, sampleRate: sampleRate), 1,
                accuracy: 1e-9
            )
        }
    }

    func testPeakingCoefficientsHitTheRequestedGainAtCentre() {
        for gainDb in [-12.0, -6.0, -3.0, 3.0, 6.0, 12.0] {
            let band = EqualizerBand(
                kind: .peaking, frequency: 1_000, q: 1.41, gainDb: gainDb
            )
            let coefficients = BiquadCoefficients.make(band: band, sampleRate: sampleRate)
            let measured = 20 * log10(
                coefficients.magnitude(atHz: 1_000, sampleRate: sampleRate)
            )
            XCTAssertEqual(measured, gainDb, accuracy: 1e-6)
        }
    }

    func testShelvesReachHalfGainAtTheCornerAndFullGainInTheBand() {
        let low = BiquadCoefficients.make(
            band: EqualizerBand(kind: .lowShelf, frequency: 200, q: 0.707, gainDb: 6),
            sampleRate: sampleRate
        )
        XCTAssertEqual(
            20 * log10(low.magnitude(atHz: 200, sampleRate: sampleRate)), 3,
            accuracy: 0.05, "cookbook shelf is at half gain on the corner"
        )
        XCTAssertEqual(
            20 * log10(low.magnitude(atHz: 10, sampleRate: sampleRate)), 6,
            accuracy: 0.1, "well inside the shelf"
        )
        XCTAssertEqual(
            20 * log10(low.magnitude(atHz: 8_000, sampleRate: sampleRate)), 0,
            accuracy: 0.1, "well outside the shelf"
        )

        let high = BiquadCoefficients.make(
            band: EqualizerBand(kind: .highShelf, frequency: 4_000, q: 0.707, gainDb: -6),
            sampleRate: sampleRate
        )
        XCTAssertEqual(
            20 * log10(high.magnitude(atHz: 4_000, sampleRate: sampleRate)), -3,
            accuracy: 0.05
        )
        XCTAssertEqual(
            20 * log10(high.magnitude(atHz: 20_000, sampleRate: sampleRate)), -6,
            accuracy: 0.3
        )
        XCTAssertEqual(
            20 * log10(high.magnitude(atHz: 100, sampleRate: sampleRate)), 0,
            accuracy: 0.1
        )
    }

    func testExtremeAndDegenerateBandsStayStable() {
        var cases: [EqualizerBand] = []
        for kind in EqualizerBandKind.allCases {
            for frequency in [20.0, 31.5, 1_000.0, 16_000.0, 23_000.0] {
                for q in [0.1, 0.707, 1.41, 18.0] {
                    for gain in [-12.0, 12.0] {
                        cases.append(
                            EqualizerBand(
                                kind: kind, frequency: frequency, q: q, gainDb: gain
                            )
                        )
                    }
                }
            }
        }
        for band in cases {
            let coefficients = BiquadCoefficients.make(band: band, sampleRate: sampleRate)
            XCTAssertTrue(
                coefficients.isUsable || coefficients == .identity,
                "unstable coefficients for \(band)"
            )
        }
    }

    func testMalformedBandsCollapseToIdentity() {
        let bad = [
            EqualizerBand(kind: .peaking, frequency: .nan, q: 1, gainDb: 6),
            EqualizerBand(kind: .peaking, frequency: 1_000, q: .nan, gainDb: 6),
            EqualizerBand(kind: .peaking, frequency: 1_000, q: 1, gainDb: .infinity),
            EqualizerBand(kind: .peaking, frequency: 30_000, q: 1, gainDb: 6),
            EqualizerBand(kind: .peaking, frequency: -100, q: 1, gainDb: 6),
            EqualizerBand(kind: .peaking, frequency: 1_000, q: 0, gainDb: 6),
        ]
        for band in bad {
            XCTAssertEqual(
                BiquadCoefficients.make(band: band, sampleRate: sampleRate), .identity
            )
        }
        XCTAssertEqual(
            BiquadCoefficients.make(
                band: EqualizerBand(frequency: 1_000, gainDb: 6), sampleRate: 0
            ),
            .identity
        )
    }

    // MARK: - Settings validation

    func testSanitizeClampsAndDropsGarbage() {
        let settings = EqualizerSettings(
            bypassed: false,
            trimDb: 99,
            bands: [
                EqualizerBand(frequency: 1_000, gainDb: 40),
                EqualizerBand(frequency: .nan, gainDb: 3),
                EqualizerBand(frequency: 500, q: 900, gainDb: -80),
            ]
        ).sanitized()
        XCTAssertEqual(settings.trimDb, EqualizerLimits.trimRangeDb.upperBound)
        XCTAssertEqual(settings.bands.count, 2)
        XCTAssertEqual(settings.bands[0].gainDb, EqualizerLimits.bandGainRangeDb.upperBound)
        XCTAssertEqual(settings.bands[1].q, EqualizerLimits.qRange.upperBound)
        XCTAssertEqual(settings.bands[1].gainDb, EqualizerLimits.bandGainRangeDb.lowerBound)
    }

    func testSanitizeCapsBandCount() {
        let many = (0..<64).map { EqualizerBand(frequency: Double(100 + $0), gainDb: 1) }
        XCTAssertEqual(
            EqualizerSettings(bands: many).sanitized().bands.count,
            EqualizerLimits.maxBands
        )
    }

    func testNeutralityRules() {
        XCTAssertTrue(EqualizerSettings.flat.isNeutral)
        XCTAssertTrue(EqualizerSettings.graphicFlat.isNeutral)
        XCTAssertFalse(EqualizerSettings.graphicFlat.hasUserCurve)

        var boosted = graphic([125: 4])
        XCTAssertFalse(boosted.isNeutral)
        XCTAssertTrue(boosted.hasUserCurve)

        boosted.bypassed = true
        XCTAssertTrue(boosted.isNeutral, "bypass makes a curve inert")
        XCTAssertTrue(boosted.hasUserCurve, "…but does not forget it")
        XCTAssertEqual(boosted.trimAmplitude, 1, "bypass is a true pass-through")

        XCTAssertFalse(EqualizerSettings(trimDb: -3).isNeutral)
    }

    func testDecodingToleratesAMissingField() throws {
        let json = Data(#"{"bands":[{"kind":"peaking","frequency":125,"q":1.41,"gainDb":3}]}"#.utf8)
        let decoded = try JSONDecoder().decode(EqualizerSettings.self, from: json)
        XCTAssertFalse(decoded.bypassed)
        XCTAssertEqual(decoded.trimDb, 0)
        XCTAssertEqual(decoded.bands.count, 1)
    }

    func testSnapToStep() {
        XCTAssertEqual(EqualizerLimits.snapToStep(0.4999), 0.5, accuracy: 1e-12)
        XCTAssertEqual(EqualizerLimits.snapToStep(-3.26), -3.5, accuracy: 1e-12)
        XCTAssertEqual(EqualizerLimits.snapToStep(.nan), 0)
    }

    // MARK: - Bank behaviour

    func testFlatBankLeavesTheBufferBitIdentical() {
        let bank = makeBank()
        bank.setSettings(.graphicFlat, pair: 0)
        var left: [Float] = (0..<512).map { Float(sin(Double($0) * 0.05)) }
        var right = left
        let original = left
        left.withUnsafeMutableBufferPointer { leftBuffer in
            right.withUnsafeMutableBufferPointer { rightBuffer in
                var pointers = [leftBuffer.baseAddress!, rightBuffer.baseAddress!]
                pointers.withUnsafeMutableBufferPointer { table in
                    for _ in 0..<8 {
                        bank.process(
                            pair: 0, channels: table.baseAddress!,
                            channelOffset: 0, channelCount: 2, frames: 512
                        )
                    }
                }
            }
        }
        XCTAssertEqual(left, original, "a flat curve must not touch the samples")
        XCTAssertEqual(bank.clipCount, 0)
    }

    func testBypassIsTheSameFastPathAsFlat() {
        let bank = makeBank()
        var settings = graphic([63: 12], trimDb: -6)
        settings.bypassed = true
        bank.setSettings(settings, pair: 0)
        // Push a long block so the crossfade into bypass has retired.
        _ = measuredGainDb(bank: bank, hz: 63, settleFrames: 4_800, measureFrames: 4_800)
        var buffer: [Float] = (0..<512).map { Float(sin(Double($0) * 0.02)) }
        let original = buffer
        buffer.withUnsafeMutableBufferPointer { channel in
            var pointers = [channel.baseAddress!]
            pointers.withUnsafeMutableBufferPointer { table in
                bank.process(
                    pair: 0, channels: table.baseAddress!,
                    channelOffset: 0, channelCount: 1, frames: 512
                )
            }
        }
        XCTAssertEqual(buffer, original)
    }

    func testPeakBandRaisesItsOwnFrequencyAndLeavesNeighboursAlone() {
        let bank = makeBank()
        bank.setSettings(graphic([1_000: 6]), pair: 0)
        XCTAssertEqual(measuredGainDb(bank: bank, hz: 1_000), 6, accuracy: 0.15)
        XCTAssertEqual(measuredGainDb(bank: bank, hz: 100), 0, accuracy: 0.2)
        XCTAssertEqual(measuredGainDb(bank: bank, hz: 10_000), 0, accuracy: 0.2)
    }

    /// The user's actual case: "低音太厉害" — pull the bottom two bands down
    /// and check that only the bottom moved.
    func testBassCutLeavesMidsAndHighsAlone() {
        let settings = graphic([31.5: -6, 63: -6])
        let bank = makeBank()
        bank.setSettings(settings, pair: 0)
        // Two adjacent constant-Q octave bands overlap, so 63 Hz sits a little
        // below -6 dB — the analytic response says how much, and the shipping
        // render path has to agree with it.
        let expectedAt63 = settings.responseDb(atHz: 63, sampleRate: sampleRate)
        XCTAssertLessThan(expectedAt63, -6)
        XCTAssertGreaterThan(expectedAt63, -9)
        XCTAssertEqual(measuredGainDb(bank: bank, hz: 63), expectedAt63, accuracy: 0.3)
        XCTAssertEqual(measuredGainDb(bank: bank, hz: 1_000), 0, accuracy: 0.2)
        XCTAssertEqual(measuredGainDb(bank: bank, hz: 8_000), 0, accuracy: 0.2)
    }

    func testTrimIsABroadbandGain() {
        let bank = makeBank()
        bank.setSettings(EqualizerSettings(trimDb: -6, bands: []), pair: 0)
        for hz in [100.0, 1_000.0, 8_000.0] {
            XCTAssertEqual(measuredGainDb(bank: bank, hz: hz), -6, accuracy: 0.05)
        }
    }

    func testPairsAreIndependent() {
        let bank = makeBank(pairs: 2)
        bank.setSettings(graphic([1_000: 6]), pair: 0)
        bank.setSettings(.flat, pair: 1)
        XCTAssertEqual(measuredGainDb(bank: bank, hz: 1_000, pair: 0), 6, accuracy: 0.15)
        XCTAssertEqual(measuredGainDb(bank: bank, hz: 1_000, pair: 1), 0, accuracy: 0.01)
    }

    func testRepublishingTheSameCurveIsANoOp() {
        let bank = makeBank()
        XCTAssertTrue(bank.setSettings(graphic([250: 3]), pair: 0))
        XCTAssertFalse(
            bank.setSettings(graphic([250: 3]), pair: 0),
            "a replan re-pushing an unchanged curve must not restart a crossfade"
        )
        XCTAssertTrue(bank.setSettings(graphic([250: 3.5]), pair: 0))
    }

    // MARK: - Crossfade

    /// A curve change must not put a step in the output. We drive a steady
    /// sine, flip from flat to a big cut mid-stream, and assert the largest
    /// sample-to-sample jump stays close to what the source itself does.
    func testCurveChangeIsSmoothed() {
        let bank = makeBank()
        bank.setSettings(.graphicFlat, pair: 0)
        let hz = 220.0
        let increment = 2 * Double.pi * hz / sampleRate
        let sourceStep = 0.5 * increment   // max |Δ| of a 0.5-amplitude sine
        var phase = 0.0
        var previous: Float = 0
        var largestJump = 0.0
        var buffer = [Float](repeating: 0, count: 256)
        var blocks = 0
        var switched = false

        while blocks < 40 {
            for index in 0..<buffer.count {
                buffer[index] = Float(0.5 * sin(phase))
                phase += increment
            }
            buffer.withUnsafeMutableBufferPointer { channel in
                var pointers = [channel.baseAddress!]
                pointers.withUnsafeMutableBufferPointer { table in
                    bank.process(
                        pair: 0, channels: table.baseAddress!,
                        channelOffset: 0, channelCount: 1, frames: 256
                    )
                }
            }
            if blocks > 4 {
                for sample in buffer {
                    largestJump = max(largestJump, abs(Double(sample - previous)))
                    previous = sample
                }
            } else {
                previous = buffer.last ?? 0
            }
            blocks += 1
            if blocks == 10, !switched {
                switched = true
                bank.setSettings(graphic([250: -12, 125: -12], trimDb: -12), pair: 0)
            }
        }
        XCTAssertTrue(switched)
        XCTAssertLessThan(
            largestJump, sourceStep * 3,
            "a coefficient swap must not produce a discontinuity "
                + "(largest Δ \(largestJump) vs source Δ \(sourceStep))"
        )
    }

    func testCrossfadeSettlesOnTheNewCurve() {
        let bank = makeBank()
        bank.setSettings(.graphicFlat, pair: 0)
        _ = measuredGainDb(bank: bank, hz: 1_000, settleFrames: 2_400, measureFrames: 2_400)
        bank.setSettings(graphic([1_000: -9]), pair: 0)
        XCTAssertEqual(measuredGainDb(bank: bank, hz: 1_000), -9, accuracy: 0.2)
    }

    // MARK: - Limiter

    func testBoostOnAHotSourceClipsAndIsCounted() {
        let bank = makeBank()
        bank.setSettings(graphic([1_000: 12]), pair: 0)
        _ = measuredGainDb(bank: bank, hz: 1_000, settleFrames: 4_800, measureFrames: 0)
        var buffer = [Float](repeating: 0, count: 1_024)
        var phase = 0.0
        let increment = 2 * Double.pi * 1_000 / sampleRate
        for index in 0..<buffer.count {
            buffer[index] = Float(0.95 * sin(phase))
            phase += increment
        }
        buffer.withUnsafeMutableBufferPointer { channel in
            var pointers = [channel.baseAddress!]
            pointers.withUnsafeMutableBufferPointer { table in
                bank.process(
                    pair: 0, channels: table.baseAddress!,
                    channelOffset: 0, channelCount: 1, frames: 1_024
                )
            }
        }
        XCTAssertGreaterThan(bank.clipCount, 0, "+12 dB on a -0.4 dBFS sine must clip")
        XCTAssertTrue(buffer.allSatisfy { $0 >= -1 && $0 <= 1 })
        bank.resetClipCount()
        XCTAssertEqual(bank.clipCount, 0)
    }

    func testNonFiniteInputIsReplacedBySilence() {
        let bank = makeBank()
        bank.setSettings(graphic([1_000: 3]), pair: 0)
        var buffer = [Float](repeating: 0.1, count: 128)
        buffer[10] = .nan
        buffer.withUnsafeMutableBufferPointer { channel in
            var pointers = [channel.baseAddress!]
            pointers.withUnsafeMutableBufferPointer { table in
                bank.process(
                    pair: 0, channels: table.baseAddress!,
                    channelOffset: 0, channelCount: 1, frames: 128
                )
            }
        }
        XCTAssertTrue(buffer.allSatisfy { $0.isFinite }, "no NaN may reach CoreAudio")
    }

    func testOversizedBlockIsRefusedRatherThanTruncated() {
        let bank = makeBank()
        bank.setSettings(graphic([1_000: 6]), pair: 0)
        let frames = EqualizerBank.maxFramesPerBlock + 1
        var buffer = [Float](repeating: 0.5, count: frames)
        let original = buffer
        buffer.withUnsafeMutableBufferPointer { channel in
            var pointers = [channel.baseAddress!]
            pointers.withUnsafeMutableBufferPointer { table in
                bank.process(
                    pair: 0, channels: table.baseAddress!,
                    channelOffset: 0, channelCount: 1, frames: frames
                )
            }
        }
        XCTAssertEqual(buffer, original)
    }

    func testOutOfRangePairIsIgnored() {
        let bank = makeBank()
        XCTAssertFalse(bank.setSettings(graphic([1_000: 6]), pair: 7))
        XCTAssertFalse(bank.setSettings(graphic([1_000: 6]), pair: -1))
    }

    // MARK: - Analytic response helper

    func testResponseDbAgreesWithTheMeasuredBank() {
        let settings = graphic([125: -6, 4_000: 4], trimDb: -2)
        let bank = makeBank()
        bank.setSettings(settings, pair: 0)
        for hz in [125.0, 1_000.0, 4_000.0] {
            XCTAssertEqual(
                settings.responseDb(atHz: hz, sampleRate: sampleRate),
                measuredGainDb(bank: bank, hz: hz),
                accuracy: 0.2,
                "analytic and measured response disagree at \(hz) Hz"
            )
        }
    }
}
