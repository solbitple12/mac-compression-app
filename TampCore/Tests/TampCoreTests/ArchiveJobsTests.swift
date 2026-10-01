import XCTest
@testable import TampCore

/// The path the window takes: a drop becomes a queued job that runs a real engine.
final class ArchiveJobsTests: EngineTestCase {
    override var requiredHelpers: [String] { ["7zz", "bsdtar", "zstd", "xz", "pigz", "pbzip2", "brotli"] }

    func testDroppedFolderIsCompressedThenExtractedThroughTheQueue() async throws {
        let registry = EngineRegistry.standard()
        let queue = JobQueue()
        for format in registry.availableFormats {
            let items = [project!]
            guard case let .compress(toCompress) = ArchivePlanner.action(for: items, registry: registry) else {
                return XCTFail("A folder should be compressed")
            }
            let engine = try XCTUnwrap(registry.engine(for: format))
            let request = CompressRequest(items: toCompress, destination: ArchivePlanner.destination(for: toCompress, format: format), step: .fast)
            let compressID = await ArchiveJobs.compress(request, engine: engine, on: queue)
            let compressed = await queue.waitUntilDone(compressID)
            XCTAssertEqual(compressed?.state, .finished, format.title)
            XCTAssertEqual(compressed?.displayTitle, "Compressed “Project” as \(format.title)")
            let archive = try XCTUnwrap(compressed?.output, format.title)
            XCTAssertEqual(archive.deletingLastPathComponent().standardizedFileURL.path, workspace.standardizedFileURL.path)
            XCTAssertEqual(archive.lastPathComponent, "Project.\(format.fileExtension)")

            guard case let .extract(archives) = ArchivePlanner.action(for: [archive], registry: registry) else {
                return XCTFail("\(format.title) archive should be extracted")
            }
            let extractor = try XCTUnwrap(registry.extractor(for: archives[0]))
            let target = try makeFolder("Out-\(format.title)")
            let extractID = await ArchiveJobs.extract(ExtractRequest(archive: archives[0], destinationDirectory: target), engine: extractor, on: queue)
            let extracted = await queue.waitUntilDone(extractID)
            XCTAssertEqual(extracted?.state, .finished, format.title)
            XCTAssertEqual(extracted?.displayTitle, "Extracted “\(archive.lastPathComponent)”")
            let unpacked = try XCTUnwrap(extracted?.output)
            if format == .dmg {
                // hdiutil copies everything, .DS_Store files included.
                XCTAssertTrue(fileManager.contentsEqual(atPath: project.appendingPathComponent("data/random.bin").path,
                                                        andPath: unpacked.appendingPathComponent("data/random.bin").path))
            } else {
                assertMatchesProject(unpacked)
            }
            try fileManager.removeItem(at: archive)
        }
    }

    func testAMissingHelperFailsTheJobWithAClearError() async throws {
        let registry = EngineRegistry.standard(helpers: HelperLocator(directories: []))
        let queue = JobQueue()
        let engine = try XCTUnwrap(registry.engine(for: .zip))
        let id = await ArchiveJobs.compress(
            CompressRequest(items: [project], destination: output.appendingPathComponent("Nope.zip"), step: .normal),
            engine: engine, on: queue
        )
        let done = await queue.waitUntilDone(id)
        XCTAssertEqual(done?.state, .failed(.helperMissing(name: "7zz")))
        XCTAssertEqual(try contents(of: output), [])
    }

    func testVerifyThenTrashTheOriginals() async throws {
        let registry = EngineRegistry.standard()
        let queue = JobQueue()
        let engine = try XCTUnwrap(registry.engine(for: .sevenZip))
        let copy = workspace.appendingPathComponent("Copy")
        try fileManager.copyItem(at: project, to: copy)
        let id = await ArchiveJobs.compress(
            CompressRequest(items: [copy], destination: output.appendingPathComponent("Copy.7z"), step: .fast),
            engine: engine, on: queue, afterwards: ArchiveJobs.Afterwards(verifies: true, trashesOriginals: true)
        )
        let done = await queue.waitUntilDone(id)
        XCTAssertEqual(done?.state, .finished)
        XCTAssertEqual(try contents(of: output), ["Copy.7z"], "the check leaves nothing behind")
        XCTAssertFalse(fileManager.fileExists(atPath: copy.path), "the original went to the Trash")
    }

    func testVerificationFindsWhatAnArchiveLost() throws {
        let copy = workspace.appendingPathComponent("Copy")
        try fileManager.copyItem(at: project, to: copy)
        let lenient = ArchiveVerifier.Allowances(junkMayBeMissing: true)
        XCTAssertNil(ArchiveVerifier.difference(between: project, and: copy, allowances: lenient, fileManager: fileManager))
        try Data("changed".utf8).write(to: copy.appendingPathComponent("readme.txt"))
        XCTAssertEqual(ArchiveVerifier.difference(between: project, and: copy, allowances: lenient, fileManager: fileManager),
                       "“Project/readme.txt” differs")
        try fileManager.removeItem(at: copy.appendingPathComponent("data"))
        XCTAssertEqual(ArchiveVerifier.difference(between: project, and: copy, allowances: lenient, fileManager: fileManager),
                       "“Project/data” is missing")
        // Junk the job left out on purpose doesn't count.
        let clean = workspace.appendingPathComponent("Clean")
        try fileManager.copyItem(at: project, to: clean)
        try fileManager.removeItem(at: clean.appendingPathComponent(".DS_Store"))
        XCTAssertNil(ArchiveVerifier.difference(between: project, and: clean, allowances: lenient, fileManager: fileManager))
        XCTAssertNotNil(ArchiveVerifier.difference(between: project, and: clean, allowances: .init(), fileManager: fileManager))
    }
}
