import Foundation

/// The engines this build of Tamp has, and which one writes or opens a given format.
/// The format picker lists only `availableFormats`; more arrive with each phase.
public struct EngineRegistry: Sendable {
    public let engines: [any ArchiveEngine]

    public init(engines: [any ArchiveEngine]) {
        self.engines = engines
    }

    public static func standard(helpers: HelperLocator = .standard) -> EngineRegistry {
        let tarFormats: [ArchiveFormat] = [.tar, .tarGz, .tarBz2, .tarXz, .tarZst, .tarLz4, .tarLz, .tarBr]
        return EngineRegistry(engines: [ZipEngine(helpers: helpers)] + tarFormats.map { TarEngine(format: $0, helpers: helpers) })
    }

    /// Formats Tamp can write, in picker order.
    public var availableFormats: [ArchiveFormat] {
        ArchiveFormat.allCases.filter { engine(for: $0) != nil }
    }

    public func engine(for format: ArchiveFormat) -> (any ArchiveEngine)? {
        engines.first { $0.format == format }
    }

    /// The engine that opens `archive`, or nil if none can.
    ///
    /// The name decides whether a file counts as an archive, and its first bytes
    /// decide which engine opens it. Many documents are ZIP files inside (.docx,
    /// .epub, .pages), and a lone "dump.sql.gz" holds no tar, so neither is extracted.
    /// A file with no extension is judged by its first bytes alone, and only a ZIP
    /// or a plain tar counts then.
    public func extractor(for archive: URL) -> (any ArchiveEngine)? {
        let named = ArchiveDetector.format(ofName: archive)
        guard named != nil || archive.pathExtension.isEmpty else { return nil }
        switch ArchiveDetector.format(of: archive) {
        case .zip:
            return engine(for: .zip)
        case .tar:
            return tarExtractor
        case let detected? where detected.isCompressedTar:
            // bsdtar recognizes the compression itself, so a mislabeled "x.tar.gz"
            // that is really xz still opens.
            return named?.isCompressedTar == true ? tarExtractor : nil
        case nil where named == .tarBr:
            // Brotli streams have no signature to check.
            return tarExtractor
        default:
            return nil
        }
    }

    /// Every TAR-family engine opens every TAR-family archive.
    private var tarExtractor: (any ArchiveEngine)? {
        engine(for: .tar) ?? engines.first { $0 is TarEngine }
    }
}

/// Recognizes archives by their first bytes, and by the name they claim.
public enum ArchiveDetector {
    static let zipSignatures: [[UInt8]] = [
        [0x50, 0x4B, 0x03, 0x04], // a local file header
        [0x50, 0x4B, 0x05, 0x06], // the end record of an empty archive
        [0x50, 0x4B, 0x07, 0x08], // spanned archives start with a data descriptor signature
    ]
    /// POSIX and GNU tar headers carry "ustar" at offset 257.
    static let tarMagicOffset = 257
    static let tarMagic = Array("ustar".utf8)
    static let zstdMagic: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD]
    /// The first bytes of each compressor's stream, and the tar format it marks.
    /// Brotli has no signature.
    static let compressionSignatures: [(bytes: [UInt8], format: ArchiveFormat)] = [
        ([0x1F, 0x8B], .tarGz),
        (Array("BZh".utf8), .tarBz2),
        ([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00], .tarXz),
        (zstdMagic, .tarZst),
        ([0x04, 0x22, 0x4D, 0x18], .tarLz4), // frame format
        ([0x02, 0x21, 0x4C, 0x18], .tarLz4), // legacy format
        (Array("LZIP".utf8), .tarLz),
    ]
    /// Longest first, so ".tar.gz" wins over ".gz".
    static let nameSuffixes: [(suffix: String, format: ArchiveFormat)] = [
        (".tar.gz", .tarGz), (".tgz", .tarGz),
        (".tar.bz2", .tarBz2), (".tbz2", .tarBz2), (".tbz", .tarBz2),
        (".tar.xz", .tarXz), (".txz", .tarXz),
        (".tar.zst", .tarZst), (".tzst", .tarZst),
        (".tar.lz4", .tarLz4),
        (".tar.lz", .tarLz), (".tlz", .tarLz),
        (".tar.br", .tarBr), (".tbr", .tarBr),
        (".tar", .tar),
        (".zip", .zip),
    ]

    /// The archive format a file name claims, such as `.tarGz` for "x.tar.gz" or "x.tgz".
    public static func format(ofName url: URL) -> ArchiveFormat? {
        let name = url.lastPathComponent.lowercased()
        return nameSuffixes.first { name.hasSuffix($0.suffix) && name.count > $0.suffix.count }?.format
    }

    /// - Returns: `.zip`, `.tar`, the compressed tar format whose compressor wrote
    ///   the file's first bytes (whatever the stream holds), or nil.
    public static func format(of url: URL) -> ArchiveFormat? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 512) else { return nil }
        return format(ofHeader: Array(data))
    }

    static func format(ofHeader bytes: [UInt8]) -> ArchiveFormat? {
        if zipSignatures.contains(where: { bytes.starts(with: $0) }) { return .zip }
        // Before the short compression signatures, which a tar's first file name could start with.
        let end = tarMagicOffset + tarMagic.count
        if bytes.count >= end, Array(bytes[tarMagicOffset..<end]) == tarMagic { return .tar }
        if let match = compressionSignatures.first(where: { bytes.starts(with: $0.bytes) }) {
            // "BZh" is followed by the block size, 1 to 9.
            if match.format == .tarBz2, !(bytes.count > 3 && (0x31...0x39).contains(bytes[3])) { return nil }
            return match.format
        }
        return nil
    }
}
