import Foundation

/// The format and speed step last used, restored at launch.
public struct ArchiveChoice: Codable, Equatable, Sendable {
    public var format: ArchiveFormat
    public var step: SpeedStep

    public init(format: ArchiveFormat, step: SpeedStep) {
        self.format = format
        self.step = step
    }

    public static let `default` = ArchiveChoice(format: .zip, step: .normal)
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
