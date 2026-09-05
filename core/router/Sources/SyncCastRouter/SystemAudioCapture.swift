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

    /// Non-nil when this backend stamps every delivered block with the
    /// capture hardware's own clock.
    ///
    /// The LAN link builds its packet timeline from these when they exist
    /// (`HostAnchoredRingClock`) and falls back to inferring it from the
    /// write cursor when they do not (`RingWriteClock`). Nothing else in the
    /// router cares, which is why this is a defaulted requirement rather
    /// than a change every backend has to answer.
    var captureAnchors: CaptureAnchorPublisher? { get }

    func start() async throws
    func stop()
    func stopAndWait() async
    func diagnosticReport() -> String
}

public extension SystemAudioCapture {
    func stopAndWait() async {
        stop()
    }

    /// Backends that cannot say when a block was captured get the fallback
    /// timeline, not a wrong one.
    var captureAnchors: CaptureAnchorPublisher? { nil }
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
