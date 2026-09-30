import XCTest
@testable import TampCore

/// A pure test of the `-slt` parser against a fixed, hand-written sample of
/// real 7zz output, so a change to the parsing logic is checked without
/// needing the helper - `ArchiveContentsListerEngineTests` below checks the
/// parser against the real binary's actual output.
final class ArchiveContentsListerParsingTests: XCTestCase {
    func testParsesFilesAndFolders() {
        let lines = [
            "Path = /tmp/Archive.zip",
            "Type = zip",
            "Physical Size = 1234",
            "Path = data",
            "Folder = +",
            "Size = 0",
            "Path = data/readme.txt",
            "Folder = -",
            "Size = 100",
            "Packed Size = 80",
            "Method = Deflate",
        ]
        let entries = ArchiveContentsLister.parseSevenZipTechnicalListing(lines)
        XCTAssertEqual(entries, [
            .init(path: "data", sizeBytes: nil, isDirectory: true),
            .init(path: "data/readme.txt", sizeBytes: 100, isDirectory: false),
        ])
    }

    func testEmptyArchiveHasNoEntries() {
        let lines = ["Path = /tmp/Empty.zip", "Type = zip", "Physical Size = 22"]
        XCTAssertEqual(ArchiveContentsLister.parseSevenZipTechnicalListing(lines), [])
    }

    func testIgnoresLinesWithoutAnEquals() {
        let lines = [
            "Listing archive: /tmp/Archive.zip",
            "----------",
            "Path = /tmp/Archive.zip",
            "Path = readme.txt",
            "Folder = -",
            "Size = 5",
        ]
        XCTAssertEqual(
            ArchiveContentsLister.parseSevenZipTechnicalListing(lines),
            [.init(path: "readme.txt", sizeBytes: 5, isDirectory: false)]
        )
    }
}

/// Runs the real 7zz and bsdtar helpers, so a change to the arguments or a
/// mismatch between the parser and what 7zz actually prints shows up here.
final class ArchiveContentsListerEngineTests: EngineTestCase {
    override var requiredHelpers: [String] { ["7zz", "bsdtar"] }
    private var registry: EngineRegistry!

    override func setUpWithError() throws {
        try super.setUpWithError()
        registry = .standard()
    }

    func testListsAZipArchiveWithSizes() async throws {
        let archive = try await ZipEngine().compress(
            CompressRequest(items: [project], destination: output.appendingPathComponent("Project.zip"), step: .fast),
            progress: { _ in }
        )
        XCTAssertTrue(ArchiveContentsLister.canList(archive, registry: registry))
        let entries = try await ArchiveContentsLister.list(archive, registry: registry)
        let readme = try XCTUnwrap(entries.first { $0.path == "Project/readme.txt" })
        XCTAssertFalse(readme.isDirectory)
        XCTAssertEqual(readme.sizeBytes, try Int64(project.appendingPathComponent("readme.txt").resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1))
        XCTAssertTrue(entries.contains { $0.path == "Project/data" && $0.isDirectory })
    }

    func testListsAPasswordProtectedArchive() async throws {
        let archive = try await ZipEngine().compress(
            CompressRequest(items: [project], destination: output.appendingPathComponent("Secret.zip"), step: .fast, password: "s3cret"),
            progress: { _ in }
        )
        let entries = try await ArchiveContentsLister.list(archive, registry: registry, password: "s3cret")
        XCTAssertTrue(entries.contains { $0.path == "Project/readme.txt" })
    }

    func testListsATarArchiveByPath() async throws {
        let archive = try await TarEngine(format: .tarZst).compress(
            CompressRequest(items: [project], destination: output.appendingPathComponent("Project.tar.zst"), step: .fast),
            progress: { _ in }
        )
        XCTAssertTrue(ArchiveContentsLister.canList(archive, registry: registry))
        let entries = try await ArchiveContentsLister.list(archive, registry: registry)
        XCTAssertTrue(entries.contains { $0.path == "Project/readme.txt" && !$0.isDirectory })
    }

    func testCannotListAZpaqArchive() async throws {
        let archive = try await ZpaqEngine().compress(
            CompressRequest(items: [project], destination: output.appendingPathComponent("Project.zpaq"), step: .fast),
            progress: { _ in }
        )
        XCTAssertFalse(ArchiveContentsLister.canList(archive, registry: registry))
        do {
            _ = try await ArchiveContentsLister.list(archive, registry: registry)
            XCTFail("Expected an error for a format Tamp can't list")
        } catch {
            // expected
        }
    }
}
