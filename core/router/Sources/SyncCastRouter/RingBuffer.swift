import Foundation
import SyncCastAtomic

/// Single-producer / multi-consumer lock-free PCM ring buffer.
///
/// Layout: planar Float32, `channelCount` channels of `capacityFrames` each.
/// The producer is the BlackHole IOProc (real-time CoreAudio thread); the
/// consumers are (a) the per-device AUHAL render callbacks, also real-time,
/// and (b) the audio-socket writer, a non-RT background task. To avoid
/// priority inversion the cursor is published with C11 atomic
/// release/acquire semantics — no Darwin lock is ever held by the IOProc.
///
/// Write rules:
///   * exactly one thread calls `write` (the IOProc); calling from multiple
///     threads is undefined.
///   * after copying the frames into storage, the writer publishes the new
///     cursor with `sc_atomic_store_release`. Readers observing the new
///     cursor with acquire ordering are guaranteed to also see the new
///     frames in storage.
///
/// Read rules:
///   * any thread may call `read(at:frames:into:)` and `writePosition`.
///   * the consumer's `at` is its own monotonic cursor; the buffer
///     zero-fills frames outside the valid window.
public final class RingBuffer: @unchecked Sendable {
    public let channelCount: Int
    public let capacityFrames: Int
    private let storage: [UnsafeMutablePointer<Float>]
    private let writeCursorAtom: UnsafeMutablePointer<SCAtomicInt64>

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
        let atom = UnsafeMutablePointer<SCAtomicInt64>.allocate(capacity: 1)
        sc_atomic_init(atom, 0)
        self.writeCursorAtom = atom
    }

    deinit {
        for p in storage {
            p.deinitialize(count: capacityFrames)
            p.deallocate()
        }
        writeCursorAtom.deallocate()
    }

    /// Current write cursor (frames since start). Acquire ordering: any
    /// frames committed before this cursor are visible to the reader.
    public var writePosition: Int64 {
        sc_atomic_load_acquire(writeCursorAtom)
    }

    /// Producer: append `frames` to the ring. The producer reads the
    /// current cursor with relaxed ordering (it owns the cursor) and
    /// publishes the new value with release ordering after the copy.
    public func write(channels: UnsafePointer<UnsafePointer<Float>>, frames: Int) {
        let cap = capacityFrames
        let cursor = sc_atomic_load_acquire(writeCursorAtom)  // relaxed-equivalent for sole writer
        let start = Int(cursor & Int64(cap - 1))
        let firstChunk = min(frames, cap - start)
        let secondChunk = frames - firstChunk
        for ch in 0..<channelCount {
            let src = channels[ch]
            storage[ch].advanced(by: start).update(from: src, count: firstChunk)
            if secondChunk > 0 {
                storage[ch].update(from: src.advanced(by: firstChunk), count: secondChunk)
            }
        }
        sc_atomic_store_release(writeCursorAtom, cursor &+ Int64(frames))
    }

    /// Consumer: read `frames` starting at the absolute frame `at`.
    /// Out-of-window frames are zero-filled. Returns the number of frames
    /// genuinely backed by ring data.
    @discardableResult
    public func read(
        at startFrame: Int64,
        frames: Int,
        into out: UnsafePointer<UnsafeMutablePointer<Float>>
    ) -> Int {
        let cap = capacityFrames
        let writePos = sc_atomic_load_acquire(writeCursorAtom)
        let lowerValid = max(0, writePos - Int64(cap))
        let upperValid = writePos
        // Compute the intersection of [startFrame, startFrame + frames)
        // with [lowerValid, upperValid).
        let validStart = max(startFrame, lowerValid)
        let validEnd = min(startFrame &+ Int64(frames), upperValid)
        let validFrames = max(0, Int(validEnd - validStart))
        let leadingZeros = Int(max(0, validStart - startFrame))
        let trailingZeros = frames - leadingZeros - validFrames

        // Zero-fill leading.
        if leadingZeros > 0 {
            for ch in 0..<channelCount {
                out[ch].update(repeating: 0, count: leadingZeros)
            }
        }
        // Copy the valid window in up to two chunks (handle wrap once).
        if validFrames > 0 {
            let absStart = validStart
            let bufStart = Int(absStart & Int64(cap - 1))
            let firstChunk = min(validFrames, cap - bufStart)
            for ch in 0..<channelCount {
                out[ch].advanced(by: leadingZeros)
                    .update(from: storage[ch].advanced(by: bufStart),
                            count: firstChunk)
                if validFrames > firstChunk {
                    out[ch].advanced(by: leadingZeros + firstChunk)
                        .update(from: storage[ch],
                                count: validFrames - firstChunk)
                }
            }
        }
        // Zero-fill trailing.
        if trailingZeros > 0 {
            for ch in 0..<channelCount {
                out[ch].advanced(by: leadingZeros + validFrames)
                    .update(repeating: 0, count: trailingZeros)
            }
        }
        return validFrames
    }
}
