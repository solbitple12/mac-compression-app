import Foundation

/// Puts compress and extract requests on a `JobQueue`, wiring the engine's
/// progress into the job's ETA and recording the output for "Show in Finder".
public enum ArchiveJobs {
    /// Called with the folder a job writes into, just before it starts writing,
    /// so a crash mid-job leaves a partial file Tamp knows to clean up.
    public typealias OutputFolderHandler = @Sendable (URL) -> Void

    /// What happens once the archive is written.
    public struct Afterwards: Sendable {
        /// Opens the archive again with the same engine and compares it with the originals.
        public var verifies: Bool
        /// Moves the originals to the Trash, only once the archive (and its check) succeeded.
        public var trashesOriginals: Bool

        public init(verifies: Bool = false, trashesOriginals: Bool = false) {
            self.verifies = verifies
            self.trashesOriginals = trashesOriginals
        }
    }

    /// Enqueues at once, so the job can be seen and stopped while the input is
    /// still being measured, which takes a while for a large folder.
    @discardableResult
    public static func compress(
        _ request: CompressRequest,
        engine: any ArchiveEngine,
        on queue: JobQueue,
        afterwards: Afterwards = Afterwards(),
        willWrite: OutputFolderHandler? = nil
    ) async -> JobID {
        let subject = "\(ArchivePlanner.displayName(for: request.items)) as \(engine.format.title)"
        return await queue.enqueue(title: "Compressing \(subject)", finishedTitle: "Compressed \(subject)", totalBytes: 0) { context in
            let inputBytes = InputSize.totalBytes(of: request.items)
            try Task.checkCancellation()
            // Checking reads everything again, so it counts as much as compressing.
            await context.setTotalBytes(afterwards.verifies ? 2 * inputBytes : inputBytes)
            willWrite?(request.destination.deletingLastPathComponent())
            let output = try await engine.compress(request, progress: context.progressHandler(totalBytes: inputBytes))
            await context.reportOutput(output)
            if afterwards.verifies {
                try await ArchiveVerifier.verify(
                    output, items: request.items, password: request.password, extractor: engine,
                    allowances: .for(request, format: engine.format),
                    progress: context.progressHandler(totalBytes: inputBytes, offset: inputBytes)
                )
            }
            if afterwards.trashesOriginals {
                try trash(request.items)
            }
        }
    }

    /// Moves each item to the Trash, where it can be put back.
    static func trash(_ items: [URL], fileManager: FileManager = .default) throws {
        for item in items {
            do {
                try fileManager.trashItem(at: item, resultingItemURL: nil)
            } catch {
                throw TampError.other("The archive is ready, but “\(item.lastPathComponent)” couldn't be moved to the Trash.")
            }
        }
    }

    @discardableResult
    public static func extract(
        _ request: ExtractRequest,
        engine: any ArchiveExtractor,
        on queue: JobQueue,
        willWrite: OutputFolderHandler? = nil
    ) async -> JobID {
        let totalBytes = Int64((try? request.archive.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let subject = ArchivePlanner.displayName(for: [request.archive])
        return await queue.enqueue(title: "Extracting \(subject)", finishedTitle: "Extracted \(subject)", totalBytes: totalBytes) { context in
            willWrite?(request.destinationDirectory)
            let output = try await engine.extract(request, progress: context.progressHandler(totalBytes: totalBytes))
            await context.reportOutput(output)
        }
    }
}
