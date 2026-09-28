import XCTest
@testable import TampCore

/// Detection, drop handling and naming. None of these run a helper, so they
/// use a registry whose helpers directory is empty.
final class ArchivePlannerTests: XCTestCase {
    private var folder: URL!
    private let registry = EngineRegistry.standard(helpers: HelperLocator(directories: []))
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        folder = fileManager.temporaryDirectory.appendingPathComponent("ArchivePlannerTests-\(UUID().uuidString)")
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: folder)
    }

    private func file(_ name: String, bytes: [UInt8]) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    private var tarHeader: [UInt8] {
        var header = [UInt8](repeating: 0, count: 512)
        header.replaceSubrange(257..<262, with: Array("ustar".utf8))
        return header
    }

    func testDetectsFormatsByTheirFirstBytes() throws {
        XCTAssertEqual(ArchiveDetector.format(of: try file("a.bin", bytes: [0x50, 0x4B, 0x03, 0x04, 0, 0])), .zip)
        XCTAssertEqual(ArchiveDetector.format(of: try file("empty.zip", bytes: [0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 18))), .zip)
        XCTAssertEqual(ArchiveDetector.format(of: try file("b", bytes: TarZstEngine.zstdMagic + [0, 0])), .tarZst)
        XCTAssertEqual(ArchiveDetector.format(of: try file("c.dat", bytes: tarHeader)), .tar)
    }

    func testIgnoresTheNameAndRejectsEverythingElse() throws {
        XCTAssertNil(ArchiveDetector.format(of: try file("fake.zip", bytes: Array("hello".utf8))))
        XCTAssertNil(ArchiveDetector.format(of: try file("zero.tar.zst", bytes: [])))
        XCTAssertNil(ArchiveDetector.format(of: try file("short.tar", bytes: Array(tarHeader.prefix(260)))))
        XCTAssertNil(ArchiveDetector.format(of: folder))
        XCTAssertNil(ArchiveDetector.format(of: folder.appendingPathComponent("missing")))
    }

    func testRegistryListsThePhaseOneFormatsInPickerOrder() {
        XCTAssertEqual(registry.availableFormats, [.zip, .tarZst])
        XCTAssertEqual(registry.engine(for: .zip)?.format, .zip)
        XCTAssertNil(registry.engine(for: .sevenZip))
    }

    func testPlainTarOpensWithTheTarZstEngine() throws {
        XCTAssertEqual(registry.extractor(for: try file("plain.tar", bytes: tarHeader))?.format, .tarZst)
        XCTAssertEqual(registry.extractor(for: try file("x.zip", bytes: [0x50, 0x4B, 0x03, 0x04]))?.format, .zip)
    }

    func testTheNameDecidesWhatCountsAsAnArchive() throws {
        let zipHeader: [UInt8] = [0x50, 0x4B, 0x03, 0x04, 0, 0]
        // Documents that are ZIP files inside are compressed, not taken apart.
        for name in ["Report.docx", "Sheet.xlsx", "Book.epub", "Talk.key", "App.jar"] {
            XCTAssertNil(registry.extractor(for: try file(name, bytes: zipHeader)), name)
        }
        // A lone .zst may not hold a tar.
        XCTAssertNil(registry.extractor(for: try file("dump.sql.zst", bytes: TarZstEngine.zstdMagic)))
        XCTAssertEqual(registry.extractor(for: try file("Logs.TZST", bytes: TarZstEngine.zstdMagic))?.format, .tarZst)
        // No extension: the first bytes decide.
        XCTAssertEqual(registry.extractor(for: try file("download", bytes: zipHeader))?.format, .zip)
        XCTAssertNil(registry.extractor(for: try file("stream", bytes: TarZstEngine.zstdMagic)))
        // An archive name with other contents isn't opened.
        XCTAssertNil(registry.extractor(for: try file("fake.zip", bytes: Array("hello".utf8))))
        // A misnamed archive opens with the engine its contents need.
        XCTAssertEqual(registry.extractor(for: try file("really-a-tar.zip", bytes: tarHeader))?.format, .tarZst)
    }

    func testFormatClaimedByTheName() {
        XCTAssertEqual(ArchiveDetector.format(ofName: URL(fileURLWithPath: "/a/B.ZIP")), .zip)
        XCTAssertEqual(ArchiveDetector.format(ofName: URL(fileURLWithPath: "/a/b.tar")), .tar)
        XCTAssertEqual(ArchiveDetector.format(ofName: URL(fileURLWithPath: "/a/b.tar.zst")), .tarZst)
        XCTAssertNil(ArchiveDetector.format(ofName: URL(fileURLWithPath: "/a/b.zst")))
        XCTAssertNil(ArchiveDetector.format(ofName: URL(fileURLWithPath: "/a/b.docx")))
    }

    func testArchivesAreExtractedAndEverythingElseCompressed() throws {
        let zip = try file("One.zip", bytes: [0x50, 0x4B, 0x03, 0x04])
        let zst = try file("Two.tar.zst", bytes: TarZstEngine.zstdMagic)
        let text = try file("notes.txt", bytes: Array("notes".utf8))
        let document = try file("Report.docx", bytes: [0x50, 0x4B, 0x03, 0x04])
        let subfolder = folder.appendingPathComponent("Photos")
        try fileManager.createDirectory(at: subfolder, withIntermediateDirectories: false)

        XCTAssertEqual(ArchivePlanner.action(for: [zip, zst], registry: registry), .extract([zip, zst]))
        XCTAssertEqual(ArchivePlanner.action(for: [zip, text], registry: registry), .compress([zip, text]))
        XCTAssertEqual(ArchivePlanner.action(for: [subfolder], registry: registry), .compress([subfolder]))
        XCTAssertEqual(ArchivePlanner.action(for: [document], registry: registry), .compress([document]))
        XCTAssertEqual(ArchivePlanner.action(for: [], registry: registry), .compress([]))
    }

    func testDestinationSitsBesideTheFirstItem() {
        let photos = URL(fileURLWithPath: "/Users/me/Pictures/Photos", isDirectory: true)
        let report = URL(fileURLWithPath: "/Users/me/Documents/report.pdf")
        XCTAssertEqual(ArchivePlanner.destination(for: [photos], format: .zip).path, "/Users/me/Pictures/Photos.zip")
        XCTAssertEqual(ArchivePlanner.destination(for: [report], format: .tarZst).path, "/Users/me/Documents/report.pdf.tar.zst")
        XCTAssertEqual(ArchivePlanner.destination(for: [report, photos], format: .zip).path, "/Users/me/Documents/Archive.zip")
    }

    func testDisplayNames() {
        let a = URL(fileURLWithPath: "/x/Photos")
        let b = URL(fileURLWithPath: "/x/notes.txt")
        XCTAssertEqual(ArchivePlanner.displayName(for: [a]), "“Photos”")
        XCTAssertEqual(ArchivePlanner.displayName(for: [a, b, b]), "“Photos” and 2 more")
    }
}
