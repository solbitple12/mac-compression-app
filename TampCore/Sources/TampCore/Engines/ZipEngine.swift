import Foundation

/// ZIP through the bundled 7zz helper: Deflate by default, AES-256 when a password is set.
public struct ZipEngine: ArchiveEngine {
    private let mapping = ZipMapping()
    private let tool: SevenZipTool

    public init(runner: ProcessRunner = ProcessRunner(), helpers: HelperLocator = .standard) {
        tool = SevenZipTool(runner: runner, helpers: helpers)
    }

    public var format: ArchiveFormat { mapping.format }
    public var capabilities: EngineCapabilities { mapping.capabilities }

    public func parameters(for step: SpeedStep, options: ArchiveOptions) -> ZipParameters {
        mapping.parameters(for: step, options: options)
    }

    public func hint(for step: SpeedStep, options: ArchiveOptions) -> StepHint {
        mapping.hint(for: step, options: options)
    }

    public func compress(_ request: CompressRequest, progress: @escaping ProgressHandler) async throws -> URL {
        var destination = request.destination
        // 7zz appends ".zip" to a name without it, which would break the final rename.
        if destination.pathExtension.lowercased() != format.fileExtension {
            destination.appendPathExtension(format.fileExtension)
        }
        let parameters = parameters(for: request.step, options: request.options)
        var switches = parameters.sevenZipArguments + SevenZipTool.quietSwitches + ["-snl", "-y"]
        if request.excludesMacOSJunk { switches += SevenZipTool.junkExclusions }
        let password = request.password.flatMap { $0.isEmpty ? nil : $0 }
        if password != nil { switches += ["-mem=AES256", "-p"] }

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
