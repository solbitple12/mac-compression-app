import Foundation

/// Puts image, audio and video compress requests on a `JobQueue`. Unlike
/// `ArchiveJobs.compress`, which bundles every dropped item into one archive,
/// each media file becomes its own independent job with its own output -
/// the same one-at-a-time shape `ArchiveJobs.extract` already uses for archives.
public enum MediaJobs {
    @discardableResult
    public static func compress(
        _ request: ImageCompressRequest,
        engine: any ImageEngine,
        on queue: JobQueue,
        willWrite: ArchiveJobs.OutputFolderHandler? = nil
    ) async -> JobID {
        await enqueue(source: request.source, formatTitle: engine.format.title, on: queue, willWrite: willWrite) { context, totalBytes in
            let result = try await engine.compress(request, progress: context.progressHandler(totalBytes: totalBytes))
            return result.output
        }
    }

    @discardableResult
    public static func compress(
        _ request: AudioCompressRequest,
        engine: any AudioEngine,
        on queue: JobQueue,
        willWrite: ArchiveJobs.OutputFolderHandler? = nil
    ) async -> JobID {
        await enqueue(source: request.source, formatTitle: engine.format.title, on: queue, willWrite: willWrite) { context, totalBytes in
            let result = try await engine.compress(request, progress: context.progressHandler(totalBytes: totalBytes))
            return result.output
        }
    }

    @discardableResult
    public static func compress(
        _ request: VideoCompressRequest,
        engine: any VideoEngine,
        on queue: JobQueue,
        willWrite: ArchiveJobs.OutputFolderHandler? = nil
    ) async -> JobID {
        await enqueue(source: request.source, formatTitle: engine.format.title, on: queue, willWrite: willWrite) { context, totalBytes in
            let result = try await engine.compress(request, progress: context.progressHandler(totalBytes: totalBytes))
            return result.output
        }
    }

    private static func enqueue(
        source: URL, formatTitle: String, on queue: JobQueue,
        willWrite: ArchiveJobs.OutputFolderHandler?,
        run: @escaping @Sendable (JobContext, Int64) async throws -> URL
    ) async -> JobID {
        let subject = "“\(source.lastPathComponent)” as \(formatTitle)"
        let totalBytes = InputSize.totalBytes(of: [source])
        let destinationDirectory = source.deletingLastPathComponent()
        return await queue.enqueue(title: "Compressing \(subject)", finishedTitle: "Compressed \(subject)", totalBytes: totalBytes) { context in
            context.control.outputDirectory = destinationDirectory
            willWrite?(destinationDirectory)
            let output = try await run(context, totalBytes)
            await context.reportOutput(output)
        }
    }
}
