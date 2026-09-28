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
}
