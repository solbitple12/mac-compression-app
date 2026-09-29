import SwiftUI
import TampCore

/// The pending media batch: one row per dropped image, audio or video file,
/// each with its own format and quality controls - unlike `ArchiveSettingsView`,
/// where one picker applies to the whole batch.
struct MediaBatchView: View {
    let model: AppModel

    var body: some View {
        List(model.mediaItems) { item in
            MediaItemRow(item: item, model: model)
        }
        .listStyle(.inset)
        .frame(minHeight: 120, maxHeight: 220)
    }
}

struct MediaItemRow: View {
    let item: MediaItem
    let model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Text(item.source.lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            formatPicker
            qualityPicker
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var formatPicker: some View {
        switch item.target {
        case .image:
            Picker("Format", selection: imageFormat) {
                ForEach(model.mediaRegistry.availableImageFormats, id: \.self) { format in
                    Text(format.title).tag(format)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
        case .audio:
            Picker("Format", selection: audioFormat) {
                ForEach(model.mediaRegistry.availableAudioFormats, id: \.self) { format in
                    Text(format.title).tag(format)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
        case .video:
            Picker("Format", selection: videoFormat) {
                ForEach(model.mediaRegistry.availableVideoFormats, id: \.self) { format in
                    Text(format.title).tag(format)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
        }
    }

    @ViewBuilder
    private var qualityPicker: some View {
        if !isAlwaysLossless {
            MediaQualityPicker(quality: quality, supportsLossless: supportsLossless)
        }
    }

    private var isAlwaysLossless: Bool {
        switch item.target {
        case let .image(format): format.isAlwaysLossless
        case let .audio(format): format.isAlwaysLossless
        case .video: false
        }
    }

    private var supportsLossless: Bool {
        switch item.target {
        case let .image(format): format.supportsLossless
        case let .audio(format): format.isAlwaysLossless
        case .video: false
        }
    }

    private var quality: Binding<MediaQuality> {
        Binding(
            get: { item.quality },
            set: { newValue in model.updateMediaItem(item.id) { $0.quality = newValue } }
        )
    }

    private var imageFormat: Binding<ImageFormat> {
        Binding(
            get: {
                if case let .image(format) = item.target { return format }
                return .jpeg
            },
            set: { newFormat in model.updateMediaItem(item.id) { $0.target = .image(newFormat) } }
        )
    }

    private var audioFormat: Binding<AudioFormat> {
        Binding(
            get: {
                if case let .audio(format) = item.target { return format }
                return .flac
            },
            set: { newFormat in model.updateMediaItem(item.id) { $0.target = .audio(newFormat) } }
        )
    }

    private var videoFormat: Binding<VideoFormat> {
        Binding(
            get: {
                if case let .video(format) = item.target { return format }
                return .h264
            },
            set: { newFormat in model.updateMediaItem(item.id) { $0.target = .video(newFormat) } }
        )
    }
}

/// A quality choice for one media item: Lossless (when the format can hold
/// it) plus the four plain-language presets. The Advanced panel's custom
/// quality and bitrate controls aren't here yet.
struct MediaQualityPicker: View {
    @Binding var quality: MediaQuality
    var supportsLossless: Bool

    private enum Choice: Hashable {
        case lossless
        case preset(QualityPreset)
    }

    private var choice: Binding<Choice> {
        Binding(
            get: {
                if case .lossless = quality { return .lossless }
                if case let .preset(preset) = quality { return .preset(preset) }
                return .preset(.high)
            },
            set: { newValue in
                switch newValue {
                case .lossless: quality = .lossless
                case let .preset(preset): quality = .preset(preset)
                }
            }
        )
    }

    var body: some View {
        Picker("Quality", selection: choice) {
            if supportsLossless {
                Text("Lossless").tag(Choice.lossless)
            }
            ForEach(QualityPreset.allCases, id: \.self) { preset in
                Text(preset.title).tag(Choice.preset(preset))
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
    }
}
