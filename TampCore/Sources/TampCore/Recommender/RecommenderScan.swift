import Foundation

/// What kind of content a dropped file holds. Stage 1 of the recommender
/// (see the architecture plan's Recommender section): classifies by magic
/// bytes first, so a renamed file is still recognized, falling back to its
/// extension only when the bytes don't match anything known.
public enum FileKind: Hashable, Sendable {
    case archive(ArchiveFormat)
    case readOnlyArchive(ReadOnlyFormat)
    case image
    case audio
    case video
    case text
    case other
}

/// One file's classification and compressibility sample, the input the rules
/// stage (`RecommenderRules`) reasons about.
public struct FileProfile: Equatable, Sendable {
    public var url: URL
    public var kind: FileKind
    public var bytes: Int64
    /// Shannon entropy in bits per byte (0 to 8) of a sample of the file's
    /// content, or nil for a file too small or unreadable to sample.
    /// Near 8 means already compressed or encrypted.
    public var entropy: Double?

    public init(url: URL, kind: FileKind, bytes: Int64, entropy: Double?) {
        self.url = url
        self.kind = kind
        self.bytes = bytes
        self.entropy = entropy
    }

    /// Entropy above this suggests the file is already compressed or encrypted,
    /// so re-compressing it won't help much.
    public static let denseEntropyThreshold = 7.5
    public var isAlreadyDense: Bool { (entropy ?? 0) > Self.denseEntropyThreshold }
}

public enum RecommenderScan {
    static let jpegSignature: [UInt8] = [0xFF, 0xD8, 0xFF]
    static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    static let mp4FtypOffset = 4
    static let mp4Ftyp = Array("ftyp".utf8)
    static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "json", "csv", "tsv", "log", "xml", "yaml", "yml",
        "html", "htm", "css", "js", "ts", "swift", "py", "c", "h", "cpp", "java", "rtf",
    ]

    /// The kind a file's first bytes suggest, or (when they don't match
    /// anything known) its extension. Folders are always `.other`: the
    /// recommender treats a batch, not a single file, as a whole.
    public static func kind(of url: URL, fileManager: FileManager = .default) -> FileKind {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        guard !isDirectory else { return .other }
        if let format = ArchiveDetector.format(of: url) { return .archive(format) }
        if let format = ArchiveDetector.readOnlyFormat(of: url) { return .readOnlyArchive(format) }
        if let header = header(of: url, length: 16) {
            if header.starts(with: jpegSignature) || header.starts(with: pngSignature) { return .image }
            if header.count >= mp4FtypOffset + 4, Array(header[mp4FtypOffset..<(mp4FtypOffset + 4)]) == mp4Ftyp { return .video }
        }
        switch MediaPlanner.kind(of: url) {
        case .image: return .image
        case .audio: return .audio
        case .video: return .video
        case nil: break
        }
        if textExtensions.contains(url.pathExtension.lowercased()) { return .text }
        return .other
    }

    private static func header(of url: URL, length: Int) -> [UInt8]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: length) else { return nil }
        return Array(data)
    }

    /// Shannon entropy (bits per byte, 0 to 8) of up to 16 evenly spaced 64 KB
    /// blocks, the sample stage: near 8 means already compressed or encrypted.
    /// Nil for an empty or unreadable file.
    public static func entropy(of url: URL) -> Double? {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 0 else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let blockSize = 64 * 1024
        let blockCount = min(16, max(1, size / blockSize))
        var counts = [Int](repeating: 0, count: 256)
        var sampledBytes = 0
        for index in 0..<blockCount {
            let span = max(0, size - blockSize)
            let offset = blockCount == 1 ? 0 : (span * index) / max(1, blockCount - 1)
            guard (try? handle.seek(toOffset: UInt64(offset))) != nil, let data = try? handle.read(upToCount: blockSize) else { continue }
            for byte in data { counts[Int(byte)] += 1 }
            sampledBytes += data.count
        }
        guard sampledBytes > 0 else { return nil }
        var bits = 0.0
        for count in counts where count > 0 {
            let probability = Double(count) / Double(sampledBytes)
            bits -= probability * log2(probability)
        }
        return bits
    }

    /// One file's full profile: its kind, size and entropy sample.
    public static func profile(of url: URL, fileManager: FileManager = .default) -> FileProfile? {
        guard let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])),
              bytes.isDirectory != true else { return nil }
        return FileProfile(url: url, kind: kind(of: url, fileManager: fileManager), bytes: Int64(bytes.fileSize ?? 0), entropy: entropy(of: url))
    }

    /// Every regular file under `items`, walking into folders.
    public static func profiles(for items: [URL], fileManager: FileManager = .default) -> [FileProfile] {
        var results: [FileProfile] = []
        for item in items {
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            guard isDirectory else {
                if let profile = profile(of: item, fileManager: fileManager) { results.append(profile) }
                continue
            }
            let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey]
            let enumerator = fileManager.enumerator(at: item, includingPropertiesForKeys: keys)
            while let file = enumerator?.nextObject() as? URL {
                guard (try? file.resourceValues(forKeys: Set(keys)))?.isRegularFile == true else { continue }
                if let profile = profile(of: file, fileManager: fileManager) { results.append(profile) }
            }
        }
        return results
    }
}
