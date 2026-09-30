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
            metadataPicker
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
    }

    /// Video has no strip-metadata option yet (see `MediaItem.metadata`'s doc comment).
    @ViewBuilder
    private var metadataPicker: some View {
        if item.kind != .video {
            Picker("Metadata", selection: metadata) {
                ForEach(MetadataHandling.allCases, id: \.self) { handling in
                    Text(handling.title).tag(handling)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
        }
    }

    private var metadata: Binding<MetadataHandling> {
        Binding(
            get: { item.metadata },
            set: { newValue in model.updateMediaItem(item.id) { $0.metadata = newValue } }
        )
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
/// it), the four plain-language presets, or Custom, which reveals a 0-100
/// constant-quality slider (`MediaQuality.customQuality`, the same scale
/// `ImageQualityMapping` and `VideoQualityMapping` use). The Advanced panel's
/// target-bitrate control isn't here yet.
struct MediaQualityPicker: View {
    @Binding var quality: MediaQuality
    var supportsLossless: Bool

    private enum Choice: Hashable {
        case lossless
        case preset(QualityPreset)
        case custom
    }

    private var choice: Binding<Choice> {
        Binding(
            get: {
                if case .lossless = quality { return .lossless }
                if case let .preset(preset) = quality { return .preset(preset) }
                if case .customQuality = quality { return .custom }
                return .preset(.high)
            },
            set: { newValue in
                switch newValue {
                case .lossless: quality = .lossless
                case let .preset(preset): quality = .preset(preset)
                case .custom: quality = .customQuality(Double(ImageQualityMapping.percent(for: quality)))
                }
            }
        )
    }

    var body: some View {
        HStack(spacing: 6) {
            Picker("Quality", selection: choice) {
                if supportsLossless {
                    Text("Lossless").tag(Choice.lossless)
                }
                ForEach(QualityPreset.allCases, id: \.self) { preset in
                    Text(preset.title).tag(Choice.preset(preset))
                }
                Text("Custom…").tag(Choice.custom)
            }
            .pickerStyle(.menu)
            .fixedSize()
            if case let .customQuality(value) = quality {
                Slider(value: customValue(value), in: 0...100, step: 1)
                    .frame(width: 90)
                    .accessibilityLabel("Custom quality")
                    .accessibilityValue("\(Int(value.rounded()))")
                Text("\(Int(value.rounded()))")
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 22, alignment: .trailing)
                    .accessibilityHidden(true)
            }
        }
    }

    private func customValue(_ value: Double) -> Binding<Double> {
        Binding(get: { value }, set: { quality = .customQuality($0) })
    }
}
