import Foundation

/// Converts single-thread speed, which is what small probes measure, into the
/// speed of the whole job on all its threads.
///
/// Most tools split their input into independent units (pigz and pbzip2 blocks,
/// xz and zstd jobs, ZPAQ and Apple Archive blocks) and give each thread one, so a
/// job can't use more threads than it has units. The per-thread efficiencies come
/// from the Phase 2a benchmark on a 3-core runner: 1 to 3 threads made pigz 2.6
/// times and pbzip2 2.7 times as fast, 7Z LZMA2 1.4 times (one block, whose match
/// finder takes a second thread) and ZIP Deflate 1.6 times (files in parallel);
/// xz, zstd and ZPAQ didn't scale because the 22 MB set fit in a single unit.
public struct ThreadScaling: Equatable, Sendable {
    /// Bytes per independent unit; nil when the whole input is one unit.
    public var unitBytes: Int64?
    /// Extra speed each additional busy thread adds, from 0 to 1.
    public var efficiency: Double
    /// Speed-up from a helper thread inside one unit, such as LZMA's match finder.
    public var innerSpeedup: Double
    /// Threads each unit keeps busy.
    public var threadsPerUnit: Int

    public init(unitBytes: Int64?, efficiency: Double, innerSpeedup: Double = 1, threadsPerUnit: Int = 1) {
        self.unitBytes = unitBytes
        self.efficiency = efficiency
        self.innerSpeedup = innerSpeedup
        self.threadsPerUnit = max(1, threadsPerUnit)
    }

    public static let singleThreaded = ThreadScaling(unitBytes: nil, efficiency: 0)

    /// How many times faster `threads` threads are than one on `totalBytes` of input.
    public func speedup(threads: Int, totalBytes: Int64) -> Double {
        guard threads > 1 else { return 1 }
        let inner = threads >= threadsPerUnit ? innerSpeedup : 1
        let units = unitBytes.map { max(1, Int((totalBytes + $0 - 1) / max(1, $0))) } ?? 1
        let busy = min(max(1, threads / threadsPerUnit), units)
        return inner * (1 + Double(busy - 1) * efficiency)
    }

    public static func of(format: ArchiveFormat, step: SpeedStep, options: ArchiveOptions) -> ThreadScaling {
        let mebibyte: Int64 = 1 << 20
        guard step != .store else { return .singleThreaded }
        switch format {
        case .tarGz:
            return ThreadScaling(unitBytes: 128 * 1024, efficiency: 0.8)
        case .tarBz2:
            return ThreadScaling(unitBytes: 900 * 1000, efficiency: 0.85)
        case .tarXz:
            let preset = TarMapping(format: .tarXz).levels[step.rawValue]
            let dictionaries: [Int64] = [0, 1, 2, 4, 4, 8, 8, 16, 32, 64]
            let dictionary = preset == 0 ? 256 * 1024 : dictionaries[min(preset, 9)] * mebibyte
            let block = options.advanced.xzBlockMebibytes.map { Int64(max(1, $0)) * mebibyte } ?? 3 * dictionary
            return ThreadScaling(unitBytes: block, efficiency: 0.9)
        case .tarZst:
            // zstd hands each worker a job of about four windows.
            guard case let .zstd(zstd) = TarZstMapping().parameters(for: step, options: options) else { return .singleThreaded }
            let windowLog = zstd.longWindowLog ?? (zstd.level >= 16 ? 23 : zstd.level >= 4 ? 22 : 21)
            return ThreadScaling(unitBytes: Int64(4) << windowLog, efficiency: 0.85)
        case .sevenZip:
            let parameters = SevenZipMapping().parameters(for: step, options: options)
            switch parameters.method {
            case .lzma2:
                let dictionary = Int64(parameters.dictionaryBytes ?? SevenZipMapping.dictionarySize(level: parameters.level))
                let pairs = parameters.level >= 5
                return ThreadScaling(unitBytes: 4 * dictionary, efficiency: 0.9,
                                     innerSpeedup: pairs ? 1.4 : 1, threadsPerUnit: pairs ? 2 : 1)
            case .lzma:
                return ThreadScaling(unitBytes: nil, efficiency: 0, innerSpeedup: parameters.level >= 5 ? 1.4 : 1, threadsPerUnit: 2)
            case .bzip2:
                return ThreadScaling(unitBytes: 900 * 1000, efficiency: 0.85)
            default:
                return .singleThreaded
            }
        case .zip:
            // 7-Zip compresses several files at once, one per thread.
            return ThreadScaling(unitBytes: 1 * mebibyte, efficiency: 0.3)
        case .zpaq:
            let block = Int64(ZpaqMapping().parameters(for: step, options: options).blockBytes)
            return ThreadScaling(unitBytes: block, efficiency: 0.9)
        case .appleArchive:
            let block = Int64(AppleArchiveMapping().parameters(for: step, options: options).blockBytes)
            return ThreadScaling(unitBytes: block, efficiency: 0.8)
        case .dmg:
            return ThreadScaling(unitBytes: 1 * mebibyte, efficiency: 0.3)
        case .tar, .tarLz4, .tarLz, .tarBr:
            return .singleThreaded
        }
    }
}
