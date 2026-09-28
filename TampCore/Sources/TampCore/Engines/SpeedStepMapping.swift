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

/// Options shared by every format, plus the advanced ones that only some use.
public struct ArchiveOptions: Equatable, Sendable {
    /// Worker threads; always at least 1.
    public var threads: Int
    /// The method inside a ZIP or 7Z archive. Nil, or one the format can't hold,
    /// means the format's default (see `ArchiveFormat.resolvedMethod`).
    public var method: CompressionMethod?
    /// Settings behind the Advanced panel. Each engine reads only its own.
    public var advanced: AdvancedOptions

    public init(
        threads: Int = ProcessInfo.processInfo.activeProcessorCount,
        method: CompressionMethod? = nil,
        advanced: AdvancedOptions = AdvancedOptions()
    ) {
        self.threads = max(1, threads)
        self.method = method
        self.advanced = advanced
    }
}

/// 7Z solid blocks: files compressed together share one stream, which is smaller
/// but means a damaged block loses every file in it.
public enum SolidMode: Equatable, Hashable, Codable, Sendable {
    /// 7-Zip's own choice for the level.
    case automatic
    /// Every file compressed on its own (-ms=off).
    case off
    /// A new block every N MiB (-ms=Nm).
    case blockMebibytes(Int)

    var sevenZipSwitch: String? {
        switch self {
        case .automatic: nil
        case .off: "-ms=off"
        case let .blockMebibytes(size): "-ms=\(max(1, size))m"
        }
    }
}

/// How a password protects a ZIP.
public enum ZipEncryption: String, CaseIterable, Codable, Sendable {
    /// Strong, but Windows Explorer and macOS Archive Utility can't open it.
    case aes256
    /// Weak legacy encryption that every unzip tool opens.
    case zipCrypto

    public var title: String {
        switch self {
        case .aes256: "AES-256"
        case .zipCrypto: "ZipCrypto (weak)"
        }
    }
}

/// The advanced settings a format can offer, so the panel shows only those that apply.
public enum AdvancedOption: String, CaseIterable, Sendable {
    case threads
    case dictionary
    case solid
    case wordSize
    case executableFilter
    case encryptFileNames
    case zipEncryption
    case zstdLongWindow
    case xzBlockSize
    case zpaqBlockSize
    case brotliLargeWindow
}

/// Settings behind the Advanced panel. Nil means the speed step's own choice.
public struct AdvancedOptions: Equatable, Codable, Sendable {
    /// 7Z LZMA and LZMA2 dictionary (-md).
    public var dictionaryMebibytes: Int?
    /// 7Z solid blocks (-ms).
    public var solid: SolidMode = .automatic
    /// 7Z LZMA and LZMA2 word size, the "fast bytes" (-mfb), 5 to 273.
    public var wordSize: Int?
    /// 7Z BCJ2 filter, which shrinks Intel executables (-mf=BCJ2).
    public var executableFilter = false
    /// 7Z with a password: hide the file names as well (-mhe=on).
    public var encryptFileNames = true
    public var zipEncryption: ZipEncryption = .aes256
    /// TAR.ZST long-distance window as log2 bytes; 0 turns it off.
    public var zstdLongWindowLog: Int?
    /// TAR.XZ block size for threaded compression; smaller blocks use less RAM
    /// and more threads, larger ones compress a little better.
    public var xzBlockMebibytes: Int?
    /// ZPAQ block size as log2 MiB, 0 to 11.
    public var zpaqBlockLog: Int?
    /// TAR.BR window up to 1 GiB, which stock brotli decodes only with --large_window.
    public var brotliLargeWindow = false

    public init() {}

    public init(from decoder: Decoder) throws {
        // Every field is optional in saved settings, so older or partial ones still load.
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AdvancedOptions()
        dictionaryMebibytes = try container.decodeIfPresent(Int.self, forKey: .dictionaryMebibytes)
        solid = try container.decodeIfPresent(SolidMode.self, forKey: .solid) ?? defaults.solid
        wordSize = try container.decodeIfPresent(Int.self, forKey: .wordSize)
        executableFilter = try container.decodeIfPresent(Bool.self, forKey: .executableFilter) ?? defaults.executableFilter
        encryptFileNames = try container.decodeIfPresent(Bool.self, forKey: .encryptFileNames) ?? defaults.encryptFileNames
        zipEncryption = try container.decodeIfPresent(ZipEncryption.self, forKey: .zipEncryption) ?? defaults.zipEncryption
        zstdLongWindowLog = try container.decodeIfPresent(Int.self, forKey: .zstdLongWindowLog)
        xzBlockMebibytes = try container.decodeIfPresent(Int.self, forKey: .xzBlockMebibytes)
        zpaqBlockLog = try container.decodeIfPresent(Int.self, forKey: .zpaqBlockLog)
        brotliLargeWindow = try container.decodeIfPresent(Bool.self, forKey: .brotliLargeWindow) ?? defaults.brotliLargeWindow
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
