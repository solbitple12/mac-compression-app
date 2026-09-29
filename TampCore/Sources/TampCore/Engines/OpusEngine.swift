import Foundation

/// A preset-to-bitrate mapping for Opus, in kbps. Opus is lossy only and tuned
/// for good quality at low bitrates, so these sit well below AAC's equivalents.
public enum OpusMapping {
    public static func kilobitsPerSecond(for value: MediaQuality) -> Int {
        switch value {
        case .lossless: return 192
        case let .preset(preset):
            switch preset {
            case .low: return 48
            case .medium: return 80
            case .high: return 128
            case .veryHigh: return 192
            }
        case let .customBitrate(kbps): return max(6, kbps)
        case let .customQuality(percent):
            let clamped: Double = min(100, max(0, percent))
            let value: Double = 48 + (192 - 48) * (clamped / 100)
            return Int(value)
        }
    }
}

/// Opus encoding through the bundled opusenc helper.
public struct OpusEngine: AudioEngine {
    static let helperName = "opusenc"

    private let runner: ProcessRunner
    private let helpers: HelperLocator

    public init(runner: ProcessRunner = ProcessRunner(), helpers: HelperLocator = .standard) {
        self.runner = runner
        self.helpers = helpers
    }

    public var format: AudioFormat { .opus }

    public func compress(_ request: AudioCompressRequest, progress: @escaping ProgressHandler) async throws -> AudioCompressResult {
        guard FileManager.default.fileExists(atPath: request.source.path) else {
            throw TampError.fileNotFound(path: request.source.path)
        }
        let opusenc = try helpers.url(for: Self.helperName)
        let inputBytes = Self.fileSize(request.source)
        let bitrate = OpusMapping.kilobitsPerSecond(for: request.quality)

        let output = try await SafeOutput.write(to: request.destination, fileExtension: format.fileExtension) { temporary in
            progress(0)
            let arguments = ["--quiet", "--bitrate", "\(bitrate)", request.source.path, temporary.path]
            let result = try await runner.run(opusenc, arguments: arguments)
            guard result.succeeded else {
                throw TampError.classify(tool: "opusenc", exitCode: result.exitCode, standardError: result.standardError)
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
