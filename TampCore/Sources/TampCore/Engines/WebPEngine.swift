import Foundation

/// cwebp's two separate speed controls: `-m` (0 to 6) for a lossy encode's
/// compression method, `-z` (0 to 9) for a lossless encode's effort. Starting
/// points, like the other Phase 3 mappings, pending a real per-step benchmark.
public enum WebPMapping {
    public static func lossyMethod(for step: SpeedStep) -> Int {
        switch step {
        case .store: 0
        case .fastest: 1
        case .fast: 2
        case .normal: 4
        case .good: 5
        case .best: 6
        }
    }

    public static func losslessEffort(for step: SpeedStep) -> Int {
        switch step {
        case .store: 0
        case .fastest: 2
        case .fast: 4
        case .normal: 6
        case .good: 8
        case .best: 9
        }
    }

    public static func quality(for value: MediaQuality) -> Int {
        ImageQualityMapping.percent(for: value) // unused for .lossless: -lossless is passed instead.
    }

    /// cwebp strips every metadata block by default; `-metadata all` is the only
    /// way to keep any of it, and there's no per-tag control to keep everything but
    /// GPS, so "strip location" behaves the same as "strip all".
    public static func metadataArguments(_ handling: MetadataHandling) -> [String] {
        handling == .keep ? ["-metadata", "all"] : []
    }
}

/// WebP encoding through the bundled cwebp helper, lossy or lossless
/// (`request.quality == .lossless`).
public struct WebPEngine: ImageEngine {
    static let cwebpName = "cwebp"

    private let runner: ProcessRunner
    private let helpers: HelperLocator

    public init(runner: ProcessRunner = ProcessRunner(), helpers: HelperLocator = .standard) {
        self.runner = runner
        self.helpers = helpers
    }

    public var format: ImageFormat { .webp }

    public func compress(_ request: ImageCompressRequest, progress: @escaping ProgressHandler) async throws -> ImageCompressResult {
        guard FileManager.default.fileExists(atPath: request.source.path) else {
            throw TampError.fileNotFound(path: request.source.path)
        }
        let cwebp = try helpers.url(for: Self.cwebpName)
        let inputBytes = Self.fileSize(request.source)

        let output = try await SafeOutput.write(to: request.destination, fileExtension: format.fileExtension) { temporary in
            progress(0)
            var arguments = request.quality == .lossless
                ? ["-lossless", "-z", "\(WebPMapping.losslessEffort(for: request.step))"]
                : ["-m", "\(WebPMapping.lossyMethod(for: request.step))", "-q", "\(WebPMapping.quality(for: request.quality))"]
            arguments += WebPMapping.metadataArguments(request.metadata)
            arguments += ["-o", temporary.path, "--", request.source.path]
            let result = try await runner.run(cwebp, arguments: arguments)
            guard result.succeeded else {
                throw TampError.classify(tool: "cwebp", exitCode: result.exitCode, standardError: result.standardError)
            }
            guard FileManager.default.fileExists(atPath: temporary.path) else {
                throw TampError.fileNotFound(path: request.source.path)
            }
            progress(1)
        }
        return ImageCompressResult(output: output, inputBytes: inputBytes, outputBytes: Self.fileSize(output))
    }

    private static func fileSize(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }
}
