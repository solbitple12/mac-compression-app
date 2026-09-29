import Foundation

/// The image, audio and video engines this build of Tamp has. Formats arrive
/// one engine at a time through Phase 3 and 4; the batch panel lists only
/// `availableImageFormats`, `availableAudioFormats` and `availableVideoFormats`.
public struct MediaEngineRegistry: Sendable {
    public let imageEngines: [any ImageEngine]
    public let audioEngines: [any AudioEngine]
    public let videoEngines: [any VideoEngine]

    public init(imageEngines: [any ImageEngine] = [], audioEngines: [any AudioEngine] = [], videoEngines: [any VideoEngine] = []) {
        self.imageEngines = imageEngines
        self.audioEngines = audioEngines
        self.videoEngines = videoEngines
    }

    /// More engines arrive one at a time through Phase 3 and Phase 4.
    public static func standard(helpers: HelperLocator = .standard) -> MediaEngineRegistry {
        MediaEngineRegistry(
            imageEngines: [
                OxipngEngine(helpers: helpers), MozjpegEngine(helpers: helpers), WebPEngine(helpers: helpers), HEICEngine(),
                JxlEngine(helpers: helpers), AvifEngine(helpers: helpers),
            ],
            audioEngines: [
                FlacEngine(helpers: helpers), WavPackEngine(helpers: helpers), AACEngine(), ALACEngine(),
                LameEngine(helpers: helpers), OpusEngine(helpers: helpers),
            ],
            videoEngines: [
                H264Engine(helpers: helpers), HEVCEngine(helpers: helpers), AV1Engine(helpers: helpers), VP9Engine(helpers: helpers),
            ]
        )
    }

    public var availableImageFormats: [ImageFormat] {
        ImageFormat.allCases.filter { format in imageEngines.contains { $0.format == format } }
    }

    public var availableAudioFormats: [AudioFormat] {
        AudioFormat.allCases.filter { format in audioEngines.contains { $0.format == format } }
    }

    public var availableVideoFormats: [VideoFormat] {
        VideoFormat.allCases.filter { format in videoEngines.contains { $0.format == format } }
    }

    public func imageEngine(for format: ImageFormat) -> (any ImageEngine)? {
        imageEngines.first { $0.format == format }
    }

    public func audioEngine(for format: AudioFormat) -> (any AudioEngine)? {
        audioEngines.first { $0.format == format }
    }

    public func videoEngine(for format: VideoFormat) -> (any VideoEngine)? {
        videoEngines.first { $0.format == format }
    }

    /// The image format a file's extension and UTType suggest it holds, for
    /// deciding whether a dropped file belongs in an image batch.
    public static func imageFormat(of url: URL) -> ImageFormat? {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": .jpeg
        case "png": .png
        case "webp": .webp
        case "avif": .avif
        case "heic", "heif": .heic
        case "jxl": .jxl
        default: nil
        }
    }

    /// The audio format a file's extension suggests it holds.
    public static func audioFormat(of url: URL) -> AudioFormat? {
        switch url.pathExtension.lowercased() {
        case "flac": .flac
        case "m4a", "alac": .alac
        case "wv", "wavpack": .wavpack
        case "aac": .aac
        case "opus": .opus
        case "mp3": .mp3
        case "wav", "aiff", "aif": nil // source-only formats, not re-encode targets
        default: nil
        }
    }

    /// The video format a file's extension suggests it holds. Only WebM maps
    /// to one: MP4, MOV and MKV can each hold H.264, HEVC or AV1, so the
    /// extension alone can't say which codec a re-encode of one would target.
    public static func videoFormat(of url: URL) -> VideoFormat? {
        switch url.pathExtension.lowercased() {
        case "webm": .vp9
        default: nil
        }
    }
}
