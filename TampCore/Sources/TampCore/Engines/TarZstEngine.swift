import Foundation

/// TAR.ZST through two bundled helpers: bsdtar (libarchive) writes the tar stream,
/// Tamp copies it into zstd while counting bytes for progress, and zstd writes the
/// file. Store skips zstd and writes a plain .tar. Extraction runs the same path in
/// reverse and also opens plain .tar files.
public struct TarZstEngine: ArchiveEngine {
    static let tarHelper = "bsdtar"
    static let zstdHelper = "zstd"
    static let junkExclusions = ["--exclude", ".DS_Store", "--exclude", "._*", "--exclude", "__MACOSX"]
    /// Every zstd frame starts with these bytes.
    static let zstdMagic: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD]
    static let knownSuffixes = [".tar.zst", ".tzst", ".tar", ".zst"]

    private let mapping = TarZstMapping()
    private let helpers: HelperLocator
    private let gracePeriod: TimeInterval

    public init(helpers: HelperLocator = .standard, terminationGracePeriod: TimeInterval = 2) {
        self.helpers = helpers
        self.gracePeriod = terminationGracePeriod
    }

    public var format: ArchiveFormat { mapping.format }
    public var capabilities: EngineCapabilities { mapping.capabilities }

    public func parameters(for step: SpeedStep, options: ArchiveOptions) -> TarZstParameters {
        mapping.parameters(for: step, options: options)
    }

    public func hint(for step: SpeedStep, options: ArchiveOptions) -> StepHint {
        mapping.hint(for: step, options: options)
    }

    public func compress(_ request: CompressRequest, progress: @escaping ProgressHandler) async throws -> URL {
        let bsdtar = try helpers.url(for: Self.tarHelper)
        var zstdArguments: [String]?
        if case let .zstd(zstd) = parameters(for: request.step, options: request.options) {
            zstdArguments = zstd.cliArguments + ["-q", "-c"]
        }
        let zstd = try zstdArguments.map { _ in try helpers.url(for: Self.zstdHelper) }
        let fileExtension = hint(for: request.step, options: request.options).outputExtension
        let destination = Self.replacingArchiveExtension(of: request.destination, with: fileExtension)
        let tarArguments = ["-c", "-f", "-"]
            + (request.excludesMacOSJunk ? Self.junkExclusions : [])
            + request.items.flatMap(Self.tarMemberArguments)
        let totalBytes = InputSize.totalBytes(of: request.items)
        let gracePeriod = gracePeriod

        return try await SafeOutput.write(to: destination, fileExtension: fileExtension) { temporary in
            guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
                throw TampError.permissionDenied(path: temporary.deletingLastPathComponent().path)
            }
            let output = try FileHandle(forWritingTo: temporary)
            defer { try? output.close() }

            let tarOutput = Pipe()
            let tar = ChildProcess(
                name: "tar", executable: bsdtar, arguments: tarArguments,
                standardInput: FileHandle.nullDevice, standardOutput: tarOutput, gracePeriod: gracePeriod
            )
            if let zstd, let zstdArguments {
                let zstdInput = Pipe()
                let compressor = ChildProcess(
                    name: "zstd", executable: zstd, arguments: zstdArguments,
                    standardInput: zstdInput, standardOutput: output, gracePeriod: gracePeriod
                )
                try await ProcessPipeline.run(
                    stages: [compressor, tar], checkOrder: [tar, compressor],
                    source: tarOutput.fileHandleForReading, sink: zstdInput.fileHandleForWriting,
                    totalBytes: totalBytes, progress: progress
                )
            } else {
                try await ProcessPipeline.run(
                    stages: [tar], checkOrder: [tar],
                    source: tarOutput.fileHandleForReading, sink: output,
                    totalBytes: totalBytes, progress: progress
                )
            }
        }
    }

    public func extract(_ request: ExtractRequest, progress: @escaping ProgressHandler) async throws -> URL {
        let bsdtar = try helpers.url(for: Self.tarHelper)
        let zstd = try Self.startsWithZstdFrame(request.archive) ? helpers.url(for: Self.zstdHelper) : nil
        let totalBytes = Int64((try? request.archive.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let gracePeriod = gracePeriod

        return try await SafeOutput.extract(into: request.destinationDirectory, baseName: Self.baseName(of: request.archive)) { staging in
            let input = try FileHandle(forReadingFrom: request.archive)
            defer { try? input.close() }

            let tarInput = Pipe()
            // bsdtar refuses absolute paths and ".." components unless told otherwise.
            let tar = ChildProcess(
                name: "tar", executable: bsdtar, arguments: ["-x", "-f", "-", "-C", staging.path],
                standardInput: tarInput, standardOutput: FileHandle.nullDevice, gracePeriod: gracePeriod
            )
            if let zstd {
                let zstdInput = Pipe()
                let decompressor = ChildProcess(
                    name: "zstd", executable: zstd, arguments: ["-d", "-q", "-c"],
                    standardInput: zstdInput, standardOutput: tarInput, gracePeriod: gracePeriod
                )
                try await ProcessPipeline.run(
                    stages: [tar, decompressor], checkOrder: [decompressor, tar],
                    source: input, sink: zstdInput.fileHandleForWriting,
                    totalBytes: totalBytes, progress: progress
                )
            } else {
                try await ProcessPipeline.run(
                    stages: [tar], checkOrder: [tar],
                    source: input, sink: tarInput.fileHandleForWriting,
                    totalBytes: totalBytes, progress: progress
                )
            }
        }
    }

    /// "-C parent name" for each item, so the archive holds just the item's name.
    /// A name starting with "-" gets a "./" prefix so bsdtar doesn't read it as an option.
    static func tarMemberArguments(for item: URL) -> [String] {
        let name = item.lastPathComponent
        return ["-C", item.deletingLastPathComponent().path, name.hasPrefix("-") ? "./\(name)" : name]
    }

    /// "Photos.tar.zst" with "tar" becomes "Photos.tar"; "Photos" with "tar.zst" becomes "Photos.tar.zst".
    static func replacingArchiveExtension(of url: URL, with fileExtension: String) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("\(baseName(of: url)).\(fileExtension)")
    }

    static func baseName(of url: URL) -> String {
        let name = url.lastPathComponent
        for suffix in knownSuffixes where name.lowercased().hasSuffix(suffix) && name.count > suffix.count {
            return String(name.dropLast(suffix.count))
        }
        return name
    }

    static func startsWithZstdFrame(_ url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: zstdMagic.count) ?? Data()
        return Array(header) == zstdMagic
    }
}
