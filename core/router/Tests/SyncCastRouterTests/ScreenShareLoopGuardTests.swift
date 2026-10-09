import XCTest
@testable import SyncCastRouter

/// The screen-sharing feedback-loop guard's decision.
///
/// # Why these exist
///
/// With a LAN receiver live and that receiver Mac's screen open in Screen
/// Sharing, the receiver's audio came back into the sink and circulated
/// forever: a full-scale squeal on every speaker that outlived the music.
/// The guard excludes the return audio from the sink tap; these pin when it
/// does, and, as importantly, when it must not (a FaceTime call through the
/// same conferencing daemon with no Screen Sharing open).
final class ScreenShareLoopGuardTests: XCTestCase {

    private let music = SinkRenderer(
        processObjectID: 10, pid: 100,
        bundleID: "com.apple.Music", executablePath: "/System/Applications/Music.app/Contents/MacOS/Music"
    )
    private let conferencing = SinkRenderer(
        processObjectID: 11, pid: 101,
        bundleID: nil, executablePath: "/usr/libexec/avconferenced"
    )
    private let viewer = SinkRenderer(
        processObjectID: 12, pid: 102,
        bundleID: "com.apple.ScreenSharing", executablePath: nil
    )

    func testLoopPossibleExcludesOnlyTheReturnAudio() {
        XCTAssertEqual(
            ScreenShareLoopGuard.processesToExclude(
                renderers: [music, conferencing, viewer],
                lanLegLive: true,
                screenSharingViewerRunning: true
            ),
            [11, 12]
        )
    }

    /// FaceTime goes through the same daemon. Without Screen Sharing open
    /// there is no loop, and dropping a call's audio would be a new bug.
    func testNoScreenSharingViewerExcludesNothing() {
        XCTAssertEqual(
            ScreenShareLoopGuard.processesToExclude(
                renderers: [music, conferencing],
                lanLegLive: true,
                screenSharingViewerRunning: false
            ),
            []
        )
    }

    /// Without a LAN leg nothing carries the audio to the shared Mac.
    func testNoLanLegExcludesNothing() {
        XCTAssertEqual(
            ScreenShareLoopGuard.processesToExclude(
                renderers: [music, conferencing, viewer],
                lanLegLive: false,
                screenSharingViewerRunning: true
            ),
            []
        )
    }

    func testRendererIdentification() {
        XCTAssertFalse(ScreenShareLoopGuard.isReturnAudioRenderer(music))
        XCTAssertTrue(ScreenShareLoopGuard.isReturnAudioRenderer(conferencing))
        XCTAssertTrue(ScreenShareLoopGuard.isReturnAudioRenderer(viewer))
        XCTAssertTrue(ScreenShareLoopGuard.isReturnAudioRenderer(SinkRenderer(
            processObjectID: 13, pid: 103, bundleID: "com.apple.avconferenced",
            executablePath: nil
        )))
        XCTAssertFalse(ScreenShareLoopGuard.isReturnAudioRenderer(SinkRenderer(
            processObjectID: 14, pid: 104, bundleID: nil, executablePath: nil
        )))
    }

    /// Stable order, so an unchanged set never rewrites the tap.
    func testResultIsSorted() {
        XCTAssertEqual(
            ScreenShareLoopGuard.processesToExclude(
                renderers: [viewer, conferencing],
                lanLegLive: true,
                screenSharingViewerRunning: true
            ),
            [11, 12]
        )
    }
}
