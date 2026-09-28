import XCTest
@testable import TampCore

/// Hands the monitor whatever sample a test sets.
private final class FakeSampler: ResourceSampling, @unchecked Sendable {
    private let lock = NSLock()
    private var next = ResourceSample(availableMemoryBytes: 8 << 30, physicalMemoryBytes: 16 << 30)

    var current: ResourceSample {
        get { lock.withLock { next } }
        set { lock.withLock { next = newValue } }
    }

    func sample(processIDs: [pid_t], volumes: [URL]) -> ResourceSample { current }
    func footprint(of processIDs: [pid_t]) -> UInt64 { current.jobFootprintBytes }
}

/// A clock the test moves by hand.
private final class MonitorClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 1000

    var now: TimeInterval { lock.withLock { time } }
    func advance(_ seconds: TimeInterval) { lock.withLock { time += seconds } }
}

final class ResourcePolicyTests: XCTestCase {
    private let policy = ResourcePolicy()
    private let calm = ResourceSample(jobFootprintBytes: 1 << 30, availableMemoryBytes: 8 << 30, physicalMemoryBytes: 16 << 30)

    func testCalmIsNormal() {
        XCTAssertEqual(policy.assess(calm, swapGrowth: 0).0, .normal)
    }

    func testWarningFromPressureOrAFootprintAboveThePreflightShare() {
        var sample = calm
        sample.pressure = .warning
        XCTAssertEqual(policy.assess(sample, swapGrowth: 0).0, .warning)
        sample = calm
        sample.jobFootprintBytes = 6 << 30
        sample.availableMemoryBytes = 1 << 30
        XCTAssertEqual(policy.assess(sample, swapGrowth: 0).0, .warning)
    }

    func testCriticalFromPressureFootprintSwapOrDisk() {
        var sample = calm
        sample.pressure = .critical
        XCTAssertEqual(policy.assess(sample, swapGrowth: 0).0, .critical)
        sample = calm
        sample.jobFootprintBytes = 15 << 30
        XCTAssertEqual(policy.assess(sample, swapGrowth: 0).0, .critical)
        XCTAssertEqual(policy.assess(calm, swapGrowth: 2 << 30).0, .critical)
        sample = calm
        sample.freeDiskBytes = ["Macintosh HD": 100 << 20]
        let (level, reason) = policy.assess(sample, swapGrowth: 0)
        XCTAssertEqual(level, .critical)
        XCTAssertTrue(reason?.contains("Macintosh HD") == true)
    }
}

final class ResourceMonitorTests: XCTestCase {
    private var queue: JobQueue!
    private var sampler: FakeSampler!
    private var clock: MonitorClock!
    private var monitor: ResourceMonitor!

    override func setUp() {
        queue = JobQueue()
        sampler = FakeSampler()
        clock = MonitorClock()
        let clock = clock!
        monitor = ResourceMonitor(queue: queue, sampler: sampler, clock: { clock.now })
    }

    /// A job that runs until cancelled.
    private func startLongJob() async -> JobID {
        let (started, signal) = AsyncStream<Void>.makeStream()
        let id = await queue.enqueue(title: "Long", totalBytes: 0) { _ in
            signal.yield()
            try await Task.sleep(for: .seconds(60))
        }
        for await _ in started { break }
        return id
    }

    private func setCritical() {
        var sample = sampler.current
        sample.pressure = .critical
        sampler.current = sample
    }

    func testWarningOnlyReports() async {
        let id = await startLongJob()
        var sample = sampler.current
        sample.pressure = .warning
        sampler.current = sample
        await monitor.tick()
        let status = await monitor.currentStatus
        XCTAssertEqual(status.level, .warning)
        XCTAssertFalse(status.isAwaitingAnswer)
        let paused = await queue.snapshot(of: id)?.isPaused
        XCTAssertEqual(paused, false)
        await queue.cancel(id)
    }

    func testCriticalPausesAndResumeContinues() async {
        let id = await startLongJob()
        setCritical()
        await monitor.tick()
        var status = await monitor.currentStatus
        XCTAssertEqual(status.pausedJobs, [id])
        XCTAssertEqual(status.secondsUntilAutomaticStop, 60)
        var snapshot = await queue.snapshot(of: id)
        XCTAssertEqual(snapshot?.isPaused, true)

        await monitor.resumePausedJobs()
        snapshot = await queue.snapshot(of: id)
        XCTAssertEqual(snapshot?.isPaused, false)
        status = await monitor.currentStatus
        XCTAssertFalse(status.isAwaitingAnswer)
        await queue.cancel(id)
    }

    func testUnansweredAndStillCriticalStopsSafelyAfterTheTimeout() async {
        let id = await startLongJob()
        setCritical()
        await monitor.tick()
        clock.advance(30)
        await monitor.tick()
        var status = await monitor.currentStatus
        XCTAssertEqual(status.secondsUntilAutomaticStop ?? 0, 30, accuracy: 0.01)
        XCTAssertNil(status.automaticStop)

        clock.advance(31)
        await monitor.tick()
        status = await monitor.currentStatus
        XCTAssertEqual(status.automaticStop?.jobs, [id])
        let done = await queue.waitUntilDone(id)
        XCTAssertEqual(done?.state, .cancelled)
    }

    func testNoAutomaticStopOnceThingsCalmDown() async {
        let id = await startLongJob()
        setCritical()
        await monitor.tick()
        sampler.current = ResourceSample(availableMemoryBytes: 8 << 30, physicalMemoryBytes: 16 << 30)
        clock.advance(61)
        await monitor.tick()
        let status = await monitor.currentStatus
        XCTAssertNil(status.automaticStop)
        XCTAssertEqual(status.pausedJobs, [id], "still paused, waiting for an answer")
        XCTAssertNil(status.secondsUntilAutomaticStop)
        await monitor.stopPausedJobs()
        let done = await queue.waitUntilDone(id)
        XCTAssertEqual(done?.state, .cancelled)
    }

    func testFastSwapGrowthIsCritical() async {
        let id = await startLongJob()
        await monitor.tick()
        var sample = sampler.current
        sample.swapUsedBytes = 3 << 30
        sampler.current = sample
        clock.advance(2)
        await monitor.tick()
        let status = await monitor.currentStatus
        XCTAssertEqual(status.level, .critical)
        XCTAssertEqual(status.pausedJobs, [id])
        await monitor.stopPausedJobs()
    }

    func testLowDiskPauses() async {
        let id = await startLongJob()
        var sample = sampler.current
        sample.freeDiskBytes = ["Backup": 10 << 20]
        sampler.current = sample
        await monitor.tick()
        let status = await monitor.currentStatus
        XCTAssertEqual(status.pausedJobs, [id])
        XCTAssertTrue(status.reason?.contains("Backup") == true)
        await monitor.stopPausedJobs()
    }

    func testNothingHappensWithoutJobs() async {
        setCritical()
        await monitor.tick()
        let status = await monitor.currentStatus
        XCTAssertEqual(status.level, .normal)
        XCTAssertFalse(status.isAwaitingAnswer)
    }
}

final class JobControlTests: XCTestCase {
    func testPausingStopsAHelperUntilResumed() async throws {
        let queue = JobQueue()
        let runner = ProcessRunner()
        let id = await queue.enqueue(title: "Sleep", totalBytes: 0) { _ in
            _ = try await runner.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["0.5"])
        }
        // Wait for the helper to register.
        var control: JobControl?
        for _ in 0..<200 {
            control = await queue.runningJobs.first?.control
            if control?.runningProcessIDs.isEmpty == false { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(control?.runningProcessIDs.count, 1)
        await queue.pause(id)
        try await Task.sleep(for: .seconds(1.5))
        let paused = await queue.snapshot(of: id)
        XCTAssertEqual(paused?.isPaused, true)
        XCTAssertEqual(paused?.state.isFinal, false, "a stopped sleep can't finish")
        await queue.resume(id)
        let done = await queue.waitUntilDone(id)
        XCTAssertEqual(done?.state, .finished)
        XCTAssertEqual(control?.runningProcessIDs, [])
    }

    func testCancellingAPausedJobStillStopsIt() async throws {
        let queue = JobQueue()
        let runner = ProcessRunner(terminationGracePeriod: 0.5)
        let id = await queue.enqueue(title: "Sleep", totalBytes: 0) { _ in
            _ = try await runner.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"])
        }
        for _ in 0..<200 {
            if await queue.runningJobs.first?.control.runningProcessIDs.isEmpty == false { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await queue.pause(id)
        await queue.cancel(id)
        let done = await queue.waitUntilDone(id)
        XCTAssertEqual(done?.state, .cancelled)
    }

    func testInProcessWorkWaitsWhilePaused() async throws {
        let control = JobControl()
        control.pause()
        let released = LineRecorder()
        let thread = Thread {
            control.waitWhilePaused()
            released.append("ran")
        }
        thread.start()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(released.all, [])
        control.resume()
        for _ in 0..<100 where released.all.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(released.all, ["ran"])
    }
}

final class PreflightTests: XCTestCase {
    func testMemoryProblemAboveTheShareOfAvailable() {
        let settings = SafetySettings()
        XCTAssertNil(Preflight.memoryProblem(peakMemoryBytes: 1 << 30, availableMemoryBytes: 8 << 30, settings: settings))
        XCTAssertEqual(Preflight.memoryProblem(peakMemoryBytes: 7 << 30, availableMemoryBytes: 8 << 30, settings: settings),
                       .memory(needed: 7 << 30, available: 8 << 30))
    }

    func testMemoryFixFindsTheHighestLowerStepAndTheMostThreads() {
        // Memory grows with the step and the thread count.
        let fix = Preflight.memoryFix(step: .best, threads: 8, limit: 3000) { step, threads in
            UInt64(step.rawValue * 100 * threads)
        }
        XCTAssertEqual(fix.lowerStep?.step, .normal) // Good needs 4 × 100 × 8 = 3200, Normal 2400
        XCTAssertEqual(fix.lowerStep?.memory, 2400)
        XCTAssertEqual(fix.fewerThreads?.threads, 6) // 5 × 100 × 6 = 3000
    }

    func testDiskCountsTheCheckAndTheReserve() {
        var settings = SafetySettings()
        settings.diskReserveBytes = 100
        let free: (URL) -> [String: Int64] = { _ in ["Data": 1000] }
        let folder = URL(fileURLWithPath: "/tmp")
        XCTAssertNil(Preflight.diskProblem(outputBytes: 500, verifyBytes: 0, destination: folder, settings: settings, freeBytes: free))
        XCTAssertEqual(Preflight.diskProblem(outputBytes: 500, verifyBytes: 500, destination: folder, settings: settings, freeBytes: free),
                       .disk(needed: 1100, free: 1000, volume: "Data"))
    }
}
