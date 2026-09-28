import Foundation

/// Archive formats Tamp opens but doesn't write.
public enum ReadOnlyFormat: String, CaseIterable, Sendable {
    case rar
    case cab
    case iso
    case cpio

    public var title: String {
        switch self {
        case .rar: "RAR"
        case .cab: "CAB"
        case .iso: "ISO"
        case .cpio: "CPIO"
        }
    }
}

/// Opens RAR through 7zz, and CAB, ISO and CPIO through bsdtar, which keeps
/// Unix permissions and links (and Rock Ridge names on discs). When bsdtar can't
/// read one (a UDF-only disc, an unusual CAB method), 7zz tries next.
public struct ReadOnlyEngine: ArchiveExtractor {
    public let format: ReadOnlyFormat
    private let runner: ProcessRunner
    private let helpers: HelperLocator
    private let tool: SevenZipTool

    public init(format: ReadOnlyFormat, runner: ProcessRunner = ProcessRunner(), helpers: HelperLocator = .standard) {
        self.format = format
        self.runner = runner
        self.helpers = helpers
        tool = SevenZipTool(runner: runner, helpers: helpers)
    }

    public var writableFormat: ArchiveFormat? { nil }

    public func extract(_ request: ExtractRequest, progress: @escaping ProgressHandler) async throws -> URL {
        let baseName = request.archive.deletingPathExtension().lastPathComponent
        guard format != .rar else {
            return try await tool.extract(request, archiveBaseName: baseName, progress: progress)
        }
        do {
            return try await extractWithBsdtar(request, baseName: baseName)
        } catch let error as TampError where Self.worthTryingSevenZip(after: error) {
            return try await tool.extract(request, archiveBaseName: baseName, progress: progress)
        }
    }

    private func extractWithBsdtar(_ request: ExtractRequest, baseName: String) async throws -> URL {
        let bsdtar = try helpers.url(for: TarEngine.tarHelper)
        let format = format
        return try await SafeOutput.extract(into: request.destinationDirectory, baseName: baseName) { staging in
            // Files on a disc are read-only; making them writable lets people edit and
            // delete what they extracted, and lets a failed job clean up.
            defer { if format == .iso { Self.addOwnerWrite(under: staging) } }
            // bsdtar refuses absolute paths, ".." and writing through links unless told otherwise.
            let result = try await runner.run(bsdtar, arguments: ["-x", "-f", request.archive.path, "-C", staging.path])
            guard result.succeeded else {
                throw TampError.classify(tool: "bsdtar", exitCode: result.exitCode, standardError: result.standardError)
            }
        }
    }

    /// Anything but a problem 7-Zip would hit just the same.
    static func worthTryingSevenZip(after error: TampError) -> Bool {
        switch error {
        case .corruptArchive, .toolFailed, .other: true
        default: false
        }
    }

    static func addOwnerWrite(under root: URL, fileManager: FileManager = .default) {
        let paths = [root.path] + (fileManager.subpaths(atPath: root.path) ?? []).map { root.appendingPathComponent($0).path }
        for path in paths {
            guard let attributes = try? fileManager.attributesOfItem(atPath: path),
                  attributes[.type] as? FileAttributeType != .typeSymbolicLink,
                  let mode = attributes[.posixPermissions] as? Int else { continue }
            try? fileManager.setAttributes([.posixPermissions: mode | 0o200], ofItemAtPath: path)
        }
    }
}

/// Opens a lone compressed file, such as "dump.sql.gz", into the file it holds.
/// bsdcat reads gzip, bzip2, xz, zstd, lz4 and lzip; brotli, which has no
/// signature, needs its own tool.
public struct CompressedFileEngine: ArchiveExtractor {
    /// Longest first, so ".lz4" isn't taken for ".lz".
    static let suffixes = [".bz2", ".zst", ".lz4", ".gz", ".xz", ".lz", ".br"]

    private let helpers: HelperLocator
    private let gracePeriod: TimeInterval

    public init(helpers: HelperLocator = .standard, terminationGracePeriod: TimeInterval = 2) {
        self.helpers = helpers
        gracePeriod = terminationGracePeriod
    }

    public var writableFormat: ArchiveFormat? { nil }

    /// The suffix of a lone compressed file's name, or nil.
    static func suffix(of url: URL) -> String? {
        let name = url.lastPathComponent.lowercased()
        return suffixes.first { name.hasSuffix($0) && name.count > $0.count }
    }

    /// "dump.sql.gz" holds "dump.sql".
    static func outputName(for archive: URL) -> String {
        let name = archive.lastPathComponent
        guard let suffix = suffix(of: archive) else { return name + " (decompressed)" }
        return String(name.dropLast(suffix.count))
    }

    public func extract(_ request: ExtractRequest, progress: @escaping ProgressHandler) async throws -> URL {
        let isBrotli = Self.suffix(of: request.archive) == ".br"
        let executable = try helpers.url(for: isBrotli ? TarEngine.brotliHelper : "bsdcat")
        let name = Self.outputName(for: request.archive)
        let totalBytes = Int64((try? request.archive.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let gracePeriod = gracePeriod

        return try await SafeOutput.extract(into: request.destinationDirectory, baseName: name) { staging in
            let target = staging.appendingPathComponent(name)
            guard FileManager.default.createFile(atPath: target.path, contents: nil) else {
                throw TampError.permissionDenied(path: request.destinationDirectory.path)
            }
            let output = try FileHandle(forWritingTo: target)
            defer { try? output.close() }
            let input = try FileHandle(forReadingFrom: request.archive)
            defer { try? input.close() }
            let stdin = Pipe()
            let stage = ChildProcess(
                name: isBrotli ? "brotli" : "bsdcat", executable: executable, arguments: isBrotli ? ["-d", "-c"] : [],
                standardInput: stdin, standardOutput: output, gracePeriod: gracePeriod
            )
            try await ProcessPipeline.run(
                stages: [stage], checkOrder: [stage],
                source: input, sink: stdin.fileHandleForWriting, totalBytes: totalBytes, progress: progress
            )
        }
    }
}
