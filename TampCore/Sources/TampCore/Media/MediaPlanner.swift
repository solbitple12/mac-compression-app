import Foundation

/// What kind of media a dropped file is, for the batch panel's per-item row:
/// unlike an archive drop, which bundles everything into one output, each
/// recognized media file gets its own format and quality controls and becomes
/// its own independent job.
public enum MediaKind: Equatable, Sendable {
    case image
    case audio
    case video
}

public enum MediaPlanner {
    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "avif", "heic", "heif", "jxl"]
    /// WAV and AIFF are re-encode sources only (see `MediaEngineRegistry.audioFormat(of:)`),
    /// but still recognized here so a dropped WAV gets an audio row, not an archive one.
    private static let audioExtensions: Set<String> = ["flac", "m4a", "alac", "wv", "wavpack", "aac", "opus", "mp3", "wav", "aiff", "aif"]
    /// MP4, MOV and MKV can each hold several codecs (see `MediaEngineRegistry.videoFormat(of:)`),
    /// so they're recognized as video sources without implying a current codec.
    private static let videoExtensions: Set<String> = ["mp4", "mov", "mkv", "webm", "m4v"]

    /// The kind a dropped file's extension suggests, or nil if it isn't a
    /// recognized media source (an archive, a folder, or something else),
    /// which should fall back to `ArchivePlanner`.
    public static func kind(of url: URL) -> MediaKind? {
        let ext = url.pathExtension.lowercased()
        if imageExtensions.contains(ext) { return .image }
        if audioExtensions.contains(ext) { return .audio }
        if videoExtensions.contains(ext) { return .video }
        return nil
    }

    /// The target format to preselect for a dropped image: the format it's
    /// already in, when this build can write it, else the first available format.
    public static func defaultImageFormat(for url: URL, available: [ImageFormat]) -> ImageFormat? {
        guard !available.isEmpty else { return nil }
        if let current = MediaEngineRegistry.imageFormat(of: url), available.contains(current) { return current }
        return available.first
    }

    /// The target format to preselect for a dropped audio file: the format
    /// it's already in when that's a re-encode target this build can write,
    /// else FLAC for a source-only file like WAV or AIFF (or the first
    /// available format, if this build can't write FLAC).
    public static func defaultAudioFormat(for url: URL, available: [AudioFormat]) -> AudioFormat? {
        guard !available.isEmpty else { return nil }
        if let current = MediaEngineRegistry.audioFormat(of: url), available.contains(current) { return current }
        return available.contains(.flac) ? .flac : available.first
    }

    /// The target format to preselect for a dropped video: H.264, the widest-
    /// compatibility choice, when this build can write it, else the first available format.
    public static func defaultVideoFormat(available: [VideoFormat]) -> VideoFormat? {
        available.contains(.h264) ? .h264 : available.first
    }

    /// Where a re-encoded media file goes: beside the source, same base name,
    /// new extension - "Name N.ext" if that name is taken.
    public static func destination(for source: URL, fileExtension: String, fileManager: FileManager = .default) -> URL {
        let base = source.deletingPathExtension().lastPathComponent
        let proposed = source.deletingLastPathComponent().appendingPathComponent("\(base).\(fileExtension)")
        return SafeOutput.availableURL(for: proposed, fileExtension: fileExtension, fileManager: fileManager)
    }
}
