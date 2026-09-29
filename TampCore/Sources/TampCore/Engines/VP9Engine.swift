import Foundation

/// libvpx's `-cpu-used`, 8 (fastest) down to 1 (slowest, best compression),
/// per the architecture plan. A starting point pending a real per-step benchmark.
public enum VP9Mapping {
    public static func cpuUsed(for step: SpeedStep) -> Int {
        switch step {
        case .store: 8
        case .fastest: 7
        case .fast: 5
        case .normal: 4
        case .good: 2
        case .best: 1
        }
    }
}

/// VP9 encoding through FFmpeg's libvpx-vp9, in constant-quality mode with row
/// multithreading. `-b:v 0` is required alongside `-crf`: without it libvpx
/// treats the CRF as a ceiling on a bitrate-controlled encode rather than pure
/// constant quality (ffmpeg's own libvpxenc.c reads `-b:v 0` as the signal to
/// use "constrained quality" mode outright).
public struct VP9Engine: VideoEngine {
    private let runner: ProcessRunner
    private let helpers: HelperLocator

    public init(runner: ProcessRunner = ProcessRunner(), helpers: HelperLocator = .standard) {
        self.runner = runner
        self.helpers = helpers
    }

    public var format: VideoFormat { .vp9 }

    public func compress(_ request: VideoCompressRequest, progress: @escaping ProgressHandler) async throws -> VideoCompressResult {
        guard FileManager.default.fileExists(atPath: request.source.path) else {
            throw TampError.fileNotFound(path: request.source.path)
        }
        let ffmpeg = try helpers.url(for: FFmpegConversion.helperName)
        let inputBytes = FFmpegConversion.fileSize(request.source)
        let codecArguments = [
            "-c:v", "libvpx-vp9",
            "-b:v", "0",
            "-crf", "\(VideoQualityMapping.crf(for: request.quality))",
            "-cpu-used", "\(VP9Mapping.cpuUsed(for: request.step))",
            "-row-mt", "1",
        ]

        let output = try await SafeOutput.write(to: request.destination, fileExtension: format.fileExtension) { temporary in
            try await FFmpegConversion.run(
                runner: runner, ffmpeg: ffmpeg, source: request.source, destination: temporary,
                codecArguments: codecArguments, progress: progress
            )
            guard FileManager.default.fileExists(atPath: temporary.path) else {
                throw TampError.fileNotFound(path: request.source.path)
            }
        }
        return VideoCompressResult(output: output, inputBytes: inputBytes, outputBytes: FFmpegConversion.fileSize(output))
    }
}
