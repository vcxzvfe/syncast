import XCTest
import SyncCastRouter
@testable import SyncCastMenuBar

/// The status-strip line shown after SyncCast hands the PTP ports to macOS.
final class SystemAirPlayNoticeTests: XCTestCase {
    private func event(_ trigger: SystemAirPlayYield.Trigger, endpoint: String?) -> SystemAirPlayYield {
        SystemAirPlayYield(
            sequence: 1, trigger: trigger, endpoint: endpoint,
            previousMode: "whole_home", deviceIDs: []
        )
    }

    func testTimelyHandOverNamesTheSpeakerAndTheNewMode() {
        let text = AppModel.systemAirPlayNoticeText(
            for: event(.activation, endpoint: "Living Room"), leftWholeHome: true
        )
        XCTAssertEqual(
            text,
            "系统开始隔空播放到「Living Room」，SyncCast 已退出全屋、切到立体声"
                + " · macOS started AirPlay to “Living Room”; SyncCast switched to Stereo"
        )
    }

    func testLateHandOverTellsTheUserToRepick() {
        let text = AppModel.systemAirPlayNoticeText(
            for: event(.ptpConflict, endpoint: nil), leftWholeHome: true
        )
        XCTAssertTrue(text.contains("a speaker"))
        XCTAssertTrue(text.contains("请重新选一次该音箱"))
        XCTAssertTrue(text.hasSuffix("If silent, pick the speaker again"))
    }

    func testHandOverOutsideWholeHomeDoesNotClaimAModeSwitch() {
        let text = AppModel.systemAirPlayNoticeText(
            for: event(.activation, endpoint: "Kitchen Speaker"), leftWholeHome: false
        )
        XCTAssertFalse(text.contains("Stereo"))
        XCTAssertFalse(text.contains("立体声"))
        XCTAssertTrue(text.hasSuffix("SyncCast stepped aside"))
    }
}
