import Foundation

/// cjpeg's `-quality` (0 to 100) for a lossy re-encode. cjpeg has no separate speed
/// control the way an archiver's dictionary size does, so the speed step is unused
/// for JPEG; only the quality matters.
public enum MozjpegMapping {
    public static func quality(for value: MediaQuality) -> Int {
        switch value {
        case .lossless: 100 // unused: lossless goes through jpegtran, not cjpeg.
        case let .preset(preset):
            switch preset {
            case .low: 50
            case .medium: 70
            case .high: 85
            case .veryHigh: 95
            }
        case let .customQuality(value): Int(min(100, max(0, value)).rounded())
        case .customBitrate: 85 // JPEG has no bitrate mode; falls back to High.
        }
    }
}

/// JPEG re-encoding through the bundled mozjpeg helpers, in two paths:
///
/// - `request.quality == .lossless` runs jpegtran, which only rewrites the Huffman
///   tables for a smaller file; it never touches a DCT coefficient, so the image
///   decodes to the exact same pixels.
/// - Any other quality decodes to raw pixels with djpeg and re-encodes them with
///   cjpeg at that quality. That intermediate has no metadata fields, so a lossy
///   re-encode always drops metadata, whatever `request.metadata` asks for; only
///   the lossless path can honor it.
public struct MozjpegEngine: ImageEngine {
    static let jpegtranName = "jpegtran"
    static let djpegName = "djpeg"
    static let cjpegName = "cjpeg"

    private let runner: ProcessRunner
    private let helpers: HelperLocator

    public init(runner: ProcessRunner = ProcessRunner(), helpers: HelperLocator = .standard) {
        self.runner = runner
        self.helpers = helpers
    }

    public var format: ImageFormat { .jpeg }

    public func compress(_ request: ImageCompressRequest, progress: @escaping ProgressHandler) async throws -> ImageCompressResult {
        guard FileManager.default.fileExists(atPath: request.source.path) else {
            throw TampError.fileNotFound(path: request.source.path)
        }
        let inputBytes = Self.fileSize(request.source)
        let output = try await SafeOutput.write(to: request.destination, fileExtension: format.fileExtension) { temporary in
            progress(0)
            if request.quality == .lossless {
                try await runJpegtran(source: request.source, destination: temporary, metadata: request.metadata)
            } else {
                try await runLossyReencode(source: request.source, destination: temporary, quality: request.quality)
            }
            guard FileManager.default.fileExists(atPath: temporary.path) else {
                throw TampError.fileNotFound(path: request.source.path)
            }
            progress(1)
        }
        return ImageCompressResult(output: output, inputBytes: inputBytes, outputBytes: Self.fileSize(output))
    }

    private func runJpegtran(source: URL, destination: URL, metadata: MetadataHandling) async throws {
        let jpegtran = try helpers.url(for: Self.jpegtranName)
        // jpegtran only offers "all" or "none": there's no per-tag control to drop
        // just GPS, so "strip location" strips everything, like "strip all".
        let copy = metadata == .keep ? "all" : "none"
        let result = try await runner.run(jpegtran, arguments: ["-copy", copy, "-optimize", "-outfile", destination.path, source.path])
        guard result.succeeded else {
            throw TampError.classify(tool: "jpegtran", exitCode: result.exitCode, standardError: result.standardError)
        }
    }

    private func runLossyReencode(source: URL, destination: URL, quality: MediaQuality) async throws {
        let djpeg = try helpers.url(for: Self.djpegName)
        let cjpeg = try helpers.url(for: Self.cjpegName)
        let pixels = destination.deletingLastPathComponent().appendingPathComponent("\(SafeOutput.partialPrefix)mozjpeg-\(UUID().uuidString).ppm")
        defer { try? FileManager.default.removeItem(at: pixels) }

        let decode = try await runner.run(djpeg, arguments: ["-pnm", "-outfile", pixels.path, source.path])
        guard decode.succeeded else {
            throw TampError.classify(tool: "djpeg", exitCode: decode.exitCode, standardError: decode.standardError)
        }
        let level = MozjpegMapping.quality(for: quality)
        let encode = try await runner.run(cjpeg, arguments: ["-quality", "\(level)", "-optimize", "-progressive", "-outfile", destination.path, pixels.path])
        guard encode.succeeded else {
            throw TampError.classify(tool: "cjpeg", exitCode: encode.exitCode, standardError: encode.standardError)
        }
    }

    private static func fileSize(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }
}
