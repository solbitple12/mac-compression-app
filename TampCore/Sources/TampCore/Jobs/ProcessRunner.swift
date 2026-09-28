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
    /// - Throws: `CancellationError` when the task was cancelled, whatever the exit code.
    public func run(
        _ executable: URL,
        arguments: [String] = [],
        standardInput: Data? = nil,
        onOutputLine: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        let collector = OutputCollector(onLine: onOutputLine)
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { collector.appendOutput(data) }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { collector.appendError(data) }
        }
        let stopper = ProcessStopper(process: process, gracePeriod: terminationGracePeriod)

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { _ in continuation.resume() }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    output.fileHandleForReading.readabilityHandler = nil
                    errors.fileHandleForReading.readabilityHandler = nil
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

        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        if let rest = try? output.fileHandleForReading.readToEnd() { collector.appendOutput(rest) }
        if let rest = try? errors.fileHandleForReading.readToEnd() { collector.appendError(rest) }
        collector.flush()

        if stopper.wasStopped { throw CancellationError() }
        return ProcessResult(exitCode: process.terminationStatus, standardError: collector.errorText)
    }
}

/// Sends the stop signals, whether cancellation arrives before or after launch.
private final class ProcessStopper: @unchecked Sendable {
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
private final class OutputCollector: @unchecked Sendable {
    private static let errorLimit = 64 * 1024
    private static let lineBreaks: Set<UInt8> = [0x0A, 0x0D, 0x08]

    private let lock = NSLock()
    private let onLine: @Sendable (String) -> Void
    private var pending = Data()
    private var errorData = Data()

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
