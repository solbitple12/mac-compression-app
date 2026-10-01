import XCTest
@testable import TampCore

/// ZIP with each inner method: 7zz writes all but Zstandard, which minizip writes.
final class ZipMethodTests: EngineTestCase {
    private var engine: ZipEngine!

    override var requiredHelpers: [String] { ["7zz", "minizip"] }

    override func setUpWithError() throws {
        try super.setUpWithError()
        engine = ZipEngine()
    }

    /// Each entry's method as 7zz lists it, such as "Deflate" or "AES-256 ZSTD".
    private func storedMethods(of archive: URL, password: String? = nil) async throws -> [String] {
        let arguments = ["l", "-slt", archive.path] + (password.map { ["-p\($0)"] } ?? [])
        let lines = LineRecorder()
        let result = try await ProcessRunner().run(try HelperLocator.standard.url(for: "7zz"), arguments: arguments) { lines.append($0) }
        XCTAssertTrue(result.succeeded, result.standardError)
        return lines.all.filter { $0.hasPrefix("Method = ") }.map { String($0.dropFirst("Method = ".count)) }
    }

    private func compress(_ items: [URL], name: String, step: SpeedStep = .normal, method: CompressionMethod, password: String? = nil) async throws -> URL {
        try await engine.compress(
            CompressRequest(items: items, destination: output.appendingPathComponent(name), step: step,
                            options: ArchiveOptions(threads: 2, method: method), password: password),
            progress: { _ in }
        )
    }

    func testEveryMethodRoundTripsAndIsStoredAsChosen() async throws {
        let expected: [CompressionMethod: String] = [.deflate: "deflate", .deflate64: "deflate64", .bzip2: "bzip2", .lzma: "lzma", .zstd: "zstd"]
        for method in ArchiveFormat.zip.methods {
            let archive = try await compress([project], name: "\(method.title).zip", method: method)
            let methods = try await storedMethods(of: archive).map { $0.lowercased() }
            XCTAssertTrue(methods.contains { $0.split(separator: " ").contains { $0.hasPrefix(expected[method] ?? "?") } },
                          "\(method.title) was stored as \(methods)")
            let extracted = try await engine.extract(
                ExtractRequest(archive: archive, destinationDirectory: try makeFolder("Out-\(method.title)")),
                progress: { _ in }
            )
            assertMatchesProject(extracted)
        }
    }

    func testZstandardRoundTripsAtEveryStep() async throws {
        for step in SpeedStep.allCases {
            let archive = try await compress([project], name: "Zstd-\(step.title).zip", step: step, method: .zstd)
            let extracted = try await engine.extract(
                ExtractRequest(archive: archive, destinationDirectory: try makeFolder("Zstd-\(step.title)")),
                progress: { _ in }
            )
            XCTAssertEqual(extracted.lastPathComponent, "Project")
            assertMatchesProject(extracted)
        }
    }

    func testZstandardArchivesAreReadableByEveryone() async throws {
        let archive = try await compress([project], name: "Mode.zip", method: .zstd)
        let mode = try fileManager.attributesOfItem(atPath: archive.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o644)
    }

    func testZstandardWithAPasswordUsesAESAndChecksIt() async throws {
        let password = "zstd pässword"
        let archive = try await compress([project], name: "Secret.zip", method: .zstd, password: password)
        let methods = try await storedMethods(of: archive, password: password)
        XCTAssertTrue(methods.contains { $0.contains("AES-256") }, "\(methods)")

        let target = try makeFolder("Locked")
        do {
            _ = try await engine.extract(ExtractRequest(archive: archive, destinationDirectory: target, password: "wrong"), progress: { _ in })
            XCTFail("Expected a wrong-password error")
        } catch {
            XCTAssertEqual(error as? TampError, .wrongPassword)
        }
        XCTAssertEqual(try contents(of: target), [])

        let extracted = try await engine.extract(
            ExtractRequest(archive: archive, destinationDirectory: try makeFolder("Unlocked"), password: password),
            progress: { _ in }
        )
        assertMatchesProject(extracted)
    }

    func testZstandardTakesItemsFromSeveralFoldersAndOddNames() async throws {
        let other = try makeFolder("Elsewhere")
        let dashed = other.appendingPathComponent("-dash.txt")
        try Data("a name that looks like an option".utf8).write(to: dashed)
        let spaced = other.appendingPathComponent("one - two.txt")
        try Data("a name with minizip's separator".utf8).write(to: spaced)
        let items = [project.appendingPathComponent("readme.txt"), dashed, project.appendingPathComponent("data"), spaced]
        let archive = try await compress(items, name: "Mixed.zip", method: .zstd)
        let extracted = try await engine.extract(
            ExtractRequest(archive: archive, destinationDirectory: try makeFolder("MixedOut")),
            progress: { _ in }
        )
        XCTAssertEqual(try contents(of: extracted), ["-dash.txt", "data", "one - two.txt", "readme.txt"])
        for item in items {
            XCTAssertTrue(fileManager.contentsEqual(atPath: item.path, andPath: extracted.appendingPathComponent(item.lastPathComponent).path),
                          item.lastPathComponent)
        }
    }

    func testZstandardReportsProgressUpToTheWhole() async throws {
        let seen = LineRecorder()
        _ = try await engine.compress(
            CompressRequest(items: [project], destination: output.appendingPathComponent("Progress.zip"), step: .fast,
                            options: ArchiveOptions(threads: 2, method: .zstd)),
            progress: { seen.append(String($0)) }
        )
        let fractions = seen.all.compactMap(Double.init)
        XCTAssertFalse(fractions.isEmpty)
        XCTAssertTrue(fractions.allSatisfy { (0...1).contains($0) }, "\(fractions)")
        XCTAssertEqual(fractions.last ?? 0, 1, accuracy: 0.01)
    }

    func testZstandardFailureLeavesNothingBehind() async throws {
        let missing = project.appendingPathComponent("gone.txt")
        do {
            _ = try await compress([missing], name: "Missing.zip", method: .zstd)
            XCTFail("Expected an error for a missing item")
        } catch {
            XCTAssertNotNil(error as? TampError, "\(error)")
        }
        XCTAssertEqual(try contents(of: output), [])
    }

    func testCancellingZstandardLeavesNoPartialArchive() async throws {
        try Self.randomData(count: 64 << 20).write(to: project.appendingPathComponent("data/big.bin"))
        let (started, signal) = AsyncStream<Void>.makeStream()
        let engine = engine!
        let request = CompressRequest(items: [project], destination: output.appendingPathComponent("Big.zip"), step: .best,
                                      options: ArchiveOptions(threads: 2, method: .zstd))
        let task = Task { try await engine.compress(request, progress: { _ in signal.yield() }) }
        let timeout = Task {
            try? await Task.sleep(for: .seconds(1))
            signal.yield()
        }
        for await _ in started { break }
        timeout.cancel()
        task.cancel()
        switch await task.result {
        case .success:
            break
        case let .failure(error):
            XCTAssertTrue(error is CancellationError, "\(error)")
            XCTAssertEqual(try contents(of: output), [])
        }
    }
}

final class MinizipProgressTests: XCTestCase {
    func testParsesFromTheEndOfTheLine() {
        let parsed = MinizipProgress.parse("Photos/a - b.jpg - 65535 / 3000000 (2.18%)")
        XCTAssertEqual(parsed?.name, "Photos/a - b.jpg")
        XCTAssertEqual(parsed?.position, 65535)
        XCTAssertNil(MinizipProgress.parse("Adding Photos/a.jpg"))
        XCTAssertNil(MinizipProgress.parse("Archive /tmp/x.zip"))
        // A link's target can be longer than its reported size.
        XCTAssertEqual(MinizipProgress.parse("P/link - 5 / 3 (166.67%)")?.position, 3)
    }

    func testAddsUpFilesAcrossTheArchive() {
        let seen = LineRecorder()
        let meter = MinizipProgress(totalBytes: 300) { seen.append(String($0)) }
        for line in [
            "Adding a", "a - 0 / 100 (0.00%)", "a - 100 / 100 (100.00%)",
            "Adding b", "b - 0 / 100 (0.00%)", "b - 50 / 100 (50.00%)", "b - 100 / 100 (100.00%)",
            // A file of the same name from another folder, in the next run.
            "a - 0 / 100 (0.00%)", "a - 100 / 100 (100.00%)",
        ] {
            meter.consume(line)
        }
        let fractions = seen.all.compactMap(Double.init)
        XCTAssertEqual(fractions, [0, 1.0 / 3, 1.0 / 3, 0.5, 2.0 / 3, 2.0 / 3, 1])
    }

    func testCollectsErrorLines() {
        let meter = MinizipProgress(totalBytes: 0) { _ in }
        meter.consume("Error -107 adding path to archive gone.txt")
        XCTAssertEqual(meter.errorLines, ["Error -107 adding path to archive gone.txt"])
        XCTAssertEqual(ZipEngine.minizipError(exitCode: 149, output: meter.errorLines), .fileNotFound(path: nil))
    }
}
