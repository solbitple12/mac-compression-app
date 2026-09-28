import CoreGraphics
import ImageIO
import XCTest
@testable import TampCore

/// No bundled helper, so no `requiredHelpers`: this engine runs on every Mac Tamp
/// supports (macOS 14+) without TAMP_HELPERS_DIR.
final class HEICEngineTests: EngineTestCase {
    private var engine: HEICEngine!
    private var sourceImage: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        engine = HEICEngine()
        sourceImage = try makeCorpus().appendingPathComponent("media/photo.jpg")
    }

    private func compress(quality: MediaQuality = .preset(.high), metadata: MetadataHandling = .keep, name: String) async throws -> ImageCompressResult {
        try await engine.compress(
            ImageCompressRequest(
                source: sourceImage, destination: output.appendingPathComponent(name),
                format: .heic, step: .normal, quality: quality, metadata: metadata
            ),
            progress: { _ in }
        )
    }

    func testEveryQualityPresetProducesADecodableFile() async throws {
        for preset in QualityPreset.allCases {
            let result = try await compress(quality: .preset(preset), name: "\(preset.rawValue).heic")
            XCTAssertGreaterThan(result.outputBytes, 0, "\(preset.title) wrote an empty file")
            XCTAssertNoThrow(try decodedPixels(of: result.output), "\(preset.title) isn't a decodable HEIC")
        }
    }

    func testResultReportsRealByteCounts() async throws {
        let result = try await compress(name: "sizes.heic")
        XCTAssertGreaterThan(result.inputBytes, 0)
        XCTAssertGreaterThan(result.outputBytes, 0)
    }

    /// ImageIO exposes GPS separately from the rest of EXIF, so "strip location"
    /// can be checked precisely, unlike the command-line engines' coarser modes:
    /// a JPEG with real GPS tags loses only those, keeping its pixel dimensions.
    func testStripLocationRemovesOnlyGPS() throws {
        let tagged = try Self.makeTaggedJPEG(in: output)
        guard let source = CGImageSourceCreateWithURL(tagged as CFURL, nil),
              let original = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              original[kCGImagePropertyGPSDictionary] != nil else {
            return XCTFail("the test JPEG doesn't carry the GPS tag it's meant to")
        }

        let strippedLocation = HEICEngine.strippedProperties(of: source, handling: .stripLocation)
        XCTAssertNil(strippedLocation[kCGImagePropertyGPSDictionary])
        XCTAssertEqual(strippedLocation[kCGImagePropertyPixelWidth] as? Int, original[kCGImagePropertyPixelWidth] as? Int)

        let strippedAll = HEICEngine.strippedProperties(of: source, handling: .stripAll)
        XCTAssertNil(strippedAll[kCGImagePropertyGPSDictionary])
        XCTAssertNil(strippedAll[kCGImagePropertyExifDictionary])

        let kept = HEICEngine.strippedProperties(of: source, handling: .keep)
        XCTAssertNotNil(kept[kCGImagePropertyGPSDictionary])
    }

    /// A tiny solid-color JPEG with a GPS tag, written through ImageIO.
    private static func makeTaggedJPEG(in directory: URL) throws -> URL {
        let width = 4, height = 4
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ), let image = context.makeImage() else {
            throw TampError.other("couldn't build a test image")
        }
        let url = directory.appendingPathComponent("tagged.jpg")
        guard let writer = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else {
            throw TampError.other("couldn't create the test JPEG")
        }
        let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 37.0, kCGImagePropertyGPSLongitude: -122.0]
        let properties: [CFString: Any] = [kCGImagePropertyGPSDictionary: gps]
        CGImageDestinationAddImage(writer, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(writer) else {
            throw TampError.other("couldn't write the test JPEG")
        }
        return url
    }
}
