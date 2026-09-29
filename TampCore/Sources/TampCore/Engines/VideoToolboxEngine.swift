import Foundation

/// H.264 and HEVC both go through VideoToolbox, Apple's hardware encoder
/// available on every Mac this app targets, with no software fallback: x264
/// and x265 are GPL, so Tamp doesn't bundle either (see CLAUDE.md's licensing
/// rules). Quality per bit is below x265's slow presets, but it's fast, and
/// patent licensing for H.264/HEVC is carried by Apple's encoder rather than
/// by Tamp bundling one of its own.
enum VideoToolboxMapping {
    /// VideoToolbox's constant-quality mode (`-q:v`) only takes effect on
    /// Apple Silicon (confirmed against ffmpeg's own videotoolboxenc.c:
    /// `vtenc_qscale_enabled()` gates it on `TARGET_CPU_ARM64`); on Intel the
    /// encoder silently falls back to needing a bitrate instead. `#if
    /// arch(arm64)` is a compile-time check of which slice of Tamp's
    /// universal binary is running, which is exactly what decides that.
    static var supportsConstantQuality: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }

    /// ffmpeg's `-q:v N` on this encoder sets VideoToolbox's own 0.0-1.0
    /// quality property to N/100 (traced through videotoolboxenc.c's own
    /// scaling: `global_quality / (FF_QP2LAMBDA * 100)`, and the CLI's
    /// `-q:v N` sets `global_quality` to `N * FF_QP2LAMBDA`), so this can pass
    /// `ImageQualityMapping`'s 0-100 percent straight through with no rescaling.
    static func qualityArguments(for value: MediaQuality) -> [String] {
        if supportsConstantQuality {
            return ["-q:v", "\(ImageQualityMapping.percent(for: value))"]
        }
        return ["-b:v", "\(kilobitsPerSecond(for: value))k"]
    }

    /// Intel's bitrate fallback. A starting point pending a real per-step
    /// benchmark, like `AvifMapping.speed` and the other Phase 3/4 mappings.
    private static func kilobitsPerSecond(for value: MediaQuality) -> Int {
        switch value {
        case .lossless: return 20000
        case let .preset(preset):
            switch preset {
            case .low: return 2000
            case .medium: return 5000
            case .high: return 9000
            case .veryHigh: return 16000
            }
        case let .customBitrate(kbps): return max(200, kbps)
        case let .customQuality(percent):
            let clamped = min(100, max(0, percent))
            return Int(2000 + (16000 - 2000) * (clamped / 100))
        }
    }
}

/// Shared by `H264Engine` and `HEVCEngine`: both just pick VideoToolbox's
/// encoder name and quality arguments, then run the same FFmpeg conversion.
enum VideoToolboxConversion {
    static func compress(
        _ request: VideoCompressRequest, encoderName: String, runner: ProcessRunner, helpers: HelperLocator,
        progress: @escaping ProgressHandler
    ) async throws -> VideoCompressResult {
        guard FileManager.default.fileExists(atPath: request.source.path) else {
            throw TampError.fileNotFound(path: request.source.path)
        }
        let ffmpeg = try helpers.url(for: FFmpegConversion.helperName)
        let inputBytes = FFmpegConversion.fileSize(request.source)
        let codecArguments = ["-c:v", encoderName] + VideoToolboxMapping.qualityArguments(for: request.quality)

        let output = try await SafeOutput.write(to: request.destination, fileExtension: request.format.fileExtension) { temporary in
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

/// H.264 encoding through VideoToolbox.
public struct H264Engine: VideoEngine {
    private let runner: ProcessRunner
    private let helpers: HelperLocator

    public init(runner: ProcessRunner = ProcessRunner(), helpers: HelperLocator = .standard) {
        self.runner = runner
        self.helpers = helpers
    }

    public var format: VideoFormat { .h264 }

    public func compress(_ request: VideoCompressRequest, progress: @escaping ProgressHandler) async throws -> VideoCompressResult {
        try await VideoToolboxConversion.compress(request, encoderName: "h264_videotoolbox", runner: runner, helpers: helpers, progress: progress)
    }
}

/// HEVC encoding through VideoToolbox.
public struct HEVCEngine: VideoEngine {
    private let runner: ProcessRunner
    private let helpers: HelperLocator

    public init(runner: ProcessRunner = ProcessRunner(), helpers: HelperLocator = .standard) {
        self.runner = runner
        self.helpers = helpers
    }

    public var format: VideoFormat { .hevc }

    public func compress(_ request: VideoCompressRequest, progress: @escaping ProgressHandler) async throws -> VideoCompressResult {
        try await VideoToolboxConversion.compress(request, encoderName: "hevc_videotoolbox", runner: runner, helpers: helpers, progress: progress)
    }
}
