import XCTest
@testable import TampCore

final class TampErrorTests: XCTestCase {
    func testClassifiesKnownHelperMessages() {
        XCTAssertEqual(TampError.classify(tool: "zstd", exitCode: 1, standardError: "zstd: error 70 : Write error : No space left on device"), .diskFull)
        XCTAssertEqual(TampError.classify(tool: "7zz", exitCode: 2, standardError: "ERROR: Wrong password : secret.txt"), .wrongPassword)
        XCTAssertEqual(TampError.classify(tool: "7zz", exitCode: 2, standardError: "ERROR: CRC Failed : photo.jpg"), .corruptArchive)
        XCTAssertEqual(TampError.classify(tool: "7zz", exitCode: 8, standardError: ""), .outOfMemory)
        XCTAssertEqual(TampError.classify(tool: "zstd", exitCode: 1, standardError: "zstd: /Volumes/x: Permission denied"), .permissionDenied(path: nil))
        XCTAssertEqual(TampError.classify(tool: "brotli", exitCode: 1, standardError: "corrupt input [con]"), .corruptArchive)
        XCTAssertEqual(TampError.classify(tool: "tar", exitCode: 1, standardError: "bsdtar: Error opening archive: truncated lz4 input"), .corruptArchive)
        XCTAssertEqual(TampError.classify(tool: "xz", exitCode: 1, standardError: "xz: (stdin): File format not recognized"), .corruptArchive)
    }

    func testUnknownFailureKeepsFirstLine() {
        let error = TampError.classify(tool: "7zz", exitCode: 7, standardError: "\n  Command Line Error:\nUnsupported switch\n")
        XCTAssertEqual(error, .toolFailed(tool: "7zz", exitCode: 7, message: "Command Line Error:"))
        XCTAssertEqual(error.errorDescription, "7zz stopped with error code 7: Command Line Error:")
    }

    /// ffmpeg's stderr is almost entirely routine chatter that appears on every
    /// run, success or failure alike: a version/build banner, "Input #0 .../
    /// Stream #.../Output #0 .../Stream mapping:/Press [q] to stop" as it opens
    /// files, then periodic and final "frame=..." progress stats, then, if
    /// transcoding had started before failing, a generic "Conversion failed!"
    /// trailer (ffmpeg_cleanup(), fftools/ffmpeg.c). Unlike 7zz's short,
    /// front-loaded errors, ffmpeg's real, specific error is logged somewhere
    /// before all of that routine noise, not after it - so this has to read
    /// backwards past every known noise pattern, not just skip past the front.
    func testFfmpegErrorIsFoundPastAllTheRoutineNoise() {
        let standardError = """
        ffmpeg version n9.0.2 Copyright (c) 2000-2026 the FFmpeg developers
          built with Apple clang version 17.0.0
          configuration: --prefix=/usr --enable-videotoolbox --enable-libsvtav1
          libavutil      59. 23.100 / 59. 23.100
          libavcodec     61. 24.100 / 61. 24.100
        Input #0, mov,mp4,m4a,3gp,3g2,mj2, from 'clip.mp4':
          Stream #0:0: Video: h264 (avc1 / 0x31637661), yuv420p, 160x120, 15 fps
        [libvpx-vp9 @ 0x600] Invalid CQ level 200, valid range is [0, 63]
        Stream mapping:
          Stream #0:0 -> #0:0 (h264 (native) -> vp9 (libvpx-vp9))
        Press [q] to stop, [?] for help
        frame=    0 fps=0.0 q=0.0 Lsize=       0KiB time=00:00:00.60 bitrate=   0.0kbits/s speed=76.8x
        Conversion failed!
        """
        let error = TampError.classify(tool: "ffmpeg", exitCode: 1, standardError: standardError)
        XCTAssertEqual(error, .toolFailed(tool: "ffmpeg", exitCode: 1, message: "[libvpx-vp9 @ 0x600] Invalid CQ level 200, valid range is [0, 63]"))
    }

    func testWrapsSystemErrors() {
        XCTAssertEqual(TampError(CancellationError()), .cancelled)
        XCTAssertEqual(TampError(POSIXError(.ENOSPC)), .diskFull)
        XCTAssertEqual(TampError(CocoaError(.fileWriteOutOfSpace)), .diskFull)
        XCTAssertEqual(TampError(TampError.wrongPassword), .wrongPassword)
    }

    func testMessagesNameTheFile() {
        let message = TampError.permissionDenied(path: "/Users/me/Downloads").errorDescription ?? ""
        XCTAssertTrue(message.contains("\u{201C}Downloads\u{201D}"), message)
    }
}

final class ThroughputTrackerTests: XCTestCase {
    private let megabyte: Int64 = 1_000_000

    func testSteadySpeedGivesExactETA() {
        var tracker = ThroughputTracker(totalBytes: 100 * megabyte, startTime: 0)
        _ = tracker.record(bytesProcessed: 10 * megabyte, at: 1)
        let progress = tracker.record(bytesProcessed: 20 * megabyte, at: 2)
        XCTAssertEqual(progress.bytesPerSecond, 10_000_000, accuracy: 1)
        XCTAssertEqual(progress.estimatedTimeRemaining ?? -1, 8, accuracy: 1e-6)
        XCTAssertEqual(progress.elapsed, 2)
        XCTAssertEqual(progress.fractionCompleted, 0.2, accuracy: 1e-9)
    }

    func testSpeedChangeIsSmoothed() {
        var tracker = ThroughputTracker(totalBytes: 1000 * megabyte, startTime: 0)
        _ = tracker.record(bytesProcessed: 10 * megabyte, at: 1)
        let progress = tracker.record(bytesProcessed: 30 * megabyte, at: 2)
        XCTAssertGreaterThan(progress.bytesPerSecond, 10_000_000)
        XCTAssertLessThan(progress.bytesPerSecond, 20_000_000)
    }

    func testEarlyETABlendsWithInitialEstimate() {
        var tracker = ThroughputTracker(totalBytes: 100 * megabyte, startTime: 0, initialEstimate: 50)
        // 1% done after 1 s: measured says 99 s left, the plan says 49 s; weight is 0.2.
        let progress = tracker.record(bytesProcessed: 1 * megabyte, at: 1)
        XCTAssertEqual(progress.estimatedTimeRemaining ?? -1, 0.2 * 99 + 0.8 * 49, accuracy: 1e-6)
    }

    func testFinishedJobHasNoTimeLeft() {
        var tracker = ThroughputTracker(totalBytes: 10, startTime: 0)
        let progress = tracker.record(bytesProcessed: 10, at: 1)
        XCTAssertEqual(progress.estimatedTimeRemaining, 0)
    }

    func testUnknownTotalHasNoETA() {
        var tracker = ThroughputTracker(totalBytes: 0, startTime: 0)
        let progress = tracker.record(bytesProcessed: 500, at: 1)
        XCTAssertNil(progress.estimatedTimeRemaining)
        XCTAssertEqual(progress.bytesProcessed, 500)
    }

    func testBytesNeverGoBackwards() {
        var tracker = ThroughputTracker(totalBytes: 100, startTime: 0)
        _ = tracker.record(bytesProcessed: 50, at: 1)
        let progress = tracker.record(bytesProcessed: 40, at: 2)
        XCTAssertEqual(progress.bytesProcessed, 50)
    }
}
