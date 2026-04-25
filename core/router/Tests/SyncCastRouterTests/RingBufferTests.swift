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
