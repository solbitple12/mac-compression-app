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
        XCTAssertEqual(ArchiveDetector.format(of: try file("b", bytes: ArchiveDetector.zstdMagic + [0, 0])), .tarZst)
        XCTAssertEqual(ArchiveDetector.format(of: try file("c.dat", bytes: tarHeader)), .tar)
        XCTAssertEqual(ArchiveDetector.format(of: try file("d", bytes: [0x1F, 0x8B, 8, 0])), .tarGz)
        XCTAssertEqual(ArchiveDetector.format(of: try file("e", bytes: Array("BZh9".utf8))), .tarBz2)
        XCTAssertEqual(ArchiveDetector.format(of: try file("f", bytes: [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00, 0])), .tarXz)
        XCTAssertEqual(ArchiveDetector.format(of: try file("g", bytes: [0x04, 0x22, 0x4D, 0x18, 0])), .tarLz4)
        XCTAssertEqual(ArchiveDetector.format(of: try file("h", bytes: Array("LZIP".utf8) + [1])), .tarLz)
        // "BZh" needs a block size digit after it.
        XCTAssertNil(ArchiveDetector.format(of: try file("i", bytes: Array("BZhx".utf8))))
    }

    func testATarWhoseFirstNameLooksLikeASignatureIsStillATar() throws {
        var header = tarHeader
        header.replaceSubrange(0..<5, with: Array("LZIP1".utf8))
        XCTAssertEqual(ArchiveDetector.format(of: try file("odd.tar", bytes: header)), .tar)
    }

    func testIgnoresTheNameAndRejectsEverythingElse() throws {
        XCTAssertNil(ArchiveDetector.format(of: try file("fake.zip", bytes: Array("hello".utf8))))
        XCTAssertNil(ArchiveDetector.format(of: try file("zero.tar.zst", bytes: [])))
        XCTAssertNil(ArchiveDetector.format(of: try file("short.tar", bytes: Array(tarHeader.prefix(260)))))
        XCTAssertNil(ArchiveDetector.format(of: folder))
        XCTAssertNil(ArchiveDetector.format(of: folder.appendingPathComponent("missing")))
    }

    func testRegistryListsItsFormatsInPickerOrder() {
        XCTAssertEqual(registry.availableFormats, [.zip, .tar, .tarGz, .tarBz2, .tarXz, .tarZst, .tarLz4, .tarLz, .tarBr])
        XCTAssertEqual(registry.engine(for: .zip)?.format, .zip)
        XCTAssertNil(registry.engine(for: .sevenZip))
    }

    func testTarFamilyArchivesOpenWithTheTarEngine() throws {
        XCTAssertEqual(registry.extractor(for: try file("plain.tar", bytes: tarHeader))?.format, .tar)
        XCTAssertEqual(registry.extractor(for: try file("a.tar.gz", bytes: [0x1F, 0x8B, 8, 0]))?.format, .tar)
        XCTAssertEqual(registry.extractor(for: try file("a.tgz", bytes: [0x1F, 0x8B, 8, 0]))?.format, .tar)
        XCTAssertEqual(registry.extractor(for: try file("a.tar.bz2", bytes: Array("BZh9".utf8)))?.format, .tar)
        XCTAssertEqual(registry.extractor(for: try file("a.txz", bytes: [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]))?.format, .tar)
        XCTAssertEqual(registry.extractor(for: try file("a.tar.lz4", bytes: [0x04, 0x22, 0x4D, 0x18]))?.format, .tar)
        XCTAssertEqual(registry.extractor(for: try file("a.tar.lz", bytes: Array("LZIP".utf8)))?.format, .tar)
        // Brotli has no signature, so the name alone counts.
        XCTAssertEqual(registry.extractor(for: try file("a.tar.br", bytes: [0x1B, 0x00]))?.format, .tar)
        // The compression needn't match the name: bsdtar recognizes it.
        XCTAssertEqual(registry.extractor(for: try file("xz-inside.tar.gz", bytes: [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]))?.format, .tar)
        XCTAssertEqual(registry.extractor(for: try file("x.zip", bytes: [0x50, 0x4B, 0x03, 0x04]))?.format, .zip)
    }

    func testTheNameDecidesWhatCountsAsAnArchive() throws {
        let zipHeader: [UInt8] = [0x50, 0x4B, 0x03, 0x04, 0, 0]
        // Documents that are ZIP files inside are compressed, not taken apart.
        for name in ["Report.docx", "Sheet.xlsx", "Book.epub", "Talk.key", "App.jar"] {
            XCTAssertNil(registry.extractor(for: try file(name, bytes: zipHeader)), name)
        }
        // A lone compressed file may not hold a tar.
        XCTAssertNil(registry.extractor(for: try file("dump.sql.zst", bytes: ArchiveDetector.zstdMagic)))
        XCTAssertNil(registry.extractor(for: try file("dump.sql.gz", bytes: [0x1F, 0x8B, 8, 0])))
        XCTAssertNil(registry.extractor(for: try file("page.html.br", bytes: [0x1B, 0x00])))
        XCTAssertEqual(registry.extractor(for: try file("Logs.TZST", bytes: ArchiveDetector.zstdMagic))?.format, .tar)
        // No extension: the first bytes decide.
        XCTAssertEqual(registry.extractor(for: try file("download", bytes: zipHeader))?.format, .zip)
        XCTAssertNil(registry.extractor(for: try file("stream", bytes: ArchiveDetector.zstdMagic)))
        XCTAssertNil(registry.extractor(for: try file("gzipped", bytes: [0x1F, 0x8B, 8, 0])))
        // An archive name with other contents isn't opened.
        XCTAssertNil(registry.extractor(for: try file("fake.zip", bytes: Array("hello".utf8))))
        // A misnamed archive opens with the engine its contents need.
        XCTAssertEqual(registry.extractor(for: try file("really-a-tar.zip", bytes: tarHeader))?.format, .tar)
    }

    func testFormatClaimedByTheName() {
        XCTAssertEqual(ArchiveDetector.format(ofName: URL(fileURLWithPath: "/a/B.ZIP")), .zip)
        XCTAssertEqual(ArchiveDetector.format(ofName: URL(fileURLWithPath: "/a/b.tar")), .tar)
        XCTAssertEqual(ArchiveDetector.format(ofName: URL(fileURLWithPath: "/a/b.tar.zst")), .tarZst)
        XCTAssertEqual(ArchiveDetector.format(ofName: URL(fileURLWithPath: "/a/b.TGZ")), .tarGz)
        XCTAssertEqual(ArchiveDetector.format(ofName: URL(fileURLWithPath: "/a/b.tar.bz2")), .tarBz2)
        XCTAssertEqual(ArchiveDetector.format(ofName: URL(fileURLWithPath: "/a/b.tbz")), .tarBz2)
        XCTAssertEqual(ArchiveDetector.format(ofName: URL(fileURLWithPath: "/a/b.tar.xz")), .tarXz)
        XCTAssertEqual(ArchiveDetector.format(ofName: URL(fileURLWithPath: "/a/b.tar.lz4")), .tarLz4)
        XCTAssertEqual(ArchiveDetector.format(ofName: URL(fileURLWithPath: "/a/b.tar.lz")), .tarLz)
        XCTAssertEqual(ArchiveDetector.format(ofName: URL(fileURLWithPath: "/a/b.tar.br")), .tarBr)
        XCTAssertNil(ArchiveDetector.format(ofName: URL(fileURLWithPath: "/a/b.zst")))
        XCTAssertNil(ArchiveDetector.format(ofName: URL(fileURLWithPath: "/a/b.gz")))
        XCTAssertNil(ArchiveDetector.format(ofName: URL(fileURLWithPath: "/a/.tar")))
        XCTAssertNil(ArchiveDetector.format(ofName: URL(fileURLWithPath: "/a/b.docx")))
    }

    func testArchivesAreExtractedAndEverythingElseCompressed() throws {
        let zip = try file("One.zip", bytes: [0x50, 0x4B, 0x03, 0x04])
        let zst = try file("Two.tar.zst", bytes: ArchiveDetector.zstdMagic)
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
