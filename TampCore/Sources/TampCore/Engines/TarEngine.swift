import Foundation

/// The TAR family: plain TAR, TAR.GZ, TAR.BZ2, TAR.XZ, TAR.ZST, TAR.LZ4, TAR.LZ and TAR.BR.
///
/// bsdtar (libarchive) writes the tar stream and Tamp copies it onward while counting
/// bytes for progress. The copy goes into the format's compressor (pigz, pbzip2, xz,
/// zstd or brotli), or into a second bsdtar that applies libarchive's own lz4 or lzip
/// filter, or straight into the file for a plain .tar.
///
/// Any engine of the family extracts every TAR-family archive: bsdtar reads each
/// compression itself except brotli, which has no signature and runs through
/// `brotli -d` first.
public struct TarEngine: ArchiveEngine {
    static let tarHelper = "bsdtar"
    static let brotliHelper = "brotli"
    static let junkExclusions = ["--exclude", ".DS_Store", "--exclude", "._*", "--exclude", "__MACOSX"]
    /// Longest first, so "x.tar.gz" loses ".tar.gz" rather than ".gz".
    static let knownSuffixes = [
        ".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst", ".tar.lz4", ".tar.lz", ".tar.br",
        ".tgz", ".tbz2", ".tbz", ".txz", ".tzst", ".tlz", ".tbr", ".tar",
    ]

    private let mapping: TarMapping
    private let helpers: HelperLocator
    private let gracePeriod: TimeInterval

    /// - Parameter format: `.tar` or a compressed tar format.
    public init(format: ArchiveFormat, helpers: HelperLocator = .standard, terminationGracePeriod: TimeInterval = 2) {
        mapping = TarMapping(format: format)
        self.helpers = helpers
        gracePeriod = terminationGracePeriod
    }

    public var format: ArchiveFormat { mapping.format }
    public var capabilities: EngineCapabilities { mapping.capabilities }

    public func parameters(for step: SpeedStep, options: ArchiveOptions) -> TarCompression {
        mapping.parameters(for: step, options: options)
    }

    public func hint(for step: SpeedStep, options: ArchiveOptions) -> StepHint {
        mapping.hint(for: step, options: options)
    }

    public func compress(_ request: CompressRequest, progress: @escaping ProgressHandler) async throws -> URL {
        try request.checkNamesAreUnique()
        let bsdtar = try helpers.url(for: Self.tarHelper)
        let compression = parameters(for: request.step, options: request.options)
        let compressor: URL
        switch compression {
        case .plainTar, .libarchiveFilter: compressor = bsdtar
        case let .tool(name, _): compressor = try helpers.url(for: name)
        }
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
            let tarOutput = Pipe()
            let tar = ChildProcess(
                name: "tar", executable: bsdtar, arguments: tarArguments,
                standardInput: FileHandle.nullDevice, standardOutput: tarOutput, gracePeriod: gracePeriod
            )
            let source = tarOutput.fileHandleForReading

            switch compression {
            case .plainTar:
                let output = try FileHandle(forWritingTo: temporary)
                defer { try? output.close() }
                try await ProcessPipeline.run(
                    stages: [tar], checkOrder: [tar],
                    source: source, sink: output, totalBytes: totalBytes, progress: progress
                )
            case let .tool(name, arguments):
                let output = try FileHandle(forWritingTo: temporary)
                defer { try? output.close() }
                let input = Pipe()
                let stage = ChildProcess(
                    name: name, executable: compressor, arguments: arguments,
                    standardInput: input, standardOutput: output, gracePeriod: gracePeriod
                )
                try await ProcessPipeline.run(
                    stages: [stage, tar], checkOrder: [tar, stage],
                    source: source, sink: input.fileHandleForWriting, totalBytes: totalBytes, progress: progress
                )
            case let .libarchiveFilter(name, level):
                // Written to the path rather than stdout: bsdtar pads stdout to a whole
                // 10 KB block, and the lz4 tool rejects the trailing zeros.
                let input = Pipe()
                let stage = ChildProcess(
                    name: name, executable: bsdtar,
                    arguments: ["-c", "--\(name)", "--options", "\(name):compression-level=\(level)", "-f", temporary.path, "@-"],
                    standardInput: input, standardOutput: FileHandle.nullDevice, gracePeriod: gracePeriod
                )
                try await ProcessPipeline.run(
                    stages: [stage, tar], checkOrder: [tar, stage],
                    source: source, sink: input.fileHandleForWriting, totalBytes: totalBytes, progress: progress
                )
            }
        }
    }

    public func extract(_ request: ExtractRequest, progress: @escaping ProgressHandler) async throws -> URL {
        let bsdtar = try helpers.url(for: Self.tarHelper)
        let brotli = Self.isBrotliTar(request.archive) ? try helpers.url(for: Self.brotliHelper) : nil
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
            if let brotli {
                let brotliInput = Pipe()
                let decompressor = ChildProcess(
                    name: "brotli", executable: brotli, arguments: ["-d", "-c"],
                    standardInput: brotliInput, standardOutput: tarInput, gracePeriod: gracePeriod
                )
                try await ProcessPipeline.run(
                    stages: [tar, decompressor], checkOrder: [decompressor, tar],
                    source: input, sink: brotliInput.fileHandleForWriting,
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
        return ["-C", item.deletingLastPathComponent().path, name.hasPrefix("-") || name.hasPrefix("@") ? "./\(name)" : name]
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

    /// Brotli streams carry no signature, so only the name tells them apart.
    static func isBrotliTar(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name.hasSuffix(".tar.br") || name.hasSuffix(".tbr")
    }
}
