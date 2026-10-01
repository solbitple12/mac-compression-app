import Foundation

/// One finished compress job, kept so later estimates for the same format and
/// step can learn from how far off earlier ones were.
public struct HistoryRecord: Codable, Equatable, Sendable {
    public var date: Date
    public var format: ArchiveFormat
    public var method: CompressionMethod?
    public var step: SpeedStep
    public var threads: Int
    public var macModel: String
    public var inputBytes: Int64
    public var outputBytes: Int64
    /// What the estimator predicted, when it had finished before the job started.
    public var estimatedSeconds: Double?
    public var actualSeconds: Double
    /// The largest footprint the resource monitor saw, when it was watching.
    public var peakMemoryBytes: UInt64?
    /// What the mapping predicted.
    public var hintMemoryBytes: UInt64?

    public init(date: Date = Date(), format: ArchiveFormat, method: CompressionMethod?, step: SpeedStep, threads: Int,
                macModel: String = HistoryRecord.currentMacModel, inputBytes: Int64, outputBytes: Int64,
                estimatedSeconds: Double?, actualSeconds: Double, peakMemoryBytes: UInt64? = nil, hintMemoryBytes: UInt64? = nil) {
        self.date = date
        self.format = format
        self.method = method
        self.step = step
        self.threads = threads
        self.macModel = macModel
        self.inputBytes = inputBytes
        self.outputBytes = outputBytes
        self.estimatedSeconds = estimatedSeconds
        self.actualSeconds = actualSeconds
        self.peakMemoryBytes = peakMemoryBytes
        self.hintMemoryBytes = hintMemoryBytes
    }

    /// For example "Mac14,2".
    public static let currentMacModel: String = {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: bytes)
    }()
}

/// The local history file in Application Support. Nothing in it leaves the Mac.
public final class EstimateHistory: @unchecked Sendable {
    /// Keeps the file small; corrections only look at the last `window` matching runs.
    static let recordLimit = 1000
    static let window = 20

    public let fileURL: URL?
    private let lock = NSLock()
    private var records: [HistoryRecord]

    /// - Parameter fileURL: nil keeps the history in memory only, for tests.
    public init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let saved = try? Self.decoder.decode([HistoryRecord].self, from: data) {
            records = saved
        } else {
            records = []
        }
    }

    /// ~/Library/Application Support/Tamp/History.json
    public static var standard: EstimateHistory {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return EstimateHistory(fileURL: support?.appendingPathComponent("Tamp/History.json"))
    }

    public var allRecords: [HistoryRecord] {
        lock.withLock { records }
    }

    public func append(_ record: HistoryRecord) {
        let snapshot: [HistoryRecord] = lock.withLock {
            records.append(record)
            if records.count > Self.recordLimit { records.removeFirst(records.count - Self.recordLimit) }
            return records
        }
        guard let fileURL, let data = try? Self.encoder.encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    /// The last runs of this format, method and step on this Mac, newest last.
    func recent(format: ArchiveFormat, method: CompressionMethod?, step: SpeedStep) -> [HistoryRecord] {
        let model = HistoryRecord.currentMacModel
        let matching = allRecords.filter {
            $0.format == format && $0.method == method && $0.step == step && $0.macModel == model
        }
        return Array(matching.suffix(Self.window))
    }

    /// What to multiply a fresh estimate by: the median of actual over estimated
    /// time for the last 20 runs, or 1 without any.
    public func timeCorrection(format: ArchiveFormat, method: CompressionMethod?, step: SpeedStep) -> Double {
        let ratios = recent(format: format, method: method, step: step).compactMap { record -> Double? in
            guard let estimated = record.estimatedSeconds, estimated > 0.5, record.actualSeconds > 0 else { return nil }
            return record.actualSeconds / estimated
        }
        return Self.median(ratios).map { min(max($0, 0.25), 4) } ?? 1
    }

    /// What to multiply the mapping's memory figure by: the median of measured over
    /// predicted peak for the last 20 runs, or 1 without any.
    public func memoryCorrection(format: ArchiveFormat, method: CompressionMethod?, step: SpeedStep) -> Double {
        let ratios = recent(format: format, method: method, step: step).compactMap { record -> Double? in
            guard let peak = record.peakMemoryBytes, let hint = record.hintMemoryBytes, hint > 0 else { return nil }
            return Double(peak) / Double(hint)
        }
        return Self.median(ratios).map { min(max($0, 0.5), 4) } ?? 1
    }

    /// A figure from earlier runs alone, shown as "rough" until a probe finishes.
    /// Nil without any earlier run of this format and step.
    public func roughEstimate(format: ArchiveFormat, method: CompressionMethod?, step: SpeedStep,
                              threads: Int, totalBytes: Int64, peakMemoryBytes: UInt64) -> Estimate? {
        let runs = recent(format: format, method: method, step: step).filter { $0.inputBytes > 0 && $0.actualSeconds > 0 }
        guard !runs.isEmpty else { return nil }
        // Throughput depends on threads, so prefer runs with the same count.
        let sameThreads = runs.filter { $0.threads == threads }
        let basis = sameThreads.isEmpty ? runs : sameThreads
        guard let rate = Self.median(basis.map { Double($0.inputBytes) / $0.actualSeconds }), rate > 0 else { return nil }
        let ratios = basis.map { Double($0.outputBytes) / Double($0.inputBytes) }
        let seconds = Double(totalBytes) / rate
        let total = Double(totalBytes)
        return Estimate(
            seconds: (seconds * 0.6)...(seconds * 1.6),
            outputBytes: Int64(total * (ratios.min() ?? 1) * 0.9)...Int64(total * (ratios.max() ?? 1) * 1.1),
            peakMemoryBytes: peakMemoryBytes,
            isRough: true
        )
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
