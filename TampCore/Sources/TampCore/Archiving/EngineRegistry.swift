import Foundation

/// The engines this build of Tamp has, and which one writes or opens a given format.
/// The format picker lists only `availableFormats`; more arrive with each phase.
public struct EngineRegistry: Sendable {
    public let engines: [any ArchiveEngine]
    /// Openers for formats Tamp doesn't write: `ReadOnlyEngine`s and a `CompressedFileEngine`.
    public let extractors: [any ArchiveExtractor]

    public init(engines: [any ArchiveEngine], extractors: [any ArchiveExtractor] = []) {
        self.engines = engines
        self.extractors = extractors
    }

    public static func standard(helpers: HelperLocator = .standard) -> EngineRegistry {
        let tarFormats: [ArchiveFormat] = [.tar, .tarGz, .tarBz2, .tarXz, .tarZst, .tarLz4, .tarLz, .tarBr]
        let archivers: [any ArchiveEngine] = [ZipEngine(helpers: helpers), SevenZipEngine(helpers: helpers)]
        let readOnly: [any ArchiveExtractor] = ReadOnlyFormat.allCases.map { ReadOnlyEngine(format: $0, helpers: helpers) }
        return EngineRegistry(
            engines: archivers + tarFormats.map { TarEngine(format: $0, helpers: helpers) } + [ZpaqEngine(helpers: helpers)],
            extractors: readOnly + [CompressedFileEngine(helpers: helpers)]
        )
    }

    /// Formats Tamp can write, in picker order.
    public var availableFormats: [ArchiveFormat] {
        ArchiveFormat.allCases.filter { engine(for: $0) != nil }
    }

    public func engine(for format: ArchiveFormat) -> (any ArchiveEngine)? {
        engines.first { $0.format == format }
    }

    /// The extractor that opens `archive`, or nil if none can.
    ///
    /// The name decides whether a file counts as an archive, and its first bytes
    /// decide which engine opens it. Many documents are ZIP files inside (.docx,
    /// .epub, .pages), so they aren't extracted. A lone "dump.sql.gz" is
    /// decompressed into "dump.sql". A file with no extension is judged by its
    /// first bytes alone, and only a ZIP, 7Z, ZPAQ or plain tar counts then.
    public func extractor(for archive: URL) -> (any ArchiveExtractor)? {
        if let readOnly = ArchiveDetector.readOnlyFormat(ofName: archive) {
            return ArchiveDetector.readOnlyFormat(of: archive) == readOnly ? readOnlyExtractor(for: readOnly) : nil
        }
        let named = ArchiveDetector.format(ofName: archive)
        if named == nil, let suffix = CompressedFileEngine.suffix(of: archive) {
            let detected = ArchiveDetector.format(of: archive)
            // Brotli streams have no signature, so the name alone counts.
            let compressed = detected?.isCompressedTar == true || (suffix == ".br" && detected == nil)
            return compressed ? extractors.first { $0 is CompressedFileEngine } : nil
        }
        guard named != nil || archive.pathExtension.isEmpty else { return nil }
        switch ArchiveDetector.format(of: archive) {
        case .zip:
            return engine(for: .zip)
        case .sevenZip:
            return engine(for: .sevenZip)
        case .zpaq:
            return engine(for: .zpaq)
        case .tar:
            return tarExtractor
        case let detected? where detected.isCompressedTar:
            // bsdtar recognizes the compression itself, so a mislabeled "x.tar.gz"
            // that is really xz still opens.
            return named?.isCompressedTar == true ? tarExtractor : nil
        case nil where named == .tarBr:
            // Brotli streams have no signature to check.
            return tarExtractor
        case nil where named == .zpaq:
            // Encrypted ZPAQ archives start with random salt.
            return engine(for: .zpaq)
        default:
            return nil
        }
    }

    private func readOnlyExtractor(for format: ReadOnlyFormat) -> (any ArchiveExtractor)? {
        extractors.first { ($0 as? ReadOnlyEngine)?.format == format }
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
    static let sevenZipSignature: [UInt8] = [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]
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
        (".7z", .sevenZip),
        (".zpaq", .zpaq),
    ]

    static let readOnlySuffixes: [(suffix: String, format: ReadOnlyFormat)] = [
        (".rar", .rar), (".cab", .cab), (".iso", .iso), (".cpio", .cpio),
    ]
    static let rarSignatures: [[UInt8]] = [
        Array("Rar!".utf8) + [0x1A, 0x07, 0x00], // RAR 1.5 to 4
        Array("Rar!".utf8) + [0x1A, 0x07, 0x01, 0x00], // RAR 5
    ]
    static let cabSignature: [UInt8] = Array("MSCF".utf8) + [0, 0, 0, 0]
    static let cpioSignatures: [[UInt8]] = [
        Array("070701".utf8), Array("070702".utf8), Array("070707".utf8), // ASCII headers
        [0xC7, 0x71], [0x71, 0xC7], // old binary headers, either byte order
    ]
    /// Discs mark their first volume descriptor at 32769: "CD001" for ISO 9660, "BEA01" for UDF.
    static let discMarkerOffset = 32769
    static let discMarkers = [Array("CD001".utf8), Array("BEA01".utf8)]

    /// The read-only format a file name claims, such as `.iso` for "Disk.ISO".
    public static func readOnlyFormat(ofName url: URL) -> ReadOnlyFormat? {
        let name = url.lastPathComponent.lowercased()
        return readOnlySuffixes.first { name.hasSuffix($0.suffix) && name.count > $0.suffix.count }?.format
    }

    /// The read-only format whose signature the file starts with, or nil.
    public static func readOnlyFormat(of url: URL) -> ReadOnlyFormat? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: discMarkerOffset + 5) else { return nil }
        let bytes = Array(data)
        if rarSignatures.contains(where: { bytes.starts(with: $0) }) { return .rar }
        if bytes.starts(with: cabSignature) { return .cab }
        if cpioSignatures.contains(where: { bytes.starts(with: $0) }) { return .cpio }
        if bytes.count >= discMarkerOffset + 5,
           discMarkers.contains(Array(bytes[discMarkerOffset..<(discMarkerOffset + 5)])) { return .iso }
        return nil
    }

    /// The archive format a file name claims, such as `.tarGz` for "x.tar.gz" or "x.tgz".
    public static func format(ofName url: URL) -> ArchiveFormat? {
        let name = url.lastPathComponent.lowercased()
        return nameSuffixes.first { name.hasSuffix($0.suffix) && name.count > $0.suffix.count }?.format
    }

    /// - Returns: `.zip`, `.sevenZip`, `.zpaq`, `.tar`, the compressed tar format whose compressor wrote
    ///   the file's first bytes (whatever the stream holds), or nil.
    public static func format(of url: URL) -> ArchiveFormat? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 512) else { return nil }
        return format(ofHeader: Array(data))
    }

    static func format(ofHeader bytes: [UInt8]) -> ArchiveFormat? {
        if zipSignatures.contains(where: { bytes.starts(with: $0) }) { return .zip }
        if bytes.starts(with: sevenZipSignature) { return .sevenZip }
        if bytes.starts(with: ZpaqEngine.signature) { return .zpaq }
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
