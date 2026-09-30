import Foundation

/// The format, speed step, inner methods and Advanced panel settings last used,
/// restored at launch. Passwords are never saved.
public struct ArchiveChoice: Codable, Equatable, Sendable {
    public var format: ArchiveFormat
    public var step: SpeedStep
    /// The method last chosen for each format that has several, keyed by the format's raw value.
    private var methods: [String: CompressionMethod]
    public var advanced = AdvancedOptions()
    /// Nil uses every core.
    public var threads: Int?
    public var excludesMacOSJunk = true
    /// Split 7Z and ZIP archives into parts of this size; nil writes one file.
    public var volumeMebibytes: Int?
    public var verifies = false
    public var trashesOriginals = false

    public init(format: ArchiveFormat, step: SpeedStep, methods: [ArchiveFormat: CompressionMethod] = [:]) {
        self.format = format
        self.step = step
        self.methods = Dictionary(uniqueKeysWithValues: methods.map { ($0.key.rawValue, $0.value) })
    }

    public static let `default` = ArchiveChoice(format: .zip, step: .normal)

    /// The method for `format`: the one last chosen, else the format's default. Nil for
    /// formats with only one.
    public func method(for format: ArchiveFormat) -> CompressionMethod? {
        format.resolvedMethod(methods[format.rawValue])
    }

    public mutating func setMethod(_ method: CompressionMethod, for format: ArchiveFormat) {
        methods[format.rawValue] = method
    }

    /// The current format's settings, for a compress request or a hint.
    public var options: ArchiveOptions {
        ArchiveOptions(threads: threads ?? ProcessInfo.processInfo.activeProcessorCount, method: method(for: format), advanced: advanced)
    }

    /// The part size in bytes, when the current format and method can be split.
    public var volumeBytes: Int64? {
        guard let volumeMebibytes, format.canSplit(method: method(for: format)) else { return nil }
        return Int64(max(1, volumeMebibytes)) << 20
    }

    private enum CodingKeys: String, CodingKey {
        case format, step, methods, advanced, threads, excludesMacOSJunk, volumeMebibytes, verifies, trashesOriginals
    }

    /// Settings saved by an older Tamp lack the newer keys, which keep their defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = try container.decode(ArchiveFormat.self, forKey: .format)
        step = try container.decode(SpeedStep.self, forKey: .step)
        methods = (try? container.decodeIfPresent([String: CompressionMethod].self, forKey: .methods)) ?? [:]
        advanced = (try? container.decodeIfPresent(AdvancedOptions.self, forKey: .advanced)) ?? AdvancedOptions()
        threads = try? container.decodeIfPresent(Int.self, forKey: .threads)
        excludesMacOSJunk = (try? container.decodeIfPresent(Bool.self, forKey: .excludesMacOSJunk)) ?? true
        volumeMebibytes = try? container.decodeIfPresent(Int.self, forKey: .volumeMebibytes)
        verifies = (try? container.decodeIfPresent(Bool.self, forKey: .verifies)) ?? false
        trashesOriginals = (try? container.decodeIfPresent(Bool.self, forKey: .trashesOriginals)) ?? false
    }
}

/// The format, quality and metadata choice last used for each media kind
/// (image, audio, video), restored at launch the way `ArchiveChoice` restores
/// the last archive format and step. Nil until something of that kind has
/// been re-encoded, so a fresh install still gets `MediaPlanner`'s own defaults.
public struct MediaChoice: Codable, Equatable, Sendable {
    public var imageFormat: ImageFormat?
    public var imageQuality: MediaQuality?
    public var imageMetadata: MetadataHandling?
    public var audioFormat: AudioFormat?
    public var audioQuality: MediaQuality?
    public var audioMetadata: MetadataHandling?
    public var videoFormat: VideoFormat?
    /// Video has no metadata toggle yet (see `MediaItem.metadata`'s doc comment in the app).
    public var videoQuality: MediaQuality?

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case imageFormat, imageQuality, imageMetadata, audioFormat, audioQuality, audioMetadata, videoFormat, videoQuality
    }

    /// Settings saved by an older Tamp lack newer keys, which keep their nil default.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        imageFormat = try? container.decodeIfPresent(ImageFormat.self, forKey: .imageFormat)
        imageQuality = try? container.decodeIfPresent(MediaQuality.self, forKey: .imageQuality)
        imageMetadata = try? container.decodeIfPresent(MetadataHandling.self, forKey: .imageMetadata)
        audioFormat = try? container.decodeIfPresent(AudioFormat.self, forKey: .audioFormat)
        audioQuality = try? container.decodeIfPresent(MediaQuality.self, forKey: .audioQuality)
        audioMetadata = try? container.decodeIfPresent(MetadataHandling.self, forKey: .audioMetadata)
        videoFormat = try? container.decodeIfPresent(VideoFormat.self, forKey: .videoFormat)
        videoQuality = try? container.decodeIfPresent(MediaQuality.self, forKey: .videoQuality)
    }
}

/// Tamp's saved settings, stored as Codable values in UserDefaults.
/// UserDefaults is thread-safe, so the store can be used from any thread.
public final class SettingsStore: @unchecked Sendable {
    enum Key {
        static let archiveChoice = "archiveChoice"
        static let mediaChoice = "mediaChoice"
        static let recommendationGoal = "recommendationGoal"
        static let recentOutputDirectories = "recentOutputDirectories"
        static let unfinishedBatch = "unfinishedBatch"
    }

    /// How many output folders are remembered for the launch-time cleanup of partial files.
    public static let recentDirectoryLimit = 20

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Unreadable data (say, from a newer Tamp) falls back to the default.
    public var archiveChoice: ArchiveChoice {
        get { decode(ArchiveChoice.self, forKey: Key.archiveChoice) ?? .default }
        set { encode(newValue, forKey: Key.archiveChoice) }
    }

    /// Unreadable data falls back to an empty choice, the same as a fresh install.
    public var mediaChoice: MediaChoice {
        get { decode(MediaChoice.self, forKey: Key.mediaChoice) ?? MediaChoice() }
        set { encode(newValue, forKey: Key.mediaChoice) }
    }

    /// What the person wants most from "Recommend for me", asked once and
    /// remembered; nil until they've answered.
    public var recommendationGoal: RecommendationGoal? {
        get { decode(RecommendationGoal.self, forKey: Key.recommendationGoal) }
        set {
            if let newValue { encode(newValue, forKey: Key.recommendationGoal) }
            else { defaults.removeObject(forKey: Key.recommendationGoal) }
        }
    }

    /// The saved choice, with the format swapped for the first available one
    /// if this build can't write it.
    public func archiveChoice(availableFormats: [ArchiveFormat]) -> ArchiveChoice {
        var choice = archiveChoice
        if !availableFormats.contains(choice.format) {
            choice.format = availableFormats.contains(ArchiveChoice.default.format)
                ? ArchiveChoice.default.format
                : availableFormats.first ?? ArchiveChoice.default.format
        }
        return choice
    }

    /// Folders Tamp recently wrote into, most recent first.
    public var recentOutputDirectories: [URL] {
        (decode([String].self, forKey: Key.recentOutputDirectories) ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    public func noteOutputDirectory(_ directory: URL) {
        let path = directory.standardizedFileURL.path
        var paths = recentOutputDirectories.map(\.path).filter { $0 != path }
        paths.insert(path, at: 0)
        encode(Array(paths.prefix(Self.recentDirectoryLimit)), forKey: Key.recentOutputDirectories)
    }

    /// Archives a stopped batch hadn't started, so Resume can pick up where it
    /// stopped, even after a relaunch. Empty when there's nothing to resume.
    public var unfinishedBatch: [URL] {
        get { (decode([String].self, forKey: Key.unfinishedBatch) ?? []).map { URL(fileURLWithPath: $0) } }
        set {
            if newValue.isEmpty {
                defaults.removeObject(forKey: Key.unfinishedBatch)
            } else {
                encode(newValue.map(\.path), forKey: Key.unfinishedBatch)
            }
        }
    }

    private func decode<Value: Decodable>(_ type: Value.Type, forKey key: String) -> Value? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func encode(_ value: some Encodable, forKey key: String) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
    }
}
