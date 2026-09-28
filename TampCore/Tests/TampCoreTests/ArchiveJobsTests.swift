import XCTest
@testable import TampCore

/// The path the window takes: a drop becomes a queued job that runs a real engine.
final class ArchiveJobsTests: EngineTestCase {
    override var requiredHelpers: [String] { ["7zz", "bsdtar", "zstd"] }

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
            assertMatchesProject(try XCTUnwrap(extracted?.output))
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
}
