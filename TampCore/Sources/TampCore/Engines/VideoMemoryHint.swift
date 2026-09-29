import AVFoundation
import Foundation

/// A rough peak-RAM estimate for one video job, the same purpose as an archive
/// engine's `SpeedStepMapping.hint(for:options:)` but shaped for video: memory
/// here scales with the source's resolution and how many frames a format
/// buffers at once (reference frames, encoder lookahead), not with the input's
/// byte count the way an archive's dictionary or window does, and Tamp's video
/// jobs don't expose a thread count to fold in yet.
///
/// Like every other new speed-step mapping in Phase 3 and 4 (see
/// `AvifMapping.speed`, `AV1Mapping.preset`, `VP9Mapping.cpuUsed`), the numbers
/// below are a starting point pending a real per-format, per-step benchmark,
/// not measured peaks.
public enum VideoMemoryHint {
    /// Bytes for one 4:2:0 8-bit frame at this resolution: 1 byte per luma
    /// sample plus 0.5 combined for chroma, sampled at half resolution each way.
    static func frameBytes(width: Int, height: Int) -> UInt64 {
        UInt64(max(0, width)) * UInt64(max(0, height)) * 3 / 2
    }

    /// Every format decodes the source while it encodes the output (ffmpeg
    /// demuxes and decodes the input stream in parallel with encoding), which
    /// costs a handful of frame buffers regardless of the target format or step.
    static let sourceDecodeFrames: UInt64 = 4

    /// How many frames' worth of buffering the target format keeps at once,
    /// on top of `sourceDecodeFrames`: reference frames plus encoder lookahead.
    static func bufferedFrames(format: VideoFormat, step: SpeedStep) -> UInt64 {
        switch format {
        case .h264, .hevc:
            // VideoToolbox's hardware pipeline: a handful of reference and
            // B-frame reorder buffers, roughly constant regardless of step -
            // the step only changes bitrate or quality, not the pipeline depth.
            return 8
        case .av1:
            // SVT-AV1's lookahead deepens at slower presets (see AV1Mapping.preset).
            switch step {
            case .store: return 6
            case .fastest: return 10
            case .fast: return 16
            case .normal: return 24
            case .good: return 32
            case .best: return 48
            }
        case .vp9:
            // libvpx's row-multithreaded lookahead, shallower than SVT-AV1's at
            // a comparable step since VP9 has no long-range lookahead mode.
            switch step {
            case .store: return 4
            case .fastest: return 6
            case .fast, .normal: return 10
            case .good: return 14
            case .best: return 20
            }
        }
    }

    /// Fixed overhead roughly constant regardless of resolution: the ffmpeg
    /// process itself, its demux/mux buffers, and, for AV1 and VP9, the
    /// encoder library's own fixed tables.
    static func baseOverheadBytes(format: VideoFormat) -> UInt64 {
        switch format {
        case .h264, .hevc: 64 * .mebibyte // VideoToolbox's own session overhead
        case .av1: 96 * .mebibyte // SVT-AV1's fixed tables are the largest of the three
        case .vp9: 48 * .mebibyte
        }
    }

    /// Buffered frames (source decode plus the target format's own reference
    /// and lookahead frames) times one frame's size, plus fixed overhead.
    public static func peakMemoryBytes(format: VideoFormat, step: SpeedStep, pixelWidth: Int, pixelHeight: Int) -> UInt64 {
        let frame = frameBytes(width: pixelWidth, height: pixelHeight)
        let frames = bufferedFrames(format: format, step: step) + sourceDecodeFrames
        return frame * frames + baseOverheadBytes(format: format)
    }

    /// Reads `source`'s pixel dimensions with AVFoundation and estimates from
    /// those, the way `VideoPreview` reads its duration.
    public static func peakMemoryBytes(source: URL, format: VideoFormat, step: SpeedStep) async throws -> UInt64 {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw TampError.other("Tamp couldn't read that video's dimensions")
        }
        let size = try await track.load(.naturalSize)
        return peakMemoryBytes(format: format, step: step, pixelWidth: Int(abs(size.width)), pixelHeight: Int(abs(size.height)))
    }
}
