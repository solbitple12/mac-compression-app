import Foundation

/// Puts compress and extract requests on a `JobQueue`, wiring the engine's
/// progress into the job's ETA and recording the output for "Show in Finder".
public enum ArchiveJobs {
    /// Called with the folder a job writes into, just before it starts writing,
    /// so a crash mid-job leaves a partial file Tamp knows to clean up.
    public typealias OutputFolderHandler = @Sendable (URL) -> Void

    /// Enqueues at once, so the job can be seen and stopped while the input is
    /// still being measured, which takes a while for a large folder.
    @discardableResult
    public static func compress(
        _ request: CompressRequest,
        engine: any ArchiveEngine,
        on queue: JobQueue,
        willWrite: OutputFolderHandler? = nil
    ) async -> JobID {
        let title = "Compressing \(ArchivePlanner.displayName(for: request.items)) as \(engine.format.title)"
        return await queue.enqueue(title: title, totalBytes: 0) { context in
            let totalBytes = InputSize.totalBytes(of: request.items)
            try Task.checkCancellation()
            await context.setTotalBytes(totalBytes)
            willWrite?(request.destination.deletingLastPathComponent())
            let output = try await engine.compress(request, progress: context.progressHandler(totalBytes: totalBytes))
            await context.reportOutput(output)
        }
    }

    @discardableResult
    public static func extract(
        _ request: ExtractRequest,
        engine: any ArchiveEngine,
        on queue: JobQueue,
        willWrite: OutputFolderHandler? = nil
    ) async -> JobID {
        let totalBytes = Int64((try? request.archive.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let title = "Extracting \(ArchivePlanner.displayName(for: [request.archive]))"
        return await queue.enqueue(title: title, totalBytes: totalBytes) { context in
            willWrite?(request.destinationDirectory)
            let output = try await engine.extract(request, progress: context.progressHandler(totalBytes: totalBytes))
            await context.reportOutput(output)
        }
    }
}
