import Foundation

/// Checks a finished archive by opening it into a hidden folder beside it and
/// comparing what comes out with the originals, byte for byte.
public enum ArchiveVerifier {
    /// What the format is known not to keep, so its absence isn't a failure.
    public struct Allowances: Sendable {
        /// ZPAQ drops symbolic links.
        public var linksMayBeMissing = false
        /// Left out on purpose when the job excluded them.
        public var junkMayBeMissing = false
        /// Disk images add their own .DS_Store and the like; Tamp doesn't copy the
        /// volume's housekeeping folders, but ignores extra junk the same way.
        public var extraJunkAllowed = false

        public init(linksMayBeMissing: Bool = false, junkMayBeMissing: Bool = false, extraJunkAllowed: Bool = false) {
            self.linksMayBeMissing = linksMayBeMissing
            self.junkMayBeMissing = junkMayBeMissing
            self.extraJunkAllowed = extraJunkAllowed
        }

        public static func `for`(_ request: CompressRequest, format: ArchiveFormat) -> Allowances {
            Allowances(
                linksMayBeMissing: format == .zpaq,
                junkMayBeMissing: request.excludesMacOSJunk,
                extraJunkAllowed: format == .dmg || !request.excludesMacOSJunk
            )
        }
    }

    /// - Throws: `TampError.other` naming the first item that differs, or whatever
    ///   opening the archive threw.
    public static func verify(
        _ archive: URL,
        items: [URL],
        password: String?,
        extractor: any ArchiveExtractor,
        allowances: Allowances,
        progress: @escaping ProgressHandler
    ) async throws {
        let fileManager = FileManager.default
        let folder = SafeOutput.temporaryURL(for: archive.deletingLastPathComponent().appendingPathComponent("verify"))
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { SafeOutput.remove(folder, fileManager: fileManager) }

        let extracted = try await extractor.extract(
            ExtractRequest(archive: archive, destinationDirectory: folder, password: password),
            progress: progress
        )
        try Task.checkCancellation()
        // One item comes out as itself, or as its contents in a folder for a disk
        // image made from a folder; several come out side by side in a folder.
        let pairs: [(original: URL, copy: URL)] = items.count == 1
            ? [(items[0], extracted)]
            : items.map { ($0, extracted.appendingPathComponent($0.lastPathComponent)) }
        for (original, copy) in pairs {
            try Task.checkCancellation()
            if let problem = difference(between: original, and: copy, allowances: allowances, fileManager: fileManager) {
                throw TampError.other("Verification failed: \(problem). The archive was kept, but don't rely on it.")
            }
        }
    }

    /// A description of the first difference, or nil when the copy matches.
    static func difference(between original: URL, and copy: URL, allowances: Allowances, fileManager: FileManager) -> String? {
        let originals = entries(under: original, fileManager: fileManager)
        let copies = entries(under: copy, fileManager: fileManager)
        let name = original.lastPathComponent
        for (path, kind) in originals.sorted(by: { $0.key < $1.key }) {
            let shown = path.isEmpty ? "“\(name)”" : "“\(name)/\(path)”"
            if isJunk(path), allowances.junkMayBeMissing { continue }
            guard let copied = copies[path] else {
                if kind == .typeSymbolicLink, allowances.linksMayBeMissing { continue }
                return "\(shown) is missing"
            }
            guard copied == kind else { return "\(shown) changed kind" }
            let a = original.appendingPathComponent(path).path
            let b = copy.appendingPathComponent(path).path
            switch kind {
            case .typeRegular:
                if !fileManager.contentsEqual(atPath: a, andPath: b) { return "\(shown) differs" }
            case .typeSymbolicLink:
                if (try? fileManager.destinationOfSymbolicLink(atPath: a)) != (try? fileManager.destinationOfSymbolicLink(atPath: b)) {
                    return "\(shown) points elsewhere"
                }
            default:
                break
            }
        }
        for path in copies.keys where originals[path] == nil {
            if isJunk(path), allowances.extraJunkAllowed { continue }
            return "“\(name)/\(path)” wasn't in the original"
        }
        return nil
    }

    /// Every item under `root` by relative path ("" for `root` itself), Unicode-normalized.
    static func entries(under root: URL, fileManager: FileManager) -> [String: FileAttributeType] {
        var result: [String: FileAttributeType] = [:]
        guard let kind = (try? fileManager.attributesOfItem(atPath: root.path))?[.type] as? FileAttributeType else { return result }
        result[""] = kind
        guard kind == .typeDirectory else { return result }
        for relative in (try? fileManager.subpathsOfDirectory(atPath: root.path)) ?? [] {
            let attributes = try? fileManager.attributesOfItem(atPath: root.appendingPathComponent(relative).path)
            result[relative.precomposedStringWithCanonicalMapping] = attributes?[.type] as? FileAttributeType ?? .typeUnknown
        }
        return result
    }

    static func isJunk(_ path: String) -> Bool {
        path.split(separator: "/").contains { component in
            component == ".DS_Store" || component.hasPrefix("._") || component == "__MACOSX"
        }
    }
}
