import XCTest
@testable import TampCore

final class SevenZipEngineTests: EngineTestCase {
    private var engine: SevenZipEngine!

    override var requiredHelpers: [String] { ["7zz"] }

    override func setUpWithError() throws {
        try super.setUpWithError()
        engine = SevenZipEngine()
    }

    /// The method 7zz reports for the archive's first compressed file, such as "LZMA2:22".
    private func storedMethod(of archive: URL, password: String? = nil) async throws -> String {
        let arguments = ["l", "-slt", archive.path] + (password.map { ["-p\($0)"] } ?? [])
        let lines = LineRecorder()
        let result = try await ProcessRunner().run(try HelperLocator.standard.url(for: "7zz"), arguments: arguments) { lines.append($0) }
        XCTAssertTrue(result.succeeded, result.standardError)
        let methods = lines.all.filter { $0.hasPrefix("Method = ") }.map { String($0.dropFirst("Method = ".count)) }
        // The first "Method" line describes the whole archive; entries follow.
        return methods.first { !$0.isEmpty } ?? ""
    }

    func testRoundTripIsByteForByteAtEveryStep() async throws {
        for step in SpeedStep.allCases {
            let archive = try await engine.compress(
                CompressRequest(items: [project], destination: output.appendingPathComponent("Project-\(step.title).7z"), step: step,
                                options: ArchiveOptions(threads: 2)),
                progress: { _ in }
            )
            let extracted = try await engine.extract(
                ExtractRequest(archive: archive, destinationDirectory: try makeFolder("Out-\(step.title)")),
                progress: { _ in }
            )
            XCTAssertEqual(extracted.lastPathComponent, "Project")
            assertMatchesProject(extracted)
        }
    }

    func testEveryMethodRoundTripsAndIsStoredAsChosen() async throws {
        let expected: [CompressionMethod: String] = [.lzma2: "LZMA2:", .lzma: "LZMA:", .ppmd: "PPMD", .bzip2: "BZip2", .deflate: "Deflate"]
        for method in ArchiveFormat.sevenZip.methods {
            let archive = try await engine.compress(
                CompressRequest(items: [project], destination: output.appendingPathComponent("\(method.title).7z"), step: .fast,
                                options: ArchiveOptions(threads: 2, method: method)),
                progress: { _ in }
            )
            let stored = try await storedMethod(of: archive)
            XCTAssertTrue(stored.split(separator: " ").contains { $0.hasPrefix(expected[method] ?? "?") }, "\(method.title) was stored as \(stored)")
            let extracted = try await engine.extract(
                ExtractRequest(archive: archive, destinationDirectory: try makeFolder("Out-\(method.title)")),
                progress: { _ in }
            )
            assertMatchesProject(extracted)
        }
    }

    func testHigherStepsAreNotLarger() async throws {
        func size(_ step: SpeedStep) async throws -> Int {
            let archive = try await engine.compress(
                CompressRequest(items: [project], destination: output.appendingPathComponent("Size-\(step.title).7z"), step: step),
                progress: { _ in }
            )
            return try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        }
        let store = try await size(.store)
        let normal = try await size(.normal)
        let best = try await size(.best)
        XCTAssertLessThan(normal, store)
        XCTAssertLessThanOrEqual(best, normal)
    }

    func testPasswordHidesTheNamesToo() async throws {
        let archive = try await engine.compress(
            CompressRequest(items: [project], destination: output.appendingPathComponent("Secret.7z"), step: .normal, password: "7z secret"),
            progress: { _ in }
        )
        // With the headers encrypted, even listing needs the password.
        let listing = try await ProcessRunner().run(try HelperLocator.standard.url(for: "7zz"), arguments: ["l", archive.path, "-p"])
        XCTAssertFalse(listing.succeeded)

        let target = try makeFolder("Locked")
        do {
            _ = try await engine.extract(ExtractRequest(archive: archive, destinationDirectory: target), progress: { _ in })
            XCTFail("Expected a password-required error")
        } catch {
            XCTAssertEqual(error as? TampError, .passwordRequired)
        }
        do {
            _ = try await engine.extract(ExtractRequest(archive: archive, destinationDirectory: target, password: "wrong"), progress: { _ in })
            XCTFail("Expected a wrong-password error")
        } catch {
            XCTAssertEqual(error as? TampError, .wrongPassword)
        }
        XCTAssertEqual(try contents(of: target), [])

        let extracted = try await engine.extract(
            ExtractRequest(archive: archive, destinationDirectory: try makeFolder("Unlocked"), password: "7z secret"),
            progress: { _ in }
        )
        assertMatchesProject(extracted)
    }

    func testNeverOverwritesAnExistingArchive() async throws {
        let destination = output.appendingPathComponent("Project.7z")
        try Data("keep me".utf8).write(to: destination)
        let archive = try await engine.compress(CompressRequest(items: [project], destination: destination, step: .fastest), progress: { _ in })
        XCTAssertEqual(archive.lastPathComponent, "Project 2.7z")
        XCTAssertEqual(try Data(contentsOf: destination), Data("keep me".utf8))
    }

    func testTheRegistryOpens7zFiles() async throws {
        let archive = try await engine.compress(
            CompressRequest(items: [project], destination: output.appendingPathComponent("Detect.7z"), step: .fastest),
            progress: { _ in }
        )
        XCTAssertEqual(ArchiveDetector.format(of: archive), .sevenZip)
        XCTAssertEqual(EngineRegistry.standard().extractor(for: archive)?.format, .sevenZip)
    }
}
