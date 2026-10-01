import Foundation

/// Output is written to a hidden temp file beside the destination and renamed
/// into place only once complete, with a rename that never overwrites. A stopped
/// or failed job therefore never leaves a half-written file under the real name.
public enum SafeOutput {
    public static let partialPrefix = ".tamp-partial-"

    /// Runs `body` against a temp URL, then moves the result to the first free name
    /// based on `destination` ("Photos.tar.zst", then "Photos 2.tar.zst", ...).
    /// On any error, cancellation included, the temp file is deleted and the error rethrown.
    /// - Returns: Where the output ended up.
    public static func write(
        to destination: URL,
        fileExtension: String,
        fileManager: FileManager = .default,
        body: (URL) async throws -> Void
    ) async throws -> URL {
        let temporary = temporaryURL(for: destination)
        do {
            try await body(temporary)
            try Task.checkCancellation()
            return try commitToAvailableName(temporary, preferring: destination, fileExtension: fileExtension, fileManager: fileManager)
        } catch {
            discard(temporary, fileManager: fileManager)
            throw error
        }
    }

    /// Like `write`, for output split into parts: `body` writes "Name.7z.001",
    /// "Name.7z.002" and so on into a hidden folder beside `destination`, then every
    /// part moves out under the first base name none of whose parts is taken.
    /// - Returns: The first part.
    public static func writeVolumes(
        to destination: URL,
        fileExtension: String,
        fileManager: FileManager = .default,
        body: (_ folder: URL, _ name: String) async throws -> Void
    ) async throws -> URL {
        let folder = temporaryURL(for: destination)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { remove(folder, fileManager: fileManager) }
        try await body(folder, destination.lastPathComponent)
        try Task.checkCancellation()
        let prefix = destination.lastPathComponent + "."
        let parts = try fileManager.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasPrefix(prefix) && Int($0.dropFirst(prefix.count)) != nil }
            .sorted()
        guard !parts.isEmpty else { throw TampError.fileNotFound(path: destination.path) }
        let suffixes = parts.map { String($0.dropFirst(destination.lastPathComponent.count)) }
        let directory = destination.deletingLastPathComponent()

        for _ in 0..<100 {
            let target = availableVolumeName(for: destination, fileExtension: fileExtension, suffixes: suffixes, fileManager: fileManager)
            var moved: [(from: URL, to: URL)] = []
            do {
                for (part, suffix) in zip(parts, suffixes) {
                    let from = folder.appendingPathComponent(part)
                    let to = directory.appendingPathComponent(target.lastPathComponent + suffix)
                    try commit(from, to: to)
                    moved.append((from, to))
                }
                return directory.appendingPathComponent(target.lastPathComponent + suffixes[0])
            } catch let error as POSIXError where error.code == .EEXIST {
                // A part's name was taken meanwhile: put the moved ones back and try the next name.
                for (from, to) in moved.reversed() { try? commit(to, to: from) }
                continue
            }
        }
        throw POSIXError(.EEXIST)
    }

    /// The first of "Name.7z", "Name 2.7z", ... none of whose parts exists yet.
    static func availableVolumeName(for destination: URL, fileExtension: String, suffixes: [String],
                                    fileManager: FileManager) -> URL {
        let directory = destination.deletingLastPathComponent()
        let name = destination.lastPathComponent
        let suffix = ".\(fileExtension)"
        let base = name.hasSuffix(suffix) && name.count > suffix.count ? String(name.dropLast(suffix.count)) : name
        let ending = name.hasSuffix(suffix) && name.count > suffix.count ? suffix : ""
        var number = 1
        while true {
            let candidate = directory.appendingPathComponent(number == 1 ? name : "\(base) \(number)\(ending)")
            let taken = fileManager.fileExists(atPath: candidate.path)
                || suffixes.contains { fileManager.fileExists(atPath: candidate.path + $0) }
            if !taken { return candidate }
            number += 1
        }
    }

    /// Moves a finished file or folder to the first free name based on `destination`.
    /// - Returns: Where it ended up.
    public static func commitToAvailableName(
        _ source: URL,
        preferring destination: URL,
        fileExtension: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        for _ in 0..<100 {
            let target = availableURL(for: destination, fileExtension: fileExtension, fileManager: fileManager)
            do {
                try commit(source, to: target)
                return target
            } catch let error as POSIXError where error.code == .EEXIST {
                // Another file took the name between the check and the rename; try the next one.
                continue
            }
        }
        throw POSIXError(.EEXIST)
    }

    /// Runs `body` against a hidden staging folder in `directory`, then moves the
    /// result into place: a single top-level item directly, several items inside a
    /// folder named `baseName`. On any error the staging folder is deleted.
    /// - Returns: The extracted file or folder.
    public static func extract(
        into directory: URL,
        baseName: String,
        fileManager: FileManager = .default,
        body: (URL) async throws -> Void
    ) async throws -> URL {
        let preferred = directory.appendingPathComponent(baseName, isDirectory: true)
        let staging = temporaryURL(for: preferred)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        do {
            try await body(staging)
            try Task.checkCancellation()
            let children = try fileManager.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
            if children.count == 1, let only = children.first {
                let target = try commitToAvailableName(
                    only,
                    preferring: directory.appendingPathComponent(only.lastPathComponent),
                    fileExtension: only.pathExtension,
                    fileManager: fileManager
                )
                try? fileManager.removeItem(at: staging)
                return target
            }
            return try commitToAvailableName(staging, preferring: preferred, fileExtension: "", fileManager: fileManager)
        } catch {
            remove(staging, fileManager: fileManager)
            throw error
        }
    }

    /// Deletes a file or folder, even one a failed extraction left with read-only
    /// folders or locked files inside, which a plain delete can't remove.
    public static func remove(_ url: URL, fileManager: FileManager = .default) {
        guard (try? fileManager.removeItem(at: url)) == nil else { return }
        makeRemovable(url, fileManager: fileManager)
        try? fileManager.removeItem(at: url)
    }

    /// Clears locks, and gives the owner full access to each folder, top down so
    /// that folders nobody could read can still be walked.
    private static func makeRemovable(_ url: URL, fileManager: FileManager) {
        _ = url.withUnsafeFileSystemRepresentation { path in path.map { lchflags($0, 0) } }
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeDirectory else { return }
        let mode = attributes[.posixPermissions] as? Int ?? 0
        try? fileManager.setAttributes([.posixPermissions: mode | 0o700], ofItemAtPath: url.path)
        for name in (try? fileManager.contentsOfDirectory(atPath: url.path)) ?? [] {
            makeRemovable(url.appendingPathComponent(name), fileManager: fileManager)
        }
    }

    public static func temporaryURL(for destination: URL) -> URL {
        destination
            .deletingLastPathComponent()
            .appendingPathComponent("\(partialPrefix)\(UUID().uuidString)-\(destination.lastPathComponent)")
    }

    /// The destination itself if free, else the first free "Name N.ext".
    /// `fileExtension` may be compound, such as "tar.zst".
    public static func availableURL(for destination: URL, fileExtension: String, fileManager: FileManager = .default) -> URL {
        guard fileManager.fileExists(atPath: destination.path) else { return destination }
        let directory = destination.deletingLastPathComponent()
        let name = destination.lastPathComponent
        let suffix = fileExtension.isEmpty ? "" : ".\(fileExtension)"
        let hasSuffix = !suffix.isEmpty && name.hasSuffix(suffix) && name.count > suffix.count
        let base = hasSuffix ? String(name.dropLast(suffix.count)) : name
        let ending = hasSuffix ? suffix : ""
        var number = 2
        while true {
            let candidate = directory.appendingPathComponent("\(base) \(number)\(ending)")
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            number += 1
        }
    }

    /// Renames atomically, failing with EEXIST rather than replacing an existing file.
    public static func commit(_ temporary: URL, to destination: URL) throws {
        let result = temporary.withUnsafeFileSystemRepresentation { from in
            destination.withUnsafeFileSystemRepresentation { to in
                renamex_np(from, to, UInt32(RENAME_EXCL))
            }
        }
        if result != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    public static func discard(_ temporary: URL, fileManager: FileManager = .default) {
        remove(temporary, fileManager: fileManager)
    }

    /// Deletes partial files a crash left behind. Called at launch for recent destinations.
    @discardableResult
    public static func removeStalePartials(in directory: URL, fileManager: FileManager = .default) -> Int {
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        var removed = 0
        for name in names where name.hasPrefix(partialPrefix) {
            let url = directory.appendingPathComponent(name)
            remove(url, fileManager: fileManager)
            if !fileManager.fileExists(atPath: url.path) { removed += 1 }
        }
        return removed
    }
}
