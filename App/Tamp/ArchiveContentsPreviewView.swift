import SwiftUI
import TampCore

/// What "Preview Contents" shows: every file and folder an archive holds,
/// listed without extracting it (see `ArchiveContentsLister`).
struct ArchiveContentsPreviewView: View {
    let preview: AppModel.ArchiveContentsPreview
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Inside “\(preview.archive.lastPathComponent)”")
                .font(.headline)
            if preview.entries.isEmpty {
                Text("This archive is empty.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                List(preview.entries) { entry in
                    HStack {
                        Image(systemName: entry.isDirectory ? "folder" : "doc")
                            .foregroundStyle(.secondary)
                        Text(entry.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        if let sizeBytes = entry.sizeBytes {
                            Text(EstimateText.file(sizeBytes))
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .listStyle(.inset)
                .frame(minWidth: 420, minHeight: 300)
            }
            HStack {
                Text(preview.entries.isEmpty ? "" : "\(preview.entries.count) item\(preview.entries.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Close") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(SheetLayout.padding)
    }
}
