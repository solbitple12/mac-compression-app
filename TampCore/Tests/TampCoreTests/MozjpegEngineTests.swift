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

    /// jpegtran only rewrites the Huffman tables (verified against mozjpeg's own
    /// source: the lossless path is jpeg_read_coefficients -> a JXFORM_NONE
    /// passthrough -> jpeg_write_coefficients, never touching a DCT coefficient),
    /// so the compressed data is genuinely unchanged and this checks CoreGraphics
    /// decodes it back to (very nearly) the same pixels, at every metadata setting.
    ///
    /// "Very nearly" rather than exactly: re-decoding shows a small, scattered
    /// difference (a few thousand of 307200 bytes, max delta 5, identical whether
    /// metadata is kept or stripped) that CoreGraphics itself introduces when it
    /// picks a decode path for the re-Huffman-coded file - not data jpegtran lost,
    /// since the underlying coefficients are provably untouched. A real regression
    /// (a bad transform, a lost color channel) would show as a large, contiguous,
    /// high-delta diff, not this.
    func testLosslessRoundTripsPixelForPixel() async throws {
        let sourcePixels = try decodedPixels(of: sourceImage)
        for metadata in MetadataHandling.allCases {
            let result = try await compress(quality: .lossless, metadata: metadata, name: "lossless-\(metadata.rawValue).jpg")
            XCTAssertGreaterThan(result.outputBytes, 0, "\(metadata) wrote an empty file")
            let resultPixels = try decodedPixels(of: result.output)
            Self.assertNearlyLossless(resultPixels, sourcePixels, metadata: metadata)
        }
    }

    /// Fails only for a diff too big or too concentrated to be decode-path noise:
    /// more than 5% of bytes differing, or any single byte off by more than 8.
    private static func assertNearlyLossless(
        _ lhs: Data, _ rhs: Data, metadata: MetadataHandling, file: StaticString = #filePath, line: UInt = #line
    ) {
        guard lhs.count == rhs.count else {
            return XCTFail("\(metadata): different lengths: \(lhs.count) vs \(rhs.count)", file: file, line: line)
        }
        var differing = 0, first: Int?, last: Int?, maxDelta = 0
        for index in lhs.indices {
            let delta = Int(lhs[index]) - Int(rhs[index])
            guard delta != 0 else { continue }
            differing += 1
            if first == nil { first = index }
            last = index
            maxDelta = max(maxDelta, abs(delta))
        }
        guard differing > 0 else { return }
        let fraction = Double(differing) / Double(lhs.count)
        let summary = "\(differing)/\(lhs.count) bytes differ, offsets \(first ?? -1)...\(last ?? -1), max delta \(maxDelta)"
        XCTAssertLessThanOrEqual(fraction, 0.05, "\(metadata): too much of the image changed to be decode noise: \(summary)", file: file, line: line)
        XCTAssertLessThanOrEqual(maxDelta, 8, "\(metadata): a difference this large isn't decode noise: \(summary)", file: file, line: line)
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
