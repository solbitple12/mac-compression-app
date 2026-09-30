import XCTest
@testable import TampCore

/// Pure logic plus real file reads, no helpers needed: the recommender's
/// Scan and Sample stages (see the architecture plan's Recommender section).
final class RecommenderScanTests: EngineTestCase {
    func testKindIsDetectedByMagicBytesEvenWithAWrongExtension() throws {
        let corpus = try makeCorpus()
        XCTAssertEqual(RecommenderScan.kind(of: corpus.appendingPathComponent("media/photo.jpg")), .image)
        XCTAssertEqual(RecommenderScan.kind(of: corpus.appendingPathComponent("media/diagram.png")), .image)
        XCTAssertEqual(RecommenderScan.kind(of: corpus.appendingPathComponent("media/clip.mp4")), .video)
        XCTAssertEqual(RecommenderScan.kind(of: corpus.appendingPathComponent("documents/report.txt")), .text)

        // A JPEG renamed with a misleading extension is still detected by its bytes.
        let renamed = output.appendingPathComponent("photo.zip")
        try fileManager.copyItem(at: corpus.appendingPathComponent("media/photo.jpg"), to: renamed)
        XCTAssertEqual(RecommenderScan.kind(of: renamed), .image)
    }

    func testKindDetectsArchivesByTheSameMagicBytesAsArchiveDetector() throws {
        // A local file header signature, same as ArchiveDetector.zipSignatures - no
        // need to run a real archiver just to exercise the magic-byte dispatch.
        let zipLike = output.appendingPathComponent("Project.zip")
        try Data([0x50, 0x4B, 0x03, 0x04]).write(to: zipLike)
        XCTAssertEqual(RecommenderScan.kind(of: zipLike), .archive(.zip))
    }

    func testKindFallsBackToOtherForAnUnrecognizedFile() throws {
        let plain = output.appendingPathComponent("data.bin")
        try Data([0x00, 0x01, 0x02]).write(to: plain)
        XCTAssertEqual(RecommenderScan.kind(of: plain), .other)
    }

    func testKindIsOtherForAFolder() throws {
        XCTAssertEqual(RecommenderScan.kind(of: project), .other)
    }

    func testEntropyIsLowForPlainText() throws {
        let corpus = try makeCorpus()
        let entropy = try XCTUnwrap(RecommenderScan.entropy(of: corpus.appendingPathComponent("documents/report.txt")))
        XCTAssertLessThan(entropy, 6, "repetitive English text should compress well, so its entropy should be well under the 8-bit ceiling")
    }

    func testEntropyIsHighForRandomBytes() throws {
        let file = output.appendingPathComponent("random.bin")
        try Self.randomData(count: 256 * 1024).write(to: file)
        let entropy = try XCTUnwrap(RecommenderScan.entropy(of: file))
        XCTAssertGreaterThan(entropy, 7.5, "purely random bytes should sample as nearly incompressible")
    }

    func testEntropyIsNilForAnEmptyFile() throws {
        let corpus = try makeCorpus()
        XCTAssertNil(RecommenderScan.entropy(of: corpus.appendingPathComponent("documents/empty.txt")))
    }

    func testProfilesWalksIntoFolders() throws {
        let corpus = try makeCorpus()
        let profiles = RecommenderScan.profiles(for: [corpus.appendingPathComponent("documents")])
        XCTAssertTrue(profiles.contains { $0.url.lastPathComponent == "report.txt" })
        XCTAssertTrue(profiles.contains { $0.url.lastPathComponent == "table.csv" })
        XCTAssertTrue(profiles.contains { $0.url.lastPathComponent == "Ünïcode café.txt" }, "nested/deeper files are included too")
    }

    func testIsAlreadyDenseReflectsTheEntropyThreshold() {
        let dense = FileProfile(url: URL(fileURLWithPath: "/a.zip"), kind: .archive(.zip), bytes: 100, entropy: 7.9)
        let sparse = FileProfile(url: URL(fileURLWithPath: "/a.txt"), kind: .text, bytes: 100, entropy: 3.0)
        let unknown = FileProfile(url: URL(fileURLWithPath: "/a.txt"), kind: .text, bytes: 0, entropy: nil)
        XCTAssertTrue(dense.isAlreadyDense)
        XCTAssertFalse(sparse.isAlreadyDense)
        XCTAssertFalse(unknown.isAlreadyDense)
    }
}
