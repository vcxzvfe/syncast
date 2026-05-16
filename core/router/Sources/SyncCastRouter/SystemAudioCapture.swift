import Foundation

/// Common interface for the system-audio capture backend.
///
/// Downstream routing only needs a live producer that writes 48 kHz stereo
/// Float32 planar samples into `ringBuffer`. Keeping Router on this protocol
/// lets ScreenCaptureKit and Core Audio Process Tap implementations coexist
/// without duplicating the local-output or sidecar paths.
public protocol SystemAudioCapture: AnyObject, Sendable {
    var backendName: String { get }
    var ringBuffer: RingBuffer { get }
    var sampleRate: Double { get }
    var channelCount: Int { get }
    var onUnexpectedStop: (@Sendable () -> Void)? { get set }
    var tickCount: UInt64 { get }

    func start() async throws
    func stop()
    func stopAndWait() async
    func diagnosticReport() -> String
}

public extension SystemAudioCapture {
    func stopAndWait() async {
        stop()
    }
}

public final class UnavailableSystemAudioCapture: @unchecked Sendable, SystemAudioCapture {
    public let backendName: String
    public let ringBuffer: RingBuffer
    public let sampleRate: Double
    public let channelCount: Int
    public var onUnexpectedStop: (@Sendable () -> Void)?
    public private(set) var tickCount: UInt64 = 0

    private let reason: String

    public init(
        backendName: String,
        reason: String,
        sampleRate: Double = 48_000,
        channelCount: Int = 2,
        ringCapacityFrames: Int = 1 << 18
    ) {
        self.backendName = backendName
        self.reason = reason
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.ringBuffer = RingBuffer(
            channelCount: channelCount,
            capacityFrames: ringCapacityFrames
        )
    }

    public func start() async throws {
        throw NSError(domain: "SyncCastCapture", code: 1, userInfo: [
            NSLocalizedDescriptionKey: reason
        ])
    }

    public func stop() {}

    public func stopAndWait() async {}

    public func diagnosticReport() -> String {
        "backend=\(backendName) unavailable reason=\"\(reason)\""
    }
}
