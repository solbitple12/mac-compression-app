import XCTest
@testable import TampCore

final class ProgressTextTests: XCTestCase {
    func testClock() {
        XCTAssertEqual(ProgressText.clock(0), "0:00")
        XCTAssertEqual(ProgressText.clock(7.9), "0:07")
        XCTAssertEqual(ProgressText.clock(750), "12:30")
        XCTAssertEqual(ProgressText.clock(3723), "1:02:03")
        XCTAssertEqual(ProgressText.clock(-5), "0:00")
    }

    func testTimeLeftRoundsUp() {
        XCTAssertEqual(ProgressText.timeLeft(0.4), "almost done")
        XCTAssertEqual(ProgressText.timeLeft(42), "less than a minute left")
        XCTAssertEqual(ProgressText.timeLeft(61), "about 2 min left")
        XCTAssertEqual(ProgressText.timeLeft(3600), "about 1 h left")
        XCTAssertEqual(ProgressText.timeLeft(3601), "about 1 h 1 min left")
    }

    func testStatusLine() {
        let progress = JobProgress(bytesProcessed: 42, totalBytes: 100, elapsed: 12, bytesPerSecond: 40_000_000, estimatedTimeRemaining: 90)
        let parts = ProgressText.status(progress).components(separatedBy: " · ")
        XCTAssertEqual(parts.count, 4)
        XCTAssertEqual(parts[0], "42%")
        XCTAssertTrue(parts[1].hasSuffix("/s"), parts[1])
        XCTAssertEqual(parts[2], "0:12 elapsed")
        XCTAssertEqual(parts[3], "about 2 min left")
    }

    func testStatusLineWithoutTotalOrSpeed() {
        let progress = JobProgress(bytesProcessed: 0, totalBytes: 0, elapsed: 3, bytesPerSecond: 0, estimatedTimeRemaining: nil)
        XCTAssertEqual(ProgressText.status(progress), "0:03 elapsed")
    }
}
