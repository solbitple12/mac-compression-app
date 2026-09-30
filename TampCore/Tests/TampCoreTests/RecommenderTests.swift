import XCTest
@testable import TampCore

/// The Trial stage and the top-level orchestrator, against the real ZIP and
/// 7-Zip engines (a real probe, not a fake), on the shared "Project" corpus.
final class RecommenderTests: EngineTestCase {
    override var requiredHelpers: [String] { ["7zz"] }

    func testOpensAnywhereRecommendsZipWithARealEstimate() async throws {
        let result = try await Recommender.recommend(
            items: [project], goal: .opensAnywhere, registry: .standard(),
            estimator: Estimator(history: EstimateHistory(fileURL: nil)), destination: output
        )
        let recommendation = try XCTUnwrap(result, "a plain project folder should always recommend something")
        XCTAssertEqual(recommendation.recommendation.format, .zip)
        XCTAssertNil(recommendation.recommendation.alternative)
        XCTAssertGreaterThan(recommendation.estimate.peakMemoryBytes, 0)
        XCTAssertNil(recommendation.alternativeEstimate, "opensAnywhere has no alternative to try")
    }

    func testLosslessOnlyRecommendsZipAndTriesTheSevenZipAlternative() async throws {
        // "project" (from EngineTestCase) deliberately includes a megabyte of
        // random, incompressible data for the archive round-trip tests, which
        // would trip RecommenderRules' dense-content rule here; this needs
        // genuinely compressible, ordinary content instead.
        let folder = try makeFolder("Compressible")
        try Data(String(repeating: "Tamp compresses text well. ", count: 4000).utf8).write(to: folder.appendingPathComponent("readme.txt"))
        let result = try await Recommender.recommend(
            items: [folder], goal: .losslessOnly, registry: .standard(),
            estimator: Estimator(history: EstimateHistory(fileURL: nil)), destination: output
        )
        let recommendation = try XCTUnwrap(result)
        XCTAssertEqual(recommendation.recommendation.format, .zip)
        XCTAssertEqual(recommendation.recommendation.alternative, .sevenZip)
        XCTAssertNotNil(recommendation.alternativeEstimate, "7zz is built, so the alternative should have its own estimate too")
    }

    func testAnImpossiblySmallMemoryShareDropsEveryCandidate() async throws {
        var safety = SafetySettings()
        safety.memoryShare = 0.0000001 // no real archiver's estimate fits under this.
        let result = try await Recommender.recommend(
            items: [project], goal: .losslessOnly, registry: .standard(),
            estimator: Estimator(history: EstimateHistory(fileURL: nil)), destination: output, safety: safety
        )
        XCTAssertNil(result, "both the primary and its alternative should trip the memory check")
    }

    func testNoFilesToScanReturnsNil() async throws {
        let empty = try makeFolder("Empty")
        let result = try await Recommender.recommend(
            items: [empty], goal: .fastest, registry: .standard(),
            estimator: Estimator(history: EstimateHistory(fileURL: nil)), destination: output
        )
        XCTAssertNil(result)
    }
}
