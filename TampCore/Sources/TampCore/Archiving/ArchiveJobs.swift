import Foundation

/// Puts compress and extract requests on a `JobQueue`, wiring the engine's
/// progress into the job's ETA and recording the output for "Show in Finder".
public enum ArchiveJobs {
    @discardableResult
    public static func compress(_ request: CompressRequest, engine: any ArchiveEngine, on queue: JobQueue) async -> JobID {
        // Walking a large folder takes a while, so it stays off the caller's actor.
        let totalBytes = await Task.detached(priority: .userInitiated) {
            InputSize.totalBytes(of: request.items)
        }.value
        let title = "Compressing \(ArchivePlanner.displayName(for: request.items)) as \(engine.format.title)"
        return await queue.enqueue(title: title, totalBytes: totalBytes) { context in
            let output = try await engine.compress(request, progress: context.progressHandler(totalBytes: totalBytes))
            await context.reportOutput(output)
        }
    }

    @discardableResult
    public static func extract(_ request: ExtractRequest, engine: any ArchiveEngine, on queue: JobQueue) async -> JobID {
        let totalBytes = Int64((try? request.archive.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let title = "Extracting \(ArchivePlanner.displayName(for: [request.archive]))"
        return await queue.enqueue(title: title, totalBytes: totalBytes) { context in
            let output = try await engine.extract(request, progress: context.progressHandler(totalBytes: totalBytes))
            await context.reportOutput(output)
        }
    }
}
