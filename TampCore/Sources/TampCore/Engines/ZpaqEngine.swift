import Foundation

/// ZPAQ settings for the bundled zpaq helper.
public struct ZpaqParameters: Equatable, Sendable {
    /// zpaq's -m: 0 only deduplicates, 5 is the slowest context mixing.
    public var method: Int
    public var threads: Int
    /// Block size as log2 MiB, 0 to 11; nil keeps zpaq's (16 MiB at -m0 and -m1, 64 MiB above).
    public var blockLog: Int?

    public init(method: Int, threads: Int, blockLog: Int? = nil) {
        self.method = method
        self.threads = threads
        self.blockLog = blockLog
    }

    /// The block size in bytes.
    public var blockBytes: UInt64 {
        (1 << UInt64(blockLog.map { min(max($0, 0), 11) } ?? (method >= 2 ? 6 : 4))) * .mebibyte
    }

    public var arguments: [String] {
        let block = blockLog.map { "\(min(max($0, 0), 11))" } ?? ""
        return ["-m\(method)\(block)", "-threads", "\(threads)"]
    }
}

public struct ZpaqMapping: SpeedStepMapping {
    public init() {}

    public var format: ArchiveFormat { .zpaq }
    public var capabilities: EngineCapabilities { [.encryption, .multithreading] }

    public func parameters(for step: SpeedStep, options: ArchiveOptions) -> ZpaqParameters {
        ZpaqParameters(method: step.rawValue, threads: options.threads, blockLog: options.advanced.zpaqBlockLog)
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

    /// Per thread, since each thread compresses its own block: a fixed part plus a
    /// multiple of the block, fitted to single-thread peaks of zpaq 7.15 with full
    /// blocks of 72 MB of text (for example -m2 at 64 MiB blocks: 388 MB).
    static func memory(for parameters: ZpaqParameters) -> UInt64 {
        let threads = UInt64(max(1, parameters.threads))
        let blockMebibytes = parameters.blockBytes / .mebibyte
        let (fixed, perBlockMebibyte): (UInt64, UInt64) = switch parameters.method {
        case ...0: (40, 1)
        case 1: (44, 4)
        case 2: (24, 6)
        case 3, 4: (28, 5)
        default: (300, 6)
        }
        return threads * (fixed + perBlockMebibyte * blockMebibytes) * .mebibyte
    }
}

/// ZPAQ through the bundled zpaq helper. zpaq keeps folders, file contents,
/// executable bits and timestamps to the second, but not symbolic links.
/// Passwords (AES-256 over the whole archive) go to the patched zpaq on stdin via "-key -".
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
        try request.checkNamesAreUnique()
        let zpaq = try helpers.url(for: Self.helperName)
        // zpaq skips a missing input with a warning and still exits 0.
        for item in request.items where !FileManager.default.fileExists(atPath: item.path) {
            throw TampError.fileNotFound(path: item.path)
        }
        var destination = request.destination
        if destination.pathExtension.lowercased() != format.fileExtension {
            destination.appendPathExtension(format.fileExtension)
        }
        // -to stores each item under its own name instead of its full path. zpaq renames
        // by the first item whose path is a prefix, so longer paths go first: otherwise
        // "/u/Docs Old/report.pdf" would match "/u/Docs" and be stored as "Docs Old/report.pdf".
        let items = request.items.sorted { $0.path.count > $1.path.count }
        let names = items.map(Self.memberName)
        var arguments = parameters(for: request.step, options: request.options).arguments + ["-summary", "1"]
        if request.excludesMacOSJunk { arguments += Self.junkExclusions }
        let key = Self.keyArguments(request.password)
        arguments += key.arguments

        return try await SafeOutput.write(to: destination, fileExtension: format.fileExtension) { temporary in
            try await run(zpaq, ["a", temporary.path] + items.map(\.path) + ["-to"] + names + arguments,
                          input: key.input, progress: progress)
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
            let key = Self.keyArguments(request.password)
            do {
                // The patched zpaq drops ".." from stored names, so nothing lands outside staging.
                try await run(zpaq, ["x", request.archive.path, "-to", staging.path] + key.arguments,
                              input: key.input, progress: progress)
            } catch TampError.wrongPassword where key.input == nil {
                // zpaq takes anything without its locator tag for an encrypted archive.
                throw Self.hasSignature(request.archive) ? TampError.corruptArchive : TampError.passwordRequired
            }
        }
    }

    private func run(_ zpaq: URL, _ arguments: [String], input: Data?, progress: @escaping ProgressHandler) async throws {
        let result = try await runner.run(zpaq, arguments: arguments, standardInput: input) { line in
            if let fraction = Self.fraction(in: line) { progress(fraction) }
        }
        guard result.succeeded else {
            throw Self.error(exitCode: result.exitCode, standardError: result.standardError)
        }
    }

    /// "-key -" with the password as stdin's first line, or nothing without one.
    /// Like 7zz and minizip, zpaq stops reading at a line break, so the app allows none in passwords.
    static func keyArguments(_ password: String?) -> (arguments: [String], input: Data?) {
        guard let password, !password.isEmpty else { return ([], nil) }
        return (["-key", "-"], Data((password + "\n").utf8))
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
