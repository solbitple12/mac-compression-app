import XCTest
@testable import TampCore

final class AvifEngineTests: EngineTestCase {
    private var engine: AvifEngine!
    private var sourceImage: URL!

    override var requiredHelpers: [String] { ["avifenc"] }

    override func setUpWithError() throws {
        try super.setUpWithError()
        engine = AvifEngine()
        sourceImage = try makeCorpus().appendingPathComponent("media/diagram.png")
    }

    private func compress(quality: MediaQuality, name: String) async throws -> ImageCompressResult {
        try await engine.compress(
            ImageCompressRequest(source: sourceImage, destination: output.appendingPathComponent(name), format: .avif, step: .normal, quality: quality),
            progress: { _ in }
        )
    }

    /// Nothing in Tamp can decode AVIF yet (no bundled decoder), so this only
    /// checks avifenc actually wrote a non-empty file; ImageIO may or may not
    /// decode it depending on the OS version, so that check is best-effort and
    /// skipped rather than failed if it can't.
    func testEveryQualityPresetProducesANonEmptyFile() async throws {
        for preset in QualityPreset.allCases {
            let result = try await compress(quality: .preset(preset), name: "\(preset.rawValue).avif")
            XCTAssertGreaterThan(result.outputBytes, 0, "\(preset.title) wrote an empty file")
        }
    }

    func testLosslessProducesANonEmptyFile() async throws {
        let result = try await compress(quality: .lossless, name: "lossless.avif")
        XCTAssertGreaterThan(result.outputBytes, 0)
    }

    func testImageIOCanDecodeTheResultIfItSupportsAVIF() async throws {
        let result = try await compress(quality: .preset(.high), name: "decodable.avif")
        guard let decoded = try? decodedPixels(of: result.output) else {
            throw XCTSkip("ImageIO couldn't decode the AVIF output on this OS version")
        }
        XCTAssertFalse(decoded.isEmpty)
    }

    func testResultReportsRealByteCounts() async throws {
        let result = try await compress(quality: .preset(.high), name: "sizes.avif")
        XCTAssertEqual(result.inputBytes, 46763)
        XCTAssertGreaterThan(result.outputBytes, 0)
    }
}
