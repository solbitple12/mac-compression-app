import Foundation

public struct JobID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init() {
        rawValue = UUID()
    }

    public var description: String { rawValue.uuidString }
}

public enum JobState: Equatable, Sendable {
    case queued
    /// Progress is nil until the job reports its first bytes.
    case running(JobProgress?)
    case finished
    case failed(TampError)
    case cancelled

    public var isFinal: Bool {
        switch self {
        case .finished, .failed, .cancelled: true
        case .queued, .running: false
        }
    }
}

public struct JobSnapshot: Equatable, Sendable, Identifiable {
    public var id: JobID
    public var title: String
    public var state: JobState
    /// The archive or extracted item a finished job produced, for "Show in Finder".
    public var output: URL?
}

/// Handed to a running job so it can report progress without touching the queue's internals.
public final class JobContext: Sendable {
    public let id: JobID
    private let queue: JobQueue

    init(id: JobID, queue: JobQueue) {
        self.id = id
        self.queue = queue
    }

    public func reportProgress(bytesProcessed: Int64) async {
        await queue.recordProgress(id, bytesProcessed: bytesProcessed)
    }

    /// Records what the job produced; published with the job's next state change.
    public func reportOutput(_ url: URL) async {
        await queue.recordOutput(id, url: url)
    }
}

/// Runs every compress, extract and re-encode job off the main thread, a few at a
/// time, and publishes each state change. Cancelling a running job cancels its
/// task; the job's own code (the process runner and `SafeOutput`) stops the helper
/// and removes partial output.
public actor JobQueue {
    public typealias Work = @Sendable (JobContext) async throws -> Void

    private struct Entry {
        var snapshot: JobSnapshot
        var totalBytes: Int64
        var initialEstimate: TimeInterval?
        var work: Work
        var tracker: ThroughputTracker?
        var task: Task<Void, Never>?
    }

    public let maxConcurrentJobs: Int
    private let clock: @Sendable () -> TimeInterval
    private var entries: [JobID: Entry] = [:]
    private var order: [JobID] = []
    private var pending: [JobID] = []
    private var runningCount = 0
    private var observers: [UUID: AsyncStream<JobSnapshot>.Continuation] = [:]
    private var waiters: [JobID: [CheckedContinuation<JobSnapshot, Never>]] = [:]

    /// - Parameter clock: Seconds on a monotonic clock; injectable for tests.
    public init(
        maxConcurrentJobs: Int = 1,
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.maxConcurrentJobs = max(1, maxConcurrentJobs)
        self.clock = clock
    }

    /// - Parameters:
    ///   - totalBytes: Input size, used for % done and the ETA; 0 when unknown.
    ///   - initialEstimate: Seconds predicted before start, blended into the early ETA.
    @discardableResult
    public func enqueue(
        title: String,
        totalBytes: Int64,
        initialEstimate: TimeInterval? = nil,
        work: @escaping Work
    ) -> JobID {
        let id = JobID()
        entries[id] = Entry(
            snapshot: JobSnapshot(id: id, title: title, state: .queued),
            totalBytes: totalBytes,
            initialEstimate: initialEstimate,
            work: work
        )
        order.append(id)
        pending.append(id)
        publish(id)
        startNextJobs()
        return id
    }

    public func cancel(_ id: JobID) {
        guard let entry = entries[id], !entry.snapshot.state.isFinal else { return }
        if let index = pending.firstIndex(of: id) {
            pending.remove(at: index)
            finish(id, state: .cancelled)
        } else {
            entry.task?.cancel()
        }
    }

    public func cancelAll() {
        for id in order { cancel(id) }
    }

    /// Forgets jobs that have finished, failed or been cancelled.
    public func removeFinishedJobs() {
        let finished = order.filter { entries[$0]?.snapshot.state.isFinal == true }
        for id in finished { entries[id] = nil }
        order.removeAll { entries[$0] == nil }
    }

    public func snapshot(of id: JobID) -> JobSnapshot? {
        entries[id]?.snapshot
    }

    /// Every job in the order it was added.
    public var snapshots: [JobSnapshot] {
        order.compactMap { entries[$0]?.snapshot }
    }

    /// Returns once the job has finished, failed or been cancelled.
    public func waitUntilDone(_ id: JobID) async -> JobSnapshot? {
        guard let entry = entries[id] else { return nil }
        if entry.snapshot.state.isFinal { return entry.snapshot }
        return await withCheckedContinuation { continuation in
            waiters[id, default: []].append(continuation)
        }
    }

    /// A stream of every state change from now on, for the progress view.
    public func updates() -> AsyncStream<JobSnapshot> {
        let token = UUID()
        let (stream, continuation) = AsyncStream<JobSnapshot>.makeStream()
        observers[token] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(token) }
        }
        return stream
    }

    func recordProgress(_ id: JobID, bytesProcessed: Int64) {
        guard var entry = entries[id], case .running = entry.snapshot.state, var tracker = entry.tracker else { return }
        let progress = tracker.record(bytesProcessed: bytesProcessed, at: clock())
        entry.tracker = tracker
        entry.snapshot.state = .running(progress)
        entries[id] = entry
        publish(id)
    }

    func recordOutput(_ id: JobID, url: URL) {
        guard entries[id]?.snapshot.state.isFinal == false else { return }
        entries[id]?.snapshot.output = url
    }

    private func removeObserver(_ token: UUID) {
        observers[token] = nil
    }

    private func startNextJobs() {
        while runningCount < maxConcurrentJobs, !pending.isEmpty {
            let id = pending.removeFirst()
            guard var entry = entries[id] else { continue }
            runningCount += 1
            entry.tracker = ThroughputTracker(
                totalBytes: entry.totalBytes,
                startTime: clock(),
                initialEstimate: entry.initialEstimate
            )
            entry.snapshot.state = .running(nil)
            let work = entry.work
            let context = JobContext(id: id, queue: self)
            entry.task = Task { await self.execute(id, work: work, context: context) }
            entries[id] = entry
            publish(id)
        }
    }

    private func execute(_ id: JobID, work: Work, context: JobContext) async {
        let finalState: JobState
        do {
            try await work(context)
            finalState = .finished
        } catch {
            let tampError = TampError(error)
            finalState = tampError == .cancelled ? .cancelled : .failed(tampError)
        }
        runningCount -= 1
        finish(id, state: finalState)
        startNextJobs()
    }

    private func finish(_ id: JobID, state: JobState) {
        guard var entry = entries[id] else { return }
        entry.snapshot.state = state
        entry.task = nil
        entries[id] = entry
        publish(id)
        let snapshot = entry.snapshot
        for waiter in waiters.removeValue(forKey: id) ?? [] {
            waiter.resume(returning: snapshot)
        }
    }

    private func publish(_ id: JobID) {
        guard let snapshot = entries[id]?.snapshot else { return }
        for continuation in observers.values {
            continuation.yield(snapshot)
        }
    }
}
