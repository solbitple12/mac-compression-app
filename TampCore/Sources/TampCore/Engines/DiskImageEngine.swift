import Foundation

/// Disk image settings for `hdiutil create -srcfolder`.
public struct DiskImageParameters: Equatable, Sendable {
    /// hdiutil's image format: UDRO read-only, UDZO zlib, ULFO LZFSE, ULMO LZMA.
    public var imageFormat: String
    /// UDZO only.
    public var zlibLevel: Int?

    public var arguments: [String] {
        ["-format", imageFormat] + (zlibLevel.map { ["-imagekey", "zlib-level=\($0)"] } ?? [])
    }
}

public struct DiskImageMapping: SpeedStepMapping {
    public init() {}

    public var format: ArchiveFormat { .dmg }
    public var capabilities: EngineCapabilities { [.encryption] }

    public func parameters(for step: SpeedStep, options: ArchiveOptions) -> DiskImageParameters {
        switch step {
        case .store: DiskImageParameters(imageFormat: "UDRO")
        case .fastest: DiskImageParameters(imageFormat: "UDZO", zlibLevel: 1)
        case .fast: DiskImageParameters(imageFormat: "ULFO")
        case .normal: DiskImageParameters(imageFormat: "UDZO", zlibLevel: 6)
        case .good: DiskImageParameters(imageFormat: "UDZO", zlibLevel: 9)
        case .best: DiskImageParameters(imageFormat: "ULMO")
        }
    }

    public func hint(for step: SpeedStep, options: ArchiveOptions) -> StepHint {
        let parameters = parameters(for: step, options: options)
        return StepHint(
            step: step,
            summary: step.summary,
            peakMemoryBytes: (parameters.imageFormat == "ULMO" ? 160 : 64) * .mebibyte,
            outputExtension: format.fileExtension,
            notes: ["Opens only on a Mac, which mounts it like a drive"]
        )
    }
}

/// Disk images through macOS's own hdiutil. Creating copies the items into a
/// fresh volume named after the image; opening mounts the image read-only out of
/// sight, copies its contents out with ditto and unmounts it. Passwords (AES-256)
/// go to hdiutil on stdin. hdiutil can't leave out .DS_Store files, which a disk
/// image, opened only on Macs, is expected to have anyway.
public struct DiskImageEngine: ArchiveEngine {
    static let hdiutil = URL(fileURLWithPath: "/usr/bin/hdiutil")
    static let ditto = URL(fileURLWithPath: "/usr/bin/ditto")
    /// Folders macOS keeps at the top of a volume, which aren't part of its contents.
    static let volumeHousekeeping: Set<String> = [
        ".fseventsd", ".Trashes", ".Spotlight-V100", ".TemporaryItems", ".DocumentRevisions-V100", ".DS_Store",
    ]
    /// UDIF images end with a 512-byte trailer that starts with "koly"; encrypted
    /// images start with "encrcdsa" instead.
    static let trailerMagic = Array("koly".utf8)
    static let encryptedMagic = Array("encrcdsa".utf8)

    private let mapping = DiskImageMapping()
    private let runner: ProcessRunner

    public init(runner: ProcessRunner = ProcessRunner()) {
        self.runner = runner
    }

    public var format: ArchiveFormat { mapping.format }
    public var capabilities: EngineCapabilities { mapping.capabilities }

    public func parameters(for step: SpeedStep, options: ArchiveOptions) -> DiskImageParameters {
        mapping.parameters(for: step, options: options)
    }

    public func hint(for step: SpeedStep, options: ArchiveOptions) -> StepHint {
        mapping.hint(for: step, options: options)
    }

    public func compress(_ request: CompressRequest, progress: @escaping ProgressHandler) async throws -> URL {
        try request.checkNamesAreUnique()
        for item in request.items where !FileManager.default.fileExists(atPath: item.path) {
            throw TampError.fileNotFound(path: item.path)
        }
        var destination = request.destination
        if destination.pathExtension.lowercased() != format.fileExtension {
            destination.appendPathExtension(format.fileExtension)
        }
        let volumeName = String(destination.deletingPathExtension().lastPathComponent.prefix(60))
        var arguments = ["create", "-puppetstrings", "-volname", volumeName]
            + parameters(for: request.step, options: request.options).arguments
        // One -srcfolder copies that folder's contents to the top of the volume;
        // several put each item there.
        for item in request.items { arguments += ["-srcfolder", item.path] }
        let password = request.password.flatMap { $0.isEmpty ? nil : $0 }
        if password != nil { arguments += ["-encryption", "AES-256", "-stdinpass"] }

        return try await SafeOutput.write(to: destination, fileExtension: format.fileExtension) { temporary in
            try await run(arguments + ["-o", temporary.path], password: password, progress: progress)
        }
    }

    public func extract(_ request: ExtractRequest, progress: @escaping ProgressHandler) async throws -> URL {
        let mountRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("tamp-mount-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: mountRoot, withIntermediateDirectories: true)
        let runner = runner
        var device: String?
        do {
            let result = try await SafeOutput.extract(
                into: request.destinationDirectory,
                baseName: request.archive.deletingPathExtension().lastPathComponent
            ) { staging in
                let attached = try await attach(request.archive, under: mountRoot, password: request.password)
                device = attached.device
                try await copyContents(of: attached.mountPoints, to: staging, progress: progress)
            }
            await Self.detach(device, runner: runner)
            try? FileManager.default.removeItem(at: mountRoot)
            return result
        } catch {
            await Self.detach(device, runner: runner)
            try? FileManager.default.removeItem(at: mountRoot)
            throw error
        }
    }

    /// Mounts the image read-only, hidden from Finder, under `root`.
    private func attach(_ image: URL, under root: URL, password: String?) async throws -> (device: String?, mountPoints: [URL]) {
        let plist = OutputBuffer()
        let arguments = ["attach", image.path, "-nobrowse", "-readonly", "-noautoopen",
                         "-mountrandom", root.path, "-plist", "-stdinpass"]
        // Always -stdinpass, so an encrypted image never brings up a password dialog.
        let input = Data((password ?? "").utf8) + Data([0])
        let result = try await runner.run(Self.hdiutil, arguments: arguments, standardInput: input) { line in
            plist.append(line)
        }
        guard result.succeeded else {
            let error = Self.error(exitCode: result.exitCode, standardError: result.standardError)
            if error == .wrongPassword, password?.isEmpty ?? true { throw TampError.passwordRequired }
            throw error
        }
        let entities = (try? PropertyListSerialization.propertyList(from: Data(plist.text.utf8), format: nil))
            .flatMap { $0 as? [String: Any] }?["system-entities"] as? [[String: Any]] ?? []
        let device = entities.lazy.compactMap { $0["dev-entry"] as? String }.first
        let mountPoints = entities.compactMap { $0["mount-point"] as? String }.map { URL(fileURLWithPath: $0, isDirectory: true) }
        guard !mountPoints.isEmpty else {
            await Self.detach(device, runner: runner)
            throw TampError.other("The disk image holds no volume Tamp can open.")
        }
        return (device, mountPoints)
    }

    private func copyContents(of volumes: [URL], to staging: URL, progress: @escaping ProgressHandler) async throws {
        let fileManager = FileManager.default
        let items = volumes.flatMap { volume in
            ((try? fileManager.contentsOfDirectory(atPath: volume.path)) ?? [])
                .filter { !Self.volumeHousekeeping.contains($0) }
                .map { volume.appendingPathComponent($0) }
        }
        let total = max(1, InputSize.totalBytes(of: items))
        var copied: Int64 = 0
        for item in items {
            let target = staging.appendingPathComponent(item.lastPathComponent)
            guard !fileManager.fileExists(atPath: target.path) else { continue }
            // ditto keeps permissions, dates, extended attributes, ACLs and links.
            let result = try await runner.run(Self.ditto, arguments: [item.path, target.path])
            guard result.succeeded else {
                throw TampError.classify(tool: "ditto", exitCode: result.exitCode, standardError: result.standardError)
            }
            copied += InputSize.totalBytes(of: [item])
            progress(Double(copied) / Double(total))
        }
    }

    /// Unmounts even when the job was cancelled: a detached task doesn't inherit
    /// the cancellation that would stop hdiutil at once.
    static func detach(_ device: String?, runner: ProcessRunner) async {
        guard let device else { return }
        await Task.detached {
            let result = try? await runner.run(Self.hdiutil, arguments: ["detach", device, "-quiet"])
            if result?.succeeded != true {
                _ = try? await runner.run(Self.hdiutil, arguments: ["detach", device, "-force", "-quiet"])
            }
        }.value
    }

    private func run(_ arguments: [String], password: String?, progress: @escaping ProgressHandler) async throws {
        let input = password.map { Data($0.utf8) + Data([0]) }
        let result = try await runner.run(Self.hdiutil, arguments: arguments, standardInput: input) { line in
            if let fraction = Self.fraction(in: line) { progress(fraction) }
        }
        guard result.succeeded else {
            throw Self.error(exitCode: result.exitCode, standardError: result.standardError)
        }
    }

    /// Reads -puppetstrings lines such as "PERCENT:24.509804". -1 means hdiutil can't tell.
    static func fraction(in line: String) -> Double? {
        guard line.hasPrefix("PERCENT:"), let value = Double(line.dropFirst("PERCENT:".count)),
              (0...100).contains(value) else { return nil }
        return value / 100
    }

    static func error(exitCode: Int32, standardError: String) -> TampError {
        let text = standardError.lowercased()
        if text.contains("authentication error") { return .wrongPassword }
        if text.contains("not recognized") || text.contains("checksum") || text.contains("image data corrupted") {
            return .corruptArchive
        }
        return TampError.classify(tool: "hdiutil", exitCode: exitCode, standardError: standardError)
    }

    /// A UDIF trailer at the end, or the header of an encrypted image at the start.
    static func looksLikeDiskImage(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        if let start = try? handle.read(upToCount: encryptedMagic.count), Array(start) == encryptedMagic { return true }
        guard let size = try? handle.seekToEnd(), size >= 512 else { return false }
        try? handle.seek(toOffset: size - 512)
        return (try? handle.read(upToCount: trailerMagic.count)).map { Array($0) == trailerMagic } ?? false
    }
}

/// Collects a helper's output lines, from whichever queue delivers them.
final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.withLock { lines.append(line) }
    }

    var text: String {
        lock.withLock { lines.joined(separator: "\n") }
    }
}
