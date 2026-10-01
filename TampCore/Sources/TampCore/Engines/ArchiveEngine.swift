import Foundation

/// Reports progress as a fraction from 0 to 1. Called from background queues.
public typealias ProgressHandler = @Sendable (Double) -> Void

public struct CompressRequest: Sendable {
    public var items: [URL]
    /// Where the archive should go. If that name is taken, the output gets "Name 2.ext" instead.
    public var destination: URL
    public var step: SpeedStep
    public var options: ArchiveOptions
    public var password: String?
    /// Leaves out .DS_Store, AppleDouble "._" files and __MACOSX folders.
    public var excludesMacOSJunk: Bool
    /// Splits the archive into parts of this size ("Name.7z.001", ...), for formats
    /// that can (see `ArchiveFormat.canSplit`). Nil writes one file.
    public var volumeBytes: Int64?

    public init(
        items: [URL],
        destination: URL,
        step: SpeedStep,
        options: ArchiveOptions = ArchiveOptions(),
        password: String? = nil,
        excludesMacOSJunk: Bool = true,
        volumeBytes: Int64? = nil
    ) {
        self.items = items
        self.destination = destination
        self.step = step
        self.options = options
        self.password = password
        self.excludesMacOSJunk = excludesMacOSJunk
        self.volumeBytes = volumeBytes.map { max(64 * 1024, $0) }
    }
}

extension CompressRequest {
    /// Every item is stored under its own name, so two with the same name (ignoring
    /// case, as APFS does) would collide: one would be dropped or overwrite the other.
    public func checkNamesAreUnique() throws {
        var seen = Set<String>()
        for item in items {
            let name = item.lastPathComponent
            guard seen.insert(name.precomposedStringWithCanonicalMapping.lowercased()).inserted else {
                throw TampError.other("Two items are named “\(name)”. Rename one, or put them in a folder, and try again.")
            }
        }
    }
}

public struct ExtractRequest: Sendable {
    public var archive: URL
    /// The folder the contents go into. A single top-level item lands directly in it;
    /// several items get a folder named after the archive.
    public var destinationDirectory: URL
    public var password: String?

    public init(archive: URL, destinationDirectory: URL, password: String? = nil) {
        self.archive = archive
        self.destinationDirectory = destinationDirectory
        self.password = password
    }
}

/// Opens one kind of archive. Every extractor writes through `SafeOutput`, so a
/// cancelled or failed job leaves nothing behind.
public protocol ArchiveExtractor: Sendable {
    /// The format, when Tamp can also write it; nil for RAR, CAB, ISO, CPIO and
    /// lone compressed files, which Tamp only opens.
    var writableFormat: ArchiveFormat? { get }
    /// - Returns: The extracted file or folder.
    func extract(_ request: ExtractRequest, progress: @escaping ProgressHandler) async throws -> URL
}

/// One adapter per tool for a format Tamp writes as well as opens.
public protocol ArchiveEngine: ArchiveExtractor, SpeedStepMapping {
    /// - Returns: The archive that was written.
    func compress(_ request: CompressRequest, progress: @escaping ProgressHandler) async throws -> URL
}

extension ArchiveEngine {
    public var writableFormat: ArchiveFormat? { format }
}

/// Finds bundled helper executables: `TAMP_HELPERS_DIR` first (build scripts and
/// tests), then the app's Contents/Helpers.
public struct HelperLocator: Sendable {
    public var directories: [URL]

    public init(directories: [URL]) {
        self.directories = directories
    }

    public static var standard: HelperLocator {
        var directories: [URL] = []
        if let override = ProcessInfo.processInfo.environment["TAMP_HELPERS_DIR"], !override.isEmpty {
            directories.append(URL(fileURLWithPath: override, isDirectory: true))
        }
        directories.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true))
        return HelperLocator(directories: directories)
    }

    public func url(for name: String, fileManager: FileManager = .default) throws -> URL {
        for directory in directories {
            let candidate = directory.appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        throw TampError.helperMissing(name: name)
    }
}

extension JobContext {
    /// Turns an engine's fractional progress into byte counts for the job's ETA.
    /// - Parameter offset: Bytes already done before this step, such as the
    ///   compressing that comes before checking the archive.
    public func progressHandler(totalBytes: Int64, offset: Int64 = 0) -> ProgressHandler {
        { [self] fraction in
            let bytes = offset + Int64(Double(totalBytes) * min(1, max(0, fraction)))
            Task { await self.reportProgress(bytesProcessed: bytes) }
        }
    }
}

public enum InputSize {
    /// Sum of regular file sizes, walking into folders.
    public static func totalBytes(of items: [URL], fileManager: FileManager = .default) -> Int64 {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]
        var total: Int64 = 0
        for item in items {
            let values = try? item.resourceValues(forKeys: Set(keys))
            guard values?.isDirectory == true else {
                total += Int64(values?.fileSize ?? 0)
                continue
            }
            let enumerator = fileManager.enumerator(at: item, includingPropertiesForKeys: keys)
            while let file = enumerator?.nextObject() as? URL {
                let fileValues = try? file.resourceValues(forKeys: Set(keys))
                if fileValues?.isRegularFile == true {
                    total += Int64(fileValues?.fileSize ?? 0)
                }
            }
        }
        return total
    }
}
