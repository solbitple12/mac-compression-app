import AVFoundation
import XCTest
@testable import TampCore

final class VideoPreviewTests: EngineTestCase {
    private var sourceVideo: URL!

    override var requiredHelpers: [String] { ["ffmpeg"] }

    override func setUpWithError() throws {
        try super.setUpWithError()
        sourceVideo = try makeCorpus().appendingPathComponent("media/clip.mp4")
    }

    /// clip.mp4 is only 2 seconds, shorter than VideoPreview.clipSeconds (5), so
    /// this exercises the "clip shorter than the preview window" path: the
    /// whole file gets trimmed-and-compressed rather than a true middle slice,
    /// and the result must still be a normal playable file with audio intact.
    func testPreviewOfAShortClipProducesThePlayableWholeFile() async throws {
        let result = try await VideoPreview.compress(
            source: sourceVideo, destination: output.appendingPathComponent("preview.mp4"),
            engine: H264Engine(), step: .normal, quality: .preset(.high)
        )
        XCTAssertGreaterThan(result.outputBytes, 0)
        let asset = AVURLAsset(url: result.output)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertFalse(videoTracks.isEmpty, "no video track in the preview")
        XCTAssertFalse(audioTracks.isEmpty, "audio stream wasn't preserved in the preview")
    }

    /// The preview must never run longer than the source, whatever the source's
    /// own length: this is the only property VideoPreview promises regardless
    /// of clip length, so it's the one worth pinning down with a real decode.
    func testPreviewNeverExceedsTheSourceDuration() async throws {
        let sourceDuration = try await AVURLAsset(url: sourceVideo).load(.duration).seconds
        let result = try await VideoPreview.compress(
            source: sourceVideo, destination: output.appendingPathComponent("bounded.mp4"),
            engine: H264Engine(), step: .normal, quality: .preset(.high)
        )
        let previewDuration = try await AVURLAsset(url: result.output).load(.duration).seconds
        XCTAssertLessThanOrEqual(previewDuration, sourceDuration + 0.5, "the preview ran longer than the source")
    }
}
