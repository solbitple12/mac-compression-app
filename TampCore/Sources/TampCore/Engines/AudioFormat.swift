import Foundation

/// Every audio format Tamp can re-encode into. Engines arrive phase by phase;
/// `AudioFormat.allCases` is the full list the batch picker is built from.
public enum AudioFormat: String, CaseIterable, Codable, Sendable {
    case flac
    case alac
    case wavpack
    case aac
    case opus
    case mp3

    public var title: String {
        switch self {
        case .flac: "FLAC"
        case .alac: "Apple Lossless"
        case .wavpack: "WavPack"
        case .aac: "AAC"
        case .opus: "Opus"
        case .mp3: "MP3"
        }
    }

    /// File extension without the leading dot. ALAC is written in an M4A container.
    public var fileExtension: String {
        switch self {
        case .flac: "flac"
        case .alac: "m4a"
        case .wavpack: "wv"
        case .aac: "m4a"
        case .opus: "opus"
        case .mp3: "mp3"
        }
    }

    /// Always lossless, no quality control: FLAC, Apple Lossless, WavPack.
    public var isAlwaysLossless: Bool {
        switch self {
        case .flac, .alac, .wavpack: true
        default: false
        }
    }
}

/// One audio file's re-encode job. `quality` is ignored for a lossless format.
public struct AudioCompressRequest: Sendable {
    public var source: URL
    public var destination: URL
    public var format: AudioFormat
    public var step: SpeedStep
    public var quality: MediaQuality
    public var metadata: MetadataHandling

    public init(
        source: URL,
        destination: URL,
        format: AudioFormat,
        step: SpeedStep,
        quality: MediaQuality = .lossless,
        metadata: MetadataHandling = .keep
    ) {
        self.source = source
        self.destination = destination
        self.format = format
        self.step = step
        self.quality = quality
        self.metadata = metadata
    }
}

/// One re-encoded audio file's result, for per-file savings in the batch view.
public struct AudioCompressResult: Sendable {
    public var output: URL
    public var inputBytes: Int64
    public var outputBytes: Int64

    public var savingsFraction: Double {
        guard inputBytes > 0 else { return 0 }
        return 1 - Double(outputBytes) / Double(inputBytes)
    }
}

/// Re-encodes one audio format. Every implementation writes through `SafeOutput`.
public protocol AudioEngine: Sendable {
    var format: AudioFormat { get }
    func compress(_ request: AudioCompressRequest, progress: @escaping ProgressHandler) async throws -> AudioCompressResult
}
