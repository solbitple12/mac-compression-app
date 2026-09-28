/// ZIP settings for the bundled 7zz helper.
public struct ZipParameters: Equatable, Sendable {
    /// 7-Zip's own level (-mx), not zlib's: 7-Zip's Deflate runs extra passes at 7 and 9.
    public var level: Int
    public var threads: Int

    /// Store uses the Copy method; every other step uses Deflate.
    public var method: String { level == 0 ? "Copy" : "Deflate" }

    public var sevenZipArguments: [String] {
        ["-tzip", "-mm=\(method)", "-mx=\(level)", "-mmt=\(threads)"]
    }
}

public struct ZipMapping: SpeedStepMapping {
    public init() {}

    public var format: ArchiveFormat { .zip }
    public var capabilities: EngineCapabilities { [.encryption, .volumes, .multithreading] }

    public func parameters(for step: SpeedStep, options: ArchiveOptions) -> ZipParameters {
        let level = switch step {
        case .store: 0
        case .fastest: 1
        case .fast: 3
        case .normal: 5
        case .good: 7
        case .best: 9
        }
        return ZipParameters(level: level, threads: options.threads)
    }

    public func hint(for step: SpeedStep, options: ArchiveOptions) -> StepHint {
        // Placeholder until the Phase 2a benchmark measures real peaks:
        // Deflate keeps only a 32 KB window, so memory is buffers per thread.
        let perThread: UInt64 = step == .store ? 4 * .mebibyte : 16 * .mebibyte
        return StepHint(
            step: step,
            summary: step.summary,
            peakMemoryBytes: 32 * .mebibyte + perThread * UInt64(options.threads),
            outputExtension: format.fileExtension,
            notes: step == .store ? [] : ["Opens on any computer, including Windows"]
        )
    }
}
