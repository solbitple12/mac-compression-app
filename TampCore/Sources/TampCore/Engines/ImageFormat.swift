import Foundation

/// Every image format Tamp can re-encode into. Engines arrive phase by phase;
/// `ImageFormat.allCases` is the full list the batch picker is built from.
public enum ImageFormat: String, CaseIterable, Codable, Sendable {
    case jpeg
    case png
    case webp
    case avif
    case heic
    case jxl

    public var title: String {
        switch self {
        case .jpeg: "JPEG"
        case .png: "PNG"
        case .webp: "WebP"
        case .avif: "AVIF"
        case .heic: "HEIC"
        case .jxl: "JPEG XL"
        }
    }

    /// File extension without the leading dot.
    public var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .png: "png"
        case .webp: "webp"
        case .avif: "avif"
        case .heic: "heic"
        case .jxl: "jxl"
        }
    }

    /// Whether this format can hold a lossless encode, so the batch panel offers
    /// the choice. JPEG re-encodes only lossy, except through
    /// `losslessJPEGToJXL`, which is JXL's lossless path, not this one.
    public var supportsLossless: Bool {
        switch self {
        case .png, .webp, .jxl: true
        default: false
        }
    }

    /// PNG optimization (oxipng) never loses information: there's no quality
    /// control to show, only the speed step.
    public var isAlwaysLossless: Bool {
        self == .png
    }
}

/// One image's re-encode job. `quality` is ignored for `.png`, which is always
/// lossless, and for `losslessJPEGToJXL`.
public struct ImageCompressRequest: Sendable {
    public var source: URL
    public var destination: URL
    public var format: ImageFormat
    public var step: SpeedStep
    public var quality: MediaQuality
    /// Rewraps a JPEG into JPEG XL losslessly, reconstructable back to the exact
    /// original bytes. Only meaningful when `format` is `.jxl` and `source` is a JPEG.
    public var losslessJPEGToJXL: Bool
    public var metadata: MetadataHandling

    public init(
        source: URL,
        destination: URL,
        format: ImageFormat,
        step: SpeedStep,
        quality: MediaQuality = .lossless,
        losslessJPEGToJXL: Bool = false,
        metadata: MetadataHandling = .keep
    ) {
        self.source = source
        self.destination = destination
        self.format = format
        self.step = step
        self.quality = quality
        self.losslessJPEGToJXL = losslessJPEGToJXL
        self.metadata = metadata
    }
}

/// One re-encoded image's result, for the before/after preview and per-file savings.
public struct ImageCompressResult: Sendable {
    public var output: URL
    public var inputBytes: Int64
    public var outputBytes: Int64

    public var savingsFraction: Double {
        guard inputBytes > 0 else { return 0 }
        return 1 - Double(outputBytes) / Double(inputBytes)
    }
}

/// Re-encodes one image format. Every implementation writes through `SafeOutput`.
public protocol ImageEngine: Sendable {
    var format: ImageFormat { get }
    func compress(_ request: ImageCompressRequest, progress: @escaping ProgressHandler) async throws -> ImageCompressResult
}
