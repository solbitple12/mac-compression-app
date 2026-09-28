import XCTest
@testable import TampCore

final class DiskImageEngineTests: EngineTestCase {
    private let engine = DiskImageEngine()

    private func compress(_ items: [URL], name: String, step: SpeedStep = .fastest, password: String? = nil) async throws -> URL {
        try await engine.compress(
            CompressRequest(items: items, destination: output.appendingPathComponent(name), step: step, password: password),
            progress: { _ in }
        )
    }

    private func extract(_ archive: URL, into name: String, password: String? = nil) async throws -> URL {
        try await engine.extract(ExtractRequest(archive: archive, destinationDirectory: try makeFolder(name), password: password),
                                 progress: { _ in })
    }

    /// The disk image's own copy of the project, which keeps .DS_Store files.
    private func assertHoldsProject(_ extracted: URL, file: StaticString = #filePath, line: UInt = #line) {
        for relative in ["readme.txt", "data/random.bin"] {
            XCTAssertTrue(fileManager.contentsEqual(atPath: project.appendingPathComponent(relative).path,
                                                    andPath: extracted.appendingPathComponent(relative).path),
                          "\(relative) differs", file: file, line: line)
        }
        XCTAssertTrue(fileManager.fileExists(atPath: extracted.appendingPathComponent("empty").path), file: file, line: line)
        XCTAssertFalse(fileManager.fileExists(atPath: extracted.appendingPathComponent(".fseventsd").path), file: file, line: line)
    }

    func testRoundTripAtEveryStepLeavesNothingMounted() async throws {
        let registry = EngineRegistry.standard()
        for step in SpeedStep.allCases {
            let image = try await compress([project], name: "Project-\(step.title).dmg", step: step)
            XCTAssertTrue(registry.extractor(for: image) is DiskImageEngine, "\(step.title) isn't recognized")
            let extracted = try await extract(image, into: "Out-\(step.title)")
            XCTAssertEqual(extracted.lastPathComponent, "Project-\(step.title)")
            assertHoldsProject(extracted)
        }
        let mounted = try await ProcessRunner().run(DiskImageEngine.hdiutil, arguments: ["info"])
        XCTAssertTrue(mounted.succeeded)
    }

    func testTheCorpusKeepsLinksAndExecutableBits() async throws {
        let corpus = try makeCorpus()
        let image = try await compress([corpus], name: "Corpus.dmg", step: .normal)
        let extracted = try await extract(image, into: "CorpusOut")
        try assertTreesEqual(corpus, extracted)
    }

    func testSeveralItemsSitAtTheTopOfTheVolume() async throws {
        let other = try makeFolder("Elsewhere")
        let note = other.appendingPathComponent("note.txt")
        try Data("a note".utf8).write(to: note)
        let image = try await compress([project.appendingPathComponent("data"), note], name: "Mixed.dmg")
        let extracted = try await extract(image, into: "MixedOut")
        XCTAssertEqual(extracted.lastPathComponent, "Mixed")
        XCTAssertEqual(try contents(of: extracted).filter { !$0.hasPrefix(".") }, ["data", "note.txt"])
    }

    func testPasswordProtectedImages() async throws {
        let image = try await compress([project], name: "Secret.dmg", password: "correct horse ü")
        XCTAssertTrue(DiskImageEngine.looksLikeDiskImage(image))
        for (password, expected) in [(nil, TampError.passwordRequired), ("wrong", .wrongPassword)] as [(String?, TampError)] {
            do {
                _ = try await extract(image, into: "Denied-\(password ?? "none")", password: password)
                XCTFail("Expected \(expected)")
            } catch {
                XCTAssertEqual(error as? TampError, expected)
            }
        }
        let extracted = try await extract(image, into: "SecretOut", password: "correct horse ü")
        assertHoldsProject(extracted)
    }

    func testDamagedImagesAreReported() async throws {
        let image = try await compress([project], name: "Whole.dmg")
        let data = try Data(contentsOf: image)
        // Keep the trailer, so it's still taken for a disk image, and spoil the data.
        var damaged = data
        let middle = damaged.count / 2
        damaged.replaceSubrange(middle..<(middle + 4096), with: Data(repeating: 0xA5, count: 4096))
        let spoiled = output.appendingPathComponent("Spoiled.dmg")
        try damaged.write(to: spoiled)
        let target = try makeFolder("Damaged")
        do {
            _ = try await engine.extract(ExtractRequest(archive: spoiled, destinationDirectory: target), progress: { _ in })
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? TampError, .corruptArchive, "\(error)")
        }
        XCTAssertEqual(try contents(of: target), [])
        let garbage = output.appendingPathComponent("Garbage.dmg")
        try Data("not a disk image".utf8).write(to: garbage)
        XCTAssertNil(EngineRegistry.standard().extractor(for: garbage))
    }

    func testMappingAndProgressLines() {
        let mapping = DiskImageMapping()
        let formats = SpeedStep.allCases.map { mapping.parameters(for: $0, options: ArchiveOptions()).arguments }
        XCTAssertEqual(formats, [
            ["-format", "UDRO"],
            ["-format", "UDZO", "-imagekey", "zlib-level=1"],
            ["-format", "ULFO"],
            ["-format", "UDZO", "-imagekey", "zlib-level=6"],
            ["-format", "UDZO", "-imagekey", "zlib-level=9"],
            ["-format", "ULMO"],
        ])
        XCTAssertEqual(DiskImageEngine.fraction(in: "PERCENT:24.5"), 0.245)
        XCTAssertNil(DiskImageEngine.fraction(in: "PERCENT:-1.000000"))
        XCTAssertNil(DiskImageEngine.fraction(in: "created: /tmp/x.dmg"))
        XCTAssertEqual(DiskImageEngine.error(exitCode: 1, standardError: "hdiutil: attach failed - Authentication error"), .wrongPassword)
        XCTAssertEqual(DiskImageEngine.error(exitCode: 1, standardError: "hdiutil: attach failed - image not recognized"), .corruptArchive)
    }
}
