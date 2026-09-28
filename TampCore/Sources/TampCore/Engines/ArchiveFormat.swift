/// How formats are grouped in the format picker.
public enum FormatGroup: String, CaseIterable, Codable, Sendable {
    case compatible
    case fast
    case highRatio
    case extreme
    case macOSNative

    public var title: String {
        switch self {
        case .compatible: "Compatible"
        case .fast: "Fast"
        case .highRatio: "High ratio"
        case .extreme: "Extreme"
        case .macOSNative: "macOS-native"
        }
    }
}

/// Every archive format Tamp can write. Engines arrive phase by phase;
/// `ArchiveFormat.allCases` is the full list the picker is built from.
public enum ArchiveFormat: String, CaseIterable, Codable, Sendable {
    case zip
    case sevenZip
    case tar
    case tarGz
    case tarBz2
    case tarXz
    case tarZst
    case tarLz4
    case tarLz
    case tarBr
    case zpaq
    case appleArchive
    case dmg

    public var title: String {
        switch self {
        case .zip: "ZIP"
        case .sevenZip: "7Z"
        case .tar: "TAR"
        case .tarGz: "TAR.GZ"
        case .tarBz2: "TAR.BZ2"
        case .tarXz: "TAR.XZ"
        case .tarZst: "TAR.ZST"
        case .tarLz4: "TAR.LZ4"
        case .tarLz: "TAR.LZ"
        case .tarBr: "TAR.BR"
        case .zpaq: "ZPAQ"
        case .appleArchive: "Apple Archive"
        case .dmg: "Disk Image"
        }
    }

    /// File extension without the leading dot.
    public var fileExtension: String {
        switch self {
        case .zip: "zip"
        case .sevenZip: "7z"
        case .tar: "tar"
        case .tarGz: "tar.gz"
        case .tarBz2: "tar.bz2"
        case .tarXz: "tar.xz"
        case .tarZst: "tar.zst"
        case .tarLz4: "tar.lz4"
        case .tarLz: "tar.lz"
        case .tarBr: "tar.br"
        case .zpaq: "zpaq"
        case .appleArchive: "aar"
        case .dmg: "dmg"
        }
    }

    public var group: FormatGroup {
        switch self {
        case .zip, .tar, .tarGz: .compatible
        case .tarLz4, .tarZst: .fast
        case .sevenZip, .tarXz, .tarLz, .tarBr, .tarBz2: .highRatio
        case .zpaq: .extreme
        case .appleArchive, .dmg: .macOSNative
        }
    }

    /// A tar stream passed through a compressor. Store on these formats
    /// writes a plain .tar, because none of their compressors has a true store level.
    public var isCompressedTar: Bool {
        switch self {
        case .tarGz, .tarBz2, .tarXz, .tarZst, .tarLz4, .tarLz, .tarBr: true
        default: false
        }
    }

    public static func formats(in group: FormatGroup) -> [ArchiveFormat] {
        allCases.filter { $0.group == group }
    }

    /// The compression methods this format can hold inside, default first.
    /// Empty for formats with only one.
    public var methods: [CompressionMethod] {
        switch self {
        case .zip: [.deflate, .deflate64, .bzip2, .lzma, .zstd]
        case .sevenZip: [.lzma2, .lzma, .ppmd, .bzip2, .deflate]
        default: []
        }
    }

    /// The Advanced panel's settings for this format with `method` inside, in
    /// display order. Password-only settings are listed; the panel hides them
    /// until a password is entered.
    public func advancedOptions(method: CompressionMethod?) -> [AdvancedOption] {
        let method = resolvedMethod(method)
        switch self {
        case .sevenZip:
            let lzma = method == .lzma2 || method == .lzma
            return (lzma ? [.dictionary, .wordSize] : []) + [.solid, .executableFilter, .threads, .encryptFileNames]
        case .zip:
            // minizip, which writes Zstandard, uses one thread and only AES-256.
            return method == .zstd ? [] : [.threads, .zipEncryption]
        case .tarZst: return [.zstdLongWindow, .threads]
        case .tarXz: return [.xzBlockSize, .threads]
        case .tarGz, .tarBz2: return [.threads]
        case .tarBr: return [.brotliLargeWindow]
        case .zpaq: return [.zpaqBlockSize, .threads]
        default: return []
        }
    }

    /// `method` if this format can hold it, else the format's default.
    public func resolvedMethod(_ method: CompressionMethod?) -> CompressionMethod? {
        guard let method, methods.contains(method) else { return methods.first }
        return method
    }
}

/// A compression method inside a ZIP or 7Z archive.
public enum CompressionMethod: String, CaseIterable, Codable, Sendable {
    case deflate
    case deflate64
    case bzip2
    case lzma
    case lzma2
    case ppmd
    case zstd

    public var title: String {
        switch self {
        case .deflate: "Deflate"
        case .deflate64: "Deflate64"
        case .bzip2: "BZip2"
        case .lzma: "LZMA"
        case .lzma2: "LZMA2"
        case .ppmd: "PPMd"
        case .zstd: "Zstandard"
        }
    }

    /// The name 7zz's -mm= and -m0= switches take. Nil for zstd, which official
    /// 7-Zip can read in a ZIP but not write.
    var sevenZipName: String? {
        switch self {
        case .deflate: "Deflate"
        case .deflate64: "Deflate64"
        case .bzip2: "BZip2"
        case .lzma: "LZMA"
        case .lzma2: "LZMA2"
        case .ppmd: "PPMd"
        case .zstd: nil
        }
    }
}
