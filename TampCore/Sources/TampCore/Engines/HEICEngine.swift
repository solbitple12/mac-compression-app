import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// HEIC re-encoding through Apple's own ImageIO, in-process: no bundled helper,
/// since every Mac Tamp runs on already has the HEVC image codec. Lossy only —
/// ImageIO has no lossless HEIC mode to expose, so `losslessJPEGToJXL`-style
/// exactness isn't offered here and `ImageFormat.supportsLossless` leaves HEIC out.
public struct HEICEngine: ImageEngine {
    public init() {}

    public var format: ImageFormat { .heic }

    public func compress(_ request: ImageCompressRequest, progress: @escaping ProgressHandler) async throws -> ImageCompressResult {
        guard FileManager.default.fileExists(atPath: request.source.path) else {
            throw TampError.fileNotFound(path: request.source.path)
        }
        let inputBytes = Self.fileSize(request.source)
        let quality = ImageQualityMapping.percent(for: request.quality)
        let metadata = request.metadata

        let output = try await SafeOutput.write(to: request.destination, fileExtension: format.fileExtension) { temporary in
            progress(0)
            try await BlockingWork.run { _ in
                try Self.write(from: request.source, to: temporary, qualityPercent: quality, metadata: metadata)
            }
            guard FileManager.default.fileExists(atPath: temporary.path) else {
                throw TampError.fileNotFound(path: request.source.path)
            }
            progress(1)
        }
        return ImageCompressResult(output: output, inputBytes: inputBytes, outputBytes: Self.fileSize(output))
    }

    static func write(from source: URL, to destination: URL, qualityPercent: Int, metadata: MetadataHandling) throws {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw TampError.other("\u{201C}\(source.lastPathComponent)\u{201D} isn't an image Tamp can read")
        }
        guard let writer = CGImageDestinationCreateWithURL(destination as CFURL, UTType.heic.identifier as CFString, 1, nil) else {
            throw TampError.other("Tamp couldn't create a HEIC file")
        }
        var options = Self.strippedProperties(of: imageSource, handling: metadata)
        options[kCGImageDestinationLossyCompressionQuality] = Double(qualityPercent) / 100
        CGImageDestinationAddImage(writer, image, options as CFDictionary)
        guard CGImageDestinationFinalize(writer) else {
            throw TampError.other("Tamp couldn't write \u{201C}\(destination.lastPathComponent)\u{201D}")
        }
    }

    /// The source's own image properties, with the metadata dictionaries
    /// `handling` asks to drop removed. Unlike the command-line tools the other
    /// image engines shell out to, ImageIO exposes GPS separately from the rest of
    /// EXIF, so "strip location" here really does keep everything else.
    static func strippedProperties(of source: CGImageSource, handling: MetadataHandling) -> [CFString: Any] {
        var properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        switch handling {
        case .keep:
            break
        case .stripLocation:
            properties[kCGImagePropertyGPSDictionary] = nil
        case .stripAll:
            for key in [
                kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary,
                kCGImagePropertyIPTCDictionary, kCGImagePropertyTIFFDictionary,
            ] {
                properties[key] = nil
            }
        }
        return properties
    }

    private static func fileSize(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }
}
