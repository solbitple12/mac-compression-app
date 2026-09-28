import Foundation

/// ZPAQ settings for the bundled zpaq helper.
public struct ZpaqParameters: Equatable, Sendable {
    /// zpaq's -m: 0 only deduplicates, 5 is the slowest context mixing.
    public var method: Int
    public var threads: Int

    public var arguments: [String] {
        ["-m\(method)", "-threads", "\(threads)"]
    }
}

public struct ZpaqMapping: SpeedStepMapping {
    public init() {}

    public var format: ArchiveFormat { .zpaq }
    public var capabilities: EngineCapabilities { [.multithreading] }

    public func parameters(for step: SpeedStep, options: ArchiveOptions) -> ZpaqParameters {
        ZpaqParameters(method: step.rawValue, threads: options.threads)
    }

    public func hint(for step: SpeedStep, options: ArchiveOptions) -> StepHint {
        let parameters = parameters(for: step, options: options)
        var notes = ["Only zpaq and a few apps such as PeaZip open this", "Symbolic links aren't kept"]
        if step >= .good { notes.insert("\(step.title) is very slow: expect under 1 MB/s per thread", at: 0) }
        return StepHint(
            step: step,
            summary: step.summary,
            peakMemoryBytes: Self.memory(for: parameters),
            outputExtension: format.fileExtension,
            notes: notes
        )
    }

    /// Peaks measured on 12 MB of text with zpaq 7.15 on Linux, per thread, since
    /// each thread compresses its own block. The Phase 2a benchmark refines them.
    static func memory(for parameters: ZpaqParameters) -> UInt64 {
        let threads = UInt64(max(1, parameters.threads))
        let perThread: UInt64 = switch parameters.method {
        case ...0: 32
        case 1: 90
        case 2: 80
        case 3: 72
        case 4: 130
        default: 500
        }
        return threads * perThread * .mebibyte
    }
}

/// ZPAQ through the bundled zpaq helper. zpaq keeps folders, file contents,
/// executable bits and timestamps to the second, but not symbolic links.
public struct ZpaqEngine: ArchiveEngine {
    static let helperName = "zpaq"
    static let junkExclusions = ["-not", "*/.DS_Store", "*/._*", "*/__MACOSX", "*/__MACOSX/*"]
    /// ZPAQ's journaling archives start with this locator tag; encrypted ones start
    /// with random salt instead.
    static let signature: [UInt8] = [0x37, 0x6B, 0x53, 0x74, 0xA0, 0x31, 0x83, 0xD3, 0x8C, 0xB2, 0x28, 0xB0, 0xD3]

    private let mapping = ZpaqMapping()
    private let runner: ProcessRunner
    private let helpers: HelperLocator

    public init(runner: ProcessRunner = ProcessRunner(), helpers: HelperLocator = .standard) {
        self.runner = runner
        self.helpers = helpers
    }

    public var format: ArchiveFormat { mapping.format }
    public var capabilities: EngineCapabilities { mapping.capabilities }

    public func parameters(for step: SpeedStep, options: ArchiveOptions) -> ZpaqParameters {
        mapping.parameters(for: step, options: options)
    }

    public func hint(for step: SpeedStep, options: ArchiveOptions) -> StepHint {
        mapping.hint(for: step, options: options)
    }

    public func compress(_ request: CompressRequest, progress: @escaping ProgressHandler) async throws -> URL {
        if let password = request.password, !password.isEmpty {
            // zpaq takes a password only as an argument, which other processes can read.
            throw TampError.other("Tamp can't protect ZPAQ archives with a password yet. Choose 7Z or ZIP for that.")
        }
        let zpaq = try helpers.url(for: Self.helperName)
        // zpaq skips a missing input with a warning and still exits 0.
        for item in request.items where !FileManager.default.fileExists(atPath: item.path) {
            throw TampError.fileNotFound(path: item.path)
        }
        var destination = request.destination
        if destination.pathExtension.lowercased() != format.fileExtension {
            destination.appendPathExtension(format.fileExtension)
        }
        // -to stores each item under its own name instead of its full path.
        let names = request.items.map(Self.memberName)
        var arguments = parameters(for: request.step, options: request.options).arguments + ["-summary", "1"]
        if request.excludesMacOSJunk { arguments += Self.junkExclusions }

        return try await SafeOutput.write(to: destination, fileExtension: format.fileExtension) { temporary in
            try await run(zpaq, ["a", temporary.path] + request.items.map(\.path) + ["-to"] + names + arguments, progress: progress)
            guard FileManager.default.fileExists(atPath: temporary.path) else {
                throw TampError.fileNotFound(path: request.items.first?.path)
            }
        }
    }

    public func extract(_ request: ExtractRequest, progress: @escaping ProgressHandler) async throws -> URL {
        let zpaq = try helpers.url(for: Self.helperName)
        return try await SafeOutput.extract(
            into: request.destinationDirectory,
            baseName: request.archive.deletingPathExtension().lastPathComponent
        ) { staging in
            do {
                // The patched zpaq drops ".." from stored names, so nothing lands outside staging.
                try await run(zpaq, ["x", request.archive.path, "-to", staging.path], progress: progress)
            } catch TampError.wrongPassword where request.password == nil {
                // zpaq takes anything without its locator tag for an encrypted archive.
                throw Self.hasSignature(request.archive) ? TampError.corruptArchive : TampError.passwordRequired
            }
        }
    }

    private func run(_ zpaq: URL, _ arguments: [String], progress: @escaping ProgressHandler) async throws {
        let result = try await runner.run(zpaq, arguments: arguments) { line in
            if let fraction = Self.fraction(in: line) { progress(fraction) }
        }
        guard result.succeeded else {
            throw Self.error(exitCode: result.exitCode, standardError: result.standardError)
        }
    }

    /// Reads zpaq's "42.17% 0:01:05" progress lines.
    static func fraction(in line: String) -> Double? {
        let trimmed = line.drop { $0 == " " }
        guard let percent = trimmed.firstIndex(of: "%") else { return nil }
        let number = trimmed[..<percent]
        guard !number.isEmpty, number.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
              let value = Double(number), (0...100).contains(value) else { return nil }
        return value / 100
    }

    /// zpaq writes errors as "zpaq error: archive not found" and similar.
    static func error(exitCode: Int32, standardError: String) -> TampError {
        let text = standardError.lowercased()
        if text.contains("password incorrect") { return .wrongPassword }
        // A truncated journaling archive reads as holding no complete version.
        if text.contains("archive not found") { return .corruptArchive }
        if text.contains("bad_alloc") { return .outOfMemory }
        return TampError.classify(tool: "zpaq", exitCode: exitCode, standardError: standardError)
    }

    /// A leading dash would read as an option; "./-name" extracts as "-name".
    static func memberName(_ item: URL) -> String {
        let name = item.lastPathComponent
        return name.hasPrefix("-") ? "./\(name)" : name
    }

    static func hasSignature(_ archive: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: archive) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: signature.count)).map { Array($0) == signature } ?? false
    }
}
