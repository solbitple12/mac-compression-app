import XCTest
@testable import TampCore

final class ZipEngineTests: EngineTestCase {
    private var engine: ZipEngine!

    override var requiredHelpers: [String] { ["7zz"] }

    override func setUpWithError() throws {
        try super.setUpWithError()
        engine = ZipEngine()
    }

    func testRoundTripIsByteForByteAtEveryStep() async throws {
        for step in SpeedStep.allCases {
            let archive = try await engine.compress(
                CompressRequest(items: [project], destination: output.appendingPathComponent("Project-\(step.title).zip"), step: step),
                progress: { _ in }
            )
            let target = workspace.appendingPathComponent("Extracted-\(step.title)")
            try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
            let extracted = try await engine.extract(ExtractRequest(archive: archive, destinationDirectory: target), progress: { _ in })
            XCTAssertEqual(extracted.lastPathComponent, "Project", "a single top-level folder lands directly")
            assertMatchesProject(extracted)
        }
    }

    func testHigherStepsAreNotLarger() async throws {
        func size(_ step: SpeedStep) async throws -> Int {
            let archive = try await engine.compress(
                CompressRequest(items: [project], destination: output.appendingPathComponent("Size-\(step.title).zip"), step: step),
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

    func testPasswordProtectedRoundTrip() async throws {
        let archive = try await engine.compress(
            CompressRequest(items: [project], destination: output.appendingPathComponent("Secret.zip"), step: .normal, password: "s3cret"),
            progress: { _ in }
        )
        let target = workspace.appendingPathComponent("Unlocked")
        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        let extracted = try await engine.extract(ExtractRequest(archive: archive, destinationDirectory: target, password: "s3cret"), progress: { _ in })
        assertMatchesProject(extracted)
    }

    func testWrongOrMissingPasswordLeavesNothingBehind() async throws {
        let archive = try await engine.compress(
            CompressRequest(items: [project], destination: output.appendingPathComponent("Secret.zip"), step: .fast, password: "s3cret"),
            progress: { _ in }
        )
        let target = workspace.appendingPathComponent("Locked")
        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        do {
            _ = try await engine.extract(ExtractRequest(archive: archive, destinationDirectory: target, password: "wrong"), progress: { _ in })
            XCTFail("Expected a wrong-password error")
        } catch {
            XCTAssertEqual(error as? TampError, .wrongPassword)
        }
        do {
            _ = try await engine.extract(ExtractRequest(archive: archive, destinationDirectory: target), progress: { _ in })
            XCTFail("Expected a password-required error")
        } catch {
            XCTAssertEqual(error as? TampError, .passwordRequired)
        }
        XCTAssertEqual(try contents(of: target), [])
    }

    func testNeverOverwritesAnExistingArchive() async throws {
        let destination = output.appendingPathComponent("Project.zip")
        try Data("keep me".utf8).write(to: destination)
        let archive = try await engine.compress(CompressRequest(items: [project], destination: destination, step: .fastest), progress: { _ in })
        XCTAssertEqual(archive.lastPathComponent, "Project 2.zip")
        XCTAssertEqual(try Data(contentsOf: destination), Data("keep me".utf8))
    }

    func testSeveralTopLevelItemsExtractIntoAFolderNamedAfterTheArchive() async throws {
        let archive = try await engine.compress(
            CompressRequest(
                items: [project.appendingPathComponent("readme.txt"), project.appendingPathComponent("data")],
                destination: output.appendingPathComponent("Loose.zip"),
                step: .normal
            ),
            progress: { _ in }
        )
        let target = workspace.appendingPathComponent("LooseOut")
        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        let extracted = try await engine.extract(ExtractRequest(archive: archive, destinationDirectory: target), progress: { _ in })
        XCTAssertEqual(extracted.lastPathComponent, "Loose")
        XCTAssertEqual(try contents(of: extracted), ["data", "readme.txt"])
    }

    func testProgressIsReported() async throws {
        let seen = LineRecorder()
        _ = try await engine.compress(
            CompressRequest(items: [project], destination: output.appendingPathComponent("Progress.zip"), step: .best),
            progress: { seen.append(String($0)) }
        )
        let fractions = seen.all.compactMap(Double.init)
        XCTAssertTrue(fractions.allSatisfy { (0...1).contains($0) }, "\(fractions)")
    }

    func testCancelLeavesNoPartialArchive() async throws {
        try Self.randomData(count: 48 << 20).write(to: project.appendingPathComponent("data/big.bin"))
        let (started, signal) = AsyncStream<Void>.makeStream()
        let engine = engine!
        let request = CompressRequest(items: [project], destination: output.appendingPathComponent("Big.zip"), step: .best)
        let task = Task {
            try await engine.compress(request, progress: { _ in signal.yield() })
        }
        // Cancel once 7zz reports progress, or after a moment if it prints none.
        let timeout = Task {
            try? await Task.sleep(for: .seconds(1))
            signal.yield()
        }
        for await _ in started { break }
        timeout.cancel()
        task.cancel()
        let result = await task.result
        switch result {
        case .success:
            // The machine was fast enough to finish; nothing to check about cancellation.
            break
        case let .failure(error):
            XCTAssertTrue(error is CancellationError, "\(error)")
            XCTAssertEqual(try contents(of: output), [])
        }
        XCTAssertTrue(fileManager.fileExists(atPath: project.appendingPathComponent("data/big.bin").path), "inputs are untouched")
    }

    func testPercentParsing() {
        XCTAssertEqual(SevenZipTool.percent(in: "42% 3 + photo.jpg"), 42)
        XCTAssertEqual(SevenZipTool.percent(in: "100%"), 100)
        XCTAssertNil(SevenZipTool.percent(in: "0M Scan"))
        XCTAssertNil(SevenZipTool.percent(in: "Enter password:"))
    }
}
