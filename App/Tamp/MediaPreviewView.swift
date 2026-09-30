import AVKit
import SwiftUI
import TampCore

/// The original and the re-encoded clip side by side, so quality and size
/// differences are easy to compare before starting the real job.
struct MediaPreviewView: View {
    let preview: AppModel.MediaPreview
    let onDismiss: () -> Void

    @State private var originalPlayer: AVPlayer
    @State private var previewPlayer: AVPlayer

    init(preview: AppModel.MediaPreview, onDismiss: @escaping () -> Void) {
        self.preview = preview
        self.onDismiss = onDismiss
        _originalPlayer = State(initialValue: AVPlayer(url: preview.source))
        _previewPlayer = State(initialValue: AVPlayer(url: preview.output))
    }

    var body: some View {
        VStack(spacing: 14) {
            Text("Preview: \(preview.format.title)")
                .font(.headline)
            HStack(spacing: 14) {
                VStack(spacing: 4) {
                    Text("Original").font(.caption).foregroundStyle(.secondary)
                    VideoPlayer(player: originalPlayer)
                }
                VStack(spacing: 4) {
                    Text("Preview").font(.caption).foregroundStyle(.secondary)
                    VideoPlayer(player: previewPlayer)
                }
            }
            .frame(minWidth: 520, minHeight: 300)
            Button("Close") { onDismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(20)
        .onDisappear {
            originalPlayer.pause()
            previewPlayer.pause()
        }
    }
}
