import XCTest
@testable import TampCore

final class SafeOutputTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("SafeOutputTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func contents() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    func testSuccessMovesOutputIntoPlace() async throws {
        let destination = directory.appendingPathComponent("Photos.tar.zst")
        let result = try await SafeOutput.write(to: destination, fileExtension: "tar.zst") { temporary in
            XCTAssertTrue(temporary.lastPathComponent.hasPrefix(SafeOutput.partialPrefix))
            try Data("archive".utf8).write(to: temporary)
        }
        XCTAssertEqual(result, destination)
        XCTAssertEqual(try contents(), ["Photos.tar.zst"])
        XCTAssertEqual(try Data(contentsOf: destination), Data("archive".utf8))
    }

    func testNeverOverwritesAnExistingFile() async throws {
        let destination = directory.appendingPathComponent("Photos.tar.zst")
        try Data("original".utf8).write(to: destination)
        let result = try await SafeOutput.write(to: destination, fileExtension: "tar.zst") { temporary in
            try Data("new".utf8).write(to: temporary)
        }
        XCTAssertEqual(result.lastPathComponent, "Photos 2.tar.zst")
        XCTAssertEqual(try Data(contentsOf: destination), Data("original".utf8))
    }

    func testFailureLeavesNoPartialFile() async throws {
        let destination = directory.appendingPathComponent("Docs.zip")
        do {
            _ = try await SafeOutput.write(to: destination, fileExtension: "zip") { temporary in
                try Data("half".utf8).write(to: temporary)
                throw TampError.diskFull
            }
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? TampError, .diskFull)
        }
        XCTAssertEqual(try contents(), [])
    }

    func testCancellationLeavesNoPartialFile() async throws {
        let destination = directory.appendingPathComponent("Docs.zip")
        let task = Task {
            try await SafeOutput.write(to: destination, fileExtension: "zip") { temporary in
                try Data("half".utf8).write(to: temporary)
                try await Task.sleep(for: .seconds(30))
            }
        }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        _ = await task.result
        XCTAssertEqual(try contents(), [])
    }

    func testFailedExtractionRemovesReadOnlyAndLockedLeftovers() async throws {
        struct Failure: Error {}
        let fileManager = FileManager.default
        do {
            _ = try await SafeOutput.extract(into: directory, baseName: "Disc") { staging in
                // What bsdtar leaves when it fails after restoring a read-only folder and a locked file.
                let folder = staging.appendingPathComponent("System")
                try fileManager.createDirectory(at: folder, withIntermediateDirectories: false)
                let locked = folder.appendingPathComponent("locked.txt")
                try Data("locked".utf8).write(to: locked)
                try fileManager.setAttributes([.immutable: true], ofItemAtPath: locked.path)
                let hidden = folder.appendingPathComponent("hidden")
                try fileManager.createDirectory(at: hidden, withIntermediateDirectories: false)
                try Data("x".utf8).write(to: hidden.appendingPathComponent("x.txt"))
                try fileManager.setAttributes([.posixPermissions: 0], ofItemAtPath: hidden.path)
                try fileManager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
                throw Failure()
            }
            XCTFail("Expected the failure")
        } catch is Failure {}
        XCTAssertEqual(try contents(), [])
    }

    func testVolumesMoveOutTogetherUnderAFreeName() async throws {
        let destination = directory.appendingPathComponent("Photos.7z")
        // "Photos.7z.002" is taken, so the parts become "Photos 2.7z.001" and so on.
        try Data("old".utf8).write(to: directory.appendingPathComponent("Photos.7z.002"))
        let first = try await SafeOutput.writeVolumes(to: destination, fileExtension: "7z") { folder, name in
            XCTAssertEqual(name, "Photos.7z")
            for part in ["001", "002", "003"] {
                try Data(part.utf8).write(to: folder.appendingPathComponent("\(name).\(part)"))
            }
        }
        XCTAssertEqual(first.lastPathComponent, "Photos 2.7z.001")
        XCTAssertEqual(try contents(), ["Photos 2.7z.001", "Photos 2.7z.002", "Photos 2.7z.003", "Photos.7z.002"])
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("Photos 2.7z.003")), Data("003".utf8))
    }

    func testFailedVolumesLeaveNothing() async throws {
        struct Failure: Error {}
        do {
            _ = try await SafeOutput.writeVolumes(to: directory.appendingPathComponent("Photos.zip"), fileExtension: "zip") { folder, name in
                try Data("part".utf8).write(to: folder.appendingPathComponent("\(name).001"))
                throw Failure()
            }
            XCTFail("Expected the failure")
        } catch is Failure {}
        XCTAssertEqual(try contents(), [])
    }

    func testCommitRefusesToReplace() throws {
        let source = directory.appendingPathComponent("a")
        let target = directory.appendingPathComponent("b")
        try Data("a".utf8).write(to: source)
        try Data("b".utf8).write(to: target)
        XCTAssertThrowsError(try SafeOutput.commit(source, to: target)) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .EEXIST)
        }
        XCTAssertEqual(try Data(contentsOf: target), Data("b".utf8))
    }

    func testAvailableNamesKeepCompoundExtensions() throws {
        let destination = directory.appendingPathComponent("Logs.tar.zst")
        try Data().write(to: destination)
        try Data().write(to: directory.appendingPathComponent("Logs 2.tar.zst"))
        XCTAssertEqual(SafeOutput.availableURL(for: destination, fileExtension: "tar.zst").lastPathComponent, "Logs 3.tar.zst")
    }

    func testRemovesStalePartialsOnly() throws {
        try Data().write(to: directory.appendingPathComponent("\(SafeOutput.partialPrefix)123-Old.zip"))
        try Data().write(to: directory.appendingPathComponent("Keep.zip"))
        XCTAssertEqual(SafeOutput.removeStalePartials(in: directory), 1)
        XCTAssertEqual(try contents(), ["Keep.zip"])
    }
}
