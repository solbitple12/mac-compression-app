import Foundation

/// The limits the checks before and during a job use. Phase 6 puts them in Preferences.
public struct SafetySettings: Codable, Equatable, Sendable {
    /// Ask before a job whose likely time is longer than this.
    public var longJobSeconds: TimeInterval = 30 * 60
    /// Ask before a job whose memory estimate is above this share of available memory.
    public var memoryShare: Double = 0.7
    /// Free space to leave on the output volume after the archive and its temporary files.
    public var diskReserveBytes: Int64 = 1 << 30
    /// Seconds a paused job waits for an answer before it stops on its own.
    public var answerTimeout: TimeInterval = 60

    public init() {}

    public var policy: ResourcePolicy {
        ResourcePolicy(warningShare: memoryShare, diskReserveBytes: diskReserveBytes, answerTimeout: answerTimeout)
    }

    private enum CodingKeys: String, CodingKey {
        case longJobSeconds, memoryShare, diskReserveBytes, answerTimeout
    }

    /// Settings saved by an older Tamp lack newer keys, which keep their defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        longJobSeconds = (try? container.decodeIfPresent(TimeInterval.self, forKey: .longJobSeconds)) ?? 30 * 60
        memoryShare = (try? container.decodeIfPresent(Double.self, forKey: .memoryShare)) ?? 0.7
        diskReserveBytes = (try? container.decodeIfPresent(Int64.self, forKey: .diskReserveBytes)) ?? 1 << 30
        answerTimeout = (try? container.decodeIfPresent(TimeInterval.self, forKey: .answerTimeout)) ?? 60
    }
}

/// Checks before a compress job starts: will it fit in memory, and on disk?
public enum Preflight {
    public enum Problem: Equatable, Sendable {
        /// The job's memory estimate is above the allowed share of what's available.
        case memory(needed: UInt64, available: UInt64)
        /// The archive (at the top of its size range), a check's temporary copy and
        /// the reserve don't fit on the volume.
        case disk(needed: Int64, free: Int64, volume: String)
    }

    /// Ways to make a job fit in memory, each with its own memory estimate.
    public struct MemoryFix: Equatable, Sendable {
        /// The highest lower step that fits, keeping the threads.
        public var lowerStep: (step: SpeedStep, memory: UInt64)?
        /// The most threads that fit at the chosen step.
        public var fewerThreads: (threads: Int, memory: UInt64)?

        public static func == (lhs: MemoryFix, rhs: MemoryFix) -> Bool {
            lhs.lowerStep?.step == rhs.lowerStep?.step && lhs.lowerStep?.memory == rhs.lowerStep?.memory
                && lhs.fewerThreads?.threads == rhs.fewerThreads?.threads && lhs.fewerThreads?.memory == rhs.fewerThreads?.memory
        }
    }

    public static func memoryProblem(peakMemoryBytes: UInt64, availableMemoryBytes: UInt64, settings: SafetySettings) -> Problem? {
        Double(peakMemoryBytes) > settings.memoryShare * Double(availableMemoryBytes)
            ? .memory(needed: peakMemoryBytes, available: availableMemoryBytes) : nil
    }

    /// - Parameters:
    ///   - outputBytes: The top of the archive's size range; the input size when there's no estimate.
    ///   - verifyBytes: What checking the archive extracts beside it, 0 without the check.
    public static func diskProblem(outputBytes: Int64, verifyBytes: Int64, destination: URL, settings: SafetySettings,
                                   freeBytes: (URL) -> [String: Int64] = { SystemResources.freeDisk(on: [$0]) }) -> Problem? {
        guard let volume = freeBytes(destination).first else { return nil }
        let needed = outputBytes + verifyBytes + settings.diskReserveBytes
        return needed > volume.value ? .disk(needed: needed, free: volume.value, volume: volume.key) : nil
    }

    /// The fixes that bring the memory estimate under `limit`.
    /// - Parameter memory: The corrected memory estimate for a step and thread count.
    public static func memoryFix(step: SpeedStep, threads: Int, limit: UInt64,
                                 memory: (SpeedStep, Int) -> UInt64) -> MemoryFix {
        var fix = MemoryFix()
        for candidate in SpeedStep.allCases.reversed() where candidate < step {
            let needed = memory(candidate, threads)
            if needed <= limit {
                fix.lowerStep = (candidate, needed)
                break
            }
        }
        if threads > 1 {
            for count in stride(from: threads - 1, through: 1, by: -1) {
                let needed = memory(step, count)
                if needed <= limit {
                    fix.fewerThreads = (count, needed)
                    break
                }
            }
        }
        return fix
    }
}
