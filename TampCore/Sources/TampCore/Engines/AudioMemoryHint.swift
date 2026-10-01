import Foundation

/// A rough peak-RAM estimate for one audio job. Unlike video, none of Tamp's
/// audio engines buffer more than a small, roughly constant window of PCM at
/// once, so memory here barely depends on the source's length or sample rate
/// - it's dominated by each format's own fixed overhead.
///
/// Like `VideoMemoryHint` and `ImageMemoryHint`, the numbers below are a
/// starting point pending a real per-format benchmark, not measured peaks.
public enum AudioMemoryHint {
    /// Fixed overhead: the helper process (or, for AAC and ALAC, AVFoundation's
    /// in-process encoder) and its own encode/decode buffers.
    static func baseOverheadBytes(format: AudioFormat) -> UInt64 {
        switch format {
        case .flac: 24 * .mebibyte
        case .alac: 16 * .mebibyte
        case .wavpack: 24 * .mebibyte
        case .aac: 16 * .mebibyte
        case .opus: 20 * .mebibyte
        case .mp3: 20 * .mebibyte
        }
    }

    public static func peakMemoryBytes(format: AudioFormat) -> UInt64 {
        baseOverheadBytes(format: format)
    }
}
