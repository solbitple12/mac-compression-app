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
    public static func action(for items: [URL], registry: EngineRegistry) -> DropAction {
        let allOpenable = !items.isEmpty && items.allSatisfy { item in
            let isFile = (try? item.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            return isFile && registry.extractor(for: item) != nil
        }
        return allOpenable ? .extract(items) : .compress(items)
    }

    /// Where a new archive goes: beside the first item, named after it when it's
    /// the only one ("Photos.zip", "report.pdf.zip", as Finder does), else "Archive".
    /// The engine picks "Name 2.zip" if that name is taken.
    public static func destination(for items: [URL], format: ArchiveFormat) -> URL {
        let directory = items.first?.deletingLastPathComponent() ?? FileManager.default.homeDirectoryForCurrentUser
        let baseName = items.count == 1 ? items[0].lastPathComponent : "Archive"
        return directory.appendingPathComponent("\(baseName).\(format.fileExtension)")
    }

    /// For the job list, such as “Photos” or “Photos” and 2 more.
    public static func displayName(for items: [URL]) -> String {
        guard let first = items.first else { return "" }
        let name = "“\(first.lastPathComponent)”"
        return items.count == 1 ? name : "\(name) and \(items.count - 1) more"
    }
}
