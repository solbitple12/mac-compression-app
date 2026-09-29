import Foundation

/// Every video format Tamp can re-encode into. H.264 and HEVC go through
/// VideoToolbox, Apple's hardware encoder; AV1 through SVT-AV1; VP9 through
/// libvpx. All four run inside the bundled FFmpeg helper.
public enum VideoFormat: String, CaseIterable, Codable, Sendable {
    case h264
    case hevc
    case av1
    case vp9

    public var title: String {
        switch self {
        case .h264: "H.264"
        case .hevc: "HEVC"
        case .av1: "AV1"
        case .vp9: "VP9"
        }
    }

    /// File extension without the leading dot. VP9 needs WebM: MP4 can technically
    /// hold it, but playback outside Chrome is unreliable that way.
    public var fileExtension: String {
        switch self {
        case .h264, .hevc, .av1: "mp4"
        case .vp9: "webm"
        }
    }
}

/// One video's re-encode job. Audio, subtitle and metadata streams are always
/// copied, never re-encoded (see `FFmpegConversion`). `quality` is a
/// constant-quality control through `.customQuality` (0 to 100, higher is
/// better, the same scale `ImageQualityMapping` uses) or a target bitrate
/// through `.customBitrate`; `.lossless` and `.preset` fall back to sensible
/// constants per engine, the same as an image engine with no source-specific curve.
public struct VideoCompressRequest: Sendable {
    public var source: URL
    public var destination: URL
    public var format: VideoFormat
    public var step: SpeedStep
    public var quality: MediaQuality

    public init(source: URL, destination: URL, format: VideoFormat, step: SpeedStep, quality: MediaQuality = .preset(.high)) {
        self.source = source
        self.destination = destination
        self.format = format
        self.step = step
        self.quality = quality
    }
}

/// One re-encoded video's result, for the before/after preview and per-file savings.
public struct VideoCompressResult: Sendable {
    public var output: URL
    public var inputBytes: Int64
    public var outputBytes: Int64

    public var savingsFraction: Double {
        guard inputBytes > 0 else { return 0 }
        return 1 - Double(outputBytes) / Double(inputBytes)
    }
}

/// Re-encodes one video format. Every implementation writes through `SafeOutput`.
public protocol VideoEngine: Sendable {
    var format: VideoFormat { get }
    func compress(_ request: VideoCompressRequest, progress: @escaping ProgressHandler) async throws -> VideoCompressResult
}

/// A percent-quality (0 to 100, higher better, `ImageQualityMapping`'s scale)
/// to CRF (0 to 63, lower better) conversion, shared by AV1's libsvtav1 and
/// VP9's libvpx: both standardize on that wider CRF range rather than a plain
/// 0-100 knob.
public enum VideoQualityMapping {
    public static func crf(for value: MediaQuality) -> Int {
        let percent = Double(ImageQualityMapping.percent(for: value))
        return min(63, max(0, Int(((100 - percent) / 100) * 63)))
    }
}
