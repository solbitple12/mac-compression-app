import AudioToolbox
import AVFoundation
import Foundation

/// AAC and ALAC encoding through Apple's own AVFoundation, in-process: no bundled
/// helper, since every Mac Tamp runs on already has these codecs (AAC through
/// AudioToolbox's `aac_at`, the best AAC available without non-free code; ALAC is
/// Apple's own lossless format). Both write into an M4A container.
enum AppleAudioConversion {
    /// Reads `source` as PCM and writes it to `destination` in the format `settings`
    /// describes, converting each buffer as it goes. Runs on its own thread via
    /// `BlockingWork`, since AVFoundation's file I/O here is synchronous.
    static func write(from source: URL, to destination: URL, settings: [String: Any]) async throws {
        try await BlockingWork.run { _ in
            let input = try AVAudioFile(forReading: source)
            let output = try AVAudioFile(forWriting: destination, settings: settings)
            guard let converter = AVAudioConverter(from: input.processingFormat, to: output.processingFormat) else {
                throw TampError.other("Tamp couldn't set up that audio conversion")
            }
            let frameCapacity: AVAudioFrameCount = 4096
            var reachedInputEnd = false

            // The input block below may be called several times per convert(), since
            // an encoder (AAC's 1024-sample packets, say) rarely lines up with
            // `frameCapacity`; it pulls a fresh buffer from the file each time it's
            // asked, until the file itself runs out. The outer loop then keeps
            // calling convert() until the converter, not just the file, is done.
            while true {
                guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: output.processingFormat, frameCapacity: frameCapacity) else {
                    throw TampError.other("Tamp couldn't allocate an audio buffer")
                }
                var conversionError: NSError?
                let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
                    if reachedInputEnd {
                        inputStatus.pointee = .endOfStream
                        return nil
                    }
                    guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: frameCapacity) else {
                        inputStatus.pointee = .noDataNow
                        return nil
                    }
                    do {
                        try input.read(into: inputBuffer, frameCount: frameCapacity)
                    } catch {
                        inputStatus.pointee = .noDataNow
                        return nil
                    }
                    if inputBuffer.frameLength == 0 {
                        reachedInputEnd = true
                        inputStatus.pointee = .endOfStream
                        return nil
                    }
                    inputStatus.pointee = .haveData
                    return inputBuffer
                }
                if status == .error {
                    throw TampError.other(conversionError?.localizedDescription ?? "Tamp couldn't convert that audio")
                }
                if outputBuffer.frameLength > 0 {
                    try output.write(from: outputBuffer)
                }
                if status == .endOfStream { break }
            }
        }
    }

    /// A preset-to-bitrate mapping for AAC, in bits per second. WavPack and FLAC
    /// have no such control (always lossless); ALAC is lossless too, so this is
    /// AAC-only.
    static func aacBitsPerSecond(for value: MediaQuality) -> Int {
        switch value {
        case .lossless: return 256_000
        case let .preset(preset):
            switch preset {
            case .low: return 96_000
            case .medium: return 128_000
            case .high: return 192_000
            case .veryHigh: return 256_000
            }
        case let .customBitrate(kbps): return max(32, kbps) * 1000
        case let .customQuality(percent):
            let clamped: Double = min(100, max(0, percent))
            let value: Double = 32_000 + (256_000 - 32_000) * (clamped / 100)
            return Int(value)
        }
    }

    /// Shared by `AACEngine` and `ALACEngine`: both just read PCM and write it back
    /// through `write(from:to:settings:)` with a different `formatID`.
    static func compress(
        _ request: AudioCompressRequest, formatID: AudioFormatID, extraSettings: [String: Any] = [:],
        progress: @escaping ProgressHandler
    ) async throws -> AudioCompressResult {
        guard FileManager.default.fileExists(atPath: request.source.path) else {
            throw TampError.fileNotFound(path: request.source.path)
        }
        let inputBytes = fileSize(request.source)
        let sourceFormat = try AVAudioFile(forReading: request.source).fileFormat
        var settings: [String: Any] = [
            AVFormatIDKey: formatID,
            AVSampleRateKey: sourceFormat.sampleRate,
            AVNumberOfChannelsKey: sourceFormat.channelCount,
        ]
        settings.merge(extraSettings) { _, new in new }

        let output = try await SafeOutput.write(to: request.destination, fileExtension: "m4a") { temporary in
            progress(0)
            try await write(from: request.source, to: temporary, settings: settings)
            guard FileManager.default.fileExists(atPath: temporary.path) else {
                throw TampError.fileNotFound(path: request.source.path)
            }
            progress(1)
        }
        return AudioCompressResult(output: output, inputBytes: inputBytes, outputBytes: fileSize(output))
    }

    static func fileSize(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }
}

/// AAC encoding, lossy, through AVFoundation's `aac_at` encoder.
public struct AACEngine: AudioEngine {
    public init() {}

    public var format: AudioFormat { .aac }

    public func compress(_ request: AudioCompressRequest, progress: @escaping ProgressHandler) async throws -> AudioCompressResult {
        try await AppleAudioConversion.compress(
            request, formatID: kAudioFormatMPEG4AAC,
            extraSettings: [AVEncoderBitRateKey: AppleAudioConversion.aacBitsPerSecond(for: request.quality)],
            progress: progress
        )
    }
}

/// Apple Lossless encoding through AVFoundation. Always lossless, so
/// `request.quality` is ignored.
public struct ALACEngine: AudioEngine {
    public init() {}

    public var format: AudioFormat { .alac }

    public func compress(_ request: AudioCompressRequest, progress: @escaping ProgressHandler) async throws -> AudioCompressResult {
        try await AppleAudioConversion.compress(request, formatID: kAudioFormatAppleLossless, progress: progress)
    }
}
