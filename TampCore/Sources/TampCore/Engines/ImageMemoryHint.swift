import CoreGraphics
import Foundation
import ImageIO

/// A rough peak-RAM estimate for one image job, the same purpose as
/// `VideoMemoryHint` but shaped for still images: memory scales with the
/// source's pixel dimensions (one decoded buffer in, one encoded buffer out),
/// not with frame buffering the way video's reference frames and lookahead do.
///
/// Like `VideoMemoryHint`, the numbers below are a starting point pending a
/// real per-format benchmark, not measured peaks.
public enum ImageMemoryHint {
    /// Bytes for one decoded RGBA 8-bit-per-channel buffer at this resolution,
    /// the shape every image engine here decodes into or encodes from.
    static func frameBytes(width: Int, height: Int) -> UInt64 {
        UInt64(max(0, width)) * UInt64(max(0, height)) * 4
    }

    /// Fixed overhead roughly constant regardless of resolution: the helper
    /// process itself and its own internal buffers.
    static func baseOverheadBytes(format: ImageFormat) -> UInt64 {
        switch format {
        case .jpeg: 16 * .mebibyte
        case .png: 24 * .mebibyte // oxipng tries several filter/strategy combinations at once
        case .webp: 24 * .mebibyte
        case .avif: 48 * .mebibyte // libaom's encoder keeps the deepest internal state here
        case .heic: 32 * .mebibyte
        case .jxl: 40 * .mebibyte
        }
    }

    /// One decoded source buffer plus one encoded destination buffer, plus
    /// the format's own fixed overhead.
    public static func peakMemoryBytes(format: ImageFormat, pixelWidth: Int, pixelHeight: Int) -> UInt64 {
        2 * frameBytes(width: pixelWidth, height: pixelHeight) + baseOverheadBytes(format: format)
    }

    /// Reads `source`'s pixel dimensions with ImageIO (no full decode) and
    /// estimates from those.
    public static func peakMemoryBytes(source: URL, format: ImageFormat) throws -> UInt64 {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else {
            throw TampError.other("Tamp couldn't read that image's dimensions")
        }
        return peakMemoryBytes(format: format, pixelWidth: width, pixelHeight: height)
    }
}
