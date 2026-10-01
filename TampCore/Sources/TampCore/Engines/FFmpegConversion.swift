import Foundation

/// Shared FFmpeg plumbing every video engine builds on: the common argument
/// array (overwrite, input, stream passthrough, whatever codec-specific
/// arguments the engine supplies, output) run through the bundled `ffmpeg` helper.
enum FFmpegConversion {
    static let helperName = "ffmpeg"

    /// Runs ffmpeg with `codecArguments` inserted right after `-c copy`, so they
    /// override just what they name; by default that's only the video stream's
    /// codec, and every other stream (audio, subtitles, attachments, chapters,
    /// container metadata) stays copied unchanged, matching the architecture
    /// plan's "-map 0 and -c copy unless the user changes them". VP9Engine is
    /// the one exception, also overriding the audio codec: see its own doc comment.
    static func run(
        runner: ProcessRunner, ffmpeg: URL, source: URL, destination: URL, codecArguments: [String],
        progress: @escaping ProgressHandler
    ) async throws {
        progress(0)
        var arguments = ["-y", "-i", source.path, "-map", "0", "-map_metadata", "0", "-c", "copy"]
        arguments += codecArguments
        arguments += [destination.path]
        let result = try await runner.run(ffmpeg, arguments: arguments)
        guard result.succeeded else {
            throw TampError.classify(tool: "ffmpeg", exitCode: result.exitCode, standardError: result.standardError)
        }
        progress(1)
    }

    static func fileSize(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }
}
