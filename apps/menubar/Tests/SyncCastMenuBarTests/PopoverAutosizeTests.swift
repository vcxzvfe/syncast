import XCTest
@testable import SyncCastMenuBar

final class PopoverAutosizeTests: XCTestCase {
    func testHeightIsCappedToWhatTheScreenCanShow() {
        XCTAssertEqual(PopoverAutosize.fittedHeight(content: 500, available: 900), 500)
        XCTAssertEqual(PopoverAutosize.fittedHeight(content: 1400, available: 900), 900)
        XCTAssertEqual(PopoverAutosize.fittedHeight(content: 0, available: 900), 1)
    }

    func testResizingKeepsTheTopEdgeWhereTheMenuBarPutIt() {
        let current = NSRect(x: 100, y: 300, width: 340, height: 600)   // top edge at 900
        let shorter = PopoverAutosize.fittedFrame(current: current, currentContentHeight: 600, contentHeight: 420)
        XCTAssertEqual(shorter.maxY, 900)
        XCTAssertEqual(shorter.height, 420)
        XCTAssertEqual(shorter.minX, 100)
        let taller = PopoverAutosize.fittedFrame(current: current, currentContentHeight: 590, contentHeight: 700)
        XCTAssertEqual(taller.maxY, 900)
        XCTAssertEqual(taller.height, 710, "10 pt of window chrome is preserved")
    }
}
