import Foundation
import TampCore

/// One dropped image, audio or video file with its own target format, speed
/// step and quality. Unlike an archive drop, which bundles every pending item
/// into one output, each of these becomes its own independent job.
struct MediaItem: Identifiable, Equatable {
    enum Target: Equatable {
        case image(ImageFormat)
        case audio(AudioFormat)
        case video(VideoFormat)
    }

    let id = UUID()
    var source: URL
    var target: Target
    var step: SpeedStep = .normal
    var quality: MediaQuality = .lossless
    /// Ignored for video: none of the video engines have a strip-metadata
    /// option yet, only the stream-copy passthrough that already keeps it.
    var metadata: MetadataHandling = .keep

    var kind: MediaKind {
        switch target {
        case .image: .image
        case .audio: .audio
        case .video: .video
        }
    }

    var fileExtension: String {
        switch target {
        case let .image(format): format.fileExtension
        case let .audio(format): format.fileExtension
        case let .video(format): format.fileExtension
        }
    }

    /// Builds a media item for a dropped file: `remembered`'s format and
    /// quality for its kind when this build can still write that format,
    /// else `MediaPlanner`'s own default - or nil if the file isn't a
    /// recognized media source, or this build has no engine for its kind yet.
    static func make(for url: URL, registry: MediaEngineRegistry, remembered: MediaChoice = MediaChoice()) -> MediaItem? {
        switch MediaPlanner.kind(of: url) {
        case .image:
            let available = registry.availableImageFormats
            guard let format = remembered.imageFormat.flatMap({ available.contains($0) ? $0 : nil })
                ?? MediaPlanner.defaultImageFormat(for: url, available: available) else { return nil }
            let quality = remembered.imageQuality ?? (format.isAlwaysLossless ? .lossless : .preset(.high))
            return MediaItem(source: url, target: .image(format), quality: quality, metadata: remembered.imageMetadata ?? .keep)
        case .audio:
            let available = registry.availableAudioFormats
            guard let format = remembered.audioFormat.flatMap({ available.contains($0) ? $0 : nil })
                ?? MediaPlanner.defaultAudioFormat(for: url, available: available) else { return nil }
            let quality = remembered.audioQuality ?? (format.isAlwaysLossless ? .lossless : .preset(.high))
            return MediaItem(source: url, target: .audio(format), quality: quality, metadata: remembered.audioMetadata ?? .keep)
        case .video:
            let available = registry.availableVideoFormats
            guard let format = remembered.videoFormat.flatMap({ available.contains($0) ? $0 : nil })
                ?? MediaPlanner.defaultVideoFormat(available: available) else { return nil }
            return MediaItem(source: url, target: .video(format), quality: remembered.videoQuality ?? .preset(.high))
        case nil:
            return nil
        }
    }
}

enum MediaBatch {
    /// Every dropped item recognized as its own image, audio or video source,
    /// each with its own default format - or nil if any item isn't recognized
    /// media (a folder, an archive, or anything this build has no engine for
    /// yet), which falls back to the existing bundle-into-one-archive flow.
    static func items(for urls: [URL], registry: MediaEngineRegistry, remembered: MediaChoice = MediaChoice()) -> [MediaItem]? {
        guard !urls.isEmpty else { return nil }
        var result: [MediaItem] = []
        for url in urls {
            guard let item = MediaItem.make(for: url, registry: registry, remembered: remembered) else { return nil }
            result.append(item)
        }
        return result
    }
}
