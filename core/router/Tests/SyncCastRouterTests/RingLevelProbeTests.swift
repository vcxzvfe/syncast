import XCTest
@testable import SyncCastRouter

final class RingLevelProbeTests: XCTestCase {

    private func write(_ ring: RingBuffer, left: [Float], right: [Float]) {
        precondition(left.count == right.count)
        left.withUnsafeBufferPointer { l in
            right.withUnsafeBufferPointer { r in
                let ptrs = UnsafeMutablePointer<UnsafePointer<Float>>.allocate(capacity: 2)
                defer { ptrs.deallocate() }
                ptrs[0] = l.baseAddress!
                ptrs[1] = r.baseAddress!
                ring.write(channels: ptrs, frames: left.count)
            }
        }
    }

    private func constant(_ value: Float, _ frames: Int) -> [Float] {
        [Float](repeating: value, count: frames)
    }

    func testFirstLookOnlyAnchorsAndIgnoresTheBacklog() {
        let ring = RingBuffer(channelCount: 2, capacityFrames: 1 << 14)
        write(ring, left: constant(0.9, 1000), right: constant(0.9, 1000))
        let probe = RingLevelProbe()
        XCTAssertNil(probe.measure(ring: ring, maxFrames: 48_000),
                     "audio from before the probe started looking must not count")
        XCTAssertNil(probe.measure(ring: ring, maxFrames: 48_000),
                     "no new frames since the anchor")
    }

    func testReportsThePeakOfBothChannels() {
        let ring = RingBuffer(channelCount: 2, capacityFrames: 1 << 14)
        let probe = RingLevelProbe()
        _ = probe.measure(ring: ring, maxFrames: 48_000)
        var right = constant(0, 6000)
        right[5000] = -0.5   // only on the right channel, past one chunk
        write(ring, left: constant(0.01, 6000), right: right)
        let peak = try? XCTUnwrap(probe.measure(ring: ring, maxFrames: 48_000))
        XCTAssertEqual(peak ?? 0, 0.5, accuracy: 1e-6,
                       "channel 0 alone would have missed this")
    }

    func testSilenceIsZeroNotNil() {
        let ring = RingBuffer(channelCount: 2, capacityFrames: 1 << 14)
        let probe = RingLevelProbe()
        _ = probe.measure(ring: ring, maxFrames: 48_000)
        write(ring, left: constant(0, 512), right: constant(0, 512))
        XCTAssertEqual(probe.measure(ring: ring, maxFrames: 48_000), 0,
                       "a player rendering zeros is a paused player, not a stopped producer")
    }

    func testOnlyTheNewestWindowIsReadWhenTheCallerFallsBehind() {
        let ring = RingBuffer(channelCount: 2, capacityFrames: 1 << 14)
        let probe = RingLevelProbe()
        _ = probe.measure(ring: ring, maxFrames: 1000)
        write(ring, left: constant(0.8, 4000), right: constant(0.8, 4000))
        write(ring, left: constant(0.1, 1000), right: constant(0.1, 1000))
        let peak = probe.measure(ring: ring, maxFrames: 1000)
        XCTAssertEqual(peak ?? 0, 0.1, accuracy: 1e-6,
                       "the loud stretch is older than the window")
    }

    func testSwitchingRingsReanchors() {
        let first = RingBuffer(channelCount: 2, capacityFrames: 1 << 12)
        let second = RingBuffer(channelCount: 2, capacityFrames: 1 << 12)
        let probe = RingLevelProbe()
        _ = probe.measure(ring: first, maxFrames: 4096)
        write(second, left: constant(0.7, 256), right: constant(0.7, 256))
        XCTAssertNil(probe.measure(ring: second, maxFrames: 4096),
                     "a new ring's history predates this probe")
        write(second, left: constant(0.2, 256), right: constant(0.2, 256))
        XCTAssertEqual(probe.measure(ring: second, maxFrames: 4096) ?? 0, 0.2, accuracy: 1e-6)
    }

    func testDbfs() {
        XCTAssertEqual(RingLevelProbe.dbfs(1), 0, accuracy: 1e-9)
        XCTAssertEqual(RingLevelProbe.dbfs(0.001), -60, accuracy: 1e-6)
        XCTAssertEqual(RingLevelProbe.dbfs(0), -.infinity)
        XCTAssertEqual(RingLevelProbe.dbfs(.nan), -.infinity)
    }
}

final class PlaybackRouteAudibilityTests: XCTestCase {
    func testMutedOffOrZeroRowsAreSilent() {
        XCTAssertTrue(PlaybackRouteAudibility.audible(DeviceRouting(deviceID: "d", volume: 0.4)))
        XCTAssertFalse(PlaybackRouteAudibility.audible(DeviceRouting(deviceID: "d", muted: true)))
        XCTAssertFalse(PlaybackRouteAudibility.audible(DeviceRouting(deviceID: "d", enabled: false)))
        XCTAssertFalse(PlaybackRouteAudibility.audible(DeviceRouting(deviceID: "d", volume: 0)))
    }

    func testWholeHomeZeroPercentIsStillAudible() {
        // The bridge's curve puts 0 % at −30 dB, not at silence; treating it
        // as silent would let the display sleep under playing music.
        XCTAssertTrue(PlaybackRouteAudibility.audible(DeviceRouting(deviceID: "d", volume: 0), wholeHome: true))
        XCTAssertEqual(
            PlaybackRouteAudibility.audible(DeviceRouting(deviceID: "d", volume: 0), wholeHome: true),
            Router.localBridgeGain(for: DeviceRouting(deviceID: "d", volume: 0)) > PlaybackRouteAudibility.silentVolumeCeiling,
            "must agree with what the bridge actually applies"
        )
        XCTAssertFalse(PlaybackRouteAudibility.audible(DeviceRouting(deviceID: "d", muted: true), wholeHome: true))
        XCTAssertFalse(PlaybackRouteAudibility.audible(DeviceRouting(deviceID: "d", enabled: false), wholeHome: true))
    }
}
