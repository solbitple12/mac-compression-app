import XCTest
@testable import TampCore

final class EstimateTextTests: XCTestCase {
    func testDurationsShowOneFigureWhenTheRangeIsNarrow() {
        XCTAssertEqual(EstimateText.duration(0.2...0.5), "under a second")
        XCTAssertEqual(EstimateText.duration(40...44), "~42 s")
        XCTAssertEqual(EstimateText.duration(230...250), "~4 min")
        XCTAssertEqual(EstimateText.duration(4800...4800), "~1 h 20 min")
    }

    func testDurationsShowARangeWhenSamplesDisagree() {
        XCTAssertEqual(EstimateText.duration(180...300), "about 3 to 5 min")
        XCTAssertEqual(EstimateText.duration(40...120), "about 40 s to 2 min")
    }

    func testSizesShowARangeOnlyWhenWide() {
        XCTAssertTrue(EstimateText.size(340_000_000...360_000_000).hasPrefix("~"))
        XCTAssertTrue(EstimateText.size(100_000_000...300_000_000).contains(" to "))
    }

    func testHintText() {
        let estimate = Estimate(seconds: 230...250, outputBytes: 340_000_000...360_000_000, peakMemoryBytes: 2 << 30)
        let text = estimate.hintText(step: .best)
        XCTAssertTrue(text.hasPrefix("Best: ~4 min · ~"), text)
        XCTAssertTrue(text.hasSuffix("RAM"), text)
        var rough = estimate
        rough.isRough = true
        XCTAssertTrue(rough.hintText(step: .best).contains("(rough)"))
    }
}

final class ThreadScalingTests: XCTestCase {
    func testAJobCantUseMoreThreadsThanItHasUnits() {
        let scaling = ThreadScaling(unitBytes: 1 << 20, efficiency: 1)
        XCTAssertEqual(scaling.speedup(threads: 8, totalBytes: 2 << 20), 2)
        XCTAssertEqual(scaling.speedup(threads: 8, totalBytes: 100 << 20), 8)
        XCTAssertEqual(scaling.speedup(threads: 1, totalBytes: 100 << 20), 1)
    }

    func testSingleThreadedFormatsDontScale() {
        let scaling = ThreadScaling.of(format: .tarBr, step: .normal, options: ArchiveOptions(threads: 8))
        XCTAssertEqual(scaling.speedup(threads: 8, totalBytes: 1 << 30), 1)
    }

    func testLZMA2PairsThreadsPerBlock() {
        // Normal (level 5) has a 32 MiB dictionary, so 128 MiB blocks with two threads each.
        let scaling = ThreadScaling.of(format: .sevenZip, step: .normal, options: ArchiveOptions(threads: 8))
        XCTAssertEqual(scaling.speedup(threads: 2, totalBytes: 22 << 20), 1.4, accuracy: 0.01)
        XCTAssertGreaterThan(scaling.speedup(threads: 8, totalBytes: 4 << 30), 4)
    }

    func testPigzScalesOnSmallInputs() {
        let scaling = ThreadScaling.of(format: .tarGz, step: .normal, options: ArchiveOptions(threads: 3))
        XCTAssertGreaterThan(scaling.speedup(threads: 3, totalBytes: 22 << 20), 2.4)
    }
}

final class EstimateHistoryTests: XCTestCase {
    private func record(estimated: Double?, actual: Double, input: Int64 = 100 << 20, output: Int64 = 40 << 20,
                        peak: UInt64? = nil, hint: UInt64? = nil) -> HistoryRecord {
        HistoryRecord(format: .zip, method: .deflate, step: .normal, threads: 4, inputBytes: input, outputBytes: output,
                      estimatedSeconds: estimated, actualSeconds: actual, peakMemoryBytes: peak, hintMemoryBytes: hint)
    }

    func testCorrectionIsTheMedianRatioOfRecentRuns() {
        let history = EstimateHistory(fileURL: nil)
        XCTAssertEqual(history.timeCorrection(format: .zip, method: .deflate, step: .normal), 1)
        for (estimated, actual) in [(10.0, 12.0), (10.0, 15.0), (10.0, 30.0)] {
            history.append(record(estimated: estimated, actual: actual))
        }
        XCTAssertEqual(history.timeCorrection(format: .zip, method: .deflate, step: .normal), 1.5, accuracy: 0.001)
        XCTAssertEqual(history.timeCorrection(format: .zip, method: .deflate, step: .best), 1, "other steps are separate")
    }

    func testOnlyTheLastTwentyRunsCount() {
        let history = EstimateHistory(fileURL: nil)
        for _ in 0..<30 { history.append(record(estimated: 10, actual: 40)) }
        for _ in 0..<20 { history.append(record(estimated: 10, actual: 10)) }
        XCTAssertEqual(history.timeCorrection(format: .zip, method: .deflate, step: .normal), 1, accuracy: 0.001)
    }

    func testMemoryCorrectionComparesPeaksWithHints() {
        let history = EstimateHistory(fileURL: nil)
        history.append(record(estimated: nil, actual: 1, peak: 300, hint: 100))
        XCTAssertEqual(history.memoryCorrection(format: .zip, method: .deflate, step: .normal), 3, accuracy: 0.001)
    }

    func testRoughEstimateComesFromEarlierThroughput() throws {
        let history = EstimateHistory(fileURL: nil)
        XCTAssertNil(history.roughEstimate(format: .zip, method: .deflate, step: .normal, threads: 4, totalBytes: 1 << 30, peakMemoryBytes: 0))
        history.append(record(estimated: nil, actual: 10))
        let rough = try XCTUnwrap(history.roughEstimate(format: .zip, method: .deflate, step: .normal, threads: 4,
                                                        totalBytes: 200 << 20, peakMemoryBytes: 0))
        XCTAssertTrue(rough.isRough)
        XCTAssertTrue(rough.seconds.contains(20))
        XCTAssertTrue(rough.outputBytes.contains(80 << 20))
    }

    func testHistoryIsSavedAndLoaded() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("TampHistory-\(UUID().uuidString)/History.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        EstimateHistory(fileURL: file).append(record(estimated: 10, actual: 20))
        let reloaded = EstimateHistory(fileURL: file)
        XCTAssertEqual(reloaded.allRecords.count, 1)
        XCTAssertEqual(reloaded.timeCorrection(format: .zip, method: .deflate, step: .normal), 2, accuracy: 0.001)
    }
}

/// Compresses at a fixed speed to half size, counting its runs.
private struct FakeEngine: ArchiveEngine {
    let bytesPerSecond: Double
    let fixedSeconds: Double
    let runs = LineRecorder()

    var format: ArchiveFormat { .tarBr }
    var capabilities: EngineCapabilities { [] }
    func parameters(for step: SpeedStep, options: ArchiveOptions) -> Int { step.rawValue }
    func hint(for step: SpeedStep, options: ArchiveOptions) -> StepHint {
        StepHint(step: step, summary: step.summary, peakMemoryBytes: 100 << 20, outputExtension: "tar.br")
    }

    func compress(_ request: CompressRequest, progress: @escaping ProgressHandler) async throws -> URL {
        runs.append(request.items[0].lastPathComponent)
        let bytes = InputSize.totalBytes(of: request.items)
        try await Task.sleep(nanoseconds: UInt64((fixedSeconds + Double(bytes) / bytesPerSecond) * 1_000_000_000))
        try Data(count: Int(bytes / 2) + 100).write(to: request.destination)
        return request.destination
    }

    func extract(_ request: ExtractRequest, progress: @escaping ProgressHandler) async throws -> URL {
        throw TampError.other("not used")
    }
}

final class EstimatorTests: EngineTestCase {
    private func profile() throws -> InputProfile {
        try XCTUnwrap(InputProfile.scan([project]))
    }

    func testProfileFindsLargestFilesAndCountsSmallOnes() throws {
        let profile = try profile()
        XCTAssertEqual(profile.fileCount, 4)
        XCTAssertEqual(profile.largestFiles.first?.url.lastPathComponent, "random.bin")
        XCTAssertEqual(profile.smallFileCount, 3)
        XCTAssertEqual(profile.totalBytes, InputSize.totalBytes(of: [project]))
    }

    func testFingerprintChangesWithTheContents() throws {
        let before = try profile().fingerprint
        try Data("more".utf8).write(to: project.appendingPathComponent("new.txt"))
        XCTAssertNotEqual(try profile().fingerprint, before)
    }

    func testScalesSamplesUpToTheWholeInput() async throws {
        // 20 MiB, so the probe can only afford samples of it.
        try Self.randomData(count: 20 << 20).write(to: project.appendingPathComponent("data/large.bin"))
        let profile = try profile()
        let engine = FakeEngine(bytesPerSecond: Double(20 << 20), fixedSeconds: 0.05)
        let estimator = Estimator(history: EstimateHistory(fileURL: nil), budget: 2)
        let started = Date()
        let estimate = try await XCTUnwrapAsync(await estimator.estimate(for: profile, engine: engine, step: .normal,
                                                                          options: ArchiveOptions(threads: 1)))
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "the probe keeps to its budget")
        // The whole input takes about 0.05 + 22 MiB / 20 MiB/s ≈ 1.15 s and halves in size.
        XCTAssertTrue(estimate.seconds.lowerBound < 1.6 && estimate.seconds.upperBound > 0.8, "\(estimate.seconds)")
        let half = Double(profile.totalBytes) / 2
        XCTAssertTrue(Double(estimate.outputBytes.lowerBound) < half * 1.2 && Double(estimate.outputBytes.upperBound) > half * 0.8,
                      "\(estimate.outputBytes)")
        XCTAssertEqual(estimate.peakMemoryBytes, 100 << 20)
        XCTAssertFalse(estimate.isRough)
    }

    func testMovingTheSliderBackUsesTheCache() async throws {
        let profile = try profile()
        let engine = FakeEngine(bytesPerSecond: Double(100 << 20), fixedSeconds: 0.01)
        let estimator = Estimator(history: EstimateHistory(fileURL: nil), budget: 1)
        _ = try await estimator.estimate(for: profile, engine: engine, step: .normal, options: ArchiveOptions(threads: 1))
        let runs = engine.runs.all.count
        let cached = await estimator.cachedEstimate(for: profile, engine: engine, step: .normal, options: ArchiveOptions(threads: 1))
        XCTAssertNotNil(cached)
        _ = try await estimator.estimate(for: profile, engine: engine, step: .normal, options: ArchiveOptions(threads: 1))
        XCTAssertEqual(engine.runs.all.count, runs, "no second probe")
        let other = await estimator.cachedEstimate(for: profile, engine: engine, step: .best, options: ArchiveOptions(threads: 1))
        XCTAssertNil(other)
    }

    func testASlowEngineIsCutOffAtTheBudget() async throws {
        let profile = try profile()
        let engine = FakeEngine(bytesPerSecond: 1, fixedSeconds: 0.01)
        let estimator = Estimator(history: EstimateHistory(fileURL: nil), budget: 0.5)
        let started = Date()
        let estimate = try await estimator.estimate(for: profile, engine: engine, step: .normal, options: ArchiveOptions(threads: 1))
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertNil(estimate, "no slice finished")
    }

    func testHistoryCorrectsTheEstimate() async throws {
        let profile = try profile()
        let engine = FakeEngine(bytesPerSecond: Double(100 << 20), fixedSeconds: 0.01)
        let history = EstimateHistory(fileURL: nil)
        let estimator = Estimator(history: history, budget: 1)
        let options = ArchiveOptions(threads: 1)
        let plain = try await XCTUnwrapAsync(await estimator.estimate(for: profile, engine: engine, step: .normal, options: options))
        for _ in 0..<3 {
            history.append(HistoryRecord(format: .tarBr, method: nil, step: .normal, threads: 1, inputBytes: 1, outputBytes: 1,
                                         estimatedSeconds: 10, actualSeconds: 20))
        }
        // The cached probe, corrected by what the history now says.
        let corrected = try await XCTUnwrapAsync(await estimator.estimate(for: profile, engine: engine, step: .normal, options: options))
        XCTAssertEqual(corrected.likelySeconds / plain.likelySeconds, 2, accuracy: 0.001)
        XCTAssertEqual(corrected.outputBytes, plain.outputBytes)
    }

    func testRealZipEstimateIsInTheRightRange() async throws {
        try XCTSkipIf((try? HelperLocator.standard.url(for: "7zz")) == nil, "7zz isn't built")
        let profile = try profile()
        let engine = ZipEngine()
        let estimate = try await XCTUnwrapAsync(await Estimator(history: EstimateHistory(fileURL: nil))
            .estimate(for: profile, engine: engine, step: .normal, options: ArchiveOptions()))
        let archive = try await engine.compress(
            CompressRequest(items: [project], destination: output.appendingPathComponent("Project.zip"), step: .normal),
            progress: { _ in }
        )
        let actual = Estimator.size(of: archive, fileManager: fileManager)
        // Random data dominates, so the archive is about as large as the input.
        XCTAssertGreaterThan(actual, estimate.outputBytes.lowerBound / 2)
        XCTAssertLessThan(actual, estimate.outputBytes.upperBound * 2)
    }
}

/// XCTUnwrap for an expression that has to be awaited first.
func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}
