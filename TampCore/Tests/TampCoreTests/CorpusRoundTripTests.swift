import XCTest
@testable import TampCore

/// Byte-for-byte round trips of the test corpus through every engine,
/// and cancel-mid-job checks for extraction and for jobs run by the queue.
final class CorpusRoundTripTests: EngineTestCase {
    override var requiredHelpers: [String] { ["7zz", "bsdtar", "zstd", "xz", "pigz", "pbzip2", "brotli"] }

    private let engines: [any ArchiveEngine] = [ZipEngine()]
        + [ArchiveFormat.tar, .tarGz, .tarBz2, .tarXz, .tarZst, .tarLz4, .tarLz, .tarBr].map { TarEngine(format: $0) }

    private func archiveName(_ base: String, for engine: any ArchiveEngine) -> String {
        "\(base).\(engine.format.fileExtension)"
    }

    func testEveryEngineRoundTripsTheCorpusAtEveryStep() async throws {
        let corpus = try makeCorpus()
        for engine in engines {
            for step in SpeedStep.allCases {
                let label = "\(engine.format.title) \(step.title)"
                let archive = try await engine.compress(
                    CompressRequest(items: [corpus], destination: output.appendingPathComponent(archiveName("Corpus-\(step.title)", for: engine)),
                                    step: step, options: ArchiveOptions(threads: 2)),
                    progress: { _ in }
                )
                let extracted = try await engine.extract(
                    ExtractRequest(archive: archive, destinationDirectory: try makeFolder("Out-\(engine.format.title)-\(step.title)")),
                    progress: { _ in }
                )
                XCTAssertEqual(extracted.lastPathComponent, "Corpus", label)
                try assertTreesEqual(corpus, extracted)
            }
        }
    }

    func testSeveralItemsRoundTripInsideAFolderNamedAfterTheArchive() async throws {
        let corpus = try makeCorpus()
        let items = ["documents", "media", "binary.dat", "tools"].map { corpus.appendingPathComponent($0) }
        for engine in engines {
            let archive = try await engine.compress(
                CompressRequest(items: items, destination: output.appendingPathComponent(archiveName("Loose", for: engine)), step: .normal),
                progress: { _ in }
            )
            let extracted = try await engine.extract(
                ExtractRequest(archive: archive, destinationDirectory: try makeFolder("Loose-\(engine.format.title)")),
                progress: { _ in }
            )
            XCTAssertEqual(extracted.lastPathComponent, "Loose")
            for item in items {
                try assertTreesEqual(item, extracted.appendingPathComponent(item.lastPathComponent))
            }
        }
    }

    func testPasswordProtectedZipRoundTripsTheCorpus() async throws {
        let corpus = try makeCorpus()
        let engine = ZipEngine()
        let archive = try await engine.compress(
            CompressRequest(items: [corpus], destination: output.appendingPathComponent("Locked.zip"), step: .good, password: "corpus pass"),
            progress: { _ in }
        )
        let extracted = try await engine.extract(
            ExtractRequest(archive: archive, destinationDirectory: try makeFolder("Unlocked"), password: "corpus pass"),
            progress: { _ in }
        )
        try assertTreesEqual(corpus, extracted)
    }

    func testCancellingExtractionLeavesNothingBehind() async throws {
        try Self.randomData(count: 64 << 20).write(to: project.appendingPathComponent("data/big.bin"))
        for engine in engines {
            let archive = try await engine.compress(
                CompressRequest(items: [project], destination: output.appendingPathComponent(archiveName("Big", for: engine)), step: .fastest),
                progress: { _ in }
            )
            let target = try makeFolder("Cancelled-\(engine.format.title)")
            let (started, signal) = AsyncStream<Void>.makeStream()
            let task = Task {
                try await engine.extract(ExtractRequest(archive: archive, destinationDirectory: target), progress: { _ in signal.yield() })
            }
            // Cancel on the first progress report, or after a moment if none comes.
            let timeout = Task {
                try? await Task.sleep(for: .milliseconds(500))
                signal.yield()
            }
            for await _ in started { break }
            timeout.cancel()
            task.cancel()
            switch await task.result {
            case .success:
                // Finished before the cancel landed; nothing to check about cancellation.
                break
            case let .failure(error):
                XCTAssertTrue(error is CancellationError, "\(engine.format.title): \(error)")
                XCTAssertEqual(try contents(of: target), [], "\(engine.format.title) left files behind")
            }
            XCTAssertTrue(fileManager.fileExists(atPath: archive.path), "the archive is untouched")
        }
    }

    func testCancellingAQueuedJobMidRunStopsTheHelperAndCleansUp() async throws {
        try Self.randomData(count: 64 << 20).write(to: project.appendingPathComponent("data/big.bin"))
        let queue = JobQueue()
        let updates = await queue.updates()
        let request = CompressRequest(items: [project], destination: output.appendingPathComponent("Queued.tar.zst"), step: .best,
                                      options: ArchiveOptions(threads: 2))
        let totalBytes = InputSize.totalBytes(of: request.items)
        let engine = TarEngine(format: .tarZst)
        let id = await queue.enqueue(title: "Queued", totalBytes: totalBytes) { context in
            _ = try await engine.compress(request, progress: context.progressHandler(totalBytes: totalBytes))
        }
        // Wait until the job has reported real progress, so the helpers are running.
        for await snapshot in updates where snapshot.id == id {
            if case let .running(progress?) = snapshot.state, progress.bytesProcessed > 0 { break }
            if snapshot.state.isFinal { break }
        }
        await queue.cancel(id)
        let final = await queue.waitUntilDone(id)
        switch final?.state {
        case .cancelled:
            XCTAssertEqual(try contents(of: output), [], "no partial archive is left")
        case .finished:
            // Finished before the cancel landed; nothing to check about cancellation.
            break
        default:
            XCTFail("Unexpected end state: \(String(describing: final?.state))")
        }
    }
}
