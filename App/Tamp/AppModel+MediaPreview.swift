import Foundation
import TampCore

/// A short before/after clip for one pending video item, generated on demand
/// with its current format, step and quality (see `VideoPreview` in TampCore).
extension AppModel {
    struct MediaPreview: Identifiable {
        let id = UUID()
        var source: URL
        var output: URL
        var format: VideoFormat
    }

    /// Trims and re-encodes a short clip from `item`'s middle with its current
    /// settings, then shows it beside the original. Only video items have a
    /// preview: TampCore's `VideoPreview` has no image or audio counterpart yet.
    func previewMediaItem(_ item: MediaItem) {
        guard case let .video(format) = item.target, let engine = mediaRegistry.videoEngine(for: format) else { return }
        previewTask?.cancel()
        isGeneratingPreview = true
        previewError = nil
        let source = item.source
        let step = item.step
        let quality = item.quality
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(SafeOutput.partialPrefix)preview-\(UUID().uuidString).\(format.fileExtension)")
        previewTask = Task { [weak self] in
            do {
                let result = try await VideoPreview.compress(source: source, destination: destination, engine: engine, step: step, quality: quality)
                guard !Task.isCancelled else {
                    SafeOutput.remove(result.output)
                    return
                }
                self?.mediaPreview = MediaPreview(source: source, output: result.output, format: format)
            } catch {
                guard !Task.isCancelled else { return }
                self?.previewError = TampError(error).localizedDescription
            }
            self?.isGeneratingPreview = false
        }
    }

    /// Cancels a preview still generating, or removes the finished clip's temp file.
    func dismissMediaPreview() {
        previewTask?.cancel()
        previewTask = nil
        isGeneratingPreview = false
        if let output = mediaPreview?.output { SafeOutput.remove(output) }
        mediaPreview = nil
    }

    func dismissPreviewError() {
        previewError = nil
    }
}
