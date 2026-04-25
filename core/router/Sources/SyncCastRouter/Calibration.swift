import Foundation

/// Per-device sync calibration ("tap-along click train", see ADR-004 / sync-brief).
///
/// Strategy (microphone-free default):
///   1. We schedule a series of click pulses (480-frame impulses) into the
///      ring buffer at known wall-clock instants `t_0, t_1, ..., t_N`.
///   2. The user taps a button when they hear the click on a specific
///      device. The UI records the tap wall-clock time `t_tap_i`.
///   3. The offset for that device is `(t_tap_i − t_i) − HUMAN_REACTION_MS`.
///   4. We store the offset as `manualDelayMs` for that device and re-plan.
///
/// The constant `HUMAN_REACTION_MS = 240` is the well-documented mean
/// auditory-reaction time; ±15 ms sigma is acceptable for music.
public final class CalibrationSession: @unchecked Sendable {
    public static let humanReactionMs: Int = 240

    public struct Tap: Sendable {
        public let deviceID: String
        public let clickIndex: Int
        public let tapTimeNs: UInt64
        public init(deviceID: String, clickIndex: Int, tapTimeNs: UInt64) {
            self.deviceID = deviceID
            self.clickIndex = clickIndex
            self.tapTimeNs = tapTimeNs
        }
    }

    public let clickIntervalMs: Int
    public let clickCount: Int
    public private(set) var clickWallTimesNs: [UInt64] = []
    private var taps: [Tap] = []
    private let lock = NSLock()

    public init(clickIntervalMs: Int = 1500, clickCount: Int = 8) {
        precondition(clickIntervalMs > 200)
        precondition(clickCount > 0)
        self.clickIntervalMs = clickIntervalMs
        self.clickCount = clickCount
    }

    public func scheduleClicks(startingAt anchorNs: UInt64) {
        clickWallTimesNs = (0..<clickCount).map { i in
            anchorNs &+ UInt64(i) &* UInt64(clickIntervalMs) &* 1_000_000
        }
    }

    public func recordTap(_ tap: Tap) {
        lock.lock(); defer { lock.unlock() }
        taps.append(tap)
    }

    /// Compute the median offset (ms) for a device, after subtracting the
    /// human-reaction constant. Returns nil if the user gave fewer than 3
    /// taps for the device.
    public func medianOffsetMs(for deviceID: String) -> Int? {
        lock.lock(); defer { lock.unlock() }
        let relevant = taps.filter { $0.deviceID == deviceID }
        guard relevant.count >= 3 else { return nil }
        let offsets: [Int] = relevant.compactMap { tap in
            guard tap.clickIndex < clickWallTimesNs.count else { return nil }
            let target = clickWallTimesNs[tap.clickIndex]
            let raw = Int(Int64(tap.tapTimeNs) - Int64(target)) / 1_000_000
            return raw - Self.humanReactionMs
        }
        return offsets.sorted()[offsets.count / 2]
    }

    /// Generate one stereo click pulse as Float32 PCM (10 ms, 480 frames @
    /// 48 kHz). The pulse is a half-sinusoid envelope around a 1 kHz tone —
    /// crisp, easy for the user to localize, low risk of woofer thump.
    public static func clickPulse(sampleRate: Double = 48_000) -> [[Float]] {
        let frames = Int(sampleRate * 0.010)   // 10 ms
        var ch = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            let t = Double(i) / sampleRate
            let env = sin(.pi * Double(i) / Double(frames - 1))
            let tone = sin(2 * .pi * 1000.0 * t)
            ch[i] = Float(env * tone * 0.5)
        }
        return [ch, ch]
    }
}
