import XCTest
@testable import SyncCastRouter

final class RingBufferTests: XCTestCase {
    func testWriteThenReadRoundTrip() {
        let rb = RingBuffer(channelCount: 2, capacityFrames: 1024)
        let frames = 256
        var ch0 = [Float](repeating: 0, count: frames)
        var ch1 = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            ch0[i] = Float(i)
            ch1[i] = Float(-i)
        }
        ch0.withUnsafeBufferPointer { p0 in
            ch1.withUnsafeBufferPointer { p1 in
                rb.write(channels: [p0.baseAddress!, p1.baseAddress!], frames: frames)
            }
        }
        var out0 = [Float](repeating: -999, count: frames)
        var out1 = [Float](repeating: -999, count: frames)
        let filled = out0.withUnsafeMutableBufferPointer { o0 in
            out1.withUnsafeMutableBufferPointer { o1 in
                rb.read(at: 0, frames: frames, into: [o0.baseAddress!, o1.baseAddress!])
            }
        }
        XCTAssertEqual(filled, frames)
        XCTAssertEqual(out0, ch0)
        XCTAssertEqual(out1, ch1)
    }

    func testReadBeforeWriteCursorIsZero() {
        let rb = RingBuffer(channelCount: 1, capacityFrames: 256)
        let buf = [Float](repeating: 1.0, count: 64)
        buf.withUnsafeBufferPointer {
            rb.write(channels: [$0.baseAddress!], frames: 64)
        }
        // Read before window: should be zero-filled.
        var out = [Float](repeating: -1, count: 32)
        let filled = out.withUnsafeMutableBufferPointer { o in
            rb.read(at: -100, frames: 32, into: [o.baseAddress!])
        }
        XCTAssertEqual(filled, 0)
        XCTAssertTrue(out.allSatisfy { $0 == 0 })
    }

    func testWrappingPreservesData() {
        let cap = 64
        let rb = RingBuffer(channelCount: 1, capacityFrames: cap)
        let one = [Float](repeating: 1.0, count: cap)
        let two = [Float](repeating: 2.0, count: cap)
        one.withUnsafeBufferPointer { rb.write(channels: [$0.baseAddress!], frames: cap) }
        two.withUnsafeBufferPointer { rb.write(channels: [$0.baseAddress!], frames: cap) }
        var out = [Float](repeating: -1, count: cap)
        let filled = out.withUnsafeMutableBufferPointer { o in
            rb.read(at: Int64(cap), frames: cap, into: [o.baseAddress!])
        }
        XCTAssertEqual(filled, cap)
        XCTAssertTrue(out.allSatisfy { $0 == 2.0 })
    }
}
