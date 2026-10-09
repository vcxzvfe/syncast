import Foundation
import CoreAudio

// Runs `ScreenShareLoopGuard` against the live sink path. See that file for
// the loop it breaks.

extension Router {

    /// Start polling for a Screen Sharing return path. Called once the sink
    /// tap is live; idempotent.
    func startScreenShareLoopGuard() {
        guard screenShareGuardTask == nil else { return }
        screenShareGuardTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkScreenShareLoop()
                try? await Task.sleep(nanoseconds: UInt64(
                    ScreenShareLoopGuard.pollSeconds * 1_000_000_000
                ))
            }
        }
    }

    func stopScreenShareLoopGuard() {
        screenShareGuardTask?.cancel()
        screenShareGuardTask = nil
        screenShareExcludedProcesses = []
    }

    private func checkScreenShareLoop() {
        guard #available(macOS 14.2, *) else { return }
        guard systemSinkPathIsLive,
              let tap = sinkCapture as? TapCapture,
              let sinkUID = systemSink?.sinkUID,
              let sinkID = try? Capture.deviceID(forUID: sinkUID)
        else {
            return
        }
        let lanLegLive = !lanReceiverOutputs.isEmpty
        // Cheapest test first: the process scan and the viewer check only
        // run while a loop is possible at all.
        let renderers = lanLegLive ? ScreenShareLoopGuard.renderers(into: sinkID) : []
        let viewerRunning = renderers.contains(where: ScreenShareLoopGuard.isReturnAudioRenderer)
            && ScreenShareLoopGuard.screenSharingViewerRunning()
        let wanted = ScreenShareLoopGuard.processesToExclude(
            renderers: renderers,
            lanLegLive: lanLegLive,
            screenSharingViewerRunning: viewerRunning
        )
        guard wanted != screenShareExcludedProcesses else { return }
        guard tap.setAdditionalExcludedProcesses(wanted) else {
            RouterLog.write(
                "[Router] screen-share loop guard: could not update the sink tap (\(tap.debugLastReason)); \(wanted.isEmpty ? "exclusion stays" : "loop NOT broken")\n"
            )
            return
        }
        screenShareExcludedProcesses = wanted
        if wanted.isEmpty {
            RouterLog.write(
                "[Router] screen-share loop guard: Screen Sharing return audio is no longer playing into the sink; exclusion lifted\n"
            )
        } else {
            let names = renderers
                .filter { wanted.contains($0.processObjectID) }
                .map { $0.bundleID ?? ($0.executablePath as NSString?)?.lastPathComponent ?? "pid \($0.pid)" }
                .sorted()
                .joined(separator: ",")
            RouterLog.write(
                "[Router] screen-share loop guard: Screen Sharing is playing a remote Mac's audio into the sink while a LAN receiver is live; excluding [\(names)] from the tap to break the feedback loop\n"
            )
        }
    }
}
