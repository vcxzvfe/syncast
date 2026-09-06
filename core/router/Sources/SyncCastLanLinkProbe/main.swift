import Foundation
import SyncCastRouter

/// Drive a real `LanReceiverOutput` + `LanReceiverLink` against a receiver on
/// the LAN from a SYNTHETIC ring (a 440 Hz tone with capture-style host
/// anchors), so the link's timing can be measured without any system-audio
/// capture permission. Prints the sender's diagnostic line and the receiver's
/// reported stats once a second.
///
///   swift run -c release SyncCastLanLinkProbe --host 192.0.2.10 --port 47100 \
///       --token <token> [--seconds 120] [--target 90] [--gain 0.02] [--bursty]
final class SyntheticRing: @unchecked Sendable {
    static let blockFrames = 512
    let ring = RingBuffer(channelCount: 2, capacityFrames: 1 << 18)
    let anchors = CaptureAnchorPublisher(sampleRate: 48_000)
    private let queue = DispatchQueue(label: "probe.ring", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var epochNs: UInt64 = 0
    private var written: Int64 = 0
    private var phase: Double = 0
    private var holdNs: Double = 0
    private let bursty: Bool
    init(bursty: Bool) { self.bursty = bursty }

    func start() {
        epochNs = Clock.nowNs()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(1), leeway: .microseconds(200))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }
    func stop() { timer?.cancel(); timer = nil }

    private func tick() {
        let elapsed = Double(Clock.nowNs() &- epochNs)
        while true {
            let releasable = Int64(max(0, elapsed - holdNs) / 1_000_000_000 * 48_000)
            guard written + Int64(Self.blockFrames) <= releasable else { return }
            writeBlock()
            holdNs = bursty ? Double.random(in: 0...4_000_000) : 0
        }
    }

    private func writeBlock() {
        let frames = Self.blockFrames
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        let step = 2 * Double.pi * 440 / 48_000
        for index in 0..<frames {
            left[index] = Float(sin(phase) * 0.25 + 0.05)
            right[index] = Float(sin(phase) * -0.25 - 0.05)
            phase += step
            if phase > 2 * Double.pi { phase -= 2 * Double.pi }
        }
        let startFrame = written
        left.withUnsafeBufferPointer { l in
            right.withUnsafeBufferPointer { r in
                let table = UnsafeMutablePointer<UnsafePointer<Float>>.allocate(capacity: 2)
                defer { table.deallocate() }
                table[0] = l.baseAddress!
                table[1] = r.baseAddress!
                ring.write(channels: table, frames: frames)
            }
        }
        written = startFrame + Int64(frames)
        anchors.publish(
            frame: startFrame,
            hostNs: epochNs &+ UInt64((Double(startFrame) / 48_000 * 1_000_000_000).rounded())
        )
    }
}

func arg(_ name: String, _ fallback: String) -> String {
    let a = CommandLine.arguments
    if let i = a.firstIndex(of: name), i + 1 < a.count { return a[i + 1] }
    return fallback
}
let host = arg("--host", "")
let port = UInt16(arg("--port", "47100")) ?? 47100
let token = arg("--token", "")
let seconds = Int(arg("--seconds", "120")) ?? 120
let target = Int(arg("--target", "90")) ?? 90
let gain = Double(arg("--gain", "0.02")) ?? 0.02
let bursty = CommandLine.arguments.contains("--bursty")
guard !host.isEmpty, !token.isEmpty else {
    print("usage: --host <ip> --port <p> --token <t> [--seconds N] [--target ms] [--gain 0..1] [--bursty]")
    exit(2)
}
RouterLog.sink = { line in FileHandle.standardError.write(Data(line.utf8)) }

let source = SyntheticRing(bursty: bursty)
let link = LanReceiverLink(
    receiverUID: "lan:probe",
    endpoint: .hostPort(host: host, port: port),
    token: token,
    senderName: "SyncCastLanLinkProbe",
    streamID: UInt32.random(in: 1...UInt32.max),
    targetMs: target
)
let floorFrames = RingFloorPolicy.frames(ms: RingFloorPolicy.resolveSinkFloorMs().ms, sampleRate: 48_000)
let output = LanReceiverOutput(
    receiverUID: "lan:probe",
    displayName: "probe",
    ring: source.ring,
    sampleRate: 48_000,
    channelCount: 2,
    ringFloorFrames: floorFrames,
    link: link,
    captureAnchors: source.anchors
)
source.start()
output.start()
link.setGain(linear: gain, muted: false)
print("probe: streaming to \(host):\(port) for \(seconds)s, target \(target) ms, floor \(floorFrames) frames, gain \(gain), \(bursty ? "bursty" : "smooth") producer")
for second in 1...seconds {
    Thread.sleep(forTimeInterval: 1)
    let snap = link.snapshot
    let stats = snap.stats
    let rx = stats.map {
        "rx late=\($0.late) lost=\($0.lost) underrun=\($0.underrun) buf=\(String(format: "%.1f", $0.bufferMs))ms ratio=\(String(format: "%+.1f", ($0.ratio - 1) * 1e6))ppm"
    } ?? "rx -"
    print("[\(second)s] \(output.diagnosticSummary()) | \(rx)")
}
output.stop()
source.stop()
Thread.sleep(forTimeInterval: 0.5)
print("probe: done")
