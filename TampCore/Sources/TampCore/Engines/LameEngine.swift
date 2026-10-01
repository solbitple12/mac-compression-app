import Foundation

/// LAME's `--vbr-new -V` scale, 0 (best) to 9 (worst), from a quality request.
/// Store, WavPack's `-f` and FLAC's `--best` have no MP3 equivalent since MP3 is
/// lossy only; `request.quality` drives this, not the speed step.
public enum LameMapping {
    public static func vbrQuality(for value: MediaQuality) -> Int {
        switch value {
        case .lossless: return 0 // MP3 has no lossless mode; "lossless" here just means "best".
        case let .preset(preset):
            switch preset {
            case .low: return 7
            case .medium: return 4
            case .high: return 2
            case .veryHigh: return 0
            }
        case let .customQuality(percent):
            let clamped: Double = min(100, max(0, percent))
            let scale: Double = (clamped / 100 * 9).rounded()
            return 9 - Int(scale)
        case .customBitrate: return 2 // LAME's -V has no direct bitrate target; falls back to High.
        }
    }
}

/// MP3 encoding through the bundled `lame` helper, at LAME's own VBR quality scale.
public struct LameEngine: AudioEngine {
    static let helperName = "lame"

    private let runner: ProcessRunner
    private let helpers: HelperLocator

    public init(runner: ProcessRunner = ProcessRunner(), helpers: HelperLocator = .standard) {
        self.runner = runner
        self.helpers = helpers
    }

    public var format: AudioFormat { .mp3 }

    public func compress(_ request: AudioCompressRequest, progress: @escaping ProgressHandler) async throws -> AudioCompressResult {
        guard FileManager.default.fileExists(atPath: request.source.path) else {
            throw TampError.fileNotFound(path: request.source.path)
        }
        let lame = try helpers.url(for: Self.helperName)
        let inputBytes = Self.fileSize(request.source)
        let quality = LameMapping.vbrQuality(for: request.quality)

        let output = try await SafeOutput.write(to: request.destination, fileExtension: format.fileExtension) { temporary in
            progress(0)
            var arguments = ["--quiet", "--vbr-new", "-V", "\(quality)"]
            // LAME writes its own ID3 tags only when told to; there's nothing to
            // strip since a plain encode from WAV/AIFF carries none in the first place.
            if request.metadata != .keep { arguments.append("--noreplaygain") }
            arguments += [request.source.path, temporary.path]
            let result = try await runner.run(lame, arguments: arguments)
            guard result.succeeded else {
                throw TampError.classify(tool: "lame", exitCode: result.exitCode, standardError: result.standardError)
            }
            guard FileManager.default.fileExists(atPath: temporary.path) else {
                throw TampError.fileNotFound(path: request.source.path)
            }
            progress(1)
        }
        return AudioCompressResult(output: output, inputBytes: inputBytes, outputBytes: Self.fileSize(output))
    }

    private static func fileSize(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }
}
