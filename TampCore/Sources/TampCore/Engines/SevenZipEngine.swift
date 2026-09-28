import Foundation

/// 7Z through the bundled 7zz helper: solid LZMA2 by default. With a password,
/// the file names are encrypted too.
public struct SevenZipEngine: ArchiveEngine {
    private let mapping = SevenZipMapping()
    private let tool: SevenZipTool

    public init(runner: ProcessRunner = ProcessRunner(), helpers: HelperLocator = .standard) {
        tool = SevenZipTool(runner: runner, helpers: helpers)
    }

    public var format: ArchiveFormat { mapping.format }
    public var capabilities: EngineCapabilities { mapping.capabilities }

    public func parameters(for step: SpeedStep, options: ArchiveOptions) -> SevenZipParameters {
        mapping.parameters(for: step, options: options)
    }

    public func hint(for step: SpeedStep, options: ArchiveOptions) -> StepHint {
        mapping.hint(for: step, options: options)
    }

    public func compress(_ request: CompressRequest, progress: @escaping ProgressHandler) async throws -> URL {
        var destination = request.destination
        // 7zz appends ".7z" to a name without it, which would break the final rename.
        if destination.pathExtension.lowercased() != format.fileExtension {
            destination.appendPathExtension(format.fileExtension)
        }
        let parameters = parameters(for: request.step, options: request.options)
        var switches = parameters.sevenZipArguments + SevenZipTool.quietSwitches + ["-snl", "-y"]
        if request.excludesMacOSJunk { switches += SevenZipTool.junkExclusions }
        let password = request.password.flatMap { $0.isEmpty ? nil : $0 }
        if password != nil { switches += ["-mhe=on", "-p"] }

        return try await SafeOutput.write(to: destination, fileExtension: format.fileExtension) { temporary in
            try await tool.run(
                ["a"] + switches + ["--", temporary.path] + request.items.map(\.path),
                password: password,
                progress: progress
            )
        }
    }

    public func extract(_ request: ExtractRequest, progress: @escaping ProgressHandler) async throws -> URL {
        try await tool.extract(
            request,
            archiveBaseName: request.archive.deletingPathExtension().lastPathComponent,
            progress: progress
        )
    }
}
