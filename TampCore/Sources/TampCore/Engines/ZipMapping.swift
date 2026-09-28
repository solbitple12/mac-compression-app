import Foundation

/// ZIP settings: 7zz writes every method except Zstandard, which minizip writes.
public struct ZipParameters: Equatable, Sendable {
    public enum Writer: Sendable {
        case sevenZip
        case minizip
    }

    public var method: CompressionMethod
    /// 7-Zip's own level (-mx) for its methods, zstd's level for Zstandard. 0 stores.
    public var level: Int
    public var threads: Int

    public init(method: CompressionMethod = .deflate, level: Int, threads: Int) {
        self.method = method
        self.level = level
        self.threads = threads
    }

    public var writer: Writer {
        method == .zstd && level > 0 ? .minizip : .sevenZip
    }

    /// Store uses the Copy method whatever method was chosen.
    public var sevenZipArguments: [String] {
        let name = level == 0 ? "Copy" : method.sevenZipName ?? "Deflate"
        return ["-tzip", "-mm=\(name)", "-mx=\(level)", "-mmt=\(threads)"]
    }

    /// minizip reads "-19" as level 19.
    public var minizipArguments: [String] {
        ["-t", "-\(level)"]
    }
}

public struct ZipMapping: SpeedStepMapping {
    public init() {}

    public var format: ArchiveFormat { .zip }
    public var capabilities: EngineCapabilities { [.encryption, .volumes, .multithreading] }

    public func parameters(for step: SpeedStep, options: ArchiveOptions) -> ZipParameters {
        let method = format.resolvedMethod(options.method) ?? .deflate
        // 7-Zip's Deflate runs extra passes at 7 and 9. Zstandard skips its
        // slowest levels, since minizip compresses each file on one thread.
        let levels = method == .zstd ? [0, 1, 3, 9, 15, 19] : [0, 1, 3, 5, 7, 9]
        return ZipParameters(method: method, level: levels[step.rawValue], threads: options.threads)
    }

    public func hint(for step: SpeedStep, options: ArchiveOptions) -> StepHint {
        let parameters = parameters(for: step, options: options)
        var notes: [String] = []
        if step != .store {
            notes.append(parameters.method == .deflate
                ? "Opens on any computer, including Windows"
                : "Windows Explorer and macOS Archive Utility may not open this; the recipient needs 7-Zip or similar")
        }
        return StepHint(
            step: step,
            summary: step.summary,
            peakMemoryBytes: Self.memory(for: parameters),
            outputExtension: format.fileExtension,
            notes: notes
        )
    }

    /// Placeholders until the Phase 2a benchmark measures real peaks.
    static func memory(for parameters: ZipParameters) -> UInt64 {
        let threads = UInt64(max(1, parameters.threads))
        guard parameters.level > 0 else { return 32 * .mebibyte + 4 * .mebibyte * threads }
        switch parameters.method {
        case .zstd:
            // One file at a time on one thread; zstd's tables grow with the level.
            let mebibytes: UInt64 = switch parameters.level {
            case ...3: 16
            case 4...9: 48
            case 10...15: 96
            default: 200
            }
            return 16 * .mebibyte + mebibytes * .mebibyte
        case .lzma:
            // 7-Zip compresses ZIP entries in parallel, each with its own LZMA encoder,
            // and runs fewer at once when they would pass its memory limit.
            let perEncoder = SevenZipMapping.lzmaEncoderMemory(level: parameters.level)
            let limit = ProcessInfo.processInfo.physicalMemory / 2
            return 32 * .mebibyte + max(1, min(threads, limit / perEncoder)) * perEncoder
        case .bzip2:
            return 32 * .mebibyte + threads * 10 * .mebibyte
        default:
            // Deflate keeps only a 32 KB window, so memory is buffers per thread.
            return 32 * .mebibyte + threads * 16 * .mebibyte
        }
    }
}
