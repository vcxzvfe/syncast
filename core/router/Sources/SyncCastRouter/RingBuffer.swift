import Foundation
import os.lock

/// Single-producer / multi-consumer lock-free PCM ring buffer.
///
/// Layout: planar Float32, `channelCount` channels of `capacityFrames` each.
/// The producer is the BlackHole IOProc; consumers are the per-device AUHAL
/// render callbacks, each holding its own read cursor at a frame offset that
/// implements per-device delay compensation.
///
/// Thread-safety: `write` is single-producer. `read(at:into:)` is safe for
/// many consumers as long as `at` is a stable per-consumer cursor and the
/// producer has not lapped the consumer.
public final class RingBuffer: @unchecked Sendable {
    public let channelCount: Int
    public let capacityFrames: Int
    private let storage: [UnsafeMutablePointer<Float>]
    private var writeCursor: Int64 = 0          // monotonic, in frames
    private let writeLock = OSAllocatedUnfairLock()

    public init(channelCount: Int, capacityFrames: Int) {
        precondition(channelCount > 0)
        precondition(capacityFrames > 0)
        precondition((capacityFrames & (capacityFrames - 1)) == 0,
                     "capacityFrames must be a power of two for cheap modulo")
        self.channelCount = channelCount
        self.capacityFrames = capacityFrames
        self.storage = (0..<channelCount).map { _ in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: capacityFrames)
            p.initialize(repeating: 0, count: capacityFrames)
            return p
        }
    }

    deinit {
        for p in storage {
            p.deinitialize(count: capacityFrames)
            p.deallocate()
        }
    }

    /// Current write cursor (frames since start). Read once per consumer call.
    public var writePosition: Int64 {
        writeLock.withLock { writeCursor }
    }

    /// Producer: append `frames` to the ring. Wraps automatically.
    public func write(channels: [UnsafePointer<Float>], frames: Int) {
        precondition(channels.count == channelCount)
        let cap = capacityFrames
        writeLock.withLock {
            let start = Int(writeCursor & Int64(cap - 1))
            let firstChunk = min(frames, cap - start)
            let secondChunk = frames - firstChunk
            for ch in 0..<channelCount {
                storage[ch].advanced(by: start).update(from: channels[ch], count: firstChunk)
                if secondChunk > 0 {
                    storage[ch].update(from: channels[ch].advanced(by: firstChunk), count: secondChunk)
                }
            }
            writeCursor &+= Int64(frames)
        }
    }

    /// Consumer: read `frames` ending at the absolute frame `at` (inclusive of
    /// the lower edge). Out-of-range frames are zero-filled. Returns the
    /// number of frames that were genuinely backed by ring data.
    @discardableResult
    public func read(
        at startFrame: Int64,
        frames: Int,
        into out: [UnsafeMutablePointer<Float>]
    ) -> Int {
        precondition(out.count == channelCount)
        let cap = capacityFrames
        let writePos = writePosition
        let lowerValid = max(0, writePos - Int64(cap))
        let upperValid = writePos
        var filled = 0

        for f in 0..<frames {
            let abs = startFrame &+ Int64(f)
            if abs >= lowerValid && abs < upperValid {
                let idx = Int(abs & Int64(cap - 1))
                for ch in 0..<channelCount {
                    out[ch][f] = storage[ch][idx]
                }
                filled += 1
            } else {
                for ch in 0..<channelCount {
                    out[ch][f] = 0
                }
            }
        }
        return filled
    }
}
