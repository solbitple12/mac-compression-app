import XCTest
@testable import TampCore

final class JobQueueTests: XCTestCase {
    func testRunsOneJobAtATimeInOrder() async {
        let queue = JobQueue(maxConcurrentJobs: 1)
        let events = LineRecorder()
        let first = await queue.enqueue(title: "First", totalBytes: 0) { _ in
            events.append("first started")
            try await Task.sleep(for: .milliseconds(100))
            events.append("first ended")
        }
        let second = await queue.enqueue(title: "Second", totalBytes: 0) { _ in
            events.append("second started")
        }
        let secondBeforeStart = await queue.snapshot(of: second)
        XCTAssertEqual(secondBeforeStart?.state, .queued)
        _ = await queue.waitUntilDone(first)
        let done = await queue.waitUntilDone(second)
        XCTAssertEqual(done?.state, .finished)
        XCTAssertEqual(events.all, ["first started", "first ended", "second started"])
    }

    func testCancellingARunningJobStopsIt() async {
        let queue = JobQueue()
        let (started, signal) = AsyncStream<Void>.makeStream()
        let id = await queue.enqueue(title: "Long", totalBytes: 0) { _ in
            signal.yield()
            try await Task.sleep(for: .seconds(30))
        }
        for await _ in started { break }
        await queue.cancel(id)
        let done = await queue.waitUntilDone(id)
        XCTAssertEqual(done?.state, .cancelled)
    }

    func testCancellingAQueuedJobMeansItNeverRuns() async {
        let queue = JobQueue(maxConcurrentJobs: 1)
        let events = LineRecorder()
        let first = await queue.enqueue(title: "First", totalBytes: 0) { _ in
            try await Task.sleep(for: .milliseconds(100))
        }
        let second = await queue.enqueue(title: "Second", totalBytes: 0) { _ in
            events.append("second ran")
        }
        await queue.cancel(second)
        let cancelled = await queue.snapshot(of: second)
        XCTAssertEqual(cancelled?.state, .cancelled)
        _ = await queue.waitUntilDone(first)
        XCTAssertEqual(events.all, [])
    }

    func testFailuresCarryTheError() async {
        let queue = JobQueue()
        let id = await queue.enqueue(title: "Full disk", totalBytes: 0) { _ in
            throw TampError.diskFull
        }
        let done = await queue.waitUntilDone(id)
        XCTAssertEqual(done?.state, .failed(.diskFull))
    }

    func testProgressReportsSpeedAndETA() async {
        let clock = TestClock()
        let queue = JobQueue(clock: { clock.now })
        let seen = ProgressRecorder()
        let id = await queue.enqueue(title: "Measured", totalBytes: 100_000_000) { context in
            clock.now = 1
            await context.reportProgress(bytesProcessed: 10_000_000)
            if case let .running(progress) = await queue.snapshot(of: context.id)?.state {
                seen.progress = progress
            }
        }
        _ = await queue.waitUntilDone(id)
        XCTAssertEqual(seen.progress?.bytesPerSecond ?? 0, 10_000_000, accuracy: 1)
        XCTAssertEqual(seen.progress?.estimatedTimeRemaining ?? -1, 9, accuracy: 1e-6)
    }

    func testTotalMeasuredAfterStartKeepsTheStartTime() async {
        let clock = TestClock()
        let queue = JobQueue(clock: { clock.now })
        let seen = ProgressRecorder()
        let id = await queue.enqueue(title: "Sized later", totalBytes: 0) { context in
            clock.now = 2
            await context.setTotalBytes(100_000_000)
            clock.now = 4
            await context.reportProgress(bytesProcessed: 20_000_000)
            if case let .running(progress) = await queue.snapshot(of: context.id)?.state {
                seen.progress = progress
            }
        }
        _ = await queue.waitUntilDone(id)
        XCTAssertEqual(seen.progress?.totalBytes, 100_000_000)
        XCTAssertEqual(seen.progress?.elapsed ?? 0, 4, accuracy: 1e-6)
        XCTAssertEqual(seen.progress?.fractionCompleted ?? 0, 0.2, accuracy: 1e-6)
    }

    func testShutDownStopsEverythingAndRefusesNewJobs() async {
        let queue = JobQueue(maxConcurrentJobs: 1)
        let (started, signal) = AsyncStream<Void>.makeStream()
        let events = LineRecorder()
        let running = await queue.enqueue(title: "Running", totalBytes: 0) { _ in
            signal.yield()
            try await Task.sleep(for: .seconds(30))
        }
        let waiting = await queue.enqueue(title: "Waiting", totalBytes: 0) { _ in events.append("waiting ran") }
        for await _ in started { break }
        await queue.shutDown()
        let runningState = await queue.snapshot(of: running)?.state
        let waitingState = await queue.snapshot(of: waiting)?.state
        XCTAssertEqual(runningState, .cancelled)
        XCTAssertEqual(waitingState, .cancelled)
        let late = await queue.enqueue(title: "Late", totalBytes: 0) { _ in events.append("late ran") }
        let lateState = await queue.snapshot(of: late)?.state
        XCTAssertEqual(lateState, .cancelled)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(events.all, [])
    }

    func testUpdatesStreamPublishesStateChanges() async {
        let queue = JobQueue()
        let updates = await queue.updates()
        let id = await queue.enqueue(title: "Quick", totalBytes: 0) { _ in }
        var states: [JobState] = []
        for await snapshot in updates where snapshot.id == id {
            states.append(snapshot.state)
            if snapshot.state.isFinal { break }
        }
        XCTAssertEqual(states, [.queued, .running(nil), .finished])
    }

    func testFinishedJobsCarryTheirOutput() async {
        let queue = JobQueue()
        let output = URL(fileURLWithPath: "/tmp/Photos.zip")
        let id = await queue.enqueue(title: "Photos", totalBytes: 0) { context in
            await context.reportOutput(output)
        }
        let done = await queue.waitUntilDone(id)
        XCTAssertEqual(done?.state, .finished)
        XCTAssertEqual(done?.output, output)
    }

    func testRemovingFinishedJobsKeepsTheOthers() async {
        let queue = JobQueue(maxConcurrentJobs: 1)
        let (started, signal) = AsyncStream<Void>.makeStream()
        let quick = await queue.enqueue(title: "Quick", totalBytes: 0) { _ in }
        _ = await queue.waitUntilDone(quick)
        let slow = await queue.enqueue(title: "Slow", totalBytes: 0) { _ in
            signal.yield()
            try await Task.sleep(for: .seconds(30))
        }
        for await _ in started { break }
        await queue.removeFinishedJobs()
        let remaining = await queue.snapshots.map(\.id)
        XCTAssertEqual(remaining, [slow])
        let forgotten = await queue.snapshot(of: quick)
        XCTAssertNil(forgotten)
        await queue.cancel(slow)
        _ = await queue.waitUntilDone(slow)
    }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0

    var now: TimeInterval {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: JobProgress?

    var progress: JobProgress? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
