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
            let resultPixels = try decodedPixels(of: result.output)
            XCTAssertEqual(resultPixels, sourcePixels, "\(metadata) changed the decoded pixels: \(Self.diffSummary(sourcePixels, resultPixels))")
        }
    }

    /// A short summary of how two equal-length pixel buffers differ, for a failure
    /// message that says more than "not equal": how many bytes differ, the first
    /// and last differing offsets, and the largest single difference, which
    /// distinguishes a localized artifact from a wholesale transform (a color
    /// space or orientation change) at a glance.
    private static func diffSummary(_ lhs: Data, _ rhs: Data) -> String {
        guard lhs.count == rhs.count else { return "different lengths: \(lhs.count) vs \(rhs.count)" }
        var differing = 0, first: Int?, last: Int?, maxDelta = 0
        for index in lhs.indices {
            let delta = Int(lhs[index]) - Int(rhs[index])
            guard delta != 0 else { continue }
            differing += 1
            if first == nil { first = index }
            last = index
            maxDelta = max(maxDelta, abs(delta))
        }
        guard let first, let last else { return "no byte differences found" }
        return "\(differing)/\(lhs.count) bytes differ, offsets \(first)...\(last), max delta \(maxDelta)"
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
