import Foundation

/// Drives the bundled 7zz helper. Shared by the ZIP engine now and the 7Z engine in Phase 2a.
struct SevenZipTool: Sendable {
    static let helperName = "7zz"
    /// Errors to stderr, progress to stdout, no file listing.
    static let quietSwitches = ["-bso0", "-bsp1", "-bse2"]
    static let junkExclusions = ["-xr!.DS_Store", "-xr!._*", "-xr!__MACOSX"]

    let runner: ProcessRunner
    let helpers: HelperLocator

    /// Runs 7zz, forwarding its percentage lines. A password, when given, is sent
    /// on stdin in answer to 7zz's prompt, never as an argument.
    func run(_ arguments: [String], password: String?, progress: @escaping ProgressHandler) async throws {
        let executable = try helpers.url(for: Self.helperName)
        let input = password.map { Data(($0 + "\n").utf8) }
        let result = try await runner.run(executable, arguments: arguments, standardInput: input) { line in
            if let percent = Self.percent(in: line) { progress(Double(percent) / 100) }
        }
        guard result.succeeded else {
            throw TampError.classify(tool: "7-Zip", exitCode: result.exitCode, standardError: result.standardError)
        }
    }

    /// Reads the leading percentage of a 7zz progress line such as "42% 3 + photo.jpg".
    static func percent(in line: String) -> Int? {
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3,
              line.dropFirst(digits.count).first == "%",
              let value = Int(digits), value <= 100 else { return nil }
        return value
    }

    /// Extracts into a hidden staging folder beside the destination, then moves the
    /// result into place: a single top-level item directly, several items inside a
    /// folder named after the archive. Nothing is left behind on failure.
    func extract(_ request: ExtractRequest, archiveBaseName: String, progress: @escaping ProgressHandler) async throws -> URL {
        let fileManager = FileManager.default
        let preferred = request.destinationDirectory.appendingPathComponent(archiveBaseName, isDirectory: true)
        let staging = SafeOutput.temporaryURL(for: preferred)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        do {
            // No -p switch: 7zz asks for the password only if the archive needs one,
            // and reads the answer from stdin.
            try await run(
                ["x", request.archive.path, "-o\(staging.path)", "-y"] + Self.quietSwitches,
                password: request.password,
                progress: progress
            )
            try Task.checkCancellation()
            let children = try fileManager.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
            if children.count == 1, let only = children.first {
                let target = try SafeOutput.commitToAvailableName(
                    only,
                    preferring: request.destinationDirectory.appendingPathComponent(only.lastPathComponent),
                    fileExtension: only.pathExtension
                )
                try? fileManager.removeItem(at: staging)
                return target
            }
            return try SafeOutput.commitToAvailableName(staging, preferring: preferred, fileExtension: "")
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }
}
