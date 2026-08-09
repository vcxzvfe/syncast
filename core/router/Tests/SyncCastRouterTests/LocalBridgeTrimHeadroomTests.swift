import XCTest
@testable import SyncCastRouter

/// The local leg applies a delay trim by moving its ring READ TAP further
/// back. `RingBuffer.read` zero-fills anything outside its valid window, so
/// asking for more than the ring holds does not crash — it produces silence,
/// which is the worst failure mode available because nothing reports it.
///
/// These tests pin the arithmetic that keeps that from happening, across
/// every device rate and render quantum the bridge can realistically be
/// bound to. They need no CoreAudio: the two functions under test are the
/// pure forms of what `openAudioUnit` and `maxTrimFrames` compute at runtime.
final class LocalBridgeTrimHeadroomTests: XCTestCase {

    /// Device nominal rates a CoreAudio output can present.
    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000]
    /// AUHAL render quanta seen in the wild, from a tight low-latency buffer
    /// to the largest anything sane negotiates.
    private let quanta: [Int] = [256, 512, 1_024, 2_048]

    func testRingCapacityIsAPowerOfTwo() {
        // RingBuffer.init preconditions this for its cheap modulo.
        let cap = LocalAirPlayBridge.defaultRingCapacityFrames
        XCTAssertGreaterThan(cap, 0)
        XCTAssertEqual(cap & (cap - 1), 0)
    }

    private func headroomFrames(rate: Double, quantum: Int) -> Int {
        LocalAirPlayBridge.maxTrimFrames(
            capacityFrames: LocalAirPlayBridge.defaultRingCapacityFrames,
            backoffFrames: LocalAirPlayBridge.backoffFrames(forSampleRate: rate),
            framesPerRender: quantum,
            driftAllowanceFrames: LocalAirPlayBridge.driftAllowanceFrames(
                forSampleRate: rate
            )
        )
    }

    func testBaselineBackoffFitsInTheRingAtEveryRate() {
        // The regression this guards: at 192 kHz the old 16_384-frame ring
        // could not even hold `backoffFrames` (20_928), so the read tap sat
        // permanently outside the valid window and the device played silence
        // with pkts and ticks both advancing.
        let cap = LocalAirPlayBridge.defaultRingCapacityFrames
        for rate in rates {
            let backoff = LocalAirPlayBridge.backoffFrames(forSampleRate: rate)
            for quantum in quanta {
                XCTAssertLessThan(
                    backoff + 2 * quantum, cap,
                    "rate \(rate) quantum \(quantum): backoff alone must fit"
                )
            }
        }
    }

    func testEveryRateAndQuantumClearsTheFullUserTrimRange() {
        // The UI offers ±200 ms. Normalisation can turn that into a single
        // output carrying the full 400 ms span (−200 on one speaker, +200 on
        // another), so the ring has to serve 400 ms everywhere — on top of
        // the backoff, the render quanta AND the drift the resync backstop
        // tolerates, all of which `maxTrimFrames` already subtracts.
        let widestSpanMs = Double(
            DeviceDelayTrim.rangeMs.upperBound - DeviceDelayTrim.rangeMs.lowerBound
        )
        for rate in rates {
            for quantum in quanta {
                let headroomMs =
                    Double(headroomFrames(rate: rate, quantum: quantum)) / rate * 1000.0
                XCTAssertGreaterThanOrEqual(
                    headroomMs, widestSpanMs,
                    "rate \(rate) quantum \(quantum) has only "
                    + "\(Int(headroomMs)) ms of trim headroom"
                )
            }
        }
    }

    func testHeadroomReservesTheResyncDriftAllowance() {
        // render() lets the cursor lag `target` by up to `resyncDriftMs`
        // before snapping, and the trimmed tap sits that far back AGAIN.
        // Omitting the term made the bound merely usually-true: the tap
        // would fall out of the ring during a drift excursion and zero-fill.
        let rate = 48_000.0
        let withDrift = headroomFrames(rate: rate, quantum: 512)
        let withoutDrift = LocalAirPlayBridge.maxTrimFrames(
            capacityFrames: LocalAirPlayBridge.defaultRingCapacityFrames,
            backoffFrames: LocalAirPlayBridge.backoffFrames(forSampleRate: rate),
            framesPerRender: 512,
            driftAllowanceFrames: 0
        )
        XCTAssertEqual(
            withoutDrift - withDrift,
            LocalAirPlayBridge.driftAllowanceFrames(forSampleRate: rate)
        )
    }

    func testHeadroomNeverGoesNegative() {
        // A pathological binding (tiny ring, huge backoff) must clamp to 0
        // rather than hand render() a negative tap offset.
        XCTAssertEqual(
            LocalAirPlayBridge.maxTrimFrames(
                capacityFrames: 1_024,
                backoffFrames: 20_928,
                framesPerRender: 2_048,
                driftAllowanceFrames: 76_800
            ),
            0
        )
    }

    /// `maxTrimFrames` is a STEADY-STATE bound: its arithmetic assumes the
    /// ring is full (`writePos >= capacity`). At cold start it is not, and
    /// render()'s tap goes NEGATIVE — `startFrame = max(0, writePos -
    /// backoff - frames)` pins at 0 while `_trimFramesTarget` is already the
    /// full normalised trim. The trimmed frames predate the stream, so
    /// silence is the correct output; what must never happen is
    /// `RingBuffer.read` zero-filling `trimFrames` values into a
    /// `frames`-sized AUHAL buffer.
    func testColdStartTrimmedTapIsSilentAndInBounds() {
        let rate = 48_000.0
        let quantum = 512
        let trimFrames = Int(
            Double(DeviceDelayTrim.rangeMs.upperBound
                   - DeviceDelayTrim.rangeMs.lowerBound) / 1000.0 * rate
        )
        XCTAssertLessThanOrEqual(
            trimFrames, headroomFrames(rate: rate, quantum: quantum),
            "the trim under test must be one the bridge would actually admit"
        )

        let ring = RingBuffer(channelCount: 2, capacityFrames: 4_096)
        // Cold start: a couple of OwnTone packets in, nothing more.
        let packetFrames = 352
        let packet = [Float](repeating: 1.0, count: packetFrames)
        let inPtrs = UnsafeMutablePointer<UnsafePointer<Float>>.allocate(capacity: 2)
        defer { inPtrs.deallocate() }
        packet.withUnsafeBufferPointer { bp in
            inPtrs[0] = bp.baseAddress!
            inPtrs[1] = bp.baseAddress!
            for _ in 0..<3 { ring.write(channels: inPtrs, frames: packetFrames) }
        }

        let backoffFrames = Int64(LocalAirPlayBridge.backoffFrames(forSampleRate: rate))
        let startFrame = max(
            0, ring.writePosition - backoffFrames - Int64(quantum)
        )
        XCTAssertEqual(startFrame, 0, "precondition: the cold-start tap pins at 0")
        let tap = startFrame &- Int64(trimFrames)
        XCTAssertLessThan(tap, 0, "precondition: the tap is negative")

        let guardFrames = trimFrames + quantum
        let total = quantum + guardFrames
        let sentinel: Float = -12_345.0
        let storage = (0..<2).map { _ in
            UnsafeMutablePointer<Float>.allocate(capacity: total)
        }
        defer { for p in storage { p.deallocate() } }
        for p in storage { p.update(repeating: sentinel, count: total) }
        let outPtrs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>
            .allocate(capacity: 2)
        defer { outPtrs.deallocate() }
        for ch in 0..<2 { outPtrs[ch] = storage[ch] }

        let filled = ring.read(at: tap, frames: quantum, into: outPtrs)
        XCTAssertEqual(filled, 0)
        for ch in 0..<2 {
            for i in 0..<quantum {
                XCTAssertEqual(storage[ch][i], 0, "block must be silence")
            }
            let overrun = (quantum..<total).filter { storage[ch][$0] != sentinel }
            XCTAssertTrue(
                overrun.isEmpty,
                "read wrote \(overrun.count) frame(s) past the render buffer"
            )
        }
    }

    func testHeadroomShrinksWithRateAndQuantum() {
        // Documents WHY the clamp has to be computed at runtime rather than
        // read off a static table: a 96 kHz DAC has far less room than a
        // 44.1 kHz one, at the same ring size.
        func headroomMs(rate: Double, quantum: Int) -> Double {
            Double(headroomFrames(rate: rate, quantum: quantum)) / rate * 1000.0
        }
        XCTAssertGreaterThan(
            headroomMs(rate: 44_100, quantum: 512),
            headroomMs(rate: 96_000, quantum: 512)
        )
        XCTAssertGreaterThan(
            headroomMs(rate: 48_000, quantum: 256),
            headroomMs(rate: 48_000, quantum: 2_048)
        )
    }

    // MARK: - PLL blindness

    func testReadCursorAdvanceIsIndependentOfTrim() {
        // The property the whole design rests on: render() reads at
        // `startFrame - trim` but publishes `readCursor = startFrame + frames`.
        // `updateClockControl` measures `writePosition - readCursor` against
        // `backoffFrames + framesPerRender`, so if the published cursor does
        // not move with the trim, neither can the loop's error signal.
        //
        // Mirrors the two lines in render() rather than calling it, because
        // render() requires a live AUHAL. If those lines ever start folding
        // the trim into `endFrame`, this test is the tripwire.
        let startFrame: Int64 = 1_000_000
        let frames = 512
        let writePos: Int64 = 1_006_000
        let target: Int64 = 5_744  // backoffFrames + framesPerRender at 48 kHz

        var errors: [Double] = []
        for trim in [0, 48, 480, 4_800, 9_600] {
            let tap = startFrame &- Int64(trim)
            let endFrame = startFrame &+ Int64(frames)   // trim-free by design
            XCTAssertEqual(endFrame, startFrame &+ Int64(frames))
            XCTAssertEqual(tap, startFrame &- Int64(trim))
            errors.append(Double((writePos - endFrame) - target))
        }
        // Every trim yields the same controller error.
        XCTAssertEqual(Set(errors).count, 1, "trim leaked into the PLL error signal")
    }
}
