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

    /// Builds a media item for a dropped file, with a sensible default target
    /// format from this build's available engines - or nil if the file isn't
    /// a recognized media source, or this build has no engine for its kind yet.
    static func make(for url: URL, registry: MediaEngineRegistry) -> MediaItem? {
        switch MediaPlanner.kind(of: url) {
        case .image:
            guard let format = MediaPlanner.defaultImageFormat(for: url, available: registry.availableImageFormats) else { return nil }
            return MediaItem(source: url, target: .image(format), quality: format.isAlwaysLossless ? .lossless : .preset(.high))
        case .audio:
            guard let format = MediaPlanner.defaultAudioFormat(for: url, available: registry.availableAudioFormats) else { return nil }
            return MediaItem(source: url, target: .audio(format), quality: format.isAlwaysLossless ? .lossless : .preset(.high))
        case .video:
            guard let format = MediaPlanner.defaultVideoFormat(available: registry.availableVideoFormats) else { return nil }
            return MediaItem(source: url, target: .video(format), quality: .preset(.high))
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
    static func items(for urls: [URL], registry: MediaEngineRegistry) -> [MediaItem]? {
        guard !urls.isEmpty else { return nil }
        var result: [MediaItem] = []
        for url in urls {
            guard let item = MediaItem.make(for: url, registry: registry) else { return nil }
            result.append(item)
        }
        return result
    }
}
