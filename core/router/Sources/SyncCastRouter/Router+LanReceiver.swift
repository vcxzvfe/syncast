import Foundation
import SyncCastDiscovery

/// One receiver's state, as the UI sees it.
public struct LanReceiverStatus: Sendable, Equatable {
    public let deviceID: String
    public let uid: String
    public let displayName: String
    public let targetMs: Int
    public let link: LanLinkSnapshot
    public let packetsSent: UInt64
    public let producerResyncCount: Int
    public let ringClockPpm: Double

    public init(
        deviceID: String,
        uid: String,
        displayName: String,
        targetMs: Int,
        link: LanLinkSnapshot,
        packetsSent: UInt64,
        producerResyncCount: Int,
        ringClockPpm: Double
    ) {
        self.deviceID = deviceID
        self.uid = uid
        self.displayName = displayName
        self.targetMs = targetMs
        self.link = link
        self.packetsSent = packetsSent
        self.producerResyncCount = producerResyncCount
        self.ringClockPpm = ringClockPpm
    }
}

/// The LAN receiver legs of the local Stereo path.
///
/// A receiver is an output like any other: the user toggles its row, the
/// Router opens a leg, and the leg reads the same capture ring the local
/// AUHALs read. What it is NOT is an AirPlay receiver — different protocol,
/// different clock model, different latency class — so it lives in stereo mode
/// only and never touches the whole-home fan-out.
///
/// # Why it needs a path with a ring
///
/// The leg is a ring consumer. Direct Stereo has no ring at all (the HAL
/// renders straight into a public aggregate and this process never sees the
/// samples), so a receiver cannot be driven from it. The sink path and the
/// ScreenCaptureKit path both feed a ring, and both work.
extension Router {

    // MARK: - Configuration pushed from the menubar

    /// Replace the whole receiver-UID → token map.
    ///
    /// The token is a shared secret and is never logged, never put in the
    /// diagnostics line, and never persisted by the Router — the menubar owns
    /// storage (in the keychain) and pushes the map in full.
    public func setLanReceiverTokens(_ tokensByUID: [String: String]) {
        var sanitized: [String: String] = [:]
        for (uid, token) in tokensByUID where !uid.isEmpty {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            sanitized[uid] = trimmed
        }
        guard sanitized != lanReceiverTokensByUID else { return }
        lanReceiverTokensByUID = sanitized
        // A token change means a different session: the link has to be rebuilt
        // rather than nudged, because `hello` carries it and is sent once.
        lanReceiverConfigurationRevision &+= 1
    }

    /// Replace the whole receiver-UID → playout-target map.
    public func setLanReceiverTargets(_ msByUID: [String: Int]) {
        var sanitized: [String: Int] = [:]
        for (uid, ms) in msByUID where !uid.isEmpty {
            sanitized[uid] = LanPcmWire.clampTargetMs(ms)
        }
        guard sanitized != lanReceiverTargetMsByUID else { return }
        lanReceiverTargetMsByUID = sanitized
        for output in lanReceiverOutputs.values {
            output.link.setTargetMs(targetMs(forUID: output.receiverUID))
        }
        // The local legs have to move with it — see `LanAlignmentPlanner`.
        applyLocalPairDelays()
    }

    /// The target actually in force for a receiver.
    func targetMs(forUID uid: String) -> Int {
        LanPcmWire.clampTargetMs(lanReceiverTargetMsByUID[uid] ?? LanPcmWire.defaultTargetMs)
    }

    /// Receivers this Router currently drives, for the UI.
    public func lanReceiverStatuses() -> [String: LanReceiverStatus] {
        var result: [String: LanReceiverStatus] = [:]
        for (deviceID, output) in lanReceiverOutputs {
            let counters = output.counters
            result[deviceID] = LanReceiverStatus(
                deviceID: deviceID,
                uid: output.receiverUID,
                displayName: output.displayName,
                targetMs: output.link.targetMs,
                link: output.link.snapshot,
                packetsSent: counters.packetsSent,
                producerResyncCount: counters.reanchorCount,
                ringClockPpm: counters.ringClockPpm
            )
        }
        return result
    }

    /// UIDs of the LAN legs currently open. Used by the per-device render
    /// features to decide whether to offer their controls on a receiver row.
    func lanReceiverOutputUIDs() -> [String] {
        lanReceiverOutputs.values.map(\.receiverUID)
    }

    func lanReceiverChannelMatrixClipCounts() -> [String: Int64] {
        var result: [String: Int64] = [:]
        for output in lanReceiverOutputs.values {
            result[output.receiverUID] = output.channelMatrixClipCount
        }
        return result
    }

    // MARK: - Reconcile

    /// Whether a LAN leg can run at all right now.
    ///
    /// Deliberately not "is the mode stereo": Direct Stereo is stereo and has
    /// no ring. The UI asks the same question before offering the row.
    public var lanReceiversAreSupported: Bool {
        mode == .stereo && stereoPath != .direct
    }

    /// Open, close and re-key the LAN legs to match the routing snapshot.
    ///
    /// Idempotent: a receiver whose row, token and target are unchanged keeps
    /// its live link, because tearing one down costs a full TCP handshake plus
    /// a jitter-buffer refill and would be audible.
    func reconcileLanReceivers(devices: [Device]) {
        guard lanReceiversAreSupported else {
            tearDownLanReceivers()
            return
        }
        let enabled = devices.filter {
            $0.transport == .lanReceiver && (routing[$0.id]?.enabled ?? false)
        }
        var wanted: Set<String> = []
        for device in enabled {
            guard let uid = device.persistenceKey,
                  let serviceName = device.lanServiceName
            else { continue }
            guard let token = lanReceiverTokensByUID[uid] else {
                // No token yet: the row says "needs pairing" and nothing is
                // opened. Refusing to connect without one is not politeness —
                // the receiver would close on us and we would retry forever.
                continue
            }
            wanted.insert(device.id)
            if let existing = lanReceiverOutputs[device.id],
               lanReceiverRevisionByDeviceID[device.id] == lanReceiverConfigurationRevision {
                existing.link.setTargetMs(targetMs(forUID: uid))
                continue
            }
            // Either new, or its token changed under it.
            lanReceiverOutputs.removeValue(forKey: device.id)?.stop()
            let link = LanReceiverLink(
                receiverUID: uid,
                endpoint: .bonjour(
                    name: serviceName, domain: device.lanServiceDomain
                ),
                token: token,
                senderName: Self.lanSenderName,
                streamID: lanStreamID,
                targetMs: targetMs(forUID: uid)
            )
            let source = activeCapture
            let output = LanReceiverOutput(
                receiverUID: uid,
                displayName: device.name,
                ring: source.ringBuffer,
                sampleRate: source.sampleRate,
                channelCount: source.channelCount,
                ringFloorFrames: ringFloorFrames(logWarnings: false),
                link: link
            )
            output.start()
            lanReceiverOutputs[device.id] = output
            lanReceiverRevisionByDeviceID[device.id] = lanReceiverConfigurationRevision
            RouterLog.write(
                "[Router] LAN leg opened for \(uid.prefix(24)) target=\(targetMs(forUID: uid))ms\n"
            )
        }
        for (deviceID, output) in lanReceiverOutputs where !wanted.contains(deviceID) {
            output.stop()
            lanReceiverOutputs.removeValue(forKey: deviceID)
            lanReceiverRevisionByDeviceID.removeValue(forKey: deviceID)
            RouterLog.write("[Router] LAN leg closed for \(output.receiverUID.prefix(24))\n")
        }
        applyLanReceiverSettings()
    }

    func tearDownLanReceivers() {
        guard !lanReceiverOutputs.isEmpty else { return }
        for (_, output) in lanReceiverOutputs { output.stop() }
        lanReceiverOutputs.removeAll()
        lanReceiverRevisionByDeviceID.removeAll()
    }

    /// A name for the `hello` message. Generic on purpose: it is transmitted
    /// to another machine and shown in its log, and the machine's own host
    /// name is not something to leak onto the wire.
    static var lanSenderName: String { "SyncCast" }

    // MARK: - Per-leg settings

    /// Push everything a live leg needs: the master level, the per-device
    /// balance, and the three render features. Idempotent throughout.
    func applyLanReceiverSettings() {
        guard !lanReceiverOutputs.isEmpty else { return }
        let master = lanMasterGain()
        for (deviceID, output) in lanReceiverOutputs {
            let route = routing[deviceID] ?? DeviceRouting(deviceID: deviceID)
            output.link.setGain(linear: Double(master.linear), muted: master.muted)
            output.setBalance(amplitude: lanBalanceAmplitude(for: route))
            output.setEqualizer(equalizerSettings(forUID: output.receiverUID))
            output.setStereoImage(stereoImageSettings(forUID: output.receiverUID))
            output.setChannelMatrix(channelMatrixSettingsByUID[output.receiverUID] ?? .stereo)
        }
    }

    func applyLanReceiverChannelMatrices() {
        for output in lanReceiverOutputs.values {
            output.setChannelMatrix(channelMatrixSettingsByUID[output.receiverUID] ?? .stereo)
        }
    }

    /// The master level this leg should carry, as linear amplitude.
    ///
    /// On the sink path that is the macOS system volume, converted through the
    /// sink's own dB law — the same number `SystemSinkVolumeLaw` hands the
    /// software-gain backend, so a receiver tracks the system slider exactly
    /// like a local speaker with no hardware volume. On the ScreenCaptureKit
    /// path there is no system master at all and the leg runs at unity, with
    /// the per-device balance as the only level control.
    func lanMasterGain() -> (linear: Float, muted: Bool) {
        guard systemSinkPathIsLive else { return (1, false) }
        return (
            SystemSinkVolumeLaw.wholeHomeMasterAmplitude(
                scalar: sinkMasterVolume, muted: sinkMasterMuted, law: sinkVolumeLaw
            ),
            sinkMasterMuted
        )
    }

    /// The per-device fader, as linear amplitude. Applied on THIS side, before
    /// packetising, because the receiver has exactly one level control and the
    /// master is already using it.
    func lanBalanceAmplitude(for route: DeviceRouting) -> Float {
        guard !route.muted else { return 0 }
        return sinkVolumeLaw.amplitude(forScalar: max(0, min(1, route.volume)))
    }

    // MARK: - Alignment

    /// Extra hold every local leg needs so it plays the same ring frame as the
    /// LAN receivers, in frames. Zero when no LAN leg is live.
    ///
    /// When several receivers are enabled with different targets, the LARGEST
    /// wins: the local legs can only be held back, never advanced, so lining
    /// up with the slowest receiver is the only choice that leaves every leg
    /// alignable. The faster receivers are then early by the difference, which
    /// the user fixes by raising their targets — and the UI says so.
    func lanAlignmentHoldFrames() -> Int {
        guard !lanReceiverOutputs.isEmpty else { return 0 }
        let targets = lanReceiverOutputs.values.map { $0.link.targetMs }
        guard let slowest = targets.max() else { return 0 }
        return LanAlignmentPlanner.localHoldFrames(
            targetMs: slowest,
            ringFloorFrames: ringFloorFrames(logWarnings: false),
            maximumDeviceLatencyFrames: maximumLocalDeviceLatencyFrames(),
            sampleRate: activeCapture.sampleRate
        )
    }

    /// The largest output latency any enabled local device reports, in frames.
    ///
    /// Read out of the delay-trim seeds, which store the NEGATIVE of each
    /// device's reported latency — so the largest latency is the most negative
    /// seed. Zero when nothing has been probed, which is the honest answer
    /// before the driver is up.
    func maximumLocalDeviceLatencyFrames() -> Int {
        guard let smallestSeed = localDelaySeedFrames().values.min() else { return 0 }
        return max(0, -smallestSeed)
    }

    /// End-to-end lag the user will hear while a LAN leg is live, in
    /// milliseconds, or nil when none is.
    ///
    /// Honest about its blind spot: it does not include the capture stage's
    /// own latency (the tap or ScreenCaptureKit getting the application's
    /// audio into the ring), which adds a few milliseconds on top.
    public func lanTotalLagMs() -> Double? {
        guard !lanReceiverOutputs.isEmpty else { return nil }
        let targets = lanReceiverOutputs.values.map { $0.link.targetMs }
        guard let slowest = targets.max() else { return nil }
        return LanAlignmentPlanner.totalLagMs(
            targetMs: slowest,
            ringFloorFrames: ringFloorFrames(logWarnings: false),
            maximumDeviceLatencyFrames: maximumLocalDeviceLatencyFrames(),
            sampleRate: activeCapture.sampleRate
        )
    }

    // MARK: - Diagnostics

    /// `lan[<name>]=…` segments for `diagnosticCaptureReport()`.
    func lanDiagnosticSegments() -> String {
        var out = ""
        for output in lanReceiverOutputs.values.sorted(by: { $0.receiverUID < $1.receiverUID }) {
            // The receiver's own UID, truncated. It is a user-chosen Bonjour
            // instance name, so the log gets a short prefix rather than the
            // whole thing.
            let label = output.receiverUID.prefix(20)
            out += " lan[\(label)]=\(output.diagnosticSummary())"
        }
        return out
    }
}
