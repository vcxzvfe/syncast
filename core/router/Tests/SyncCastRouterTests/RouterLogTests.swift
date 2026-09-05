import XCTest
@testable import SyncCastRouter

/// `RouterLog` is the only reason the router's diagnostics are visible at all
/// inside the installed .app, so the contract it offers the app — "every line
/// I write reaches your sink, exactly once, without a trailing newline" — is
/// pinned here rather than trusted.
final class RouterLogTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ line: String) { lock.withLock { lines.append(line) } }
        var captured: [String] { lock.withLock { lines } }
    }

    override func tearDown() {
        RouterLog.sink = nil
        RouterLog.flush()
        super.tearDown()
    }

    func testInstalledSinkReceivesTheLine() {
        let recorder = Recorder()
        RouterLog.sink = { recorder.append($0) }
        RouterLog.write("[Router] hello")
        RouterLog.flush()
        XCTAssertEqual(recorder.captured, ["[Router] hello"])
    }

    /// Every existing call site was written for `FileHandle.standardError`, so
    /// its message ends in "\n". A line-oriented logger adds its own; passing
    /// both through would put a blank line between every diagnostic.
    func testTrailingNewlineIsStrippedForTheSink() {
        let recorder = Recorder()
        RouterLog.sink = { recorder.append($0) }
        RouterLog.write("[SystemSink] takeover failed\n")
        RouterLog.flush()
        XCTAssertEqual(recorder.captured, ["[SystemSink] takeover failed"])
    }

    func testEmptyMessagesAreDropped() {
        let recorder = Recorder()
        RouterLog.sink = { recorder.append($0) }
        RouterLog.write("")
        RouterLog.write("\n")
        RouterLog.flush()
        XCTAssertTrue(recorder.captured.isEmpty)
    }

    /// Order matters for a phase-timing log: "tap start" before "output open"
    /// is the whole point. The serial queue is what guarantees it.
    func testLinesArriveInWriteOrder() {
        let recorder = Recorder()
        RouterLog.sink = { recorder.append($0) }
        for i in 0..<50 { RouterLog.write("line \(i)") }
        RouterLog.flush()
        XCTAssertEqual(recorder.captured, (0..<50).map { "line \($0)" })
    }

    /// Clearing the sink must go back to stderr rather than keep feeding a
    /// destination the app has torn down.
    func testClearingTheSinkStopsDelivery() {
        let recorder = Recorder()
        RouterLog.sink = { recorder.append($0) }
        RouterLog.write("kept")
        RouterLog.flush()
        RouterLog.sink = nil
        RouterLog.write("goes to stderr")
        RouterLog.flush()
        XCTAssertEqual(recorder.captured, ["kept"])
    }
}
