import Foundation

/// cjxl's `-e` effort, 1 (fastest) to 9 (slowest), from the six speed steps, per
/// the plan; a starting point pending a real per-step benchmark, like the other
/// Phase 3 mappings.
public enum JxlMapping {
    public static func effort(for step: SpeedStep) -> Int {
        switch step {
        case .store: 1
        case .fastest: 2
        case .fast: 4
        case .normal: 6
        case .good: 8
        case .best: 9
        }
    }

    /// cjxl's `-q` quality (0 to 100; 100 means lossless for a non-JPEG source).
    /// Unused when `losslessJPEGToJXL` is doing the encode instead.
    public static func quality(for value: MediaQuality) -> Int {
        ImageQualityMapping.percent(for: value)
    }
}

/// JPEG XL encoding through the bundled cjxl and djxl helpers, in two paths:
///
/// - `request.losslessJPEGToJXL` (source must be a JPEG) rewraps the JPEG's own
///   DCT coefficients as JXL, with no `-q`: cjxl's default for a JPEG source is
///   exactly this lossless transcode. The result is then decoded back to a JPEG
///   with djxl and compared, byte for byte, against the original, since that
///   exact reconstruction is JXL's whole promise here; a mismatch fails the job
///   rather than silently keeping a JXL that wouldn't give the JPEG back.
/// - Any other request is a normal encode at `request.quality` (100 means
///   lossless, for a source that supports it: PNG, WebP-as-source, and so on).
///
/// Metadata handling isn't wired up yet: cjxl keeps whatever it keeps by default,
/// whatever `request.metadata` asks for. Confirmed against a real `cjxl --help`
/// before it's trusted, rather than guessed at like the other engines' `--strip`
/// flags, since a wrong flag here would fail the job outright, not just keep an
/// extra tag.
public struct JxlEngine: ImageEngine {
    static let cjxlName = "cjxl"
    static let djxlName = "djxl"

    private let runner: ProcessRunner
    private let helpers: HelperLocator

    public init(runner: ProcessRunner = ProcessRunner(), helpers: HelperLocator = .standard) {
        self.runner = runner
        self.helpers = helpers
    }

    public var format: ImageFormat { .jxl }

    public func compress(_ request: ImageCompressRequest, progress: @escaping ProgressHandler) async throws -> ImageCompressResult {
        guard FileManager.default.fileExists(atPath: request.source.path) else {
            throw TampError.fileNotFound(path: request.source.path)
        }
        let cjxl = try helpers.url(for: Self.cjxlName)
        let inputBytes = Self.fileSize(request.source)
        let effort = JxlMapping.effort(for: request.step)

        let output = try await SafeOutput.write(to: request.destination, fileExtension: format.fileExtension) { temporary in
            progress(0)
            var arguments = ["-e", "\(effort)", "--quiet"]
            if request.losslessJPEGToJXL {
                arguments += [request.source.path, temporary.path]
            } else {
                arguments += ["--lossless_jpeg=0", "-q", "\(JxlMapping.quality(for: request.quality))", request.source.path, temporary.path]
            }
            let result = try await runner.run(cjxl, arguments: arguments)
            guard result.succeeded else {
                throw TampError.classify(tool: "cjxl", exitCode: result.exitCode, standardError: result.standardError)
            }
            guard FileManager.default.fileExists(atPath: temporary.path) else {
                throw TampError.fileNotFound(path: request.source.path)
            }
            if request.losslessJPEGToJXL {
                try await verifyLosslessJPEG(original: request.source, jxl: temporary)
            }
            progress(1)
        }
        return ImageCompressResult(output: output, inputBytes: inputBytes, outputBytes: Self.fileSize(output))
    }

    /// Decodes `jxl` back to a JPEG and checks it's byte-for-byte the original,
    /// as the plan requires for the lossless JPEG path. Throws rather than
    /// returning false, since a JXL that fails this check must not become the job's
    /// output: `SafeOutput.write` discards the temp file on any thrown error.
    private func verifyLosslessJPEG(original: URL, jxl: URL) async throws {
        let djxl = try helpers.url(for: Self.djxlName)
        let rebuilt = jxl.deletingLastPathComponent().appendingPathComponent("\(SafeOutput.partialPrefix)jxl-verify-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: rebuilt) }
        let result = try await runner.run(djxl, arguments: ["--quiet", jxl.path, rebuilt.path])
        guard result.succeeded else {
            throw TampError.classify(tool: "djxl", exitCode: result.exitCode, standardError: result.standardError)
        }
        guard FileManager.default.contentsEqual(atPath: original.path, andPath: rebuilt.path) else {
            throw TampError.other("The lossless JPEG XL didn't reconstruct the original JPEG exactly, so Tamp discarded it.")
        }
    }

    private static func fileSize(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }
}
