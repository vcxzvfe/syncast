import XCTest
import AudioToolbox
@testable import SyncCastRouter

/// The whole-home legs of the equalizer, measured through the SHIPPING code
/// paths and with no CoreAudio device, no sidecar and no socket:
///
///   * `LocalAirPlayBridge.render()` — the per-device curve on a local speaker
///     fed from OwnTone's fifo broadcast.
///   * `AudioSocketWriter.renderPacket()` — the single AirPlay GROUP curve,
///     applied upstream of OwnTone's fan-out, plus the stage order around it
///     (EQ → master gain → clamp → s16).
///
/// Mirrors `EqualizerBankTests`' impulse method deliberately: the same
/// measurement through a different render path is what proves the bank was
/// wired in, rather than merely present.
final class WholeHomeEqualizerTests: XCTestCase {

    private let rate: Double = 48_000
    private let block = 512
    private let channelCount = 2

    // MARK: - Bridge harness

    /// Drives one `LocalAirPlayBridge` block by block: write `block` frames of
    /// the source signal into its ring, render `block` frames out, collect the
    /// left channel. Exactly the producer/consumer order the real pipeline
    /// runs in (reader task fills the ring, AUHAL pulls).
    private final class BridgeHarness {
        let bridge: LocalAirPlayBridge
        let block: Int
        private(set) var captured: [Float] = []
        private(set) var producedFrames: Int = 0
        private let sourceSlabs: [UnsafeMutablePointer<Float>]
        private let sourcePtrs: UnsafeMutablePointer<UnsafePointer<Float>>
        private let renderSlabs: [UnsafeMutablePointer<Float>]
        private let bufferList: UnsafeMutableAudioBufferListPointer
        private let channelCount: Int

        init(bridge: LocalAirPlayBridge, block: Int, channelCount: Int) {
            self.bridge = bridge
            self.block = block
            self.channelCount = channelCount
            var slabs: [UnsafeMutablePointer<Float>] = []
            for _ in 0..<channelCount {
                let p = UnsafeMutablePointer<Float>.allocate(capacity: block)
                p.initialize(repeating: 0, count: block)
                slabs.append(p)
            }
            sourceSlabs = slabs
            let ptrs = UnsafeMutablePointer<UnsafePointer<Float>>
                .allocate(capacity: channelCount)
            for i in 0..<channelCount { ptrs[i] = UnsafePointer(slabs[i]) }
            sourcePtrs = ptrs
            var render: [UnsafeMutablePointer<Float>] = []
            let list = AudioBufferList.allocate(maximumBuffers: channelCount)
            for i in 0..<channelCount {
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

        func run(blocks: Int, signal: (Int) -> Float) {
            for _ in 0..<blocks {
                for i in 0..<block {
                    let value = signal(producedFrames + i)
                    for slab in sourceSlabs { slab[i] = value }
                }
                bridge.ring.write(
                    channels: UnsafePointer(sourcePtrs), frames: block
                )
                producedFrames += block
                let status = bridge.render(
                    frames: block, ioData: bufferList.unsafeMutablePointer
                )
                XCTAssertEqual(status, noErr)
                captured.append(
                    contentsOf: UnsafeBufferPointer(
                        start: renderSlabs[0], count: block
                    )
                )
            }
        }
    }

    private func makeBridge() -> LocalAirPlayBridge {
        LocalAirPlayBridge(
            deviceID: 0,
            deviceUID: "unit-test-bridge-\(UUID().uuidString)",
            socketPath: URL(fileURLWithPath: "/dev/null"),
            renderSampleRate: rate
        )
    }

    private func graphic(_ gains: [Double: Double], trimDb: Double = 0) -> EqualizerSettings {
        var settings = EqualizerSettings.graphicFlat
        settings.trimDb = trimDb
        for index in settings.bands.indices {
            if let gain = gains[settings.bands[index].frequency] {
                settings.bands[index].gainDb = gain
            }
        }
        return settings
    }

    /// |H| in dB at each frequency, from the impulse response the harness
    /// captured. `from` is the index the response starts at.
    private func responseDb(
        _ captured: [Float],
        from start: Int,
        frequencies: [Double],
        amplitude: Double,
        frames: Int
    ) -> [Double] {
        let end = min(captured.count, start + frames)
        let response = captured[start..<end].map(Double.init)
        return frequencies.map { hz in
            let omega = 2 * Double.pi * hz / rate
            var real = 0.0
            var imaginary = 0.0
            for (index, sample) in response.enumerated() {
                let phase = omega * Double(index)
                real += sample * cos(phase)
                imaginary -= sample * sin(phase)
            }
            let magnitude = sqrt(real * real + imaginary * imaginary) / amplitude
            return 20 * log10(max(magnitude, 1e-12))
        }
    }

    // MARK: - Bridge: the flat path is untouched

    /// A bridge with no curve must hand the AUHAL exactly what the ring holds.
    /// One impulse in, one impulse out, same value, nothing before or after —
    /// which is the bit-identical claim stated as an equality rather than a
    /// tolerance.
    func testFlatBridgeLeavesTheSignalBitIdentical() {
        let harness = BridgeHarness(
            bridge: makeBridge(), block: block, channelCount: channelCount
        )
        let amplitude: Float = 0.25
        harness.run(blocks: 40) { _ in 0 }
        let impulseFrame = harness.producedFrames + 64
        harness.run(blocks: 40) { $0 == impulseFrame ? amplitude : 0 }

        let nonZero = harness.captured.enumerated().filter { $0.element != 0 }
        XCTAssertEqual(nonZero.count, 1, "flat bridge changed the signal")
        XCTAssertEqual(nonZero.first?.element, amplitude)
    }

    // MARK: - Bridge: a boosted band is audible through render()

    /// +6 dB at 1 kHz, measured from the impulse response the bridge's render
    /// callback actually produced, against the analytic curve.
    func testBoostedBandReachesItsGainThroughTheBridgeRenderPath() {
        let centres = EqualizerLimits.graphicFrequencies
        let settings = graphic([1_000: 6])
        let bridge = makeBridge()
        XCTAssertTrue(bridge.setEqualizer(settings))
        XCTAssertTrue(bridge.equalizerIsEngaged)

        let harness = BridgeHarness(
            bridge: bridge, block: block, channelCount: channelCount
        )
        let amplitude: Double = 0.25
        // Settle the ring and retire the bank's 20 ms crossfade over silence,
        // so what follows is the settled curve and not a mixture.
        harness.run(blocks: 40) { _ in 0 }
        let impulseFrame = harness.producedFrames + 64
        // 32_768 response frames at 512 per block, plus the ~100 ms the bridge
        // deliberately trails the writer by.
        harness.run(blocks: 90) { $0 == impulseFrame ? Float(amplitude) : 0 }

        guard let onset = harness.captured.firstIndex(where: {
            abs($0) > Float(amplitude) * 0.1
        }) else {
            return XCTFail("no impulse response came out of the bridge")
        }
        XCTAssertGreaterThan(
            harness.captured.count - onset, 32_768,
            "not enough response captured to measure"
        )
        let measured = responseDb(
            harness.captured, from: onset, frequencies: centres,
            amplitude: amplitude, frames: 32_768
        )
        for (index, hz) in centres.enumerated() {
            XCTAssertEqual(
                measured[index],
                settings.responseDb(atHz: hz, sampleRate: rate),
                accuracy: 0.35,
                "bridge render response at \(hz) Hz"
            )
        }
        // And the point of the exercise: the dialled band really is +6 dB.
        let oneKilohertz = centres.firstIndex(of: 1_000)!
        XCTAssertEqual(measured[oneKilohertz], 6, accuracy: 0.35)
    }

    func testRepublishingTheSameCurveOnABridgeIsANoOp() {
        let bridge = makeBridge()
        let settings = graphic([125: -4])
        XCTAssertTrue(bridge.setEqualizer(settings))
        XCTAssertFalse(bridge.setEqualizer(settings))
        bridge.resetEqualizer()
        XCTAssertFalse(bridge.equalizerIsEngaged)
    }

    // MARK: - Writer: the AirPlay group curve

    private func makeWriter() -> AudioSocketWriter {
        AudioSocketWriter(
            ring: RingBuffer(channelCount: 2, capacityFrames: 1 << 14),
            socketPath: URL(fileURLWithPath: "/dev/null")
        )
    }

    /// Push `packets` packets of a sine through the writer's packet stage and
    /// return the interleaved s16 output of the last `measurePackets` of them.
    private func pushSine(
        writer: AudioSocketWriter,
        hz: Double,
        amplitude: Double,
        packets: Int,
        measurePackets: Int
    ) -> [Int16] {
        let frames = writer.frameCount
        let channels = writer.channelCount
        let slabs: [UnsafeMutablePointer<Float>] = (0..<channels).map { _ in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            p.initialize(repeating: 0, count: frames)
            return p
        }
        let table = UnsafeMutablePointer<UnsafeMutablePointer<Float>>
            .allocate(capacity: channels)
        for ch in 0..<channels { table[ch] = slabs[ch] }
        var packet = [Int16](repeating: 0, count: frames * channels)
        var collected: [Int16] = []
        var phase = 0.0
        let increment = 2 * Double.pi * hz / writer.sampleRate
        for index in 0..<packets {
            for f in 0..<frames {
                let sample = Float(amplitude * sin(phase))
                phase += increment
                for ch in 0..<channels { slabs[ch][f] = sample }
            }
            packet.withUnsafeMutableBufferPointer { out in
                writer.renderPacket(
                    planar: table,
                    packet: out.baseAddress!,
                    masterRampFrames: 480
                )
            }
            if index >= packets - measurePackets {
                collected.append(contentsOf: packet)
            }
        }
        table.deallocate()
        for slab in slabs { slab.deinitialize(count: frames); slab.deallocate() }
        return collected
    }

    /// RMS of an s16 buffer, in full-scale units.
    private func rms(_ samples: [Int16]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(0.0) { acc, value in
            let scaled = Double(value) / 32_767.0
            return acc + scaled * scaled
        }
        return sqrt(sum / Double(samples.count))
    }

    /// A sine through the group EQ comes out changed by exactly the analytic
    /// amount — measured on the s16 the socket would carry, not on an
    /// intermediate.
    func testGroupEqualizerChangesTheWireLevelByTheAnalyticAmount() {
        let hz = 1_000.0
        let amplitude = 0.2
        let settings = graphic([1_000: 6])

        let flatWriter = makeWriter()
        let reference = pushSine(
            writer: flatWriter, hz: hz, amplitude: amplitude,
            packets: 40, measurePackets: 20
        )
        let writer = makeWriter()
        XCTAssertTrue(writer.setEqualizer(settings))
        XCTAssertTrue(writer.equalizerIsEngaged)
        let equalised = pushSine(
            writer: writer, hz: hz, amplitude: amplitude,
            packets: 40, measurePackets: 20
        )

        let measuredDb = 20 * log10(rms(equalised) / max(rms(reference), 1e-12))
        XCTAssertEqual(
            measuredDb,
            settings.responseDb(atHz: hz, sampleRate: writer.sampleRate),
            accuracy: 0.3,
            "group EQ did not change the wire level by the dialled amount"
        )
        XCTAssertEqual(writer.equalizerClipCount, 0, "no clipping at 0.2 FS + 6 dB")
    }

    /// A flat group curve leaves the wire format exactly as it was: same
    /// samples, no clipping, nothing published to the bank.
    func testFlatGroupEqualizerLeavesTheWireFormatUnchanged() {
        let reference = pushSine(
            writer: makeWriter(), hz: 1_000, amplitude: 0.5,
            packets: 4, measurePackets: 4
        )
        let writer = makeWriter()
        // The first publish on a fresh bank always lands (it has no record of
        // what it is holding); the second one is the no-op that keeps a replan
        // from spending a crossfade.
        XCTAssertTrue(writer.setEqualizer(.flat))
        XCTAssertFalse(
            writer.setEqualizer(.flat), "re-publishing flat must be a no-op"
        )
        let equalised = pushSine(
            writer: writer, hz: 1_000, amplitude: 0.5,
            packets: 4, measurePackets: 4
        )
        XCTAssertEqual(reference, equalised)
        XCTAssertFalse(writer.equalizerIsEngaged)
    }

    /// A boost on already-hot material must clamp and be COUNTED, and the s16
    /// it produces must never wrap: a wrapped sample is a full-scale sign flip,
    /// i.e. the loudest possible click on every receiver at once.
    func testHotSourcePlusBoostClampsIsCountedAndNeverWraps() {
        let writer = makeWriter()
        writer.setEqualizer(graphic([1_000: 12], trimDb: 6))
        let output = pushSine(
            writer: writer, hz: 1_000, amplitude: 0.95,
            packets: 20, measurePackets: 10
        )
        XCTAssertGreaterThan(
            writer.equalizerClipCount, 0,
            "a +18 dB chain on a 0.95 FS sine has to hit the limiter"
        )
        XCTAssertFalse(output.isEmpty)
        // Full scale is 32_767 by construction of the cast; anything at
        // -32_768, or a sign that flips between adjacent clipped samples,
        // would be a wrap.
        XCTAssertGreaterThanOrEqual(output.min() ?? 0, -32_767)
        XCTAssertLessThanOrEqual(output.max() ?? 0, 32_767)
        // The clipped peaks are still peaks: a wrapped positive peak would
        // read as a large NEGATIVE value next to its neighbours.
        let peak = output.max() ?? 0
        XCTAssertGreaterThan(peak, 30_000, "the boosted sine should be pinned high")
    }

    /// The master fader is downstream of the group EQ: halving it halves the
    /// equalised signal rather than re-shaping it.
    func testMasterFaderAttenuatesAfterTheGroupEqualizer() {
        let settings = graphic([1_000: 6])
        let loud = makeWriter()
        loud.setEqualizer(settings)
        let reference = pushSine(
            writer: loud, hz: 1_000, amplitude: 0.2,
            packets: 40, measurePackets: 20
        )
        let quiet = makeWriter()
        quiet.setEqualizer(settings)
        quiet.seedMasterGain(0.5)
        let attenuated = pushSine(
            writer: quiet, hz: 1_000, amplitude: 0.2,
            packets: 40, measurePackets: 20
        )
        let measuredDb = 20 * log10(rms(attenuated) / max(rms(reference), 1e-12))
        XCTAssertEqual(measuredDb, -6.02, accuracy: 0.1)
    }

    // MARK: - The reserved pseudo-UID

    /// The group curve rides in the same UID-keyed map as the devices, which
    /// is what makes it persist and re-apply like one. The key therefore has
    /// to be something no CoreAudio device can present.
    func testGroupPseudoUIDIsNamespaced() {
        XCTAssertTrue(
            Router.airPlayGroupEqualizerUID.hasPrefix("syncast."),
            "the reserved key must be namespaced against real device UIDs"
        )
        XCTAssertFalse(Router.airPlayGroupEqualizerUID.isEmpty)
    }
}
