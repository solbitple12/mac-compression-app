import XCTest
@testable import TampCore

/// Pure logic, no helpers needed: audio's estimate is fixed overhead only.
final class AudioMemoryHintTests: XCTestCase {
    func testEveryFormatHasAPositiveBaseOverhead() {
        for format in AudioFormat.allCases {
            XCTAssertGreaterThan(AudioMemoryHint.peakMemoryBytes(format: format), 0, format.title)
        }
    }

    func testEstimateIsFarSmallerThanAVideoOrImageEstimate() {
        // Audio's estimate should stay a small, fixed figure regardless of the
        // source, unlike video and image, which scale with resolution.
        let audio = AudioMemoryHint.peakMemoryBytes(format: .flac)
        let video = VideoMemoryHint.peakMemoryBytes(format: .h264, step: .normal, pixelWidth: 1920, pixelHeight: 1080)
        XCTAssertLessThan(audio, video)
    }
}
