import Foundation
import TampCore

/// A quick look at what an archive holds, listed without extracting it (see
/// `ArchiveContentsLister` in TampCore).
extension AppModel {
    struct ArchiveContentsPreview: Identifiable {
        let id = UUID()
        var archive: URL
        var entries: [ArchiveContentsLister.Entry]
    }

    func canPreviewContents(_ archive: URL) -> Bool {
        ArchiveContentsLister.canList(archive, registry: registry)
    }

    func previewContents(of archive: URL) {
        archiveContentsTask?.cancel()
        isLoadingArchiveContents = true
        archiveContentsError = nil
        let registry = registry
        archiveContentsTask = Task { [weak self] in
            do {
                let entries = try await ArchiveContentsLister.list(archive, registry: registry)
                guard !Task.isCancelled else { return }
                self?.archiveContentsPreview = ArchiveContentsPreview(archive: archive, entries: entries)
            } catch {
                guard !Task.isCancelled else { return }
                self?.archiveContentsError = TampError(error).localizedDescription
            }
            self?.isLoadingArchiveContents = false
        }
    }

    func dismissArchiveContentsPreview() {
        archiveContentsTask?.cancel()
        archiveContentsTask = nil
        isLoadingArchiveContents = false
        archiveContentsPreview = nil
    }

    func dismissArchiveContentsError() {
        archiveContentsError = nil
    }
}
