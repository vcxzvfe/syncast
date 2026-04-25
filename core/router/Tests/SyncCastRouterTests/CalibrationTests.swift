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
}
