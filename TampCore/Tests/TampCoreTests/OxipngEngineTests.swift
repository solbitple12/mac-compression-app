import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import TampCore

final class OxipngEngineTests: EngineTestCase {
    private var engine: OxipngEngine!
    private var sourceImage: URL!

    override var requiredHelpers: [String] { ["oxipng"] }

    override func setUpWithError() throws {
        try super.setUpWithError()
        engine = OxipngEngine()
        sourceImage = try makeCorpus().appendingPathComponent("media/diagram.png")
    }

    private func compress(step: SpeedStep = .normal, metadata: MetadataHandling = .keep, name: String = "diagram.png") async throws -> ImageCompressResult {
        try await engine.compress(
            ImageCompressRequest(
                source: sourceImage, destination: output.appendingPathComponent(name),
                format: .png, step: step, metadata: metadata
            ),
            progress: { _ in }
        )
    }

    /// oxipng only ever re-packs the same pixels, so decoding the output must give
    /// back exactly what the source held, at every speed step.
    func testEveryStepRoundTripsPixelForPixel() async throws {
        let sourcePixels = try Self.decodedPixels(of: sourceImage)
        for step in SpeedStep.allCases {
            let result = try await compress(step: step, name: "diagram-\(step.rawValue).png")
            XCTAssertGreaterThan(result.outputBytes, 0, "\(step.title) wrote an empty file")
            XCTAssertEqual(try Self.decodedPixels(of: result.output), sourcePixels, "\(step.title) changed the decoded pixels")
        }
    }

    func testResultReportsRealByteCounts() async throws {
        let result = try await compress()
        XCTAssertEqual(result.inputBytes, 46763)
        XCTAssertGreaterThan(result.inputBytes, 0)
        XCTAssertLessThan(result.outputBytes, result.inputBytes, "oxipng should shrink an untouched PNG")
    }

    /// Draws a PNG into a fixed RGBA buffer, so the comparison is by decoded pixels
    /// rather than by the compressed bytes oxipng is free to rearrange.
    private static func decodedPixels(of url: URL) throws -> Data {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw TampError.other("couldn't decode \(url.lastPathComponent)")
        }
        let width = image.width, height = image.height
        var buffer = Data(count: width * height * 4)
        try buffer.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { throw TampError.other("couldn't create a bitmap context") }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return buffer
    }
}
