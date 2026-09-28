import Foundation

/// One helper in a pipeline whose stdin and stdout the caller wires up, such as
/// bsdtar feeding zstd. Stops the same way as `ProcessRunner`: SIGTERM, then SIGKILL.
final class ChildProcess: @unchecked Sendable {
    /// Name used in error messages.
    let name: String
    private let process: Process
    private let errors: Pipe
    private let collector = OutputCollector(onLine: { _ in })
    private let stopper: ProcessStopper
    private let lock = NSLock()
    private var exitStatus: Int32?
    private var waiters: [CheckedContinuation<Int32, Never>] = []

    /// - Parameters:
    ///   - standardInput, standardOutput: A `Pipe` or `FileHandle`, as `Process` accepts.
    init(name: String, executable: URL, arguments: [String], standardInput: Any, standardOutput: Any, gracePeriod: TimeInterval) {
        let process = Process()
        let errors = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = errors
        self.name = name
        self.process = process
        self.errors = errors
        stopper = ProcessStopper(process: process, gracePeriod: gracePeriod)

        let collector = collector
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { collector.appendError(data) }
        }
        // Cleared again in didExit, which breaks the retain cycle through the process.
        process.terminationHandler = { [self] finished in didExit(finished.terminationStatus) }
    }

    func launch() throws {
        do {
            try process.run()
        } catch {
            errors.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            throw TampError.helperMissing(name: process.executableURL?.lastPathComponent ?? name)
        }
        stopper.didLaunch()
    }

    func stop() {
        stopper.stop()
    }

    var wasStopped: Bool { stopper.wasStopped }

    /// Nil until the process has exited.
    var terminationStatus: Int32? {
        lock.withLock { exitStatus }
    }

    var standardErrorText: String { collector.errorText }

    /// Waits for a launched process to exit, then collects the rest of its error output.
    @discardableResult
    func waitUntilExit() async -> Int32 {
        let status = await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
            let finished = lock.withLock { () -> Int32? in
                if let exitStatus { return exitStatus }
                waiters.append(continuation)
                return nil
            }
            if let finished { continuation.resume(returning: finished) }
        }
        errors.fileHandleForReading.readabilityHandler = nil
        if let rest = try? errors.fileHandleForReading.readToEnd() { collector.appendError(rest) }
        return status
    }

    private func didExit(_ status: Int32) {
        let pending = lock.withLock { () -> [CheckedContinuation<Int32, Never>] in
            exitStatus = status
            defer { waiters = [] }
            return waiters
        }
        process.terminationHandler = nil
        for waiter in pending { waiter.resume(returning: status) }
    }
}

enum ProcessPipeline {
    /// Launches `stages`, copies `source` into `sink` while reporting the fraction of
    /// `totalBytes` copied, closes `sink`, and waits for every stage to exit.
    ///
    /// Cancelling the task stops every stage. Errors are reported in this order:
    /// cancellation, then the first stage in `checkOrder` that failed, then a copy
    /// error (usually a broken pipe caused by a stage that already failed).
    static func run(
        stages: [ChildProcess],
        checkOrder: [ChildProcess],
        source: FileHandle,
        sink: FileHandle,
        totalBytes: Int64,
        progress: @escaping ProgressHandler
    ) async throws {
        try await withTaskCancellationHandler {
            var launched: [ChildProcess] = []
            do {
                for stage in stages {
                    try stage.launch()
                    launched.append(stage)
                }
            } catch {
                try? sink.close()
                for stage in launched { stage.stop() }
                for stage in launched { await stage.waitUntilExit() }
                throw error
            }

            var copyError: Error?
            do {
                let total = Double(max(1, totalBytes))
                _ = try await copy(from: source, to: sink) { copied in
                    progress(min(1, Double(copied) / total))
                }
            } catch {
                copyError = error
            }
            // Closing both ends lets a stage that is still writing or reading see a
            // broken pipe and exit, so none is left blocked when another one failed.
            try? source.close()
            try? sink.close()
            for stage in stages { await stage.waitUntilExit() }

            if Task.isCancelled || stages.contains(where: \.wasStopped) {
                throw CancellationError()
            }
            for stage in checkOrder {
                if let status = stage.terminationStatus, status != 0 {
                    throw TampError.classify(tool: stage.name, exitCode: status, standardError: stage.standardErrorText)
                }
            }
            if let copyError { throw TampError(copyError) }
        } onCancel: {
            for stage in stages { stage.stop() }
        }
    }

    /// Copies until `source` reaches end of file, on a background queue so the
    /// blocking reads and writes stay off Swift's cooperative threads.
    /// - Returns: Bytes copied.
    static func copy(
        from source: FileHandle,
        to sink: FileHandle,
        chunkSize: Int = 1 << 20,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> Int64 {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var copied: Int64 = 0
                do {
                    while let chunk = try source.read(upToCount: chunkSize), !chunk.isEmpty {
                        try sink.write(contentsOf: chunk)
                        copied += Int64(chunk.count)
                        progress(copied)
                    }
                    continuation.resume(returning: copied)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
