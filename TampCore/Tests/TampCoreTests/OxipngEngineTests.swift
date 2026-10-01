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
        let sourcePixels = try decodedPixels(of: sourceImage)
        for step in SpeedStep.allCases {
            let result = try await compress(step: step, name: "diagram-\(step.rawValue).png")
            XCTAssertGreaterThan(result.outputBytes, 0, "\(step.title) wrote an empty file")
            XCTAssertEqual(try decodedPixels(of: result.output), sourcePixels, "\(step.title) changed the decoded pixels")
        }
    }

    func testResultReportsRealByteCounts() async throws {
        let result = try await compress()
        XCTAssertEqual(result.inputBytes, 46763)
        XCTAssertGreaterThan(result.inputBytes, 0)
        XCTAssertLessThan(result.outputBytes, result.inputBytes, "oxipng should shrink an untouched PNG")
    }
}
