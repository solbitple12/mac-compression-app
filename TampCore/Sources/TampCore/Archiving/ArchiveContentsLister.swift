import Foundation

/// Lists what an archive holds without extracting it, for a quick look before
/// committing to Extract. Covers whatever this build's ZIP, 7Z and RAR engines
/// can open (through 7zz's technical listing, `-slt`, with sizes) and the TAR
/// family (through bsdtar, paths only - its verbose listing has no stable,
/// locale-independent format to parse, and a path is what a preview needs
/// most). ZPAQ, Apple Archive, disk images, CAB, ISO and a lone compressed
/// file aren't listed; callers should check `canList` before offering Preview.
public enum ArchiveContentsLister {
    public struct Entry: Equatable, Sendable, Identifiable {
        public var id: String { path }
        public var path: String
        /// Nil for a directory, or when the source listing doesn't give sizes.
        public var sizeBytes: Int64?
        public var isDirectory: Bool

        public init(path: String, sizeBytes: Int64?, isDirectory: Bool) {
            self.path = path
            self.sizeBytes = sizeBytes
            self.isDirectory = isDirectory
        }
    }

    public static func canList(_ archive: URL, registry: EngineRegistry) -> Bool {
        listKind(for: archive, registry: registry) != nil
    }

    public static func list(
        _ archive: URL, registry: EngineRegistry, password: String? = nil,
        helpers: HelperLocator = .standard, runner: ProcessRunner = ProcessRunner()
    ) async throws -> [Entry] {
        switch listKind(for: archive, registry: registry) {
        case .sevenZip:
            return try await listWithSevenZip(archive, password: password, helpers: helpers, runner: runner)
        case .tar:
            return try await listWithBsdtar(archive, helpers: helpers, runner: runner)
        case nil:
            throw TampError.other("Tamp can't preview this kind of archive; extract it to see what's inside.")
        }
    }

    private enum ListKind {
        case sevenZip
        case tar
    }

    private static func listKind(for archive: URL, registry: EngineRegistry) -> ListKind? {
        guard let extractor = registry.extractor(for: archive) else { return nil }
        if extractor is ZipEngine || extractor is SevenZipEngine { return .sevenZip }
        if extractor is TarEngine { return .tar }
        if let readOnly = extractor as? ReadOnlyEngine { return readOnly.format == .rar ? .sevenZip : nil }
        return nil
    }

    private static func listWithSevenZip(
        _ archive: URL, password: String?, helpers: HelperLocator, runner: ProcessRunner
    ) async throws -> [Entry] {
        let executable = try helpers.url(for: SevenZipTool.helperName)
        let collector = LineCollector()
        let input = password.map { Data(($0 + "\n").utf8) }
        let result = try await runner.run(
            executable, arguments: ["l", "-slt", archive.path], standardInput: input,
            onOutputLine: { collector.append($0) }
        )
        guard result.succeeded else {
            throw TampError.classify(tool: "7-Zip", exitCode: result.exitCode, standardError: result.standardError)
        }
        return parseSevenZipTechnicalListing(collector.lines)
    }

    /// `7zz l -slt` prints one blank-line-separated block per item, each a run
    /// of "Key = Value" lines. The very first block describes the archive file
    /// itself (its own "Path ="), not something inside it, so it's dropped.
    static func parseSevenZipTechnicalListing(_ lines: [String]) -> [Entry] {
        var entries: [Entry] = []
        var path: String?
        var size: Int64?
        var isFolder = false

        func flush() {
            guard let currentPath = path else { return }
            entries.append(Entry(path: currentPath, sizeBytes: isFolder ? nil : size, isDirectory: isFolder))
            path = nil
            size = nil
            isFolder = false
        }

        for line in lines {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[line.startIndex..<equals].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if key == "Path" { flush() }
            switch key {
            case "Path": path = value
            case "Size": size = Int64(value)
            case "Folder": isFolder = (value == "+")
            default: break
            }
        }
        flush()
        return entries.isEmpty ? [] : Array(entries.dropFirst())
    }

    private static func listWithBsdtar(_ archive: URL, helpers: HelperLocator, runner: ProcessRunner) async throws -> [Entry] {
        let executable = try helpers.url(for: TarEngine.tarHelper)
        let collector = LineCollector()
        let result = try await runner.run(executable, arguments: ["-t", "-f", archive.path], onOutputLine: { collector.append($0) })
        guard result.succeeded else {
            throw TampError.classify(tool: "bsdtar", exitCode: result.exitCode, standardError: result.standardError)
        }
        return collector.lines.map { line in
            let isDirectory = line.hasSuffix("/")
            return Entry(path: isDirectory ? String(line.dropLast()) : line, sizeBytes: nil, isDirectory: isDirectory)
        }
    }
}

/// Collects a process's stdout lines in the order they arrive; `onOutputLine`
/// can be called from a background queue, so appends are locked.
private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ line: String) {
        lock.withLock { storage.append(line) }
    }

    var lines: [String] {
        lock.withLock { storage }
    }
}
