import XCTest
@testable import TampCore

final class ProcessRunnerTests: XCTestCase {
    private let shell = URL(fileURLWithPath: "/bin/sh")

    func testCollectsOutputLinesAndExitCode() async throws {
        let lines = LineRecorder()
        let result = try await ProcessRunner().run(
            shell,
            arguments: ["-c", "printf 'one\\ntwo\\r 50%%\\n'; echo oops >&2; exit 3"],
            onOutputLine: { lines.append($0) }
        )
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.standardError, "oops\n")
        XCTAssertEqual(lines.all, ["one", "two", "50%"])
    }

    func testPassesStandardInput() async throws {
        let lines = LineRecorder()
        let result = try await ProcessRunner().run(
            URL(fileURLWithPath: "/bin/cat"),
            standardInput: Data("secret\n".utf8),
            onOutputLine: { lines.append($0) }
        )
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(lines.all, ["secret"])
    }

    func testMissingHelperIsReported() async {
        do {
            _ = try await ProcessRunner().run(URL(fileURLWithPath: "/nonexistent/7zz"))
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? TampError, .helperMissing(name: "7zz"))
        }
    }

    func testCancelStopsTheHelperWithSIGTERM() async throws {
        let started = Date()
        let task = Task {
            try await ProcessRunner().run(shell, arguments: ["-c", "exec sleep 30"])
        }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        let result = await task.result
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testCancelEscalatesToSIGKILLWhenTERMIsIgnored() async throws {
        let started = Date()
        let task = Task {
            try await ProcessRunner(terminationGracePeriod: 0.5)
                .run(shell, arguments: ["-c", "trap '' TERM; exec sleep 30"])
        }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        let result = await task.result
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }
}

final class LineRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.withLock { lines.append(line) }
    }

    var all: [String] {
        lock.withLock { lines }
    }
}
