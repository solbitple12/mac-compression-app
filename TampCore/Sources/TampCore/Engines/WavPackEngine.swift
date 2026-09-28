import Foundation

/// The `wavpack` encoder's compression flags, mapped from the six speed steps.
/// There's no true store level (no flag skips its lossless prediction step
/// entirely), so Store and Fastest both mean "as fast as it goes": `-f`.
public enum WavPackMapping {
    public static func arguments(for step: SpeedStep) -> [String] {
        switch step {
        case .store, .fastest: ["-f"]
        case .fast: []
        case .normal: ["-h"]
        case .good: ["-hh"]
        case .best: ["-hh", "-x6"]
        }
    }
}

/// WavPack encoding through the bundled `wavpack` helper. Always lossless, so
/// `request.quality` is ignored.
public struct WavPackEngine: AudioEngine {
    static let helperName = "wavpack"

    private let runner: ProcessRunner
    private let helpers: HelperLocator

    public init(runner: ProcessRunner = ProcessRunner(), helpers: HelperLocator = .standard) {
        self.runner = runner
        self.helpers = helpers
    }

    public var format: AudioFormat { .wavpack }

    public func compress(_ request: AudioCompressRequest, progress: @escaping ProgressHandler) async throws -> AudioCompressResult {
        guard FileManager.default.fileExists(atPath: request.source.path) else {
            throw TampError.fileNotFound(path: request.source.path)
        }
        let wavpack = try helpers.url(for: Self.helperName)
        let inputBytes = Self.fileSize(request.source)

        let output = try await SafeOutput.write(to: request.destination, fileExtension: format.fileExtension) { temporary in
            progress(0)
            let arguments = ["-y"] + WavPackMapping.arguments(for: request.step) + ["-o", temporary.path, request.source.path]
            let result = try await runner.run(wavpack, arguments: arguments)
            guard result.succeeded else {
                throw TampError.classify(tool: "wavpack", exitCode: result.exitCode, standardError: result.standardError)
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
