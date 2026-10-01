import Foundation

/// The reference `flac` encoder's `-0` to `-8` compression levels, mapped from the
/// six speed steps. A starting point, like the other Phase 3 mappings.
public enum FlacMapping {
    public static func level(for step: SpeedStep) -> Int {
        switch step {
        case .store: 0
        case .fastest: 1
        case .fast: 3
        case .normal: 5
        case .good: 7
        case .best: 8
        }
    }
}

/// FLAC encoding through the bundled `flac` helper. Always lossless: every
/// compression level decodes back to the exact same samples, so
/// `request.quality` is ignored.
public struct FlacEngine: AudioEngine {
    static let helperName = "flac"

    private let runner: ProcessRunner
    private let helpers: HelperLocator

    public init(runner: ProcessRunner = ProcessRunner(), helpers: HelperLocator = .standard) {
        self.runner = runner
        self.helpers = helpers
    }

    public var format: AudioFormat { .flac }

    public func compress(_ request: AudioCompressRequest, progress: @escaping ProgressHandler) async throws -> AudioCompressResult {
        guard FileManager.default.fileExists(atPath: request.source.path) else {
            throw TampError.fileNotFound(path: request.source.path)
        }
        let flac = try helpers.url(for: Self.helperName)
        let inputBytes = Self.fileSize(request.source)
        let level = FlacMapping.level(for: request.step)

        let output = try await SafeOutput.write(to: request.destination, fileExtension: format.fileExtension) { temporary in
            progress(0)
            // The reference encoder reads WAV, AIFF and raw PCM directly; an existing
            // FLAC source is decoded to a temp WAV first, since flac itself treats a
            // .flac argument as something to verify, not to transcode.
            let source = request.source.pathExtension.lowercased() == "flac"
                ? try await decodeToTemporaryWAV(flac: flac, source: request.source, near: temporary)
                : request.source
            defer { if source != request.source { try? FileManager.default.removeItem(at: source) } }

            // flac carries none of a WAV or AIFF source's own chunks into the FLAC by
            // default; --keep-foreign-metadata is the one flag that does, so
            // that's what "keep" means here. There's no separate "location" tag in
            // audio metadata, so "strip location" and "strip all" are the same: don't ask for it.
            var arguments = ["-\(level)", "--totally-silent", "--force"]
            if request.metadata == .keep { arguments.append("--keep-foreign-metadata") }
            arguments += ["-o", temporary.path, source.path]
            let result = try await runner.run(flac, arguments: arguments)
            guard result.succeeded else {
                throw Self.error(exitCode: result.exitCode, standardError: result.standardError)
            }
            guard FileManager.default.fileExists(atPath: temporary.path) else {
                throw TampError.fileNotFound(path: request.source.path)
            }
            progress(1)
        }
        return AudioCompressResult(output: output, inputBytes: inputBytes, outputBytes: Self.fileSize(output))
    }

    private func decodeToTemporaryWAV(flac: URL, source: URL, near destination: URL) async throws -> URL {
        let wav = destination.deletingLastPathComponent().appendingPathComponent("\(SafeOutput.partialPrefix)flac-\(UUID().uuidString).wav")
        let result = try await runner.run(flac, arguments: ["--decode", "--totally-silent", "--force", "-o", wav.path, source.path])
        guard result.succeeded else {
            throw Self.error(exitCode: result.exitCode, standardError: result.standardError)
        }
        return wav
    }

    /// flac's own error text for the cases people actually hit.
    static func error(exitCode: Int32, standardError: String) -> TampError {
        let text = standardError.lowercased()
        if text.contains("not a wav or aiff file") || text.contains("got error code") {
            return .other("Tamp couldn't read that as audio FLAC understands (WAV, AIFF or FLAC).")
        }
        return TampError.classify(tool: "flac", exitCode: exitCode, standardError: standardError)
    }

    private static func fileSize(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }
}
