import Foundation

/// SVT-AV1's `-preset`, 0 (slowest, best compression) to 13 (fastest); the
/// reverse direction of most of Tamp's other speed-step mappings, the same as
/// `AvifMapping.speed`. A starting point pending a real per-step benchmark.
public enum AV1Mapping {
    public static func preset(for step: SpeedStep) -> Int {
        switch step {
        case .store: 12
        case .fastest: 10
        case .fast: 8
        case .normal: 7
        case .good: 6
        case .best: 4
        }
    }
}

/// AV1 encoding through FFmpeg's libsvtav1, the same SVT-AV1 build AvifEngine
/// uses. Unlike AVIF, this has no chroma-format conflict to work around:
/// libsvtav1 isn't asked for a lossless mode here, only a CRF.
public struct AV1Engine: VideoEngine {
    private let runner: ProcessRunner
    private let helpers: HelperLocator

    public init(runner: ProcessRunner = ProcessRunner(), helpers: HelperLocator = .standard) {
        self.runner = runner
        self.helpers = helpers
    }

    public var format: VideoFormat { .av1 }

    public func compress(_ request: VideoCompressRequest, progress: @escaping ProgressHandler) async throws -> VideoCompressResult {
        guard FileManager.default.fileExists(atPath: request.source.path) else {
            throw TampError.fileNotFound(path: request.source.path)
        }
        let ffmpeg = try helpers.url(for: FFmpegConversion.helperName)
        let inputBytes = FFmpegConversion.fileSize(request.source)
        let codecArguments = [
            "-c:v", "libsvtav1",
            "-preset", "\(AV1Mapping.preset(for: request.step))",
            "-crf", "\(VideoQualityMapping.crf(for: request.quality))",
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
