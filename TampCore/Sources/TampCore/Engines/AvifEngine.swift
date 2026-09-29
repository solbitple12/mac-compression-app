import Foundation

/// avifenc's `-s`/`--speed`, 0 (slowest, best compression) to 10 (fastest), the
/// reverse direction of most of Tamp's other speed-step mappings; a starting
/// point pending a real per-step benchmark, like the other Phase 3 mappings.
public enum AvifMapping {
    public static func speed(for step: SpeedStep) -> Int {
        switch step {
        case .store: 10
        case .fastest: 9
        case .fast: 7
        case .normal: 5
        case .good: 2
        case .best: 0
        }
    }

    public static func quality(for value: MediaQuality) -> Int {
        ImageQualityMapping.percent(for: value)
    }
}

/// AVIF encoding through the bundled avifenc helper, over SVT-AV1. Encode only:
/// there's no bundled AVIF decoder yet (see `dav1d` in `scripts/build-helpers.sh`),
/// so nothing in Tamp can open or preview an AVIF this engine writes.
///
/// Metadata handling isn't wired up yet, the same as JxlEngine and for the same
/// reason: a wrong avifenc flag would fail the job outright.
public struct AvifEngine: ImageEngine {
    static let helperName = "avifenc"

    private let runner: ProcessRunner
    private let helpers: HelperLocator

    public init(runner: ProcessRunner = ProcessRunner(), helpers: HelperLocator = .standard) {
        self.runner = runner
        self.helpers = helpers
    }

    public var format: ImageFormat { .avif }

    public func compress(_ request: ImageCompressRequest, progress: @escaping ProgressHandler) async throws -> ImageCompressResult {
        guard FileManager.default.fileExists(atPath: request.source.path) else {
            throw TampError.fileNotFound(path: request.source.path)
        }
        let avifenc = try helpers.url(for: Self.helperName)
        let inputBytes = Self.fileSize(request.source)
        let speed = AvifMapping.speed(for: request.step)

        let output = try await SafeOutput.write(to: request.destination, fileExtension: format.fileExtension) { temporary in
            progress(0)
            var arguments = ["-s", "\(speed)", "-j", "all"]
            arguments += request.quality == .lossless ? ["--lossless"] : ["-q", "\(AvifMapping.quality(for: request.quality))"]
            arguments += [request.source.path, temporary.path]
            let result = try await runner.run(avifenc, arguments: arguments)
            guard result.succeeded else {
                throw TampError.classify(tool: "avifenc", exitCode: result.exitCode, standardError: result.standardError)
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
