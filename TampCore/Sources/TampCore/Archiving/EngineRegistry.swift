import Foundation

/// The engines this build of Tamp has, and which one writes or opens a given format.
/// The format picker lists only `availableFormats`; more arrive with each phase.
public struct EngineRegistry: Sendable {
    public let engines: [any ArchiveEngine]

    public init(engines: [any ArchiveEngine]) {
        self.engines = engines
    }

    public static func standard(helpers: HelperLocator = .standard) -> EngineRegistry {
        EngineRegistry(engines: [ZipEngine(helpers: helpers), TarZstEngine(helpers: helpers)])
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
    /// .epub, .pages), and a lone .zst may not hold a tar, so neither is extracted.
    /// A file with no extension is judged by its first bytes alone.
    public func extractor(for archive: URL) -> (any ArchiveEngine)? {
        let named = ArchiveDetector.format(ofName: archive)
        guard named != nil || archive.pathExtension.isEmpty else { return nil }
        switch ArchiveDetector.format(of: archive) {
        case .zip: return engine(for: .zip)
        // The TAR.ZST engine also opens plain tar files.
        case .tar: return engine(for: .tarZst)
        case .tarZst where named == .tarZst: return engine(for: .tarZst)
        default: return nil
        }
    }
}

/// Recognizes archives by their first bytes rather than their name.
public enum ArchiveDetector {
    static let zipSignatures: [[UInt8]] = [
        [0x50, 0x4B, 0x03, 0x04], // a local file header
        [0x50, 0x4B, 0x05, 0x06], // the end record of an empty archive
        [0x50, 0x4B, 0x07, 0x08], // spanned archives start with a data descriptor signature
    ]
    /// POSIX and GNU tar headers carry "ustar" at offset 257.
    static let tarMagicOffset = 257
    static let tarMagic = Array("ustar".utf8)

    /// The archive format a file name claims: ".zip", ".tar", ".tar.zst" or ".tzst".
    public static func format(ofName url: URL) -> ArchiveFormat? {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".tar.zst") || name.hasSuffix(".tzst") { return .tarZst }
        switch url.pathExtension.lowercased() {
        case "zip": return .zip
        case "tar": return .tar
        default: return nil
        }
    }

    /// - Returns: `.zip`, `.tarZst` for any zstd stream, `.tar`, or nil.
    public static func format(of url: URL) -> ArchiveFormat? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 512) else { return nil }
        return format(ofHeader: Array(data))
    }

    static func format(ofHeader bytes: [UInt8]) -> ArchiveFormat? {
        if zipSignatures.contains(where: { bytes.starts(with: $0) }) { return .zip }
        if bytes.starts(with: TarZstEngine.zstdMagic) { return .tarZst }
        let end = tarMagicOffset + tarMagic.count
        if bytes.count >= end, Array(bytes[tarMagicOffset..<end]) == tarMagic { return .tar }
        return nil
    }
}
