import Darwin
import Foundation

/// One running job's helpers, so the resource monitor can measure and pause them.
///
/// `JobQueue` makes one per job and runs the job's work with it as
/// `JobControl.current`, a task-local that `ProcessRunner` and `ProcessPipeline`
/// read when they launch a helper. Pausing sends SIGSTOP to every helper (and to
/// any launched while paused); engines that work in-process call
/// `waitWhilePaused()` between buffers instead. Pausing halts growth but keeps the
/// memory a job holds; only stopping frees it.
public final class JobControl: @unchecked Sendable {
    @TaskLocal public static var current: JobControl?

    private let condition = NSCondition()
    private var processIDs: Set<pid_t> = []
    private var paused = false
    private var released = false
    private var peak: UInt64 = 0
    private var output: URL?

    public init() {}

    /// Where the job writes, so the resource monitor watches that volume's free space.
    public var outputDirectory: URL? {
        get { condition.withLock { output } }
        set { condition.withLock { output = newValue } }
    }

    public var isPaused: Bool {
        condition.withLock { paused }
    }

    /// Helpers running now.
    public var runningProcessIDs: [pid_t] {
        condition.withLock { Array(processIDs) }
    }

    /// The largest footprint the resource monitor has recorded, or nil if it never looked.
    public var peakFootprintBytes: UInt64? {
        condition.withLock { peak > 0 ? peak : nil }
    }

    public func recordFootprint(_ bytes: UInt64) {
        condition.withLock { peak = max(peak, bytes) }
    }

    func register(_ pid: pid_t) {
        let stopNow = condition.withLock { () -> Bool in
            processIDs.insert(pid)
            return paused
        }
        if stopNow { kill(pid, SIGSTOP) }
    }

    func unregister(_ pid: pid_t) {
        _ = condition.withLock { processIDs.remove(pid) }
    }

    public func pause() {
        let pids = condition.withLock { () -> [pid_t] in
            guard !paused, !released else { return [] }
            paused = true
            return Array(processIDs)
        }
        for pid in pids { kill(pid, SIGSTOP) }
    }

    public func resume() {
        let pids = condition.withLock { () -> [pid_t] in
            guard paused else { return [] }
            paused = false
            condition.broadcast()
            return Array(processIDs)
        }
        for pid in pids { kill(pid, SIGCONT) }
    }

    /// Lets everything run again for good, so a stopping job can reach its cleanup.
    public func release() {
        condition.withLock { released = true }
        resume()
    }

    /// For in-process engines, between buffers: blocks while paused. Checks
    /// `isCancelled` every half second so a stop isn't held up.
    public func waitWhilePaused(isCancelled: () -> Bool = { false }) {
        condition.lock()
        defer { condition.unlock() }
        while paused, !released, !isCancelled() {
            _ = condition.wait(until: Date().addingTimeInterval(0.5))
        }
    }
}
