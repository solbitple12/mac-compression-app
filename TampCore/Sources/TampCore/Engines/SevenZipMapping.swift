import Foundation

/// 7Z settings for the bundled 7zz helper. Archives are solid, as 7-Zip makes them by default.
public struct SevenZipParameters: Equatable, Sendable {
    public var method: CompressionMethod
    /// 7-Zip's level (-mx). 0 stores.
    public var level: Int
    public var threads: Int

    public init(method: CompressionMethod = .lzma2, level: Int, threads: Int) {
        self.method = method
        self.level = level
        self.threads = threads
    }

    public var sevenZipArguments: [String] {
        let name = level == 0 ? "Copy" : method.sevenZipName ?? "LZMA2"
        return ["-t7z", "-m0=\(name)", "-mx=\(level)", "-mmt=\(threads)"]
    }
}

public struct SevenZipMapping: SpeedStepMapping {
    public init() {}

    public var format: ArchiveFormat { .sevenZip }
    public var capabilities: EngineCapabilities { [.encryption, .volumes, .solid, .multithreading] }

    public func parameters(for step: SpeedStep, options: ArchiveOptions) -> SevenZipParameters {
        let levels = [0, 1, 3, 5, 7, 9]
        return SevenZipParameters(
            method: format.resolvedMethod(options.method) ?? .lzma2,
            level: levels[step.rawValue],
            threads: options.threads
        )
    }

    public func hint(for step: SpeedStep, options: ArchiveOptions) -> StepHint {
        let parameters = parameters(for: step, options: options)
        var notes: [String] = []
        if step != .store {
            switch parameters.method {
            case .lzma2: break
            case .ppmd: notes.append("PPMd suits text and is as slow to decompress as to compress")
            default: notes.append("\(parameters.method.title) is for compatibility with older tools; LZMA2 is smaller and faster")
            }
        }
        return StepHint(
            step: step,
            summary: step.summary,
            peakMemoryBytes: Self.memory(for: parameters),
            outputExtension: format.fileExtension,
            notes: notes
        )
    }

    /// Placeholders from 7-Zip's documented settings until the Phase 2a benchmark
    /// measures real peaks.
    static func memory(for parameters: SevenZipParameters) -> UInt64 {
        let buffers = 32 * UInt64.mebibyte
        let threads = UInt64(max(1, parameters.threads))
        guard parameters.level > 0 else { return buffers }
        switch parameters.method {
        case .lzma2:
            // Levels 5 and up use the BT4 match finder, which takes two threads per
            // encoder; each encoder beyond the first also holds a block of 4 × dictionary.
            // 7-Zip lowers the thread count when that would pass the memory limit.
            let dictionary = dictionarySize(level: parameters.level)
            let encoders = parameters.level >= 5 ? max(1, threads / 2) : threads
            let perEncoder = lzmaEncoderMemory(level: parameters.level) + (encoders > 1 ? 4 * dictionary : 0)
            let limit = ProcessInfo.processInfo.physicalMemory / 2
            let used = max(1, min(encoders, limit / max(1, perEncoder)))
            return buffers + used * perEncoder
        case .lzma:
            return buffers + lzmaEncoderMemory(level: parameters.level)
        case .ppmd:
            let mebibytes: UInt64 = switch parameters.level {
            case 9...: 192
            case 7...8: 64
            case 5...6: 16
            default: 4
            }
            return buffers + mebibytes * .mebibyte
        case .bzip2:
            return buffers + threads * 10 * .mebibyte
        default:
            return buffers + threads * 16 * .mebibyte
        }
    }

    /// The LZMA dictionary 7zz 26 uses at each level (measured). 7-Zip shrinks it
    /// to the input's size, which the Phase 2c estimator takes into account.
    static func dictionarySize(level: Int) -> UInt64 {
        switch level {
        case ...2: 256 * 1024
        case 3...4: 4 * .mebibyte
        case 5...6: 32 * .mebibyte
        case 7...8: 128 * .mebibyte
        default: 256 * .mebibyte
        }
    }

    /// One LZMA encoder: about 7.5 × dictionary with the HC4 match finder
    /// (levels 1 to 4), 11.5 × with BT4.
    static func lzmaEncoderMemory(level: Int) -> UInt64 {
        let dictionary = dictionarySize(level: level)
        return (level >= 5 ? dictionary * 23 / 2 : dictionary * 15 / 2) + 4 * .mebibyte
    }
}
