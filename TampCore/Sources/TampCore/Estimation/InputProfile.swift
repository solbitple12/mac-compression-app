import Foundation

/// What the estimator needs to know about the items to compress, gathered in one
/// walk: their total size and file count, the largest files to take samples from,
/// and a few small files to measure the cost of each extra file.
public struct InputProfile: Equatable, Sendable {
    public struct File: Equatable, Sendable {
        public var url: URL
        public var bytes: Int64
    }

    /// Files at or below this size count as small: their cost is mostly per file, not per byte.
    public static let smallFileBytes: Int64 = 64 * 1024

    public var items: [URL]
    public var totalBytes: Int64
    public var fileCount: Int
    public var smallFileCount: Int
    /// Up to `largestFileLimit` files, largest first.
    public var largestFiles: [File]
    /// Up to `smallFileSampleLimit` small files, spread over the whole input.
    public var smallFiles: [File]
    /// Changes when any file is added, removed, resized or modified, so cached
    /// estimates for the old contents are dropped.
    public var fingerprint: Int

    static let largestFileLimit = 8
    static let smallFileSampleLimit = 40

    public init(items: [URL], totalBytes: Int64, fileCount: Int, smallFileCount: Int,
                largestFiles: [File], smallFiles: [File], fingerprint: Int) {
        self.items = items
        self.totalBytes = totalBytes
        self.fileCount = fileCount
        self.smallFileCount = smallFileCount
        self.largestFiles = largestFiles
        self.smallFiles = smallFiles
        self.fingerprint = fingerprint
    }

    /// Walks every item, following folders but not symbolic links. Stops early,
    /// returning nil, if the task is cancelled.
    public static func scan(_ items: [URL], fileManager: FileManager = .default) -> InputProfile? {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        var hasher = Hasher()
        var total: Int64 = 0
        var count = 0
        var smallCount = 0
        var largest: [File] = []
        var small: [File] = []

        func visit(_ url: URL, _ values: URLResourceValues?) {
            guard values?.isRegularFile == true else { return }
            let bytes = Int64(values?.fileSize ?? 0)
            hasher.combine(url.path)
            hasher.combine(bytes)
            hasher.combine(values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0)
            total += bytes
            count += 1
            if bytes <= smallFileBytes {
                smallCount += 1
                // Keep every n-th small file so the sample spreads over the input
                // rather than coming from its first folder.
                if small.count < smallFileSampleLimit {
                    small.append(File(url: url, bytes: bytes))
                } else if smallCount % 16 == 0 {
                    small[(smallCount / 16) % smallFileSampleLimit] = File(url: url, bytes: bytes)
                }
            } else if largest.count < largestFileLimit || bytes > largest[largest.count - 1].bytes {
                let index = largest.firstIndex { $0.bytes < bytes } ?? largest.count
                largest.insert(File(url: url, bytes: bytes), at: index)
                if largest.count > largestFileLimit { largest.removeLast() }
            }
        }

        for item in items {
            if Task.isCancelled { return nil }
            let values = try? item.resourceValues(forKeys: Set(keys))
            guard values?.isDirectory == true else {
                visit(item, values)
                continue
            }
            let enumerator = fileManager.enumerator(at: item, includingPropertiesForKeys: keys)
            while let file = enumerator?.nextObject() as? URL {
                if count % 1024 == 0, Task.isCancelled { return nil }
                visit(file, try? file.resourceValues(forKeys: Set(keys)))
            }
        }
        return InputProfile(items: items, totalBytes: total, fileCount: count, smallFileCount: smallCount,
                            largestFiles: largest, smallFiles: small, fingerprint: hasher.finalize())
    }
}
