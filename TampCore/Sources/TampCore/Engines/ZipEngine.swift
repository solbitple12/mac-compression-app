import Foundation

/// ZIP through the bundled 7zz helper: Deflate by default, AES-256 when a password
/// is set. Zstandard goes through minizip instead, since official 7-Zip can read it
/// in a ZIP but not write it.
public struct ZipEngine: ArchiveEngine {
    static let minizipHelper = "minizip"

    private let mapping = ZipMapping()
    private let tool: SevenZipTool
    private let runner: ProcessRunner
    private let helpers: HelperLocator

    public init(runner: ProcessRunner = ProcessRunner(), helpers: HelperLocator = .standard) {
        tool = SevenZipTool(runner: runner, helpers: helpers)
        self.runner = runner
        self.helpers = helpers
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
        let password = request.password.flatMap { $0.isEmpty ? nil : $0 }

        return try await SafeOutput.write(to: destination, fileExtension: format.fileExtension) { temporary in
            switch parameters.writer {
            case .sevenZip:
                var switches = parameters.sevenZipArguments + SevenZipTool.quietSwitches + ["-snl", "-y"]
                if request.excludesMacOSJunk { switches += SevenZipTool.junkExclusions }
                if password != nil { switches += ["-mem=AES256", "-p"] }
                try await tool.run(
                    ["a"] + switches + ["--", temporary.path] + request.items.map(\.path),
                    password: password,
                    progress: progress
                )
            case .minizip:
                try await compressWithMinizip(request, parameters: parameters, password: password, to: temporary, progress: progress)
            }
        }
    }

    public func extract(_ request: ExtractRequest, progress: @escaping ProgressHandler) async throws -> URL {
        try await tool.extract(
            request,
            archiveBaseName: request.archive.deletingPathExtension().lastPathComponent,
            progress: progress
        )
    }

    /// minizip stores paths relative to its working directory, so it runs once per
    /// folder the items come from, each run after the first appending to the archive.
    private func compressWithMinizip(
        _ request: CompressRequest,
        parameters: ZipParameters,
        password: String?,
        to temporary: URL,
        progress: @escaping ProgressHandler
    ) async throws {
        let minizip = try helpers.url(for: Self.minizipHelper)
        let meter = MinizipProgress(totalBytes: InputSize.totalBytes(of: request.items), progress: progress)
        // -y stores links as links, -i keeps each item's folder structure, -v reports progress.
        var switches = parameters.minizipArguments + ["-y", "-i", "-v"]
        if request.excludesMacOSJunk { switches.append("-j") }
        // AES-256, with the password read from stdin rather than an argument.
        if password != nil { switches += ["-s", "-w"] }
        let input = password.map { Data(($0 + "\n").utf8) }

        for (index, group) in Self.itemsByFolder(request.items).enumerated() {
            let arguments = switches + [index == 0 ? "-o" : "-a", temporary.path] + group.items.map(Self.minizipMemberName)
            let result = try await runner.run(minizip, arguments: arguments, standardInput: input, currentDirectory: group.folder) { line in
                meter.consume(line)
            }
            guard result.succeeded else {
                throw Self.minizipError(exitCode: result.exitCode, output: meter.errorLines + [result.standardError])
            }
        }
        // minizip creates the archive readable by its owner only.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: temporary.path)
    }

    /// Items grouped by the folder they're in, in the order they first appear.
    static func itemsByFolder(_ items: [URL]) -> [(folder: URL, items: [URL])] {
        var groups: [(folder: URL, items: [URL])] = []
        for item in items {
            let folder = item.deletingLastPathComponent()
            if let index = groups.firstIndex(where: { $0.folder.path == folder.path }) {
                groups[index].items.append(item)
            } else {
                groups.append((folder, [item]))
            }
        }
        return groups
    }

    /// The item's name, with "./" before a leading dash so minizip doesn't read it as an
    /// option. The patched minizip stores "./-name" as "-name".
    static func minizipMemberName(_ item: URL) -> String {
        let name = item.lastPathComponent
        return name.hasPrefix("-") ? "./\(name)" : name
    }

    /// minizip prints its errors, such as "Error -116 adding path to archive x", to stdout.
    static func minizipError(exitCode: Int32, output: [String]) -> TampError {
        let text = output.joined(separator: "\n")
        // mz_error codes: -107 a file vanished, -111 a file couldn't be opened,
        // -116 a write failed.
        if text.contains("Error -107 ") { return .fileNotFound(path: nil) }
        if text.contains("Error -111 ") { return .permissionDenied(path: nil) }
        return TampError.classify(tool: "minizip", exitCode: exitCode, standardError: text)
    }
}

/// Turns minizip's per-file lines ("Photos/a.jpg - 65535 / 3000000 (2.18%)") into
/// progress across the whole archive.
final class MinizipProgress: @unchecked Sendable {
    private let lock = NSLock()
    private let totalBytes: Int64
    private let progress: ProgressHandler
    private var finishedBytes: Int64 = 0
    private var currentName: String?
    private var currentBytes: Int64 = 0
    private var errors: [String] = []

    init(totalBytes: Int64, progress: @escaping ProgressHandler) {
        self.totalBytes = totalBytes
        self.progress = progress
    }

    var errorLines: [String] {
        lock.withLock { errors }
    }

    func consume(_ line: String) {
        let fraction = lock.withLock { () -> Double? in
            if line.hasPrefix("Error ") {
                errors.append(line)
                return nil
            }
            guard let parsed = Self.parse(line) else { return nil }
            // Each file starts with a line at 0, which also tells apart two files of the same name.
            if parsed.name != currentName || parsed.position < currentBytes {
                finishedBytes += currentBytes
                currentName = parsed.name
            }
            currentBytes = parsed.position
            guard totalBytes > 0 else { return nil }
            return min(1, Double(finishedBytes + currentBytes) / Double(totalBytes))
        }
        if let fraction { progress(fraction) }
    }

    /// The file name and bytes done, from the end of the line, since names can hold " - ".
    static func parse(_ line: String) -> (name: String, position: Int64)? {
        guard let separator = line.range(of: " - ", options: .backwards) else { return nil }
        let fields = line[separator.upperBound...].split(separator: " ")
        guard fields.count == 4, fields[1] == "/", fields[3].hasPrefix("("), fields[3].hasSuffix("%)"),
              let position = Int64(fields[0]), let size = Int64(fields[2]) else { return nil }
        // A link's target can be longer than the size minizip reports for it.
        return (String(line[..<separator.lowerBound]), min(position, max(size, 0)))
    }
}
