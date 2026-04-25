import XCTest
@testable import SyncCastRouter

final class SchedulerTests: XCTestCase {
    func testPlanPadsFastPathToSlowest() {
        let s = Scheduler(sampleRate: 48_000)
        let plans = s.plan(latencies: [
            .init(deviceID: "local",   transport: .coreAudio, measuredMs: 10),
            .init(deviceID: "airplay", transport: .airplay2,  measuredMs: 1800),
        ], safetyMarginMs: 0)
        let local = plans.first { $0.deviceID == "local" }!
        let air   = plans.first { $0.deviceID == "airplay" }!
        XCTAssertEqual(local.readBackoffFrames, Int((1.790) * 48_000))
        XCTAssertEqual(air.readBackoffFrames, 0)
    }

    func testManualTrimAddsToBackoff() {
        let s = Scheduler(sampleRate: 48_000)
        let plans = s.plan(latencies: [
            .init(deviceID: "a", transport: .coreAudio, measuredMs: 10),
            .init(deviceID: "b", transport: .airplay2,  measuredMs: 1800),
        ], manualTrimMs: ["a": 50], safetyMarginMs: 0)
        let a = plans.first { $0.deviceID == "a" }!
        XCTAssertEqual(a.readBackoffFrames, Int(((1800 - 10 + 50) / 1000.0) * 48_000))
    }

    func testEmptyInputProducesEmptyPlan() {
        XCTAssertEqual(Scheduler().plan(latencies: []).count, 0)
    }
}
