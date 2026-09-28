import CoreGraphics
import ImageIO
import XCTest
@testable import TampCore

/// Base for tests that run real helpers. Skipped when a helper isn't built, unless
/// TAMP_REQUIRE_HELPERS=1 (as in CI), where a missing helper is a failure.
/// Each test gets a fresh workspace with a sample "Project" folder and an "Output" folder.
class EngineTestCase: XCTestCase {
    var workspace: URL!
    var project: URL!
    var output: URL!
    let fileManager = FileManager.default

    /// Helpers the subclass needs.
    var requiredHelpers: [String] { [] }

    override func setUpWithError() throws {
        for helper in requiredHelpers {
            do {
                _ = try HelperLocator.standard.url(for: helper)
            } catch {
                if ProcessInfo.processInfo.environment["TAMP_REQUIRE_HELPERS"] == "1" { throw error }
                throw XCTSkip("\(helper) isn't built. Run scripts/build-helpers.sh and set TAMP_HELPERS_DIR.")
            }
        }
        workspace = fileManager.temporaryDirectory.appendingPathComponent("\(type(of: self))-\(UUID().uuidString)")
        project = workspace.appendingPathComponent("Project")
        output = workspace.appendingPathComponent("Output")
        try fileManager.createDirectory(at: project.appendingPathComponent("data"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: project.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: output, withIntermediateDirectories: true)
        try Data(String(repeating: "Tamp compresses text well. ", count: 2000).utf8)
            .write(to: project.appendingPathComponent("readme.txt"))
        try Self.randomData(count: 1 << 20).write(to: project.appendingPathComponent("data/random.bin"))
        try Data("junk".utf8).write(to: project.appendingPathComponent(".DS_Store"))
        try Data("junk".utf8).write(to: project.appendingPathComponent("._readme.txt"))
    }

    override func tearDownWithError() throws {
        if let workspace { try? fileManager.removeItem(at: workspace) }
    }

    /// Incompressible bytes; `count` is rounded down to a multiple of 8.
    static func randomData(count: Int) -> Data {
        var data = Data(count: count / 8 * 8)
        data.withUnsafeMutableBytes { buffer in
            var generator = SystemRandomNumberGenerator()
            let words = buffer.bindMemory(to: UInt64.self)
            for index in words.indices { words[index] = generator.next() }
        }
        return data
    }

    func contents(of directory: URL) throws -> [String] {
        try fileManager.contentsOfDirectory(atPath: directory.path).sorted()
    }

    /// A fresh folder in the workspace to extract into.
    func makeFolder(_ name: String) throws -> URL {
        let folder = workspace.appendingPathComponent(name)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// A fresh copy of the test corpus (see Corpus/README.md) plus what git can't
    /// hold: an empty folder, an executable script and a symlink to it.
    func makeCorpus(named name: String = "Corpus") throws -> URL {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "Corpus", withExtension: nil), "the corpus isn't in the test bundle")
        let corpus = workspace.appendingPathComponent(name)
        try fileManager.copyItem(at: source, to: corpus)
        try fileManager.createDirectory(at: corpus.appendingPathComponent("documents/empty folder"), withIntermediateDirectories: false)
        let tools = corpus.appendingPathComponent("tools")
        try fileManager.createDirectory(at: tools, withIntermediateDirectories: false)
        let script = tools.appendingPathComponent("run.sh")
        try Data("#!/bin/sh\necho Tamp\n".utf8).write(to: script)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try fileManager.createSymbolicLink(atPath: tools.appendingPathComponent("latest").path, withDestinationPath: "run.sh")
        return corpus
    }

    /// Checks that two folders hold the same names, kinds, bytes, symlink targets
    /// and executable bits. Other permission bits depend on the umask, so they're ignored.
    func assertTreesEqual(_ original: URL, _ copy: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let expected = try treeEntries(at: original)
        let actual = try treeEntries(at: copy)
        XCTAssertEqual(actual.keys.sorted(), expected.keys.sorted(), "different items", file: file, line: line)
        for (key, entry) in expected {
            guard let other = actual[key] else { continue }
            XCTAssertEqual(other.kind, entry.kind, "\(key) changed kind", file: file, line: line)
            XCTAssertEqual(other.executableBits, entry.executableBits, "\(key) changed its executable bits", file: file, line: line)
            XCTAssertEqual(other.linkTarget, entry.linkTarget, "\(key) points elsewhere", file: file, line: line)
            if entry.kind == .typeRegular {
                XCTAssertTrue(fileManager.contentsEqual(atPath: entry.path, andPath: other.path), "\(key) differs", file: file, line: line)
            }
        }
    }

    struct TreeEntry {
        var path: String
        var kind: FileAttributeType
        var executableBits: Int
        var linkTarget: String?
    }

    /// Every item under `root` by relative path (Unicode-normalized, since file
    /// systems and archivers may store either form), without following symlinks.
    func treeEntries(at root: URL) throws -> [String: TreeEntry] {
        var entries: [String: TreeEntry] = [:]
        for relative in try fileManager.subpathsOfDirectory(atPath: root.path) {
            let path = root.appendingPathComponent(relative).path
            let attributes = try fileManager.attributesOfItem(atPath: path)
            let kind = attributes[.type] as? FileAttributeType ?? .typeUnknown
            entries[relative.precomposedStringWithCanonicalMapping] = TreeEntry(
                path: path,
                kind: kind,
                executableBits: (attributes[.posixPermissions] as? Int ?? 0) & 0o111,
                linkTarget: kind == .typeSymbolicLink ? try fileManager.destinationOfSymbolicLink(atPath: path) : nil
            )
        }
        return entries
    }

    func assertMatchesProject(_ extracted: URL, file: StaticString = #filePath, line: UInt = #line) {
        for relative in ["readme.txt", "data/random.bin"] {
            XCTAssertTrue(
                fileManager.contentsEqual(
                    atPath: project.appendingPathComponent(relative).path,
                    andPath: extracted.appendingPathComponent(relative).path
                ),
                "\(relative) differs after the round trip", file: file, line: line
            )
        }
        var isDirectory: ObjCBool = false
        XCTAssertTrue(fileManager.fileExists(atPath: extracted.appendingPathComponent("empty").path, isDirectory: &isDirectory) && isDirectory.boolValue,
                      "empty folder is missing", file: file, line: line)
        XCTAssertFalse(fileManager.fileExists(atPath: extracted.appendingPathComponent(".DS_Store").path), file: file, line: line)
        XCTAssertFalse(fileManager.fileExists(atPath: extracted.appendingPathComponent("._readme.txt").path), file: file, line: line)
    }

    /// Draws an image into a fixed RGBA buffer, so an image engine's round-trip
    /// tests compare decoded pixels rather than the compressed bytes an engine is
    /// free to rearrange or, for JPEG, re-entropy-code.
    func decodedPixels(of url: URL) throws -> Data {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw TampError.other("couldn't decode \(url.lastPathComponent)")
        }
        let width = image.width, height = image.height
        var buffer = Data(count: width * height * 4)
        try buffer.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { throw TampError.other("couldn't create a bitmap context") }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return buffer
    }
}
