import SwiftUI
import TampCore

/// Where files, folders and archives are dropped. Shows what's waiting to start.
struct DropZone: View {
    let model: AppModel
    @State private var isTargeted = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(isTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                    style: StrokeStyle(lineWidth: 2, dash: [6, 4])
                )
            content
                .padding(16)
        }
        .frame(maxWidth: .infinity, minHeight: 150)
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            model.add(files)
            return true
        } isTargeted: { targeted in
            isTargeted = targeted
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.pendingItems.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Drop files or folders to compress, or archives to extract")
                    .multilineTextAlignment(.center)
                Button("Choose…") { model.chooseFiles() }
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(summary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .truncationMode(.middle)
                HStack {
                    Button("Add More…") { model.chooseFiles() }
                    Button("Clear") { model.clearPendingItems() }
                    if isExtracting {
                        Button("Compress Instead") { model.forceCompress() }
                            .buttonStyle(.link)
                            .help("Bundle this into a new archive instead of opening it")
                    }
                    if let archive = singleArchiveToPreview {
                        Button("Preview Contents") { model.previewContents(of: archive) }
                            .buttonStyle(.link)
                            .disabled(model.isLoadingArchiveContents)
                            .help("See what's inside without extracting it")
                    }
                }
            }
        }
    }

    private var isExtracting: Bool {
        if case .extract = model.pendingAction { true } else { false }
    }

    /// Only offered for a single archive Tamp can list without extracting
    /// (see `ArchiveContentsLister`) - a batch preview isn't worth the extra UI.
    private var singleArchiveToPreview: URL? {
        guard case let .extract(archives) = model.pendingAction, let only = archives.first, archives.count == 1 else { return nil }
        return model.canPreviewContents(only) ? only : nil
    }

    private var iconName: String {
        if !model.mediaItems.isEmpty { return "photo.on.rectangle" }
        return isExtracting ? "archivebox" : "doc.on.doc"
    }

    private var summary: String {
        if !model.mediaItems.isEmpty { return mediaSummary }
        let names = ArchivePlanner.displayName(for: model.pendingItems)
        if model.isCheckingItems { return "Checking \(names)…" }
        return isExtracting ? "Ready to extract \(names)" : "Ready to compress \(names)"
    }

    /// "Ready to compress "photo.jpg"" for one item, else a breakdown by kind
    /// ("2 images, 1 video") since each gets its own row and settings below.
    private var mediaSummary: String {
        guard model.mediaItems.count > 1 else {
            let name = model.mediaItems.first.map { "“\($0.source.lastPathComponent)”" } ?? ""
            return "Ready to compress \(name)"
        }
        let parts: [String] = [MediaKind.image, .audio, .video].compactMap { kind in
            let count = model.mediaItems.filter { $0.kind == kind }.count
            guard count > 0 else { return nil }
            switch kind {
            case .image: return "\(count) image\(count == 1 ? "" : "s")"
            case .audio: return "\(count) audio file\(count == 1 ? "" : "s")"
            case .video: return "\(count) video\(count == 1 ? "" : "s")"
            }
        }
        return "Ready to compress " + parts.joined(separator: ", ")
    }
}
