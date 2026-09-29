import XCTest
@testable import TampCore

/// Pure logic plus one AVFoundation read, no helpers needed: clip.mp4 is
/// probed for its dimensions the same way VideoPreview probes it for duration.
final class VideoMemoryHintTests: EngineTestCase {
    func testEstimateScalesWithResolution() {
        let small = VideoMemoryHint.peakMemoryBytes(format: .h264, step: .normal, pixelWidth: 640, pixelHeight: 480)
        let large = VideoMemoryHint.peakMemoryBytes(format: .h264, step: .normal, pixelWidth: 3840, pixelHeight: 2160)
        XCTAssertGreaterThan(large, small, "4K should estimate more memory than SD")
    }

    func testAV1EstimatesMoreThanVideoToolboxAtTheSameStep() {
        // SVT-AV1's deeper lookahead should show up as a larger estimate than
        // VideoToolbox's roughly-fixed hardware pipeline, at the same resolution and step.
        let videoToolbox = VideoMemoryHint.peakMemoryBytes(format: .h264, step: .best, pixelWidth: 1920, pixelHeight: 1080)
        let av1 = VideoMemoryHint.peakMemoryBytes(format: .av1, step: .best, pixelWidth: 1920, pixelHeight: 1080)
        XCTAssertGreaterThan(av1, videoToolbox)
    }

    func testSlowerStepsEstimateMoreForAV1AndVP9() {
        for format: VideoFormat in [.av1, .vp9] {
            let fastest = VideoMemoryHint.peakMemoryBytes(format: format, step: .fastest, pixelWidth: 1920, pixelHeight: 1080)
            let best = VideoMemoryHint.peakMemoryBytes(format: format, step: .best, pixelWidth: 1920, pixelHeight: 1080)
            XCTAssertGreaterThan(best, fastest, "\(format) should estimate more at Best than Fastest")
        }
    }

    func testEstimateIsAlwaysPositiveEvenAtZeroResolution() {
        let estimate = VideoMemoryHint.peakMemoryBytes(format: .vp9, step: .store, pixelWidth: 0, pixelHeight: 0)
        XCTAssertGreaterThan(estimate, 0, "the fixed overhead alone should keep this above zero")
    }

    func testEstimateFromARealSourceMatchesItsResolution() async throws {
        let corpus = try makeCorpus()
        let clip = corpus.appendingPathComponent("media/clip.mp4")
        let estimate = try await VideoMemoryHint.peakMemoryBytes(source: clip, format: .h264, step: .normal)
        // clip.mp4 is 160x120 (see scripts/make-corpus.sh): a tiny fraction of a
        // megabyte per frame, so the estimate should stay small, not balloon to
        // an HD-sized figure.
        XCTAssertLessThan(estimate, 10 * 1024 * 1024, "a 160x120 source shouldn't estimate anywhere near 10 MB")
        XCTAssertGreaterThan(estimate, 0)
    }
}
