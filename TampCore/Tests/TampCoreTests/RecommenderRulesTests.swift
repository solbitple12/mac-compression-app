import XCTest
@testable import TampCore

/// The rules stage against fixed profiles, no file I/O - exactly the testing
/// style the architecture plan's Recommender section calls for.
final class RecommenderRulesTests: XCTestCase {
    private func profile(_ entries: [(FileKind, Int64, Double?)]) -> BatchProfile {
        BatchProfile(files: entries.map { kind, bytes, entropy in
            FileProfile(url: URL(fileURLWithPath: "/f"), kind: kind, bytes: bytes, entropy: entropy)
        })
    }

    private let textHeavy = [
        (FileKind.text, Int64(9_000_000), 4.0),
        (FileKind.other, Int64(1_000_000), 5.0),
    ]

    private let mostlyDense = [
        (FileKind.archive(.zip), Int64(9_000_000), 7.9),
        (FileKind.text, Int64(1_000_000), 4.0),
    ]

    func testOpensAnywhereForcesZipRegardlessOfContent() {
        let recommendation = RecommenderRules.recommend(profile: profile(mostlyDense), goal: .opensAnywhere)
        XCTAssertEqual(recommendation.format, .zip)
        XCTAssertNil(recommendation.alternative)
    }

    func testAlreadyDenseContentRecommendsStoreEvenWithASmallestGoal() {
        let recommendation = RecommenderRules.recommend(profile: profile(mostlyDense), goal: .smallest)
        XCTAssertEqual(recommendation.format, .zip)
        XCTAssertEqual(recommendation.step, .store)
    }

    func testSmallestGoalOnOrdinaryContentRecommendsZPAQWithSevenZipAsAlternative() {
        let ordinary = profile([(FileKind.other, 5_000_000, 6.0)])
        let recommendation = RecommenderRules.recommend(profile: ordinary, goal: .smallest)
        XCTAssertEqual(recommendation.format, .zpaq)
        XCTAssertEqual(recommendation.step, .best)
        XCTAssertEqual(recommendation.alternative, .sevenZip)
    }

    func testSmallestGoalOnTextHeavyContentOffersZstdAsTheFasterAlternative() {
        let recommendation = RecommenderRules.recommend(profile: profile(textHeavy), goal: .smallest)
        XCTAssertEqual(recommendation.format, .zpaq)
        XCTAssertEqual(recommendation.step, .best)
        XCTAssertEqual(recommendation.alternative, .tarZst, "text-like content makes zstd's speed-for-size tradeoff worth mentioning")
    }

    func testLosslessOnlyGoalRecommendsZip() {
        let recommendation = RecommenderRules.recommend(profile: profile(textHeavy), goal: .losslessOnly)
        XCTAssertEqual(recommendation.format, .zip)
        XCTAssertEqual(recommendation.alternative, .sevenZip)
    }

    func testFastestGoalUsesZstdAtFastest() {
        let recommendation = RecommenderRules.recommend(profile: profile(textHeavy), goal: .fastest)
        XCTAssertEqual(recommendation.format, .tarZst)
        XCTAssertEqual(recommendation.step, .fastest)
        XCTAssertEqual(recommendation.alternative, .zip)
    }

    func testBatchProfileFractionsAndTotals() {
        let batch = profile(textHeavy)
        XCTAssertEqual(batch.totalBytes, 10_000_000)
        XCTAssertEqual(batch.fileCount, 2)
        XCTAssertEqual(batch.textFraction, 0.9, accuracy: 0.0001)
        XCTAssertEqual(batch.denseFraction, 0)
    }

    func testIsMixedRequiresBothDenseAndCompressibleContent() {
        XCTAssertTrue(profile(mostlyDense).isMixed)
        XCTAssertFalse(profile(textHeavy).isMixed, "no already-dense content, so nothing to split")
        let allDense = profile([(FileKind.archive(.zip), 5_000_000, 7.9), (FileKind.archive(.sevenZip), 5_000_000, 7.9)])
        XCTAssertFalse(allDense.isMixed, "entirely dense, nothing to split either")
    }
}
