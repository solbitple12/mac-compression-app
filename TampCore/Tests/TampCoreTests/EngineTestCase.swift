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
}
