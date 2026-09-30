import Foundation

/// What Tamp does with items dropped on the window or chosen in the open panel.
public enum DropAction: Equatable, Sendable {
    /// Bundle everything into one archive.
    case compress([URL])
    /// Open each archive next to itself.
    case extract([URL])
}

public enum ArchivePlanner {
    /// Archives Tamp can open (see `EngineRegistry.extractor`) are extracted. Anything else,
    /// or a mix of archives and other items, is compressed together.
    /// Parts of a split archive count as its first part, once, when that exists.
    public static func action(for items: [URL], registry: EngineRegistry) -> DropAction {
        var seen = Set<URL>()
        let opened = items.compactMap { item -> URL? in
            let first = ArchiveDetector.splitPart(of: item)?.firstPart ?? item
            let target = FileManager.default.fileExists(atPath: first.path) ? first : item
            return seen.insert(target.standardizedFileURL).inserted ? target : nil
        }
        let allOpenable = !opened.isEmpty && opened.allSatisfy { item in
            let isFile = (try? item.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            return isFile && registry.extractor(for: item) != nil
        }
        return allOpenable ? .extract(opened) : .compress(items)
    }

    /// Where a new archive goes: beside the first item, named after it when it's
    /// the only one ("Photos.zip", "report.pdf.zip", as Finder does), else "Archive".
    /// The engine picks "Name 2.zip" if that name is taken. `namePattern`, when
    /// set and non-blank, replaces "{name}" in it with that same base name
    /// instead of using it directly - "{name}-compressed" makes "Photos" become
    /// "Photos-compressed.zip".
    public static func destination(for items: [URL], format: ArchiveFormat, namePattern: String? = nil) -> URL {
        let directory = items.first?.deletingLastPathComponent() ?? FileManager.default.homeDirectoryForCurrentUser
        let baseName = items.count == 1 ? items[0].lastPathComponent : "Archive"
        let name = outputName(baseName, pattern: namePattern)
        return directory.appendingPathComponent("\(name).\(format.fileExtension)")
    }

    private static func outputName(_ baseName: String, pattern: String?) -> String {
        guard let pattern, !pattern.trimmingCharacters(in: .whitespaces).isEmpty else { return baseName }
        return pattern.replacingOccurrences(of: "{name}", with: baseName)
    }

    /// For the job list, such as “Photos” or “Photos” and 2 more.
    public static func displayName(for items: [URL]) -> String {
        guard let first = items.first else { return "" }
        let name = "“\(first.lastPathComponent)”"
        return items.count == 1 ? name : "\(name) and \(items.count - 1) more"
    }
}
