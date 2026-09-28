import XCTest
@testable import TampCore

/// RAR, CAB, ISO, CPIO and lone compressed files, which Tamp opens but doesn't write.
final class ReadOnlyEngineTests: EngineTestCase {
    override var requiredHelpers: [String] { ["7zz", "bsdtar", "bsdcat", "brotli", "zstd"] }

    /// A stored RAR 4 archive holding "Box/hello.txt", built by hand, since no free tool writes RAR.
    static let rarFixture = "UmFyIRoHAM+QcwAADQAAAAAAAACNSXTggCMAAAAAAAAAAAADAAAAAABgPF0UMAMA7UEAAEJveJXmdACALQAaAAAAGgAAAAMHLP3ZAGA8XRQwDQCkgQAAQm94L2hlbGxvLnR4dEhlbGxvIGZyb20gYSBSQVIgYXJjaGl2ZS4KxD17AEAHAA=="
    /// An uncompressed CAB holding "Box\hello.txt" and "Box\notes.txt", built by hand.
    static let cabFixture = "TVNDRgAAAACXAAAAAAAAACwAAAAAAAAAAwEBAAIAAAAAAAAAaAAAAAEAAAAaAAAAAAAAAAAAPFsAYCAAQm94XGhlbGxvLnR4dAANAAAAGgAAAAAAPFsAYCAAQm94XG5vdGVzLnR4dAAAAAAAJwAnAEhlbGxvIGZyb20gYSBDQUIgYXJjaGl2ZS4KU2Vjb25kIGZpbGUuCg=="

    private let registry = EngineRegistry.standard()

    private func fixture(_ base64: String, named name: String) throws -> URL {
        let url = output.appendingPathComponent(name)
        try XCTUnwrap(Data(base64Encoded: base64)).write(to: url)
        return url
    }

    private func extract(_ archive: URL, into name: String) async throws -> URL {
        let extractor = try XCTUnwrap(registry.extractor(for: archive), archive.lastPathComponent)
        XCTAssertNil(extractor.writableFormat)
        return try await extractor.extract(ExtractRequest(archive: archive, destinationDirectory: try makeFolder(name)), progress: { _ in })
    }

    /// Writes `format` ("iso9660" or "newc") with the bundled bsdtar.
    private func bsdtarArchive(of folder: URL, format: String, named name: String) async throws -> URL {
        let archive = output.appendingPathComponent(name)
        let bsdtar = try HelperLocator.standard.url(for: "bsdtar")
        let result = try await ProcessRunner().run(
            bsdtar, arguments: ["-c", "--format", format, "-f", archive.path, "-C", folder.deletingLastPathComponent().path, folder.lastPathComponent]
        )
        XCTAssertTrue(result.succeeded, result.standardError)
        return archive
    }

    func testRar() async throws {
        let archive = try fixture(Self.rarFixture, named: "Box.rar")
        let extracted = try await extract(archive, into: "RarOut")
        XCTAssertEqual(extracted.lastPathComponent, "Box")
        XCTAssertEqual(try String(contentsOf: extracted.appendingPathComponent("hello.txt"), encoding: .utf8), "Hello from a RAR archive.\n")
    }

    func testCab() async throws {
        let archive = try fixture(Self.cabFixture, named: "Box.cab")
        let extracted = try await extract(archive, into: "CabOut")
        XCTAssertEqual(extracted.lastPathComponent, "Box")
        XCTAssertEqual(try contents(of: extracted), ["hello.txt", "notes.txt"])
        XCTAssertEqual(try String(contentsOf: extracted.appendingPathComponent("notes.txt"), encoding: .utf8), "Second file.\n")
    }

    func testIsoKeepsLinksAndLeavesFilesWritable() async throws {
        let corpus = try makeCorpus()
        let archive = try await bsdtarArchive(of: corpus, format: "iso9660", named: "Corpus.iso")
        let extracted = try await extract(archive, into: "IsoOut")
        XCTAssertEqual(extracted.lastPathComponent, "Corpus")
        try assertTreesEqual(corpus, extracted)
        let mode = try fileManager.attributesOfItem(atPath: extracted.appendingPathComponent("documents").path)[.posixPermissions] as? Int
        XCTAssertEqual((mode ?? 0) & 0o200, 0o200, "extracted folders are writable")
    }

    func testCpioKeepsLinksAndModes() async throws {
        let corpus = try makeCorpus()
        let archive = try await bsdtarArchive(of: corpus, format: "newc", named: "Corpus.cpio")
        let extracted = try await extract(archive, into: "CpioOut")
        try assertTreesEqual(corpus, extracted)
    }

    func testDamagedReadOnlyArchivesFailCleanly() async throws {
        let archive = try fixture(Self.cabFixture, named: "Broken.cab")
        let data = try Data(contentsOf: archive)
        try data.prefix(60).write(to: archive)
        let target = try makeFolder("BrokenOut")
        do {
            _ = try await registry.extractor(for: archive)?.extract(ExtractRequest(archive: archive, destinationDirectory: target), progress: { _ in })
            XCTFail("Expected an error")
        } catch {
            XCTAssertNotNil(error as? TampError, "\(error)")
        }
        XCTAssertEqual(try contents(of: target), [])
    }

    func testLoneCompressedFilesBecomeTheFileTheyHold() async throws {
        let original = project.appendingPathComponent("readme.txt")
        // zstd goes through bsdcat, like gzip, bzip2, xz, lz4 and lzip; brotli through its own tool.
        for (suffix, tool, arguments) in [(".zst", "zstd", ["-q", "-c"]), (".br", "brotli", ["-c"])] {
            let compressed = output.appendingPathComponent("readme.txt\(suffix)")
            try await compressedData(tool: tool, arguments: arguments, input: original).write(to: compressed)
            let extracted = try await extract(compressed, into: "Lone\(suffix)")
            XCTAssertEqual(extracted.lastPathComponent, "readme.txt", suffix)
            XCTAssertTrue(fileManager.contentsEqual(atPath: original.path, andPath: extracted.path), suffix)
        }
    }

    /// Runs a compressor with stdout into a file, as a pipeline stage.
    private func compressedData(tool: String, arguments: [String], input: URL) async throws -> Data {
        let destination = workspace.appendingPathComponent("stream-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let sink = try FileHandle(forWritingTo: destination)
        let source = try FileHandle(forReadingFrom: input)
        let stdin = Pipe()
        let stage = ChildProcess(
            name: tool, executable: try HelperLocator.standard.url(for: tool), arguments: arguments,
            standardInput: stdin, standardOutput: sink, gracePeriod: 2
        )
        try await ProcessPipeline.run(stages: [stage], checkOrder: [stage], source: source, sink: stdin.fileHandleForWriting,
                                      totalBytes: 1, progress: { _ in })
        try sink.close()
        return try Data(contentsOf: destination)
    }

    func testALoneFileNeverReplacesAnExistingOne() async throws {
        let original = project.appendingPathComponent("readme.txt")
        let compressed = output.appendingPathComponent("readme.txt.zst")
        try await compressedData(tool: "zstd", arguments: ["-q", "-c"], input: original).write(to: compressed)
        try Data("keep me".utf8).write(to: output.appendingPathComponent("readme.txt"))
        let extracted = try await registry.extractor(for: compressed)?.extract(
            ExtractRequest(archive: compressed, destinationDirectory: output), progress: { _ in }
        )
        XCTAssertEqual(extracted?.lastPathComponent, "readme 2.txt")
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("readme.txt")), Data("keep me".utf8))
    }

    func testWorthTryingSevenZip() {
        XCTAssertTrue(ReadOnlyEngine.worthTryingSevenZip(after: .corruptArchive))
        XCTAssertTrue(ReadOnlyEngine.worthTryingSevenZip(after: .toolFailed(tool: "bsdtar", exitCode: 1, message: "")))
        XCTAssertFalse(ReadOnlyEngine.worthTryingSevenZip(after: .diskFull))
        XCTAssertFalse(ReadOnlyEngine.worthTryingSevenZip(after: .cancelled))
    }
}
