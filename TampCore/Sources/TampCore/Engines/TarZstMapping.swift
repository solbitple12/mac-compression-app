/// zstd settings, expressed so they map to either libzstd parameters or the zstd CLI.
public struct ZstdParameters: Equatable, Sendable {
    /// The largest window any stock zstd decompresses without extra flags (128 MiB).
    public static let maxCompatibleWindowLog = 27

    public var level: Int
    /// Long-distance matching window as log2 bytes, or nil when off.
    public var longWindowLog: Int?
    public var threads: Int

    /// Levels above 19 need --ultra.
    public var isUltra: Bool { level > 19 }

    public var cliArguments: [String] {
        var arguments: [String] = []
        if isUltra { arguments.append("--ultra") }
        arguments.append("-\(level)")
        if let longWindowLog { arguments.append("--long=\(longWindowLog)") }
        arguments.append("-T\(threads)")
        return arguments
    }
}

public enum TarZstParameters: Equatable, Sendable {
    /// Store writes an uncompressed .tar.
    case plainTar
    case zstd(ZstdParameters)
}

public struct TarZstMapping: SpeedStepMapping {
    public init() {}

    public var format: ArchiveFormat { .tarZst }
    public var capabilities: EngineCapabilities { [.multithreading] }

    public func parameters(for step: SpeedStep, options: ArchiveOptions) -> TarZstParameters {
        let long = ZstdParameters.maxCompatibleWindowLog
        let threads = options.threads
        return switch step {
        case .store: .plainTar
        case .fastest: .zstd(ZstdParameters(level: 1, longWindowLog: nil, threads: threads))
        case .fast: .zstd(ZstdParameters(level: 3, longWindowLog: nil, threads: threads))
        case .normal: .zstd(ZstdParameters(level: 9, longWindowLog: nil, threads: threads))
        case .good: .zstd(ZstdParameters(level: 15, longWindowLog: long, threads: threads))
        case .best: .zstd(ZstdParameters(level: 22, longWindowLog: long, threads: threads))
        }
    }

    public func hint(for step: SpeedStep, options: ArchiveOptions) -> StepHint {
        guard case let .zstd(zstd) = parameters(for: step, options: options) else {
            return StepHint(
                step: step,
                summary: step.summary,
                peakMemoryBytes: 16 * .mebibyte,
                outputExtension: ArchiveFormat.tar.fileExtension,
                notes: ["Saves as a plain .tar without compression"]
            )
        }
        let threads = UInt64(options.threads)
        var notes: [String] = []
        if zstd.longWindowLog != nil {
            notes.append("Recipient needs zstd 1.3.2 or later")
        }
        return StepHint(
            step: step,
            summary: step.summary,
            peakMemoryBytes: Self.approximatePeakMemory(for: zstd) * threads,
            outputExtension: format.fileExtension,
            notes: notes
        )
    }

    /// Approximate memory per worker: window buffers plus match tables, using the
    /// window, chain and hash logs from zstd's default parameter table for large
    /// inputs. The Phase 2a benchmark replaces these with measured peaks.
    static func approximatePeakMemory(for parameters: ZstdParameters) -> UInt64 {
        let (windowLog, chainLog, hashLog): (Int, Int, Int) = switch parameters.level {
        case ...1: (19, 13, 14)
        case 2...3: (21, 16, 17)
        case 4...9: (22, 20, 21)
        case 10...15: (22, 22, 22)
        case 16...19: (23, 24, 22)
        default: (27, 27, 25)
        }
        let window = UInt64(1) << UInt64(max(windowLog, parameters.longWindowLog ?? 0))
        let tables = 4 * ((UInt64(1) << UInt64(chainLog)) + (UInt64(1) << UInt64(hashLog)))
        // The window buffer plus a job's input and output buffers.
        return 3 * window + tables
    }
}
