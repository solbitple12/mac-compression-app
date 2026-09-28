import XCTest
@testable import TampCore

final class ZpaqEngineTests: EngineTestCase {
    private var engine: ZpaqEngine!

    override var requiredHelpers: [String] { ["zpaq"] }

    override func setUpWithError() throws {
        try super.setUpWithError()
        engine = ZpaqEngine()
    }

    private func compress(_ items: [URL], name: String, step: SpeedStep = .fast, password: String? = nil) async throws -> URL {
        try await engine.compress(
            CompressRequest(items: items, destination: output.appendingPathComponent(name), step: step,
                            options: ArchiveOptions(threads: 2), password: password),
            progress: { _ in }
        )
    }

    func testRoundTripIsByteForByteAtEveryStep() async throws {
        for step in SpeedStep.allCases {
            let archive = try await compress([project], name: "Project-\(step.title).zpaq", step: step)
            let extracted = try await engine.extract(
                ExtractRequest(archive: archive, destinationDirectory: try makeFolder("Out-\(step.title)")),
                progress: { _ in }
            )
            XCTAssertEqual(extracted.lastPathComponent, "Project")
            assertMatchesProject(extracted)
        }
    }

    func testTheCorpusRoundTripsExceptForSymbolicLinks() async throws {
        let corpus = try makeCorpus()
        let archive = try await compress([corpus], name: "Corpus.zpaq", step: .normal)
        let extracted = try await engine.extract(
            ExtractRequest(archive: archive, destinationDirectory: try makeFolder("CorpusOut")),
            progress: { _ in }
        )
        // zpaq doesn't store links, as the hint says; everything else must match.
        try fileManager.removeItem(at: corpus.appendingPathComponent("tools/latest"))
        try assertTreesEqual(corpus, extracted)
    }

    func testItemsFromSeveralFoldersAndOddNames() async throws {
        let other = try makeFolder("Elsewhere")
        let dashed = other.appendingPathComponent("-dash.txt")
        try Data("a name that looks like an option".utf8).write(to: dashed)
        let items = [project.appendingPathComponent("readme.txt"), dashed, project.appendingPathComponent("data")]
        let archive = try await compress(items, name: "Mixed.zpaq")
        let extracted = try await engine.extract(
            ExtractRequest(archive: archive, destinationDirectory: try makeFolder("MixedOut")),
            progress: { _ in }
        )
        XCTAssertEqual(extracted.lastPathComponent, "Mixed")
        XCTAssertEqual(try contents(of: extracted), ["-dash.txt", "data", "readme.txt"])
        XCTAssertTrue(fileManager.contentsEqual(atPath: dashed.path, andPath: extracted.appendingPathComponent("-dash.txt").path))
    }

    func testAPasswordIsRefusedRatherThanIgnored() async throws {
        do {
            _ = try await compress([project], name: "Secret.zpaq", password: "no")
            XCTFail("Expected an error")
        } catch let TampError.other(message) {
            XCTAssertTrue(message.contains("password"), message)
        }
        XCTAssertEqual(try contents(of: output), [])
    }

    func testAMissingItemFailsInsteadOfBeingSkipped() async throws {
        do {
            _ = try await compress([project, project.appendingPathComponent("gone.txt")], name: "Missing.zpaq")
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? TampError, .fileNotFound(path: project.appendingPathComponent("gone.txt").path))
        }
        XCTAssertEqual(try contents(of: output), [])
    }

    func testDamagedArchivesAreReportedAndLeaveNothingBehind() async throws {
        let archive = try await compress([project], name: "Whole.zpaq")
        let data = try Data(contentsOf: archive)
        let truncated = output.appendingPathComponent("Truncated.zpaq")
        try data.prefix(data.count / 2).write(to: truncated)
        let target = try makeFolder("Damaged")
        do {
            _ = try await engine.extract(ExtractRequest(archive: truncated, destinationDirectory: target), progress: { _ in })
            XCTFail("Expected a damaged-archive error")
        } catch {
            XCTAssertEqual(error as? TampError, .corruptArchive)
        }
        // Without the locator tag zpaq assumes encryption, so a password is what's missing.
        let garbage = output.appendingPathComponent("Garbage.zpaq")
        try Data("not a zpaq archive".utf8).write(to: garbage)
        do {
            _ = try await engine.extract(ExtractRequest(archive: garbage, destinationDirectory: target), progress: { _ in })
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? TampError, .passwordRequired)
        }
        XCTAssertEqual(try contents(of: target), [])
    }

    func testStoredNamesCantEscapeTheDestination() async throws {
        // zpaq itself writes "../escape.txt" above its -to folder; Tamp's patch keeps it inside.
        let source = project.appendingPathComponent("readme.txt")
        let archive = output.appendingPathComponent("Escape.zpaq")
        let zpaq = try HelperLocator.standard.url(for: "zpaq")
        let result = try await ProcessRunner().run(zpaq, arguments: ["a", archive.path, source.path, "-to", "../escape.txt"])
        XCTAssertTrue(result.succeeded, result.standardError)

        let target = try makeFolder("Inside/Target")
        let extracted = try await engine.extract(ExtractRequest(archive: archive, destinationDirectory: target), progress: { _ in })
        XCTAssertEqual(extracted.lastPathComponent, "escape.txt")
        XCTAssertEqual(extracted.deletingLastPathComponent().path, target.path)
        XCTAssertFalse(fileManager.fileExists(atPath: workspace.appendingPathComponent("Inside/escape.txt").path))
    }

    func testTheRegistryOpensZpaqFiles() async throws {
        let archive = try await compress([project], name: "Detect.zpaq", step: .fastest)
        XCTAssertEqual(ArchiveDetector.format(of: archive), .zpaq)
        XCTAssertEqual(EngineRegistry.standard().extractor(for: archive)?.format, .zpaq)
        XCTAssertTrue(ZpaqEngine.hasSignature(archive))
    }

    func testCancelLeavesNoPartialArchive() async throws {
        try Self.randomData(count: 16 << 20).write(to: project.appendingPathComponent("data/big.bin"))
        let (started, signal) = AsyncStream<Void>.makeStream()
        let engine = engine!
        let request = CompressRequest(items: [project], destination: output.appendingPathComponent("Big.zpaq"), step: .best,
                                      options: ArchiveOptions(threads: 2))
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
}

final class ZpaqMappingTests: XCTestCase {
    let mapping = ZpaqMapping()

    func testMethodsPerStep() {
        let methods = SpeedStep.allCases.map { mapping.parameters(for: $0, options: ArchiveOptions(threads: 3)).method }
        XCTAssertEqual(methods, [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(mapping.parameters(for: .best, options: ArchiveOptions(threads: 3)).arguments, ["-m5", "-threads", "3"])
    }

    func testSlowStepsSaySo() {
        XCTAssertTrue(mapping.hint(for: .best, options: ArchiveOptions(threads: 2)).notes[0].contains("slow"))
        XCTAssertFalse(mapping.hint(for: .normal, options: ArchiveOptions(threads: 2)).notes.contains { $0.contains("slow") })
        XCTAssertTrue(mapping.hint(for: .normal, options: ArchiveOptions(threads: 2)).notes.contains { $0.contains("links") })
    }

    func testMemoryScalesWithThreads() {
        let one = mapping.hint(for: .best, options: ArchiveOptions(threads: 1)).peakMemoryBytes
        let four = mapping.hint(for: .best, options: ArchiveOptions(threads: 4)).peakMemoryBytes
        XCTAssertEqual(four, one * 4)
    }

    func testProgressParsing() {
        XCTAssertEqual(ZpaqEngine.fraction(in: "42.50% 0:01:05"), 0.425)
        XCTAssertEqual(ZpaqEngine.fraction(in: "100.00% 0:00:00 "), 1)
        XCTAssertNil(ZpaqEngine.fraction(in: "Adding 3.000015 MB in 4 files -method 36 -threads 2"))
        XCTAssertNil(ZpaqEngine.fraction(in: "0.000000 + (3.0 -> 3.0 -> 3.0) = 3.0 MB"))
        XCTAssertNil(ZpaqEngine.fraction(in: "150% odd"))
    }

    func testErrorMessages() {
        XCTAssertEqual(ZpaqEngine.error(exitCode: 2, standardError: "zpaq error: archive not found"), .corruptArchive)
        XCTAssertEqual(ZpaqEngine.error(exitCode: 2, standardError: "zpaq error: password incorrect"), .wrongPassword)
        XCTAssertEqual(ZpaqEngine.error(exitCode: 1, standardError: "std::bad_alloc"), .outOfMemory)
    }
}
