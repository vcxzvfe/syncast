import XCTest
@testable import SyncCastRouter

final class CalibrationTests: XCTestCase {
    func testMedianOffsetSubtractsHumanReaction() {
        let s = CalibrationSession(clickIntervalMs: 1000, clickCount: 6)
        s.scheduleClicks(startingAt: 1_000_000_000)  // 1 s in ns
        // User taps with a 240-ms reaction time on three of the clicks
        // → expected median offset = 0.
        for idx in 0..<3 {
            let target = s.clickWallTimesNs[idx]
            let tapNs = target + 240_000_000
            s.recordTap(.init(deviceID: "d", clickIndex: idx, tapTimeNs: tapNs))
        }
        XCTAssertEqual(s.medianOffsetMs(for: "d"), 0)
    }

    func testInsufficientTapsReturnsNil() {
        let s = CalibrationSession()
        s.scheduleClicks(startingAt: 0)
        s.recordTap(.init(deviceID: "d", clickIndex: 0, tapTimeNs: 0))
        XCTAssertNil(s.medianOffsetMs(for: "d"))
    }

    func testClickPulseHasExpectedFrameCount() {
        let pulse = CalibrationSession.clickPulse()
        XCTAssertEqual(pulse.count, 2)
        XCTAssertEqual(pulse[0].count, 480)
        XCTAssertEqual(pulse[1].count, 480)
    }

    func testAcousticFingerprintUsesUpperBandContinuousFSK() {
        let sampleRate = 48_000.0
        let probe = ActiveCalibrator.acousticFingerprintProbe(
            deviceIndex: 0,
            amplitude: 1.0,
            sampleRate: sampleRate
        )
        let expectedFrames = Int(
            Double(ActiveCalibrator.fingerprintDurationMs) / 1000.0 * sampleRate
        )

        XCTAssertEqual(probe.count, expectedFrames)
        XCTAssertEqual(ActiveCalibrator.fingerprintGapMs, 0)
        switch ActiveCalibrator.fingerprintProbeProfileName {
        case "comfort-21k":
            XCTAssertGreaterThanOrEqual(ActiveCalibrator.fingerprintFrequencies.min() ?? 0, 20_500)
            XCTAssertLessThanOrEqual(ActiveCalibrator.fingerprintFrequencies.max() ?? 0, 22_500)
        case "legacy-19k":
            XCTAssertGreaterThanOrEqual(ActiveCalibrator.fingerprintFrequencies.min() ?? 0, 19_000)
            XCTAssertLessThanOrEqual(ActiveCalibrator.fingerprintFrequencies.max() ?? 0, 21_000)
        default:
            XCTFail("unexpected probe profile \(ActiveCalibrator.fingerprintProbeProfileName)")
        }

        let symbolFrames = Int(
            Double(ActiveCalibrator.fingerprintSymbolMs) / 1000.0 * sampleRate
        )
        let halfWindow = Int(0.004 * sampleRate)
        var boundarySamplesBelowNoiseFloor = 0
        var boundarySampleAbsSum: Float = 0
        var boundaryCount = 0
        for symbol in 2..<(ActiveCalibrator.fingerprintSymbols - 2) {
            let boundary = symbol * symbolFrames
            let start = max(0, boundary - halfWindow)
            let end = min(probe.count, boundary + halfWindow)
            let boundaryRMS = ActiveCalibrator.rms(Array(probe[start..<end]))
            let boundaryAbs = abs(probe[boundary])
            boundarySampleAbsSum += boundaryAbs
            boundaryCount += 1
            if boundaryAbs < 0.004 {
                boundarySamplesBelowNoiseFloor += 1
            }
            XCTAssertGreaterThan(
                boundaryRMS,
                0.015,
                "symbol boundary \(symbol) should not contain a low-energy gap"
            )
        }
        let meanBoundaryAbs = boundarySampleAbsSum / Float(max(1, boundaryCount))
        XCTAssertGreaterThan(
            meanBoundaryAbs,
            0.015,
            "continuous-phase symbols should not restart near zero at every boundary"
        )
        XCTAssertLessThan(
            Double(boundarySamplesBelowNoiseFloor) / Double(max(1, boundaryCount)),
            0.35,
            "too many symbol boundaries are near zero; the probe may be resetting phase"
        )
    }

    func testAcousticFingerprintDeviceFiveDoesNotRepeatDeviceZeroCodebook() {
        let probe0 = ActiveCalibrator.acousticFingerprintProbe(
            deviceIndex: 0,
            amplitude: 1.0,
            sampleRate: 48_000.0
        )
        let probe5 = ActiveCalibrator.acousticFingerprintProbe(
            deviceIndex: 5,
            amplitude: 1.0,
            sampleRate: 48_000.0
        )

        XCTAssertEqual(probe0.count, probe5.count)
        let totalDifference = zip(probe0, probe5).reduce(Float(0)) {
            $0 + abs($1.0 - $1.1)
        }
        XCTAssertGreaterThan(totalDifference / Float(max(1, probe0.count)), 0.1)
    }

    func testAcousticFingerprintSelfCorrelationLocksToInjectedOffset() {
        let sampleRate = 48_000.0
        let probe = ActiveCalibrator.acousticFingerprintProbe(
            deviceIndex: 1,
            amplitude: 1.0,
            sampleRate: sampleRate
        )
        let offsetFrames = 12_345
        var captured = [Float](repeating: 0, count: offsetFrames)
        captured.append(contentsOf: probe)
        captured.append(contentsOf: [Float](repeating: 0, count: 4096))

        let corr = ActiveCalibrator.fftCrossCorrelation(env: captured, pattern: probe)
        let (idx, _) = ActiveCalibrator.argmax(corr, begin: 0, end: corr.count)

        XCTAssertLessThanOrEqual(abs(idx - offsetFrames), 2)
    }
}
