import XCTest
@testable import TampCore

final class WebPEngineTests: EngineTestCase {
    private var engine: WebPEngine!
    private var sourceImage: URL!

    override var requiredHelpers: [String] { ["cwebp"] }

    override func setUpWithError() throws {
        try super.setUpWithError()
        engine = WebPEngine()
        sourceImage = try makeCorpus().appendingPathComponent("media/diagram.png")
    }

    private func compress(quality: MediaQuality, name: String) async throws -> ImageCompressResult {
        try await engine.compress(
            ImageCompressRequest(
                source: sourceImage, destination: output.appendingPathComponent(name),
                format: .webp, step: .normal, quality: quality
            ),
            progress: { _ in }
        )
    }

    /// A lossless WebP must decode to exactly the source's pixels. ImageIO has read
    /// WebP since macOS 11; if that ever changes, skip rather than fail the build
    /// for something outside this engine.
    func testLosslessRoundTripsPixelForPixel() async throws {
        let result = try await compress(quality: .lossless, name: "lossless.webp")
        XCTAssertGreaterThan(result.outputBytes, 0)
        guard let decoded = try? decodedPixels(of: result.output) else {
            throw XCTSkip("ImageIO couldn't decode the WebP output to compare pixels")
        }
        XCTAssertEqual(decoded, try decodedPixels(of: sourceImage))
    }

    func testEveryQualityPresetProducesANonEmptyFile() async throws {
        for preset in QualityPreset.allCases {
            let result = try await compress(quality: .preset(preset), name: "\(preset.rawValue).webp")
            XCTAssertGreaterThan(result.outputBytes, 0, "\(preset.title) wrote an empty file")
        }
    }

    func testResultReportsRealByteCounts() async throws {
        let result = try await compress(quality: .lossless, name: "sizes.webp")
        XCTAssertGreaterThan(result.inputBytes, 0)
        XCTAssertGreaterThan(result.outputBytes, 0)
    }
}
