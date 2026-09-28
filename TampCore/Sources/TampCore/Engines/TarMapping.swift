import Foundation

/// How a TAR-family archive is compressed after bsdtar writes the tar stream.
public enum TarCompression: Equatable, Sendable {
    /// No compression: a plain .tar.
    case plainTar
    /// The tar stream piped through a bundled tool, such as `xz -6 -T4 -c`.
    case tool(name: String, arguments: [String])
    /// Recompressed by a second bsdtar with one of libarchive's own filters. Used
    /// for lz4 and lzip, whose command-line tools are GPL.
    case libarchiveFilter(name: String, level: Int)
}

/// The six steps for every TAR-family format: plain TAR, TAR.GZ, TAR.BZ2,
/// TAR.XZ, TAR.ZST, TAR.LZ4, TAR.LZ and TAR.BR. Store writes a plain .tar
/// for all of them, because none of their compressors has a true store level.
public struct TarMapping: SpeedStepMapping {
    public let format: ArchiveFormat

    /// - Parameter format: `.tar` or a compressed tar format.
    public init(format: ArchiveFormat) {
        precondition(format == .tar || format.isCompressedTar, "\(format) isn't a TAR format")
        self.format = format
    }

    public var capabilities: EngineCapabilities {
        switch format {
        case .tarGz, .tarBz2, .tarXz, .tarZst: [.multithreading]
        default: []
        }
    }

    public func parameters(for step: SpeedStep, options: ArchiveOptions) -> TarCompression {
        let threads = options.threads
        let level = levels[step.rawValue]
        guard format != .tar, step != .store else { return .plainTar }
        switch format {
        case .tarGz:
            return .tool(name: "pigz", arguments: ["-\(level)", "-p", "\(threads)", "-c"])
        case .tarBz2:
            return .tool(name: "pbzip2", arguments: ["-\(level)", "-p\(threads)", "-c"])
        case .tarXz:
            // xz lowers the thread count when the job would need more than half the RAM.
            // -Q keeps that notice from turning the exit status into a warning.
            let preset = step == .best ? "-\(level)e" : "-\(level)"
            return .tool(name: "xz", arguments: [preset, "-T\(threads)", "--memlimit-compress=50%", "-q", "-Q", "-c"])
        case .tarZst:
            guard case let .zstd(zstd) = TarZstMapping().parameters(for: step, options: options) else { return .plainTar }
            return .tool(name: "zstd", arguments: zstd.cliArguments + ["-q", "-c"])
        case .tarBr:
            // Window 24 (16 MiB) is the largest that stock brotli decodes without --large_window.
            return .tool(name: "brotli", arguments: ["-q", "\(level)", "-w", "24", "-c"])
        case .tarLz4:
            return .libarchiveFilter(name: "lz4", level: level)
        case .tarLz:
            return .libarchiveFilter(name: "lzip", level: level)
        default:
            return .plainTar
        }
    }

    /// Each format's own level for Store through Best. Store's entry is unused.
    var levels: [Int] {
        switch format {
        case .tarGz: [0, 1, 3, 6, 9, 11] // pigz -11 is Zopfli
        case .tarBz2: [0, 1, 3, 6, 8, 9] // block size in 100 KB units
        case .tarXz: [0, 0, 2, 6, 8, 9] // Best adds -e
        case .tarBr: [0, 1, 4, 6, 9, 11]
        case .tarLz4: [0, 1, 3, 6, 8, 9] // libarchive stops at 9; 10 to 12 need the GPL tool
        case .tarLz: [0, 0, 3, 6, 8, 9]
        default: [0, 0, 0, 0, 0, 0]
        }
    }

    public func hint(for step: SpeedStep, options: ArchiveOptions) -> StepHint {
        if format == .tar {
            return StepHint(
                step: .store,
                summary: SpeedStep.store.summary,
                peakMemoryBytes: Self.tarMemory,
                outputExtension: format.fileExtension,
                notes: ["TAR bundles files without compressing"]
            )
        }
        let compression = parameters(for: step, options: options)
        guard compression != .plainTar else {
            return StepHint(
                step: step,
                summary: step.summary,
                peakMemoryBytes: Self.tarMemory,
                outputExtension: ArchiveFormat.tar.fileExtension,
                notes: ["Saves as a plain .tar without compression"]
            )
        }
        if format == .tarZst {
            var hint = TarZstMapping().hint(for: step, options: options)
            hint.peakMemoryBytes += Self.tarMemory
            return hint
        }
        return StepHint(
            step: step,
            summary: step.summary,
            peakMemoryBytes: Self.tarMemory + compressorMemory(for: step, threads: options.threads),
            outputExtension: format.fileExtension,
            notes: notes(for: step)
        )
    }

    /// bsdtar's buffers, plus the second bsdtar for lz4 and lzip.
    static let tarMemory: UInt64 = 16 * .mebibyte

    /// Approximate peak memory of the compressor, from each tool's documented
    /// figures. The Phase 2a benchmark replaces these with measured peaks.
    func compressorMemory(for step: SpeedStep, threads: Int) -> UInt64 {
        let level = levels[step.rawValue]
        let threads = UInt64(max(1, threads))
        switch format {
        case .tarGz:
            // Deflate keeps a 32 KB window; Zopfli's search tables are far larger.
            return 8 * .mebibyte + threads * (level == 11 ? 64 : 2) * .mebibyte
        case .tarBz2:
            // bzip2 needs about 8 times its block, and pbzip2 queues a few blocks per thread.
            return 8 * .mebibyte + threads * UInt64(level) * .mebibyte
        case .tarXz:
            let perThread = Self.xzMemoryPerThread(preset: level)
            let limit = ProcessInfo.processInfo.physicalMemory / 2
            let used = max(1, min(threads, limit / max(1, perThread)))
            return used * perThread
        case .tarBr:
            let mebibytes: UInt64 = switch level {
            case ...4: 32
            case 5...9: 96
            default: 256
            }
            return mebibytes * .mebibyte
        case .tarLz4:
            return 8 * .mebibyte
        case .tarLz:
            return Self.lzmaMemory(preset: level)
        default:
            return 0
        }
    }

    /// Single-thread compressor memory for each xz / LZMA preset, from xz's manual.
    static func lzmaMemory(preset: Int) -> UInt64 {
        let mebibytes: [UInt64] = [3, 9, 17, 32, 48, 94, 94, 186, 370, 674]
        return mebibytes[min(max(preset, 0), 9)] * .mebibyte
    }

    /// xz in threaded mode: each thread holds the encoder plus about three blocks of
    /// three times the dictionary (measured: -9 with 8 threads needs about 10 GB).
    static func xzMemoryPerThread(preset: Int) -> UInt64 {
        let dictionaryMebibytes: [UInt64] = [0, 1, 2, 4, 4, 8, 8, 16, 32, 64]
        let dictionary = preset == 0 ? 256 * 1024 : dictionaryMebibytes[min(max(preset, 0), 9)] * .mebibyte
        return lzmaMemory(preset: preset) + 9 * dictionary
    }

    func notes(for step: SpeedStep) -> [String] {
        switch format {
        case .tarGz where step == .best:
            ["Best uses Zopfli: much slower than Good for a few percent smaller"]
        case .tarLz4, .tarLz, .tarBr:
            ["7-Zip and Windows can't open this without extra software"]
        default:
            []
        }
    }
}
