import AVFoundation
import Foundation

/// A short preview clip: the middle few seconds of a video, trimmed losslessly
/// (stream copy, no re-encode - the trim itself must be fast, since it runs
/// every time the user nudges a slider) and then run through the chosen
/// engine's normal `compress`, so previewing settings doesn't cost re-encoding
/// the whole file. Matches the architecture plan's "video encodes a 5-second
/// clip from the middle with the chosen settings and plays both in AVPlayer" -
/// this produces only the re-encoded half; the App layer owns the player and
/// points its other half at the original source directly.
public enum VideoPreview {
    public static let clipSeconds: Double = 5

    /// - Parameter destination: where the trimmed-and-compressed preview goes;
    ///   the caller is responsible for cleaning it up once shown.
    public static func compress(
        source: URL, destination: URL, engine: any VideoEngine, step: SpeedStep, quality: MediaQuality,
        runner: ProcessRunner = ProcessRunner(), helpers: HelperLocator = .standard,
        progress: @escaping ProgressHandler = { _ in }
    ) async throws -> VideoCompressResult {
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw TampError.fileNotFound(path: source.path)
        }
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else {
            throw TampError.other("Tamp couldn't read that video's duration")
        }
        let clip = min(clipSeconds, duration)
        let start = max(0, (duration - clip) / 2)

        let ffmpeg = try helpers.url(for: FFmpegConversion.helperName)
        let sourceExtension = source.pathExtension.isEmpty ? "mp4" : source.pathExtension
        let trimmed = destination.deletingLastPathComponent()
            .appendingPathComponent("\(SafeOutput.partialPrefix)preview-source-\(UUID().uuidString).\(sourceExtension)")
        defer { SafeOutput.remove(trimmed) }
        // -ss before -i seeks to the nearest keyframe at or before `start` without
        // decoding anything first, the fast path a stream copy needs; the clip may
        // start a little early because of that, which is fine for a preview.
        let trimResult = try await runner.run(ffmpeg, arguments: [
            "-y", "-ss", "\(start)", "-i", source.path, "-t", "\(clip)", "-c", "copy", trimmed.path,
        ])
        guard trimResult.succeeded else {
            throw TampError.classify(tool: "ffmpeg", exitCode: trimResult.exitCode, standardError: trimResult.standardError)
        }
        guard FileManager.default.fileExists(atPath: trimmed.path) else {
            throw TampError.other("Tamp couldn't trim a preview clip from that video")
        }

        let request = VideoCompressRequest(source: trimmed, destination: destination, format: engine.format, step: step, quality: quality)
        return try await engine.compress(request, progress: progress)
    }
}
