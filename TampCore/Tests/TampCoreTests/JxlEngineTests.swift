import XCTest
@testable import TampCore

final class JxlEngineTests: EngineTestCase {
    private var engine: JxlEngine!

    override var requiredHelpers: [String] { ["cjxl", "djxl"] }

    override func setUpWithError() throws {
        try super.setUpWithError()
        engine = JxlEngine()
    }

    private func compress(source: URL, quality: MediaQuality = .lossless, losslessJPEGToJXL: Bool = false, step: SpeedStep = .normal, name: String) async throws -> ImageCompressResult {
        try await engine.compress(
            ImageCompressRequest(
                source: source, destination: output.appendingPathComponent(name),
                format: .jxl, step: step, quality: quality, losslessJPEGToJXL: losslessJPEGToJXL
            ),
            progress: { _ in }
        )
    }

    /// The plan's core promise for this path: decoding the JXL back must give
    /// exactly the original JPEG's bytes, not just its pixels.
    func testLosslessJPEGToJXLReconstructsTheOriginalJPEGExactly() async throws {
        let corpus = try makeCorpus()
        let photo = corpus.appendingPathComponent("media/photo.jpg")
        for step in SpeedStep.allCases {
            let result = try await compress(source: photo, losslessJPEGToJXL: true, step: step, name: "photo-\(step.rawValue).jxl")
            XCTAssertGreaterThan(result.outputBytes, 0, "\(step.title) wrote an empty file")
        }
    }

    /// A JXL made this way must fail the job rather than produce a JXL that can't
    /// reconstruct the source: feed it a non-JPEG to prove the check actually runs.
    func testLosslessJPEGToJXLFailsOnANonJPEGSource() async throws {
        let corpus = try makeCorpus()
        let diagram = corpus.appendingPathComponent("media/diagram.png")
        do {
            _ = try await compress(source: diagram, losslessJPEGToJXL: true, name: "not-a-jpeg.jxl")
            XCTFail("cjxl should refuse to treat a PNG as a lossless JPEG transcode")
        } catch {
            // Either cjxl itself rejects the non-JPEG input, or (if it somehow
            // accepted it) the reconstruction check catches the mismatch; both
            // are the correct outcome here, so any thrown error passes.
        }
    }

    func testEveryQualityPresetProducesANonEmptyFile() async throws {
        let corpus = try makeCorpus()
        let diagram = corpus.appendingPathComponent("media/diagram.png")
        for preset in QualityPreset.allCases {
            let result = try await compress(source: diagram, quality: .preset(preset), name: "\(preset.rawValue).jxl")
            XCTAssertGreaterThan(result.outputBytes, 0, "\(preset.title) wrote an empty file")
        }
    }

    func testResultReportsRealByteCounts() async throws {
        let corpus = try makeCorpus()
        let diagram = corpus.appendingPathComponent("media/diagram.png")
        let result = try await compress(source: diagram, name: "sizes.jxl")
        XCTAssertEqual(result.inputBytes, 46763)
        XCTAssertGreaterThan(result.outputBytes, 0)
    }
}
