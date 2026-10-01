import XCTest
@testable import TampCore

final class AppleArchiveEngineTests: EngineTestCase {
    private let engine = AppleArchiveEngine()

    private func compress(_ items: [URL], name: String, step: SpeedStep = .fast, password: String? = nil) async throws -> URL {
        try await engine.compress(
            CompressRequest(items: items, destination: output.appendingPathComponent(name), step: step,
                            options: ArchiveOptions(threads: 2), password: password),
            progress: { _ in }
        )
    }

    private func extract(_ archive: URL, into name: String) async throws -> URL {
        try await engine.extract(ExtractRequest(archive: archive, destinationDirectory: try makeFolder(name)), progress: { _ in })
    }

    func testRoundTripIsByteForByteAtEveryStep() async throws {
        let registry = EngineRegistry.standard()
        for step in SpeedStep.allCases {
            let archive = try await compress([project], name: "Project-\(step.title).aar", step: step)
            XCTAssertTrue(registry.extractor(for: archive) is AppleArchiveEngine, "\(step.title) isn't recognized")
            let extracted = try await extract(archive, into: "Out-\(step.title)")
            XCTAssertEqual(extracted.lastPathComponent, "Project")
            assertMatchesProject(extracted)
        }
    }

    func testTheCorpusRoundTripsWithLinksAndExecutableBits() async throws {
        let corpus = try makeCorpus()
        let archive = try await compress([corpus], name: "Corpus.aar", step: .normal)
        let extracted = try await extract(archive, into: "CorpusOut")
        try assertTreesEqual(corpus, extracted)
    }

    func testItemsFromSeveralFoldersAndASingleFile() async throws {
        let other = try makeFolder("Elsewhere")
        let dashed = other.appendingPathComponent("-dash.txt")
        try Data("a name that looks like an option".utf8).write(to: dashed)
        let items = [project.appendingPathComponent("readme.txt"), dashed, project.appendingPathComponent("data")]
        let archive = try await compress(items, name: "Mixed.aar")
        let extracted = try await extract(archive, into: "MixedOut")
        XCTAssertEqual(extracted.lastPathComponent, "Mixed")
        XCTAssertEqual(try contents(of: extracted), ["-dash.txt", "data", "readme.txt"])
        XCTAssertTrue(fileManager.contentsEqual(atPath: dashed.path, andPath: extracted.appendingPathComponent("-dash.txt").path))

        let single = try await compress([project.appendingPathComponent("readme.txt")], name: "Single.aar")
        let file = try await extract(single, into: "SingleOut")
        XCTAssertEqual(file.lastPathComponent, "readme.txt")
        XCTAssertTrue(fileManager.contentsEqual(atPath: project.appendingPathComponent("readme.txt").path, andPath: file.path))
    }

    func testJunkIsKeptWhenAsked() async throws {
        let archive = try await engine.compress(
            CompressRequest(items: [project], destination: output.appendingPathComponent("Junk.aar"), step: .fast,
                            excludesMacOSJunk: false),
            progress: { _ in }
        )
        let extracted = try await extract(archive, into: "JunkOut")
        XCTAssertTrue(fileManager.fileExists(atPath: extracted.appendingPathComponent(".DS_Store").path))
    }

    func testAPasswordIsRefusedAndDuplicateNamesToo() async throws {
        do {
            _ = try await compress([project], name: "Secret.aar", password: "no")
            XCTFail("Expected an error")
        } catch let TampError.other(message) {
            XCTAssertTrue(message.contains("password"), message)
        }
        let twin = try makeFolder("Twin/project")
        do {
            _ = try await compress([project, twin], name: "Twins.aar")
            XCTFail("Expected an error")
        } catch let TampError.other(message) {
            XCTAssertTrue(message.contains("Two items"), message)
        }
        XCTAssertEqual(try contents(of: output), [])
    }

    func testDamagedArchivesAreReportedAndLeaveNothingBehind() async throws {
        for step in [SpeedStep.store, .normal] {
            let archive = try await compress([project], name: "Whole-\(step.title).aar", step: step)
            let data = try Data(contentsOf: archive)
            let truncated = output.appendingPathComponent("Truncated-\(step.title).aar")
            try data.prefix(data.count / 2).write(to: truncated)
            let target = try makeFolder("Damaged-\(step.title)")
            do {
                _ = try await engine.extract(ExtractRequest(archive: truncated, destinationDirectory: target), progress: { _ in })
                XCTFail("Expected a damaged-archive error at \(step.title)")
            } catch {
                XCTAssertEqual(error as? TampError, .corruptArchive)
            }
            XCTAssertEqual(try contents(of: target), [])
        }
        let garbage = output.appendingPathComponent("Garbage.aar")
        try Data("not an archive".utf8).write(to: garbage)
        XCTAssertNil(EngineRegistry.standard().extractor(for: garbage))
    }

    func testPathGuardStopsEscapes() {
        let guardian = PathGuard()
        XCTAssertTrue(guardian.allows(path: "", isLink: false))
        XCTAssertTrue(guardian.allows(path: "Box/a.txt", isLink: false))
        XCTAssertTrue(guardian.allows(path: "Box/link", isLink: true))
        XCTAssertTrue(guardian.allows(path: "Box/link", isLink: false), "the link itself may be rewritten")
        XCTAssertFalse(guardian.allows(path: "Box/link/escape.txt", isLink: false))
        XCTAssertFalse(guardian.allows(path: "../escape.txt", isLink: false))
        XCTAssertFalse(guardian.allows(path: "Box/../../escape.txt", isLink: false))
        XCTAssertFalse(guardian.allows(path: "/etc/escape", isLink: false))
        XCTAssertTrue(guardian.rejected)
        XCTAssertFalse(PathGuard().rejected)
    }

    func testCancelLeavesNoPartialArchive() async throws {
        try Self.randomData(count: 64 << 20).write(to: project.appendingPathComponent("data/big.bin"))
        let (started, signal) = AsyncStream<Void>.makeStream()
        let engine = engine
        let request = CompressRequest(items: [project], destination: output.appendingPathComponent("Big.aar"), step: .best,
                                      options: ArchiveOptions(threads: 1))
        let task = Task { try await engine.compress(request, progress: { _ in signal.yield() }) }
        let timeout = Task {
            try? await Task.sleep(for: .seconds(1))
            signal.yield()
        }
        for await _ in started { break }
        timeout.cancel()
        task.cancel()
        switch await task.result {
        case .success:
            break
        case let .failure(error):
            XCTAssertTrue(error is CancellationError, "\(error)")
            XCTAssertEqual(try contents(of: output), [])
        }
    }

    func testMappingPicksAlgorithmsAndBlocks() {
        let mapping = AppleArchiveMapping()
        let steps = SpeedStep.allCases.map { mapping.parameters(for: $0, options: ArchiveOptions(threads: 2)) }
        XCTAssertEqual(steps.map(\.algorithm), [.none, .lz4, .lzfse, .zlib, .lzma, .lzma])
        XCTAssertEqual(steps.map(\.blockBytes).last, 16 << 20)
        XCTAssertLessThan(mapping.hint(for: .good, options: ArchiveOptions(threads: 2)).peakMemoryBytes,
                          mapping.hint(for: .best, options: ArchiveOptions(threads: 2)).peakMemoryBytes)
        XCTAssertEqual(mapping.hint(for: .normal, options: ArchiveOptions()).outputExtension, "aar")
    }
}
