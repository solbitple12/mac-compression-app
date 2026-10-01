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
            let block = options.advanced.xzBlockMebibytes.map { ["--block-size=\(max(1, $0))MiB"] } ?? []
            return .tool(name: "xz", arguments: [preset, "-T\(threads)"] + block + ["--memlimit-compress=50%", "-q", "-Q", "-c"])
        case .tarZst:
            guard case let .zstd(zstd) = TarZstMapping().parameters(for: step, options: options) else { return .plainTar }
            return .tool(name: "zstd", arguments: zstd.cliArguments + ["-q", "-c"])
        case .tarBr:
            // Window 24 (16 MiB) is the largest every brotli decoder opens. Tamp's brotli
            // opens larger ones, but many other decoders need --large_window.
            let window = options.advanced.brotliLargeWindow ? ["--large_window=\(Self.brotliLargeWindowLog)"] : ["-w", "24"]
            return .tool(name: "brotli", arguments: ["-q", "\(level)"] + window + ["-c"])
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
            peakMemoryBytes: Self.tarMemory + compressorMemory(for: step, options: options),
            outputExtension: format.fileExtension,
            notes: notes(for: step, options: options)
        )
    }

    /// bsdtar's buffers, plus the second bsdtar for lz4 and lzip.
    static let tarMemory: UInt64 = 16 * .mebibyte

    /// Approximate peak memory of the compressor, from each tool's documented
    /// figures. The Phase 2a benchmark replaces these with measured peaks.
    func compressorMemory(for step: SpeedStep, options: ArchiveOptions) -> UInt64 {
        let level = levels[step.rawValue]
        let threads = UInt64(max(1, options.threads))
        switch format {
        case .tarGz:
            // Deflate keeps a 32 KB window; Zopfli's search tables are far larger.
            return 8 * .mebibyte + threads * (level == 11 ? 64 : 2) * .mebibyte
        case .tarBz2:
            // bzip2 needs about 8 times its block, and pbzip2 queues a few blocks per thread.
            return 8 * .mebibyte + threads * UInt64(level) * .mebibyte
        case .tarXz:
            let perThread = Self.xzMemoryPerThread(preset: level,
                                                   blockBytes: options.advanced.xzBlockMebibytes.map { UInt64(max(1, $0)) * .mebibyte })
            let limit = ProcessInfo.processInfo.physicalMemory / 2
            let used = max(1, min(threads, limit / max(1, perThread)))
            return used * perThread
        case .tarBr:
            // Measured on macOS 15 with 22 MB of mixed data: brotli's quality 2 to 6
            // hashers take far more there than on Linux.
            let mebibytes: UInt64 = switch level {
            case ...1: 32
            case 2...6: 480
            case 7...9: 300
            default: 400
            }
            // The encoder keeps the whole window, plus hash tables of about the same
            // size, once the input is that large.
            let window: UInt64 = options.advanced.brotliLargeWindow ? 2 << UInt64(Self.brotliLargeWindowLog) : 0
            return mebibytes * .mebibyte + window
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
    static func xzMemoryPerThread(preset: Int, blockBytes: UInt64? = nil) -> UInt64 {
        let dictionaryMebibytes: [UInt64] = [0, 1, 2, 4, 4, 8, 8, 16, 32, 64]
        let dictionary = preset == 0 ? 256 * 1024 : dictionaryMebibytes[min(max(preset, 0), 9)] * .mebibyte
        // xz's default block is 3 × dictionary; each thread holds about three.
        return lzmaMemory(preset: preset) + 3 * (blockBytes ?? 3 * dictionary)
    }

    /// 256 MiB. Larger windows need gigabytes to compress.
    static let brotliLargeWindowLog = 28

    func notes(for step: SpeedStep, options: ArchiveOptions) -> [String] {
        switch format {
        case .tarGz where step == .best:
            return ["Best uses Zopfli: much slower than Good for a few percent smaller"]
        case .tarBz2 where step >= .normal:
            // bzip2's levels only change its block size (measured: Normal to Best within 1%).
            return ["Steps above Fast barely change the size; they only use more memory"]
        case .tarBr where options.advanced.brotliLargeWindow:
            return ["Large window: many brotli decoders can't open this, and older brotli tools need --large_window",
                    "7-Zip and Windows can't open this without extra software"]
        case .tarLz4, .tarLz, .tarBr:
            return ["7-Zip and Windows can't open this without extra software"]
        default:
            return []
        }
    }
}
