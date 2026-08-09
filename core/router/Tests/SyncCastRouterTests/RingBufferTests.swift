import XCTest
@testable import SyncCastRouter

private func writeRing(_ rb: RingBuffer, _ buffers: [[Float]]) {
    let frames = buffers[0].count
    let ptrs = UnsafeMutablePointer<UnsafePointer<Float>>.allocate(capacity: buffers.count)
    defer { ptrs.deallocate() }
    var holders: [UnsafeBufferPointer<Float>] = []
    for b in buffers {
        let bp = b.withUnsafeBufferPointer { $0 }
        holders.append(bp)
    }
    for (i, bp) in holders.enumerated() { ptrs[i] = bp.baseAddress! }
    rb.write(channels: ptrs, frames: frames)
}

private func readRing(_ rb: RingBuffer, at: Int64, frames: Int, channels: Int) -> ([[Float]], Int) {
    let outPtrs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: channels)
    defer { outPtrs.deallocate() }
    var arrays = (0..<channels).map { _ in [Float](repeating: -1, count: frames) }
    for ch in 0..<channels {
        arrays[ch].withUnsafeMutableBufferPointer { outPtrs[ch] = $0.baseAddress! }
    }
    let filled = rb.read(at: at, frames: frames, into: outPtrs)
    return (arrays, filled)
}

final class RingBufferTests: XCTestCase {
    func testWriteThenReadRoundTrip() {
        let rb = RingBuffer(channelCount: 2, capacityFrames: 1024)
        let frames = 256
        let ch0 = (0..<frames).map { Float($0) }
        let ch1 = (0..<frames).map { Float(-$0) }
        writeRing(rb, [ch0, ch1])
        let (out, filled) = readRing(rb, at: 0, frames: frames, channels: 2)
        XCTAssertEqual(filled, frames)
        XCTAssertEqual(out[0], ch0)
        XCTAssertEqual(out[1], ch1)
    }

    func testReadBeforeWriteCursorIsZero() {
        let rb = RingBuffer(channelCount: 1, capacityFrames: 256)
        writeRing(rb, [[Float](repeating: 1.0, count: 64)])
        let (out, filled) = readRing(rb, at: -100, frames: 32, channels: 1)
        XCTAssertEqual(filled, 0)
        XCTAssertTrue(out[0].allSatisfy { $0 == 0 })
    }

    /// `read` must never write more than `frames` per channel, whatever `at`
    /// is. It runs on the CoreAudio RT thread straight into the AUHAL's
    /// `mData`, so an over-long zero-fill is an out-of-bounds write into a
    /// buffer the ring does not own.
    ///
    /// Driven with a guard region rather than a Swift `Array`: an overrun
    /// into an array's storage is silent, an overrun into the sentinel tail
    /// is not. `at` values here mirror `LocalAirPlayBridge.render()` at cold
    /// start, where `startFrame` is still 0 while the normalised delay trim
    /// already asks for its full value (400 ms at 48 kHz = 19_200 frames).
    func testReadNeverWritesPastTheCallersBuffer() {
        let cases: [(name: String, at: Int64, frames: Int)] = [
            ("cold-start tap under a 400 ms trim", -19_200, 512),
            ("tap one block before the window", -512, 512),
            ("tap far past the write cursor", 1_000_000, 512),
            ("tap straddling the window start", -8, 512),
        ]
        for c in cases {
            let rb = RingBuffer(channelCount: 2, capacityFrames: 4096)
            writeRing(rb, [[Float](repeating: 1.0, count: 1056),
                           [Float](repeating: 1.0, count: 1056)])

            let channels = 2
            let guardFrames = 4096
            let total = c.frames + guardFrames
            let sentinel: Float = -12_345.0
            let storage = (0..<channels).map { _ in
                UnsafeMutablePointer<Float>.allocate(capacity: total)
            }
            defer { for p in storage { p.deallocate() } }
            for p in storage { p.update(repeating: sentinel, count: total) }

            let outPtrs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>
                .allocate(capacity: channels)
            defer { outPtrs.deallocate() }
            for ch in 0..<channels { outPtrs[ch] = storage[ch] }

            _ = rb.read(at: c.at, frames: c.frames, into: outPtrs)

            for ch in 0..<channels {
                let overrun = (c.frames..<total)
                    .filter { storage[ch][$0] != sentinel }
                if !overrun.isEmpty {
                    XCTFail(
                        "\(c.name): RingBuffer.read wrote \(overrun.count) "
                        + "frame(s) past the caller's \(c.frames)-frame buffer "
                        + "(ch \(ch), up to +\((overrun.last ?? 0) - c.frames + 1))"
                    )
                }
            }
        }
    }

    func testFullyOutOfWindowTapIsAllSilence() {
        let rb = RingBuffer(channelCount: 1, capacityFrames: 4096)
        writeRing(rb, [[Float](repeating: 1.0, count: 1056)])
        let (out, filled) = readRing(rb, at: -19_200, frames: 512, channels: 1)
        XCTAssertEqual(filled, 0)
        XCTAssertTrue(out[0].allSatisfy { $0 == 0 })
    }

    func testWrappingPreservesData() {
        let cap = 64
        let rb = RingBuffer(channelCount: 1, capacityFrames: cap)
        writeRing(rb, [[Float](repeating: 1.0, count: cap)])
        writeRing(rb, [[Float](repeating: 2.0, count: cap)])
        let (out, filled) = readRing(rb, at: Int64(cap), frames: cap, channels: 1)
        XCTAssertEqual(filled, cap)
        XCTAssertTrue(out[0].allSatisfy { $0 == 2.0 })
    }
}
