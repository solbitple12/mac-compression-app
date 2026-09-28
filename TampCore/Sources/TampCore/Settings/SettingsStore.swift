import Foundation

/// The format, speed step and inner methods last used, restored at launch.
public struct ArchiveChoice: Codable, Equatable, Sendable {
    public var format: ArchiveFormat
    public var step: SpeedStep
    /// The method last chosen for each format that has several, keyed by the format's raw value.
    private var methods: [String: CompressionMethod]

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
        ArchiveOptions(method: method(for: format))
    }

    private enum CodingKeys: String, CodingKey {
        case format, step, methods
    }

    /// Settings saved before inner methods existed have no "methods".
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = try container.decode(ArchiveFormat.self, forKey: .format)
        step = try container.decode(SpeedStep.self, forKey: .step)
        methods = (try? container.decodeIfPresent([String: CompressionMethod].self, forKey: .methods)) ?? [:]
    }
}

/// Tamp's saved settings, stored as Codable values in UserDefaults.
/// UserDefaults is thread-safe, so the store can be used from any thread.
public final class SettingsStore: @unchecked Sendable {
    enum Key {
        static let archiveChoice = "archiveChoice"
        static let recentOutputDirectories = "recentOutputDirectories"
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
