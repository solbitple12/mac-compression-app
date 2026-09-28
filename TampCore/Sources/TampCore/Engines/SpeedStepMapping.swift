import Foundation

/// What an engine supports, so the UI only shows options that apply.
public struct EngineCapabilities: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let encryption = EngineCapabilities(rawValue: 1 << 0)
    public static let volumes = EngineCapabilities(rawValue: 1 << 1)
    public static let solid = EngineCapabilities(rawValue: 1 << 2)
    public static let multithreading = EngineCapabilities(rawValue: 1 << 3)
}

/// Options shared by every format. Format-specific advanced options arrive in Phase 2b.
public struct ArchiveOptions: Equatable, Sendable {
    /// Worker threads; always at least 1.
    public var threads: Int
    /// The method inside a ZIP or 7Z archive. Nil, or one the format can't hold,
    /// means the format's default (see `ArchiveFormat.resolvedMethod`).
    public var method: CompressionMethod?

    public init(threads: Int = ProcessInfo.processInfo.activeProcessorCount, method: CompressionMethod? = nil) {
        self.threads = max(1, threads)
        self.method = method
    }
}

/// The live hint next to the slider. Time and size come from the Estimator
/// (Phase 2c); this carries what the mapping alone knows.
public struct StepHint: Equatable, Sendable {
    public var step: SpeedStep
    public var summary: String
    /// Approximate peak memory for the whole job, all threads included.
    public var peakMemoryBytes: UInt64
    /// Extension the output will get, which can differ from the format's (Store on TAR.ZST writes .tar).
    public var outputExtension: String
    public var notes: [String]

    public init(step: SpeedStep, summary: String, peakMemoryBytes: UInt64, outputExtension: String, notes: [String] = []) {
        self.step = step
        self.summary = summary
        self.peakMemoryBytes = peakMemoryBytes
        self.outputExtension = outputExtension
        self.notes = notes
    }

    /// For example "Best: smallest file, slowest, uses about 1.2 GB RAM".
    public var text: String {
        let memory = ByteCountFormatter.string(fromByteCount: Int64(clamping: peakMemoryBytes), countStyle: .memory)
        return "\(step.title): \(summary), uses about \(memory) RAM"
    }
}

/// Maps the six slider steps to one engine's real settings. The archive
/// engine protocol builds on this once compress and extract land.
public protocol SpeedStepMapping: Sendable {
    associatedtype Parameters: Equatable & Sendable

    var format: ArchiveFormat { get }
    var capabilities: EngineCapabilities { get }
    func parameters(for step: SpeedStep, options: ArchiveOptions) -> Parameters
    func hint(for step: SpeedStep, options: ArchiveOptions) -> StepHint
}

extension UInt64 {
    static let mebibyte: UInt64 = 1 << 20
}
