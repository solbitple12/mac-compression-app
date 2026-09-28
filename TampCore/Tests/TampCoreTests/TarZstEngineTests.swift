import XCTest
@testable import TampCore

final class TarZstEngineTests: EngineTestCase {
    private var engine: TarZstEngine!

    override var requiredHelpers: [String] { ["bsdtar", "zstd"] }

    override func setUpWithError() throws {
        try super.setUpWithError()
        engine = TarZstEngine()
    }

    private func compress(_ step: SpeedStep, name: String = "Project.tar.zst", items: [URL]? = nil) async throws -> URL {
        try await engine.compress(
            CompressRequest(items: items ?? [project], destination: output.appendingPathComponent(name), step: step,
                            options: ArchiveOptions(threads: 2)),
            progress: { _ in }
        )
    }

    func testRoundTripIsByteForByteAtEveryStep() async throws {
        for step in SpeedStep.allCases {
            let archive = try await compress(step, name: "Project-\(step.title).tar.zst")
            let extracted = try await engine.extract(
                ExtractRequest(archive: archive, destinationDirectory: try makeFolder("Extracted-\(step.title)")),
                progress: { _ in }
            )
            XCTAssertEqual(extracted.lastPathComponent, "Project")
            assertMatchesProject(extracted)
        }
    }

    func testStoreWritesAPlainTar() async throws {
        let archive = try await compress(.store)
        XCTAssertEqual(archive.lastPathComponent, "Project.tar")
        XCTAssertFalse(try TarZstEngine.startsWithZstdFrame(archive))
        let extracted = try await engine.extract(ExtractRequest(archive: archive, destinationDirectory: try makeFolder("Plain")), progress: { _ in })
        assertMatchesProject(extracted)
    }

    func testCompressedStepsWriteZstdFrames() async throws {
        let archive = try await compress(.fastest)
        XCTAssertEqual(archive.lastPathComponent, "Project.tar.zst")
        XCTAssertTrue(try TarZstEngine.startsWithZstdFrame(archive))
    }

    func testHigherStepsAreNotLarger() async throws {
        // Text only: the fixture's random data doesn't compress, and on it zstd's
        // higher levels can come out a few bytes larger.
        let text = [project.appendingPathComponent("readme.txt")]
        func size(_ step: SpeedStep) async throws -> Int {
            let archive = try await compress(step, name: "Size-\(step.title).tar.zst", items: text)
            return try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        }
        let store = try await size(.store)
        let fastest = try await size(.fastest)
        let best = try await size(.best)
        XCTAssertLessThan(fastest, store)
        XCTAssertLessThanOrEqual(best, fastest)
    }

    func testItemsFromDifferentFoldersKeepOnlyTheirNames() async throws {
        let other = try makeFolder("Elsewhere")
        let note = other.appendingPathComponent("note.txt")
        try Data("note".utf8).write(to: note)
        let archive = try await compress(.normal, name: "Mixed.tar.zst", items: [project.appendingPathComponent("readme.txt"), note])
        let extracted = try await engine.extract(ExtractRequest(archive: archive, destinationDirectory: try makeFolder("MixedOut")), progress: { _ in })
        XCTAssertEqual(extracted.lastPathComponent, "Mixed")
        XCTAssertEqual(try contents(of: extracted), ["note.txt", "readme.txt"])
    }

    func testNeverOverwritesAnExistingArchive() async throws {
        try Data("keep me".utf8).write(to: output.appendingPathComponent("Project.tar.zst"))
        let archive = try await compress(.fast)
        XCTAssertEqual(archive.lastPathComponent, "Project 2.tar.zst")
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("Project.tar.zst")), Data("keep me".utf8))
    }

    func testDamagedArchiveFailsCleanly() async throws {
        let archive = try await compress(.normal)
        let damaged = output.appendingPathComponent("Damaged.tar.zst")
        try Data(try Data(contentsOf: archive).prefix(4096)).write(to: damaged)
        let target = try makeFolder("DamagedOut")
        do {
            _ = try await engine.extract(ExtractRequest(archive: damaged, destinationDirectory: target), progress: { _ in })
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? TampError, .corruptArchive)
        }
        XCTAssertEqual(try contents(of: target), [])
    }

    func testProgressReachesTheEnd() async throws {
        let seen = LineRecorder()
        _ = try await engine.compress(
            CompressRequest(items: [project], destination: output.appendingPathComponent("Progress.tar.zst"), step: .normal),
            progress: { seen.append(String($0)) }
        )
        let fractions = seen.all.compactMap(Double.init)
        XCTAssertFalse(fractions.isEmpty)
        XCTAssertEqual(fractions.last ?? 0, 1, accuracy: 0.001)
        XCTAssertEqual(fractions, fractions.sorted())
    }

    func testCancelLeavesNoPartialArchive() async throws {
        try Self.randomData(count: 64 << 20).write(to: project.appendingPathComponent("data/big.bin"))
        let (started, signal) = AsyncStream<Void>.makeStream()
        let engine = engine!
        let request = CompressRequest(items: [project], destination: output.appendingPathComponent("Big.tar.zst"), step: .best,
                                      options: ArchiveOptions(threads: 2))
        let task = Task {
            try await engine.compress(request, progress: { _ in signal.yield() })
        }
        for await _ in started { break }
        task.cancel()
        let result = await task.result
        if case let .failure(error) = result {
            XCTAssertTrue(error is CancellationError, "\(error)")
            XCTAssertEqual(try contents(of: output), [])
        }
        XCTAssertTrue(fileManager.fileExists(atPath: project.appendingPathComponent("data/big.bin").path), "inputs are untouched")
    }

    func testNamesAndExtensions() {
        XCTAssertEqual(TarZstEngine.baseName(of: URL(fileURLWithPath: "/a/Logs.tar.zst")), "Logs")
        XCTAssertEqual(TarZstEngine.baseName(of: URL(fileURLWithPath: "/a/Logs.TZST")), "Logs")
        XCTAssertEqual(TarZstEngine.replacingArchiveExtension(of: URL(fileURLWithPath: "/a/Logs.tar.zst"), with: "tar").lastPathComponent, "Logs.tar")
        XCTAssertEqual(TarZstEngine.replacingArchiveExtension(of: URL(fileURLWithPath: "/a/Logs"), with: "tar.zst").lastPathComponent, "Logs.tar.zst")
        XCTAssertEqual(TarZstEngine.tarMemberArguments(for: URL(fileURLWithPath: "/a/-rf")), ["-C", "/a", "./-rf"])
    }
}
