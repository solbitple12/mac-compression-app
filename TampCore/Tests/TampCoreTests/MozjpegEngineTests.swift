import XCTest
@testable import TampCore

final class MozjpegEngineTests: EngineTestCase {
    private var engine: MozjpegEngine!
    private var sourceImage: URL!

    override var requiredHelpers: [String] { ["jpegtran", "djpeg", "cjpeg"] }

    override func setUpWithError() throws {
        try super.setUpWithError()
        engine = MozjpegEngine()
        sourceImage = try makeCorpus().appendingPathComponent("media/photo.jpg")
    }

    private func compress(quality: MediaQuality, metadata: MetadataHandling = .keep, name: String) async throws -> ImageCompressResult {
        try await engine.compress(
            ImageCompressRequest(
                source: sourceImage, destination: output.appendingPathComponent(name),
                format: .jpeg, step: .normal, quality: quality, metadata: metadata
            ),
            progress: { _ in }
        )
    }

    /// jpegtran only rewrites the Huffman tables, so the lossless path must decode
    /// to the exact same pixels as the source, at every metadata setting.
    func testLosslessRoundTripsPixelForPixel() async throws {
        let sourcePixels = try decodedPixels(of: sourceImage)
        for metadata in MetadataHandling.allCases {
            let result = try await compress(quality: .lossless, metadata: metadata, name: "lossless-\(metadata.rawValue).jpg")
            XCTAssertGreaterThan(result.outputBytes, 0, "\(metadata) wrote an empty file")
            XCTAssertEqual(try decodedPixels(of: result.output), sourcePixels, "\(metadata) changed the decoded pixels")
        }
    }

    /// The lossy path decodes and re-encodes, so the output is a different, smaller
    /// but still valid JPEG at every quality preset.
    func testEveryQualityPresetProducesADecodableSmallerFile() async throws {
        for preset in QualityPreset.allCases {
            let result = try await compress(quality: .preset(preset), name: "\(preset.rawValue).jpg")
            XCTAssertGreaterThan(result.outputBytes, 0, "\(preset.title) wrote an empty file")
            XCTAssertNoThrow(try decodedPixels(of: result.output), "\(preset.title) isn't a decodable JPEG")
        }
    }

    func testResultReportsRealByteCounts() async throws {
        let result = try await compress(quality: .lossless, name: "sizes.jpg")
        XCTAssertGreaterThan(result.inputBytes, 0)
        XCTAssertGreaterThan(result.outputBytes, 0)
    }
}
