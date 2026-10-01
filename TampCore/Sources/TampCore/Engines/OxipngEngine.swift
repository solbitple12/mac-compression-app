import Foundation

/// oxipng's `-o` level, starting-point mapping from the six speed steps: the plan
/// calls for -o 1 to 6, weighted toward the slow end because oxipng's own levels 4
/// to 6 are where the exhaustive filter and Zopfli-deflate trials happen; a real
/// per-step benchmark (as Phase 2a ran for the archive formats) may re-space these.
public enum OxipngMapping {
    public static func level(for step: SpeedStep) -> Int {
        switch step {
        case .store: 0
        case .fastest: 1
        case .fast: 2
        case .normal: 3
        case .good: 5
        case .best: 6
        }
    }

    /// oxipng's `--strip` argument for the metadata a request asks to drop. PNG has
    /// no dedicated GPS chunk to strip on its own, so "strip location" removes the
    /// whole eXIf chunk, which is the only place a PNG carries GPS data.
    public static func stripArguments(_ handling: MetadataHandling) -> [String] {
        switch handling {
        case .keep: []
        case .stripLocation: ["--strip", "eXIf"]
        case .stripAll: ["--strip", "safe"]
        }
    }
}

/// PNG re-encoding through the bundled oxipng helper. Always lossless: oxipng only
/// searches for a smaller way to store the same pixels, so `request.quality` is ignored.
public struct OxipngEngine: ImageEngine {
    static let helperName = "oxipng"

    private let runner: ProcessRunner
    private let helpers: HelperLocator

    public init(runner: ProcessRunner = ProcessRunner(), helpers: HelperLocator = .standard) {
        self.runner = runner
        self.helpers = helpers
    }

    public var format: ImageFormat { .png }

    public func compress(_ request: ImageCompressRequest, progress: @escaping ProgressHandler) async throws -> ImageCompressResult {
        guard FileManager.default.fileExists(atPath: request.source.path) else {
            throw TampError.fileNotFound(path: request.source.path)
        }
        let oxipng = try helpers.url(for: Self.helperName)
        let level = OxipngMapping.level(for: request.step)
        let inputBytes = Self.fileSize(request.source)

        let output = try await SafeOutput.write(to: request.destination, fileExtension: format.fileExtension) { temporary in
            progress(0)
            let arguments = ["-o", "\(level)", "--out", temporary.path, request.source.path]
                + OxipngMapping.stripArguments(request.metadata)
            // oxipng has no machine-readable progress output for one file; it either
            // finishes or fails, so the job goes straight from 0 to done.
            let result = try await runner.run(oxipng, arguments: arguments)
            guard result.succeeded else {
                throw TampError.classify(tool: "oxipng", exitCode: result.exitCode, standardError: result.standardError)
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
