import AVFoundation
import XCTest
@testable import TampCore

final class VideoEngineTests: EngineTestCase {
    private var sourceVideo: URL!

    override var requiredHelpers: [String] { ["ffmpeg"] }

    override func setUpWithError() throws {
        try super.setUpWithError()
        sourceVideo = try makeCorpus().appendingPathComponent("media/clip.mp4")
    }

    private func compress(_ engine: any VideoEngine, quality: MediaQuality = .preset(.high), name: String) async throws -> VideoCompressResult {
        try await engine.compress(
            VideoCompressRequest(source: sourceVideo, destination: output.appendingPathComponent(name), format: engine.format, step: .normal, quality: quality),
            progress: { _ in }
        )
    }

    /// H.264 and HEVC decode reliably on every Mac this app targets (both are
    /// native AVFoundation formats), so these check the video actually plays
    /// back with its audio track intact, not just that a file was written -
    /// the real evidence that FFmpegConversion's "-map 0 -c copy" passthrough
    /// carried the audio stream through untouched.
    func testH264ProducesAPlayableFileWithAudioPreserved() async throws {
        let result = try await compress(H264Engine(), name: "h264.mp4")
        XCTAssertGreaterThan(result.outputBytes, 0)
        try await assertHasVideoAndAudioTracks(result.output)
    }

    func testHEVCProducesAPlayableFileWithAudioPreserved() async throws {
        let result = try await compress(HEVCEngine(), name: "hevc.mp4")
        XCTAssertGreaterThan(result.outputBytes, 0)
        try await assertHasVideoAndAudioTracks(result.output)
    }

    /// AV1 and VP9 playback support in AVFoundation depends on the OS version
    /// and hardware, so (like AvifEngineTests.testImageIOCanDecodeTheResultIfItSupportsAVIF)
    /// these only check that avifenc's video counterpart, ffmpeg, wrote a real file.
    func testAV1ProducesANonEmptyFile() async throws {
        let result = try await compress(AV1Engine(), name: "av1.mp4")
        XCTAssertGreaterThan(result.outputBytes, 0)
    }

    func testVP9ProducesANonEmptyFile() async throws {
        let result = try await compress(VP9Engine(), name: "vp9.webm")
        XCTAssertGreaterThan(result.outputBytes, 0)
    }

    func testResultReportsRealByteCounts() async throws {
        let result = try await compress(H264Engine(), name: "sizes.mp4")
        XCTAssertGreaterThan(result.inputBytes, 0)
        XCTAssertGreaterThan(result.outputBytes, 0)
    }

    private func assertHasVideoAndAudioTracks(_ url: URL, file: StaticString = #filePath, line: UInt = #line) async throws {
        let asset = AVURLAsset(url: url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertFalse(videoTracks.isEmpty, "no video track", file: file, line: line)
        XCTAssertFalse(audioTracks.isEmpty, "audio stream wasn't preserved by -map 0 -c copy", file: file, line: line)
    }
}
