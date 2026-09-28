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
                Image(systemName: isExtracting ? "archivebox" : "doc.on.doc")
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
                }
            }
        }
    }

    private var isExtracting: Bool {
        if case .extract = model.pendingAction { true } else { false }
    }

    private var summary: String {
        let names = ArchivePlanner.displayName(for: model.pendingItems)
        if model.isCheckingItems { return "Checking \(names)…" }
        return isExtracting ? "Ready to extract \(names)" : "Ready to compress \(names)"
    }
}
