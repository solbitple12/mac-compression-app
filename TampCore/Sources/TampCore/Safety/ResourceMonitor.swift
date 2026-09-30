import Foundation
import os

/// Decides how dangerous a sample is. Pure, so tests feed it made-up samples.
public struct ResourcePolicy: Equatable, Sendable {
    public enum Level: Int, Comparable, Sendable {
        case normal
        /// A yellow banner with current usage.
        case warning
        /// Jobs pause and Tamp asks what to do.
        case critical

        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Warn when jobs hold more than this share of the memory they could have
    /// (what's available plus what they already hold); the pre-flight threshold.
    public var warningShare: Double
    /// Critical when jobs hold more than this share of physical memory.
    public var criticalShareOfPhysical: Double
    /// Critical when swap grows by more than this within `swapWindow` seconds.
    public var swapGrowthBytes: UInt64
    public var swapWindow: TimeInterval
    /// Critical when an output volume has less free space than this.
    public var diskReserveBytes: Int64
    /// Seconds a critical level may go unanswered before jobs stop on their own.
    public var answerTimeout: TimeInterval

    public init(warningShare: Double = 0.7, criticalShareOfPhysical: Double = 0.9, swapGrowthBytes: UInt64 = 1 << 30,
                swapWindow: TimeInterval = 10, diskReserveBytes: Int64 = 1 << 30, answerTimeout: TimeInterval = 60) {
        self.warningShare = warningShare
        self.criticalShareOfPhysical = criticalShareOfPhysical
        self.swapGrowthBytes = swapGrowthBytes
        self.swapWindow = swapWindow
        self.diskReserveBytes = diskReserveBytes
        self.answerTimeout = answerTimeout
    }

    /// - Parameter swapGrowth: How much swap grew over the last `swapWindow` seconds.
    public func assess(_ sample: ResourceSample, swapGrowth: UInt64) -> (Level, String?) {
        let footprint = sample.jobFootprintBytes
        let memory = EstimateText.memory
        if let tightest = sample.freeDiskBytes.min(by: { $0.value < $1.value }), tightest.value < diskReserveBytes {
            return (.critical, "Only \(EstimateText.file(max(0, tightest.value))) is left on “\(tightest.key)”")
        }
        if sample.pressure == .critical {
            return (.critical, "The Mac is critically short of memory")
        }
        if Double(footprint) > criticalShareOfPhysical * Double(sample.physicalMemoryBytes) {
            return (.critical, "Tamp's jobs use \(memory(footprint)) of \(memory(sample.physicalMemoryBytes)) memory")
        }
        if swapGrowth > swapGrowthBytes {
            return (.critical, "The Mac is swapping fast: \(memory(swapGrowth)) in \(Int(swapWindow)) seconds")
        }
        if sample.pressure == .warning {
            return (.warning, "Memory is getting tight: Tamp's jobs use \(memory(footprint))")
        }
        if footprint > 0, Double(footprint) > warningShare * Double(sample.availableMemoryBytes + footprint) {
            return (.warning, "Tamp's jobs use \(memory(footprint)), most of the memory that's free")
        }
        return (.normal, nil)
    }
}

/// What the progress view shows: the RAM gauge, the banner, and the question
/// when jobs are paused.
public struct ResourceStatus: Equatable, Sendable {
    public var level: ResourcePolicy.Level = .normal
    public var reason: String?
    public var jobFootprintBytes: UInt64 = 0
    public var physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    /// Jobs the monitor paused, waiting for an answer.
    public var pausedJobs: [JobID] = []
    /// Seconds left before paused jobs stop on their own.
    public var secondsUntilAutomaticStop: TimeInterval?
    /// Set once when the monitor stopped jobs itself, with why.
    public var automaticStop: AutomaticStop?

    public struct AutomaticStop: Equatable, Sendable {
        public var jobs: [JobID]
        public var reason: String
    }

    public init() {}

    public var isAwaitingAnswer: Bool { !pausedJobs.isEmpty }
}

/// Watches running jobs once a second. At the warning level it only reports; at
/// the critical level it pauses every running job and waits for Resume, Stop
/// safely, or a restart with lower settings. Unanswered and still critical after
/// `answerTimeout`, it stops them safely on its own: pausing halts growth but
/// keeps the memory already held, and only a stop frees it.
public actor ResourceMonitor {
    public private(set) var policy: ResourcePolicy
    private let queue: JobQueue
    private let sampler: any ResourceSampling
    private let clock: @Sendable () -> TimeInterval
    private let logger = Logger(subsystem: "com.tamp.app", category: "resources")

    private var status = ResourceStatus()
    private var swapHistory: [(time: TimeInterval, bytes: UInt64)] = []
    private var pausedAt: TimeInterval?
    /// After Resume, a job isn't paused again for this long unless things get worse.
    private var quietUntil: TimeInterval = 0
    private var observers: [UUID: AsyncStream<ResourceStatus>.Continuation] = [:]
    private var loop: Task<Void, Never>?
    static let resumeGrace: TimeInterval = 30

    public init(queue: JobQueue, sampler: any ResourceSampling = SystemResources(), policy: ResourcePolicy = ResourcePolicy(),
                clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.queue = queue
        self.sampler = sampler
        self.policy = policy
        self.clock = clock
    }

    /// Samples once a second until `stop()`.
    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    public var currentStatus: ResourceStatus { status }

    /// Applied from the next tick onward, for a Preferences change made while jobs run.
    public func updatePolicy(_ newValue: ResourcePolicy) {
        policy = newValue
    }

    public func updates() -> AsyncStream<ResourceStatus> {
        let token = UUID()
        let (stream, continuation) = AsyncStream<ResourceStatus>.makeStream()
        observers[token] = continuation
        continuation.yield(status)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(token) }
        }
        return stream
    }

    // MARK: Answers

    public func resumePausedJobs() async {
        for id in status.pausedJobs { await queue.resume(id) }
        logger.notice("Resumed paused jobs at the person's request")
        status.pausedJobs = []
        status.secondsUntilAutomaticStop = nil
        pausedAt = nil
        quietUntil = clock() + Self.resumeGrace
        publish()
    }

    /// Cancels the paused jobs, which stops their helpers and removes partial output.
    public func stopPausedJobs() async {
        let jobs = status.pausedJobs
        for id in jobs { await queue.cancel(id) }
        logger.notice("Stopped \(jobs.count) paused job(s) at the person's request")
        status.pausedJobs = []
        status.secondsUntilAutomaticStop = nil
        pausedAt = nil
        publish()
    }

    /// Clears the automatic-stop notice once the app has shown its summary.
    public func acknowledgeAutomaticStop() {
        status.automaticStop = nil
        publish()
    }

    // MARK: Sampling

    /// One sample and whatever it calls for. The loop calls this every second;
    /// tests call it directly with a test clock.
    public func tick() async {
        let now = clock()
        let jobs = await queue.runningJobs
        var pids: [pid_t] = []
        for job in jobs {
            let own = job.control.runningProcessIDs
            job.control.recordFootprint(sampler.footprint(of: own))
            pids += own
        }
        let folders = Array(Set(jobs.compactMap { $0.control.outputDirectory }))
        let sample = sampler.sample(processIDs: pids, volumes: folders)

        swapHistory.append((now, sample.swapUsedBytes))
        swapHistory.removeAll { now - $0.time > policy.swapWindow }
        let oldestSwap = swapHistory.first?.bytes ?? sample.swapUsedBytes
        let growth = sample.swapUsedBytes > oldestSwap ? sample.swapUsedBytes - oldestSwap : 0

        let assessment: (ResourcePolicy.Level, String?) = jobs.isEmpty ? (.normal, nil) : policy.assess(sample, swapGrowth: growth)
        let (level, reason) = assessment
        status.jobFootprintBytes = sample.jobFootprintBytes
        status.physicalMemoryBytes = sample.physicalMemoryBytes
        status.level = level
        status.reason = reason
        status.pausedJobs.removeAll { id in !jobs.contains { $0.id == id } }

        if status.isAwaitingAnswer, let pausedAt {
            let left = policy.answerTimeout - (now - pausedAt)
            if left <= 0, level == .critical {
                await stopAutomatically(reason: reason ?? "Memory or disk space ran short")
            } else {
                status.secondsUntilAutomaticStop = level == .critical ? max(0, left) : nil
            }
        } else if status.isAwaitingAnswer {
            self.pausedAt = now
        } else if level == .critical, now >= quietUntil || sample.pressure == .critical {
            let running = jobs.map { $0.id }
            for id in running { await queue.pause(id) }
            status.pausedJobs = running
            pausedAt = now
            status.secondsUntilAutomaticStop = policy.answerTimeout
            logger.warning("Paused \(running.count) job(s): \(reason ?? "", privacy: .public)")
        }
        publish()
    }

    private func stopAutomatically(reason: String) async {
        let jobs = status.pausedJobs
        for id in jobs { await queue.cancel(id) }
        logger.error("Stopped \(jobs.count) job(s) on its own after no answer: \(reason, privacy: .public)")
        status.pausedJobs = []
        status.secondsUntilAutomaticStop = nil
        status.automaticStop = ResourceStatus.AutomaticStop(jobs: jobs, reason: reason)
        pausedAt = nil
    }

    private func publish() {
        for continuation in observers.values { continuation.yield(status) }
    }

    private func removeObserver(_ token: UUID) {
        observers[token] = nil
    }
}
