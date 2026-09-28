import Foundation

public struct ProcessResult: Equatable, Sendable {
    public var exitCode: Int32
    /// The last 64 KB of the helper's error output.
    public var standardError: String

    public var succeeded: Bool { exitCode == 0 }
}

/// Runs a bundled helper with an argument array (never a shell string), streams
/// its output line by line, and stops it safely when the calling task is
/// cancelled: SIGTERM first, SIGKILL only if it is still alive after the grace period.
public struct ProcessRunner: Sendable {
    public var terminationGracePeriod: TimeInterval

    public init(terminationGracePeriod: TimeInterval = 2) {
        self.terminationGracePeriod = terminationGracePeriod
        _ = Self.ignoreBrokenPipes
    }

    /// A helper that exits before reading its input must not take the app down with SIGPIPE.
    private static let ignoreBrokenPipes: Void = {
        _ = signal(SIGPIPE, SIG_IGN)
    }()

    /// - Parameters:
    ///   - standardInput: Written to the helper's stdin, then closed. Passwords go
    ///     here rather than in `arguments`, which other processes can read.
    ///   - onOutputLine: Called for each line of stdout. Carriage returns and
    ///     backspaces also end a line, since progress meters redraw with them.
    ///   - currentDirectory: The helper's working directory, for tools that store
    ///     paths relative to it. Nil keeps Tamp's own.
    /// - Throws: `CancellationError` when the task was cancelled, whatever the exit code.
    public func run(
        _ executable: URL,
        arguments: [String] = [],
        standardInput: Data? = nil,
        currentDirectory: URL? = nil,
        onOutputLine: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        let collector = OutputCollector(onLine: onOutputLine)
        // Each pipe's handler calls run one after another, so once a pipe reports its
        // end, everything it carried has been collected.
        let drained = DispatchGroup()
        drained.enter()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                if collector.markEnded(.output) { drained.leave() }
            } else {
                collector.appendOutput(data)
            }
        }
        drained.enter()
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                if collector.markEnded(.error) { drained.leave() }
            } else {
                collector.appendError(data)
            }
        }
        // Stops reading, and balances the group for each pipe that never reported its end.
        let abandonPipes = {
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            if collector.markEnded(.output) { drained.leave() }
            if collector.markEnded(.error) { drained.leave() }
        }
        let stopper = ProcessStopper(process: process, gracePeriod: terminationGracePeriod)

        let pipesDrained = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
                process.terminationHandler = { _ in
                    // The helper can exit before its last output reaches Tamp. A grandchild
                    // that inherited the pipes could hold them open, so don't wait forever.
                    DispatchQueue.global().async {
                        continuation.resume(returning: drained.wait(timeout: .now() + 5) == .success)
                    }
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    abandonPipes()
                    continuation.resume(throwing: TampError.helperMissing(name: executable.lastPathComponent))
                    return
                }
                stopper.didLaunch()
                if let standardInput {
                    try? input.fileHandleForWriting.write(contentsOf: standardInput)
                }
                try? input.fileHandleForWriting.close()
            }
        } onCancel: {
            stopper.stop()
        }

        if !pipesDrained { abandonPipes() }
        collector.flush()

        if stopper.wasStopped { throw CancellationError() }
        return ProcessResult(exitCode: process.terminationStatus, standardError: collector.errorText)
    }
}

/// Sends the stop signals, whether cancellation arrives before or after launch.
final class ProcessStopper: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private let gracePeriod: TimeInterval
    private var launched = false
    private var stopRequested = false

    init(process: Process, gracePeriod: TimeInterval) {
        self.process = process
        self.gracePeriod = gracePeriod
    }

    var wasStopped: Bool {
        lock.withLock { stopRequested }
    }

    func didLaunch() {
        let shouldSignal = lock.withLock { () -> Bool in
            launched = true
            return stopRequested
        }
        if shouldSignal { sendSignals() }
    }

    func stop() {
        let shouldSignal = lock.withLock { () -> Bool in
            stopRequested = true
            return launched
        }
        if shouldSignal { sendSignals() }
    }

    private func sendSignals() {
        guard process.isRunning else { return }
        let process = process
        let pid = process.processIdentifier
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + gracePeriod) {
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }
}

/// Splits stdout into lines and keeps the tail of stderr. Pipe handlers call it
/// from background queues, hence the lock.
final class OutputCollector: @unchecked Sendable {
    private static let errorLimit = 64 * 1024
    private static let lineBreaks: Set<UInt8> = [0x0A, 0x0D, 0x08]

    enum Stream: Hashable {
        case output
        case error
    }

    private let lock = NSLock()
    private let onLine: @Sendable (String) -> Void
    private var pending = Data()
    private var errorData = Data()
    private var ended: Set<Stream> = []

    init(onLine: @escaping @Sendable (String) -> Void) {
        self.onLine = onLine
    }

    var errorText: String {
        lock.withLock { String(decoding: errorData, as: UTF8.self) }
    }

    func appendOutput(_ data: Data) {
        let lines = lock.withLock { () -> [String] in
            pending.append(data)
            var lines: [String] = []
            while let index = pending.firstIndex(where: { Self.lineBreaks.contains($0) }) {
                lines.append(String(decoding: pending[pending.startIndex..<index], as: UTF8.self))
                pending = pending[pending.index(after: index)...]
            }
            return lines
        }
        emit(lines)
    }

    /// True the first time a stream reports its end, so the end is counted once.
    func markEnded(_ stream: Stream) -> Bool {
        lock.withLock { ended.insert(stream).inserted }
    }

    func appendError(_ data: Data) {
        lock.withLock {
            errorData.append(data)
            if errorData.count > Self.errorLimit {
                errorData = errorData.suffix(Self.errorLimit)
            }
        }
    }

    func flush() {
        let rest = lock.withLock { () -> String in
            defer { pending = Data() }
            return String(decoding: pending, as: UTF8.self)
        }
        emit([rest])
    }

    private func emit(_ lines: [String]) {
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { onLine(trimmed) }
        }
    }
}
