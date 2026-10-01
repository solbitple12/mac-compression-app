import XCTest
@testable import TampCore

/// Pure logic plus one ImageIO read, no helpers needed: photo.jpg is probed
/// for its dimensions without a full decode, the same way VideoMemoryHint
/// probes a video's dimensions with AVFoundation.
final class ImageMemoryHintTests: EngineTestCase {
    func testEstimateScalesWithResolution() {
        let small = ImageMemoryHint.peakMemoryBytes(format: .jpeg, pixelWidth: 640, pixelHeight: 480)
        let large = ImageMemoryHint.peakMemoryBytes(format: .jpeg, pixelWidth: 3840, pixelHeight: 2160)
        XCTAssertGreaterThan(large, small, "4K should estimate more memory than SD")
    }

    func testEstimateIsAlwaysPositiveEvenAtZeroResolution() {
        let estimate = ImageMemoryHint.peakMemoryBytes(format: .png, pixelWidth: 0, pixelHeight: 0)
        XCTAssertGreaterThan(estimate, 0, "the fixed overhead alone should keep this above zero")
    }

    func testEveryFormatHasAPositiveBaseOverhead() {
        for format in ImageFormat.allCases {
            XCTAssertGreaterThan(ImageMemoryHint.baseOverheadBytes(format: format), 0, format.title)
        }
    }

    func testEstimateFromARealSourceMatchesItsResolution() throws {
        let corpus = try makeCorpus()
        let photo = corpus.appendingPathComponent("media/photo.jpg")
        let estimate = try ImageMemoryHint.peakMemoryBytes(source: photo, format: .jpeg)
        // photo.jpg is 320x240 (see scripts/make-corpus.sh): its decoded buffers
        // are tiny, so the estimate should sit close to JPEG's fixed base
        // overhead, not balloon toward an HD-sized figure.
        let hdEstimate = ImageMemoryHint.peakMemoryBytes(format: .jpeg, pixelWidth: 1920, pixelHeight: 1080)
        XCTAssertLessThan(estimate, hdEstimate, "a 320x240 source shouldn't estimate as much as HD")
        XCTAssertGreaterThan(estimate, 0)
    }
}
