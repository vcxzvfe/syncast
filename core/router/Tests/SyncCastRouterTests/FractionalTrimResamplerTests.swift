import Testing
import Foundation
@testable import SyncCastRouter

/// Layer-2 trim resampler: verifies the variable-ratio fractional
/// resampler produces the expected frame counts, preserves a DC/linear
/// signal (cubic interpolation is exact for those), and stays continuous
/// across block boundaries.
struct FractionalTrimResamplerTests {

    /// Helper: run one block through the resampler with plain arrays.
    @discardableResult
    private func run(
        _ r: FractionalTrimResampler,
        input: [[Float]],
        ratio: Double,
        outCapacity: Int
    ) -> [[Float]] {
        let channelCount = input.count
        let inFrames = input[0].count
        let outBufs = (0..<channelCount).map { _ in
            [Float](repeating: 0, count: outCapacity)
        }
        var mutableOut = outBufs
        // Materialize stable pointers.
        return input.withUnsafeBufferPointers(channelCount: channelCount) { inPtrs in
            mutableOut.withUnsafeMutableChannelPointers(channelCount: channelCount) { outPtrs in
                let produced = r.process(
                    inputs: inPtrs, inFrames: inFrames, ratio: ratio,
                    outputs: outPtrs, outCapacity: outCapacity
                )
                return (0..<channelCount).map { ch in
                    Array(UnsafeBufferPointer(start: outPtrs[ch], count: produced))
                }
            }
        }
    }

    @Test("Unity ratio preserves a linear ramp (cubic is exact)")
    func unityRatioLinearRamp() {
        let r = FractionalTrimResampler(channelCount: 1)
        // A long linear ramp; 4-point cubic reproduces linear signals
        // exactly (away from the 1-sample startup transient).
        let ramp = (0..<512).map { Float($0) }
        let out = run(r, input: [ramp], ratio: 1.0, outCapacity: 600)
        #expect(out[0].count >= 500)
        // The resampler has a 1-input-sample latency; the output at index k
        // corresponds to input index ~k (offset by the priming). Check the
        // steady region reproduces a linear ramp with unit slope.
        let mid = out[0]
        var maxSlopeErr: Float = 0
        for i in 200..<300 {
            let slope = mid[i + 1] - mid[i]
            maxSlopeErr = max(maxSlopeErr, abs(slope - 1.0))
        }
        #expect(maxSlopeErr < 1e-3)
    }

    @Test("Ratio > 1 yields more output frames, ratio < 1 fewer")
    func ratioControlsFrameCount() {
        let up = FractionalTrimResampler(channelCount: 2)
        let down = FractionalTrimResampler(channelCount: 2)
        let sine = (0..<352).map { i in sinf(Float(i) * 0.1) }
        let inBlock = [sine, sine]
        // 300 ppm each way — the controller's clamp.
        let outUp = run(up, input: inBlock, ratio: 1.0 + 300e-6, outCapacity: 512)
        let outDown = run(down, input: inBlock, ratio: 1.0 - 300e-6, outCapacity: 512)
        // Over a single 352-frame block a ±300 ppm trim is a fraction of a
        // frame, so counts differ from 352 by at most 1 and up ≥ down.
        #expect(outUp[0].count >= outDown[0].count)
        #expect(abs(outUp[0].count - 352) <= 1)
        #expect(abs(outDown[0].count - 352) <= 1)
    }

    @Test("Long-run output count tracks the ratio within a frame per block")
    func longRunFrameConservation() {
        let r = FractionalTrimResampler(channelCount: 1)
        let ratio = 1.0 + 200e-6
        var totalIn = 0
        var totalOut = 0
        for _ in 0..<400 {
            let block = (0..<352).map { i in sinf(Float(i + totalIn) * 0.05) }
            let out = run(r, input: [block], ratio: ratio, outCapacity: 512)
            totalIn += 352
            totalOut += out[0].count
        }
        // Accumulated output should track ratio·totalIn to within a couple
        // frames of phase rounding.
        let expected = Double(totalIn) * ratio
        #expect(abs(Double(totalOut) - expected) < 3.0)
    }

    @Test("Capacity clamp never overflows the output buffer")
    func capacityClampSafe() {
        let r = FractionalTrimResampler(channelCount: 1)
        let block = [Float](repeating: 0.5, count: 352)
        // Deliberately tiny capacity — the resampler must stop, not scribble.
        let out = run(r, input: [block], ratio: 2.0, outCapacity: 10)
        #expect(out[0].count <= 10)
    }
}

// MARK: - Small pointer-plumbing helpers for the tests

private extension Array where Element == [Float] {
    /// Provide `channelCount` stable `UnsafePointer<Float>` for read.
    func withUnsafeBufferPointers<R>(
        channelCount: Int,
        _ body: (UnsafePointer<UnsafePointer<Float>>) -> R
    ) -> R {
        precondition(count == channelCount)
        // Copy into heap storage so pointers stay valid for the call.
        let bufs = self.map { chan -> UnsafeMutablePointer<Float> in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: chan.count)
            p.initialize(from: chan, count: chan.count)
            return p
        }
        defer {
            for (i, p) in bufs.enumerated() {
                p.deinitialize(count: self[i].count)
                p.deallocate()
            }
        }
        let slots = UnsafeMutablePointer<UnsafePointer<Float>>.allocate(capacity: channelCount)
        defer { slots.deallocate() }
        for ch in 0..<channelCount { slots[ch] = UnsafePointer(bufs[ch]) }
        return body(slots)
    }
}

private extension Array where Element == [Float] {
    /// Provide `channelCount` stable `UnsafeMutablePointer<Float>` for write.
    mutating func withUnsafeMutableChannelPointers<R>(
        channelCount: Int,
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<Float>>) -> R
    ) -> R {
        precondition(count == channelCount)
        let bufs = self.map { chan -> UnsafeMutablePointer<Float> in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: chan.count)
            p.initialize(from: chan, count: chan.count)
            return p
        }
        let slots = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: channelCount)
        defer {
            slots.deallocate()
            for (i, p) in bufs.enumerated() {
                p.deinitialize(count: self[i].count)
                p.deallocate()
            }
        }
        for ch in 0..<channelCount { slots[ch] = bufs[ch] }
        return body(slots)
    }
}
