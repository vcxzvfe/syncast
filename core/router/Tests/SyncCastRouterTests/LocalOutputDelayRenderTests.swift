import XCTest
import AudioToolbox
@testable import SyncCastRouter

/// End-to-end proof that a per-device delay actually delays that device, run
/// through the SHIPPING render callback with a hand-built `AudioBufferList`
/// and no CoreAudio device.
///
/// The signal is a single impulse. Its index in each pair's output stream is
/// unambiguous, so "pair 1 lags pair 0 by exactly N samples" is an equality
/// rather than a correlation with a tolerance.
final class LocalOutputDelayRenderTests: XCTestCase {

    private let rate: Double = 48_000
    private let block = 512
    private let channelCount = 2
    /// Two stereo pairs — what an aggregate over two physical devices looks
    /// like to the render callback.
    private let outputChannelCount = 4
    private let floorFrames = 4_800

    // MARK: - Harness

    /// Drives one `LocalOutput` block by block: write `block` frames of the
    /// source signal into the ring, render `block` frames out, and collect the
    /// left channel of each output pair.
    private final class Harness {
        let ring: RingBuffer
        let output: LocalOutput
        let block: Int
        let outputChannelCount: Int
        private(set) var captured: [[Float]]
        /// Absolute frame index of the next sample the producer will write.
        private(set) var producedFrames: Int = 0
        private let sourceSlabs: [UnsafeMutablePointer<Float>]
        private let sourcePtrs: UnsafeMutablePointer<UnsafePointer<Float>>
        private let renderSlabs: [UnsafeMutablePointer<Float>]
        private let bufferList: UnsafeMutableAudioBufferListPointer

        init(
            ring: RingBuffer,
            output: LocalOutput,
            block: Int,
            channelCount: Int,
            outputChannelCount: Int
        ) {
            self.ring = ring
            self.output = output
            self.block = block
            self.outputChannelCount = outputChannelCount
            self.captured = Array(repeating: [], count: outputChannelCount)
            var slabs: [UnsafeMutablePointer<Float>] = []
            for _ in 0..<channelCount {
                let p = UnsafeMutablePointer<Float>.allocate(capacity: block)
                p.initialize(repeating: 0, count: block)
                slabs.append(p)
            }
            sourceSlabs = slabs
            let ptrs = UnsafeMutablePointer<UnsafePointer<Float>>.allocate(capacity: channelCount)
            for i in 0..<channelCount { ptrs[i] = UnsafePointer(slabs[i]) }
            sourcePtrs = ptrs
            var render: [UnsafeMutablePointer<Float>] = []
            let list = AudioBufferList.allocate(maximumBuffers: outputChannelCount)
            for i in 0..<outputChannelCount {
                let p = UnsafeMutablePointer<Float>.allocate(capacity: block)
                p.initialize(repeating: 0, count: block)
                render.append(p)
                list[i] = AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(block * MemoryLayout<Float>.size),
                    mData: UnsafeMutableRawPointer(p)
                )
            }
            renderSlabs = render
            bufferList = list
        }

        deinit {
            for p in sourceSlabs { p.deinitialize(count: block); p.deallocate() }
            sourcePtrs.deallocate()
            for p in renderSlabs { p.deinitialize(count: block); p.deallocate() }
            free(bufferList.unsafeMutablePointer)
        }

        /// One producer block followed by one consumer block, which is the
        /// order the real pipeline runs in.
        func step(signal: (Int) -> Float) {
            for i in 0..<block {
                let value = signal(producedFrames + i)
                for slab in sourceSlabs { slab[i] = value }
            }
            ring.write(channels: UnsafePointer(sourcePtrs), frames: block)
            producedFrames += block
            let status = output.render(frames: block, ioData: bufferList.unsafeMutablePointer)
            XCTAssertEqual(status, noErr)
            for ch in 0..<outputChannelCount {
                captured[ch].append(contentsOf: UnsafeBufferPointer(start: renderSlabs[ch], count: block))
            }
        }

        func run(blocks: Int, signal: (Int) -> Float) {
            for _ in 0..<blocks { step(signal: signal) }
        }

        /// Index of the first sample above `threshold`, or nil.
        func firstPeakIndex(channel: Int, threshold: Float = 0.5) -> Int? {
            captured[channel].firstIndex { abs($0) > threshold }
        }
    }

    private func makeHarness(
        outputChannels: Int? = nil
    ) -> Harness {
        let ring = RingBuffer(channelCount: channelCount, capacityFrames: 1 << 18)
        let channels = outputChannels ?? outputChannelCount
        let output = LocalOutput(
            deviceID: 0,
            deviceUID: "unit-test-local-output-\(UUID().uuidString)",
            ring: ring,
            sampleRate: rate,
            channelCount: channelCount,
            outputChannelCount: channels,
            ringFloorFrames: floorFrames
        )
        return Harness(
            ring: ring, output: output, block: block,
            channelCount: channelCount, outputChannelCount: channels
        )
    }

    /// Silence until `at`, one sample of full scale there, silence after.
    private func impulse(at frame: Int) -> (Int) -> Float {
        { index in index == frame ? 1.0 : 0.0 }
    }

    // MARK: - The claim

    /// Pair 0 at 0 frames, pair 1 at 480 frames (10 ms): the same impulse must
    /// leave pair 1 exactly 480 samples later.
    func testPairWithA480FrameDelayLagsByExactly480Samples() {
        let harness = makeHarness()
        harness.output.setPairDelays([0: 0, 1: 480])
        // Fill the ring past the floor + window, and let the crossfade that
        // the offset change starts run to completion, before the impulse.
        let settleBlocks = 40
        harness.run(blocks: settleBlocks) { _ in 0 }
        let impulseFrame = harness.producedFrames + 64
        harness.run(blocks: 40, signal: impulse(at: impulseFrame))

        guard let lead = harness.firstPeakIndex(channel: 0),
              let lagged = harness.firstPeakIndex(channel: 2)
        else {
            return XCTFail("impulse never reached both pairs")
        }
        XCTAssertEqual(lagged - lead, 480)
        // Right channels carry the same source, so they must agree.
        XCTAssertEqual(harness.firstPeakIndex(channel: 1), lead)
        XCTAssertEqual(harness.firstPeakIndex(channel: 3), lagged)
    }

    /// The default: no offsets means the two pairs are sample-aligned, which is
    /// what the pre-feature build did.
    func testWithoutDelaysBothPairsPlayTheSameSample() {
        let harness = makeHarness()
        harness.run(blocks: 40) { _ in 0 }
        let impulseFrame = harness.producedFrames + 64
        harness.run(blocks: 40, signal: impulse(at: impulseFrame))

        guard let lead = harness.firstPeakIndex(channel: 0),
              let other = harness.firstPeakIndex(channel: 2)
        else {
            return XCTFail("impulse never reached both pairs")
        }
        XCTAssertEqual(lead, other)
    }

    /// Delaying one pair must not move the other. This is the cursor-shift
    /// invariant, measured end to end rather than on the bank alone.
    func testDelayingOnePairLeavesTheOtherWhereItWas() {
        let reference = makeHarness()
        reference.run(blocks: 40) { _ in 0 }
        let referenceImpulse = reference.producedFrames + 64
        reference.run(blocks: 40, signal: impulse(at: referenceImpulse))
        guard let referenceIndex = reference.firstPeakIndex(channel: 0) else {
            return XCTFail("reference impulse never rendered")
        }

        let delayed = makeHarness()
        delayed.run(blocks: 20) { _ in 0 }
        delayed.output.setPairDelays([1: 960])
        delayed.run(blocks: 20) { _ in 0 }
        let delayedImpulse = delayed.producedFrames + 64
        delayed.run(blocks: 40, signal: impulse(at: delayedImpulse))
        guard let delayedIndex = delayed.firstPeakIndex(channel: 0) else {
            return XCTFail("delayed-run impulse never rendered")
        }

        XCTAssertEqual(delayedIndex, referenceIndex)
    }

    // MARK: - Health of the delayed path

    /// The added backlog must come out of the ring floor, not out of the
    /// producer's headroom: a delayed pair reads OLDER audio, so nothing may
    /// underrun and nothing may resync once the stream is running.
    func testDelayedRenderingNeitherUnderrunsNorResyncs() {
        let harness = makeHarness()
        harness.output.setPairDelays([0: 0, 1: 4_800])
        // Warm-up is expected to underrun: the producer has not yet written
        // floor + window + block frames, so there is nothing behind the cursor
        // to read. The claim is about steady state, so the counters start
        // there — the same reading `LocalOutput`'s own documentation gives
        // them ("these numbers stopped moving", not "these numbers are zero").
        harness.run(blocks: 60) { _ in 0 }
        harness.output.resetGlitchCounters()
        harness.run(blocks: 200) { index in
            // A slow ramp, so a resync would show up as a step if anyone looked.
            Float((index % 4_800)) / 4_800
        }
        XCTAssertEqual(harness.output.underrunCount, 0)
        XCTAssertEqual(harness.output.resyncCount, 0)
        XCTAssertEqual(harness.output.idleBlockCount, 0)
        if let water = harness.output.minWaterLevelFrames {
            // Water level is measured for the pair reading HIGHEST, so the
            // floor is what is left after the delay is paid for.
            XCTAssertGreaterThanOrEqual(water, Int64(block))
        }
    }

    /// A moved offset is crossfaded rather than stepped. With a constant
    /// full-scale input every sample of the fade sits between the two source
    /// values, so nothing may leave [0, 1] — a step would still be in range,
    /// but a botched mix (double-applied gain, uninitialised scratch) would not.
    func testOffsetChangeStaysInsideTheSignalRange() {
        let harness = makeHarness()
        harness.run(blocks: 30) { _ in 1.0 }
        harness.output.setPairDelays([1: 720])
        harness.run(blocks: 30) { _ in 1.0 }
        let tail = harness.captured[2].suffix(30 * block)
        XCTAssertFalse(tail.contains { $0 < -0.001 || $0 > 1.001 })
        XCTAssertEqual(harness.output.underrunCount, 0)
    }

    /// Individual mode has one pair, so a delay there has nothing to align
    /// against and must leave the render path exactly as it was.
    func testSinglePairOutputIsUnaffected() {
        let harness = makeHarness(outputChannels: 2)
        harness.output.setPairDelays([0: 0])
        harness.run(blocks: 40) { _ in 0 }
        let impulseFrame = harness.producedFrames + 64
        harness.run(blocks: 40, signal: impulse(at: impulseFrame))
        XCTAssertNotNil(harness.firstPeakIndex(channel: 0))
        XCTAssertEqual(harness.output.resyncCount, 0)
    }
}
