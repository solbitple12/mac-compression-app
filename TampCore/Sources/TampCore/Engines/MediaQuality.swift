import Foundation

/// How lossy an image or audio re-encode is allowed to be. Every media engine
/// reads only the case it understands: lossless formats ignore `.preset` and
/// `.custom`, and lossy-only formats treat `.lossless` as their highest preset.
public enum MediaQuality: Equatable, Codable, Sendable {
    /// No information lost: PNG, FLAC, ALAC, and JPEG XL or WebP in lossless mode.
    case lossless
    /// A plain-language step most people pick from; each engine maps it to its
    /// own quality number or bitrate.
    case preset(QualityPreset)
    /// The Advanced panel's constant-quality control (CRF, "-q"), 0 to 100 where
    /// higher is better; overrides the preset.
    case customQuality(Double)
    /// The Advanced panel's target bitrate in kbps; overrides the preset.
    case customBitrate(Int)
}

/// A plain-language quality choice, shown instead of a raw number.
public enum QualityPreset: String, CaseIterable, Codable, Sendable {
    case low
    case medium
    case high
    case veryHigh

    public var title: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .veryHigh: "Very high"
        }
    }
}

/// What happens to a file's embedded metadata on re-encode. Metadata stays by
/// default; the two stripping modes are separate toggles in the batch panel.
public enum MetadataHandling: String, CaseIterable, Codable, Sendable {
    case keep
    /// Removes only GPS location tags.
    case stripLocation
    /// Removes all EXIF (and, for audio, ID3/Vorbis comment) metadata.
    case stripAll
}
