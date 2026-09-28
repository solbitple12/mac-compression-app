import Foundation

/// Predicts a compress job's time, size and memory before it starts, by running the
/// real engine at the chosen settings on small samples of the real input.
///
/// A probe takes at most `budget` seconds (3 by default):
/// 1. A one-byte archive, which measures what every run costs regardless of size
///    (launching helpers, writing headers).
/// 2. Up to four slices of 256 KB to 8 MB taken from the largest files, each sized
///    from the speed of the one before so the probe fits its budget. Their spread
///    becomes the estimate's range.
/// 3. For inputs with many small files, a folder of up to 40 of them, which measures
///    the extra cost of each file.
///
/// Probes run on one thread, since samples are too small to keep more busy;
/// `ThreadScaling` converts that to the job's thread count. Results are cached by
/// the input's fingerprint and the settings, so moving the slider back is instant,
/// and every estimate is corrected by how far off earlier ones were (`EstimateHistory`).
public actor Estimator {
    public nonisolated let history: EstimateHistory
    public nonisolated let budget: TimeInterval
    private let temporaryDirectory: URL
    private let clock: @Sendable () -> TimeInterval
    /// Uncorrected results, newest last.
    private var cache: [String: Estimate] = [:]
    private var cacheOrder: [String] = []
    static let cacheLimit = 128

    static let firstSliceBytes: Int64 = 256 * 1024
    static let maxSliceBytes: Int64 = 8 << 20
    static let maxSlices = 4

    public init(
        history: EstimateHistory,
        budget: TimeInterval = 3,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.history = history
        self.budget = budget
        self.temporaryDirectory = temporaryDirectory
        self.clock = clock
    }

    /// A finished estimate for exactly these settings, without probing.
    public func cachedEstimate(for profile: InputProfile, engine: any ArchiveEngine, step: SpeedStep,
                               options: ArchiveOptions) -> Estimate? {
        cache[Self.key(profile, engine.format, step, options)].map { corrected($0, format: engine.format, step: step, options: options) }
    }

    /// A figure from earlier jobs alone, for the hint while a probe runs.
    public nonisolated func roughEstimate(for profile: InputProfile, engine: any ArchiveEngine, step: SpeedStep,
                                          options: ArchiveOptions) -> Estimate? {
        history.roughEstimate(format: engine.format, method: engine.format.resolvedMethod(options.method), step: step,
                              threads: options.threads, totalBytes: profile.totalBytes,
                              peakMemoryBytes: peakMemory(engine: engine, step: step, options: options))
    }

    /// Probes the input, or returns the cached result.
    /// - Returns: nil when not even one sample finished within the budget.
    /// - Throws: `CancellationError` when cancelled, or whatever the engine threw.
    public func estimate(for profile: InputProfile, engine: any ArchiveEngine, step: SpeedStep,
                         options: ArchiveOptions) async throws -> Estimate? {
        let key = Self.key(profile, engine.format, step, options)
        if let cached = cache[key] {
            return corrected(cached, format: engine.format, step: step, options: options)
        }
        guard let measured = try await probe(profile, engine: engine, step: step, options: options) else { return nil }
        let raw = Self.combine(measured, profile: profile, format: engine.format, step: step, options: options,
                               peakMemoryBytes: engine.hint(for: step, options: options).peakMemoryBytes)
        store(raw, for: key)
        return corrected(raw, format: engine.format, step: step, options: options)
    }

    /// The highest step below `step` whose likely time is within `limit`, for the
    /// long-job warning. Nil when even Fastest takes longer.
    public func fasterStep(for profile: InputProfile, engine: any ArchiveEngine, below step: SpeedStep,
                           options: ArchiveOptions, limit: TimeInterval) async throws -> (SpeedStep, Estimate)? {
        for candidate in SpeedStep.allCases.reversed() where candidate < step && candidate != .store {
            try Task.checkCancellation()
            if let estimate = try await estimate(for: profile, engine: engine, step: candidate, options: options),
               estimate.likelySeconds <= limit {
                return (candidate, estimate)
            }
        }
        return nil
    }

    // MARK: Probing

    /// What the samples measured, on one thread.
    struct Measurements: Equatable, Sendable {
        /// Seconds and bytes of the one-byte archive.
        var fixedSeconds: Double
        var fixedBytes: Int64
        /// Bytes per second and output-to-input ratio of each slice.
        var slices: [(rate: Double, ratio: Double)]
        var perFileSeconds: Double
        var perFileBytes: Double

        static func == (lhs: Measurements, rhs: Measurements) -> Bool {
            lhs.fixedSeconds == rhs.fixedSeconds && lhs.fixedBytes == rhs.fixedBytes
                && lhs.slices.map { $0.rate } == rhs.slices.map { $0.rate } && lhs.slices.map { $0.ratio } == rhs.slices.map { $0.ratio }
                && lhs.perFileSeconds == rhs.perFileSeconds && lhs.perFileBytes == rhs.perFileBytes
        }
    }

    private func probe(_ profile: InputProfile, engine: any ArchiveEngine, step: SpeedStep,
                       options: ArchiveOptions) async throws -> Measurements? {
        let fileManager = FileManager.default
        let workspace = temporaryDirectory.appendingPathComponent("Tamp Estimate \(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { SafeOutput.remove(workspace, fileManager: fileManager) }

        let probeOptions = ArchiveOptions(threads: 1, method: options.method, advanced: options.advanced)
        let deadline = clock() + budget
        var runNumber = 0
        // Compresses one sample; nil once the budget has run out.
        func run(_ item: URL) async throws -> (seconds: Double, bytes: Int64)? {
            runNumber += 1
            let remaining = deadline - clock()
            guard remaining > 0.02 else { return nil }
            let folder = workspace.appendingPathComponent("out \(runNumber)", isDirectory: true)
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: false)
            let request = CompressRequest(items: [item], destination: folder.appendingPathComponent("probe.\(engine.format.fileExtension)"),
                                          step: step, options: probeOptions)
            let start = clock()
            guard let output = try await Self.withTimeLimit(remaining, { try await engine.compress(request, progress: { _ in }) }) else {
                return nil
            }
            let seconds = clock() - start
            return (seconds, Self.size(of: output, fileManager: fileManager))
        }

        // 1. What every run costs.
        let tiny = workspace.appendingPathComponent("tiny", isDirectory: true)
        try fileManager.createDirectory(at: tiny, withIntermediateDirectories: false)
        let tinyFile = tiny.appendingPathComponent("sample")
        try Data([0x41]).write(to: tinyFile)
        guard let fixed = try await run(tinyFile) else { return nil }

        // 2. Slices of the largest files.
        var slices: [(rate: Double, ratio: Double)] = []
        let sources = profile.largestFiles
        let smallProbe = profile.smallFileCount >= 20 && !profile.smallFiles.isEmpty
        let offsets = [0.5, 0.1, 0.9, 0.3]
        var sliceBytes = Self.firstSliceBytes
        for index in 0..<(sources.isEmpty ? 0 : Self.maxSlices) {
            try Task.checkCancellation()
            let source = sources[index % sources.count]
            let slice = workspace.appendingPathComponent("slice \(index)", isDirectory: true)
            try fileManager.createDirectory(at: slice, withIntermediateDirectories: false)
            let sample = slice.appendingPathComponent("sample")
            let length = try Self.copySlice(of: source, fraction: offsets[index], length: sliceBytes, to: sample)
            guard length > 0, let result = try await run(sample) else { break }
            let working = max(0.001, result.seconds - fixed.seconds)
            slices.append((rate: Double(length) / working,
                           ratio: max(0.0001, Double(result.bytes - fixed.bytes) / Double(length))))
            // Size the next slice to fit what's left, keeping a share for the small files.
            let rate = slices.map { $0.rate }.min() ?? 0
            let left = max(0, deadline - clock() - fixed.seconds) * (smallProbe ? 0.6 : 1)
            let runsLeft = Double(Self.maxSlices - index - 1)
            guard runsLeft > 0 else { break }
            let affordable = Int64(rate * left / runsLeft / 1.5)
            sliceBytes = min(Self.maxSliceBytes, max(Self.firstSliceBytes, affordable))
            if affordable < Self.firstSliceBytes / 2 { break }
        }

        // 3. The cost of each small file.
        var perFileSeconds = 0.0
        var perFileBytes = 0.0
        if smallProbe {
            let folder = workspace.appendingPathComponent("small", isDirectory: true)
            let inside = folder.appendingPathComponent("files", isDirectory: true)
            try fileManager.createDirectory(at: inside, withIntermediateDirectories: true)
            var copied = 0
            var copiedBytes: Int64 = 0
            for (index, file) in profile.smallFiles.enumerated() {
                let target = inside.appendingPathComponent("\(index) \(file.url.lastPathComponent)")
                if (try? fileManager.copyItem(at: file.url, to: target)) != nil {
                    copied += 1
                    copiedBytes += file.bytes
                }
            }
            if copied > 0, let result = try await run(inside) {
                if slices.isEmpty {
                    // Only small files: their speed is all there is.
                    let working = max(0.001, result.seconds - fixed.seconds)
                    slices.append((rate: Double(max(1, copiedBytes)) / working,
                                   ratio: max(0.0001, Double(result.bytes - fixed.bytes) / Double(max(1, copiedBytes)))))
                } else {
                    let rate = Self.median(slices.map { $0.rate })
                    let ratio = Self.median(slices.map { $0.ratio })
                    perFileSeconds = max(0, (result.seconds - fixed.seconds - Double(copiedBytes) / rate) / Double(copied))
                    perFileBytes = max(0, (Double(result.bytes - fixed.bytes) - Double(copiedBytes) * ratio) / Double(copied))
                }
            }
        }

        guard !slices.isEmpty || profile.totalBytes == 0 else { return nil }
        return Measurements(fixedSeconds: fixed.seconds, fixedBytes: fixed.bytes, slices: slices,
                            perFileSeconds: perFileSeconds, perFileBytes: perFileBytes)
    }

    // MARK: Arithmetic

    /// Scales the samples up to the whole input and its thread count.
    static func combine(_ measured: Measurements, profile: InputProfile, format: ArchiveFormat, step: SpeedStep,
                        options: ArchiveOptions, peakMemoryBytes: UInt64) -> Estimate {
        let total = Double(profile.totalBytes)
        let files = Double(profile.fileCount)
        let speedup = ThreadScaling.of(format: format, step: step, options: options)
            .speedup(threads: options.threads, totalBytes: profile.totalBytes)
        let rates = measured.slices.map { $0.rate }
        let ratios = measured.slices.map { min($0.ratio, 1.1) }
        func seconds(rate: Double) -> Double {
            measured.fixedSeconds + (rate > 0 ? total / (rate * speedup) : 0) + files * measured.perFileSeconds
        }
        func bytes(ratio: Double) -> Double {
            Double(measured.fixedBytes) + total * ratio + files * measured.perFileBytes
        }
        var fastest = seconds(rate: rates.max() ?? 0)
        var slowest = seconds(rate: rates.min() ?? 0)
        var smallest = bytes(ratio: ratios.min() ?? 1)
        var largest = bytes(ratio: ratios.max() ?? 1)
        // Even samples that agree are samples: keep a margin either side.
        fastest *= 0.9
        slowest *= 1.1
        smallest *= 0.95
        largest *= 1.05
        if isSensitiveToSampleSize(format: format, step: step, options: options), profile.totalBytes > maxSliceBytes {
            // Dictionaries and windows larger than a sample find matches the samples
            // can't, which shrinks the archive and slows the match finder.
            smallest *= 0.8
            slowest *= 1.3
        }
        return Estimate(
            seconds: fastest...max(fastest, slowest),
            outputBytes: Int64(smallest)...Int64(max(smallest, largest)),
            peakMemoryBytes: peakMemoryBytes
        )
    }

    /// Engines whose reach (dictionary, window or context model) is far larger than
    /// a sample, so small samples understate how well they compress a large input.
    static func isSensitiveToSampleSize(format: ArchiveFormat, step: SpeedStep, options: ArchiveOptions) -> Bool {
        guard step != .store else { return false }
        switch format {
        case .zpaq, .tarXz, .tarLz:
            return true
        case .sevenZip:
            let method = format.resolvedMethod(options.method)
            return method == .lzma2 || method == .lzma
        case .zip:
            return format.resolvedMethod(options.method) == .lzma
        case .tarZst:
            guard case let .zstd(zstd) = TarZstMapping().parameters(for: step, options: options) else { return false }
            return zstd.longWindowLog != nil
        case .tarBr:
            return step >= .good || options.advanced.brotliLargeWindow
        default:
            return false
        }
    }

    private nonisolated func peakMemory(engine: any ArchiveEngine, step: SpeedStep, options: ArchiveOptions) -> UInt64 {
        let hint = engine.hint(for: step, options: options).peakMemoryBytes
        let correction = history.memoryCorrection(format: engine.format, method: engine.format.resolvedMethod(options.method), step: step)
        return UInt64(Double(hint) * correction)
    }

    private func corrected(_ raw: Estimate, format: ArchiveFormat, step: SpeedStep, options: ArchiveOptions) -> Estimate {
        let method = format.resolvedMethod(options.method)
        let time = history.timeCorrection(format: format, method: method, step: step)
        let memory = history.memoryCorrection(format: format, method: method, step: step)
        var estimate = raw
        estimate.seconds = (raw.seconds.lowerBound * time)...(raw.seconds.upperBound * time)
        estimate.peakMemoryBytes = UInt64(Double(raw.peakMemoryBytes) * memory)
        return estimate
    }

    private func store(_ estimate: Estimate, for key: String) {
        if cache[key] == nil { cacheOrder.append(key) }
        cache[key] = estimate
        while cacheOrder.count > Self.cacheLimit {
            cache[cacheOrder.removeFirst()] = nil
        }
    }

    static func key(_ profile: InputProfile, _ format: ArchiveFormat, _ step: SpeedStep, _ options: ArchiveOptions) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let advanced = (try? encoder.encode(options.advanced)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        return "\(profile.fingerprint)|\(format.rawValue)|\(step.rawValue)|\(options.threads)|"
            + "\(format.resolvedMethod(options.method)?.rawValue ?? "-")|\(advanced)"
    }

    static func median(_ values: [Double]) -> Double {
        EstimateHistory.median(values) ?? 0
    }

    // MARK: Helpers

    /// Copies up to `length` bytes from `fraction` of the way into the file; the
    /// whole file when it's shorter. Returns the bytes copied.
    static func copySlice(of file: InputProfile.File, fraction: Double, length: Int64, to target: URL) throws -> Int64 {
        let handle = try FileHandle(forReadingFrom: file.url)
        defer { try? handle.close() }
        let count = min(length, file.bytes)
        let offset = UInt64(max(0, Double(file.bytes - count) * fraction))
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: Int(count)) ?? Data()
        try data.write(to: target)
        return Int64(data.count)
    }

    /// The size of an archive, or of all the files in a folder the engine wrote.
    static func size(of output: URL, fileManager: FileManager) -> Int64 {
        let values = try? output.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        if values?.isDirectory == true { return InputSize.totalBytes(of: [output], fileManager: fileManager) }
        return Int64(values?.fileSize ?? 0)
    }

    /// Runs `body`, cancelling it once `seconds` have passed.
    /// - Returns: nil when the time ran out first.
    static func withTimeLimit<T: Sendable>(_ seconds: TimeInterval, _ body: @escaping @Sendable () async throws -> T) async throws -> T? {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                return nil
            }
            defer { group.cancelAll() }
            do {
                guard let first = try await group.next() else { return nil }
                return first
            } catch is CancellationError {
                // The engine gave up because the time ran out, or the whole probe was cancelled.
                try Task.checkCancellation()
                return nil
            } catch let error as TampError where error == .cancelled {
                try Task.checkCancellation()
                return nil
            }
        }
    }
}
