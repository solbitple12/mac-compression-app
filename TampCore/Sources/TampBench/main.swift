import Foundation
import TampCore

// tamp-bench: time, size and peak memory of every format at every speed step,
// plus thread scaling, on the set from scripts/make-bench-set.sh.
//
//   tamp-bench --input DIR --json results.json --markdown results.md [--formats zip,tarXz] [--quick]
//
// Each measurement runs in a child copy of this tool, so getrusage(RUSAGE_CHILDREN)
// there covers exactly that job's helpers. Helpers come from TAMP_HELPERS_DIR.

struct Measurement: Codable {
    var format: String
    var method: String?
    var step: String
    var threads: Int
    var inputBytes: Int64
    var outputBytes: Int64
    var compressSeconds: Double
    var compressPeakBytes: Int64
    var extractSeconds: Double
    var extractPeakBytes: Int64
    var hintPeakBytes: UInt64
}

struct ChildResult: Codable {
    var seconds: Double
    var peakBytes: Int64
    var output: String
}

enum Bench {
    static let registry = EngineRegistry.standard()

    /// The largest resident size of any helper this process has waited for.
    /// macOS reports ru_maxrss in bytes.
    static func childrenPeakBytes() -> Int64 {
        var usage = rusage()
        getrusage(RUSAGE_CHILDREN, &usage)
        return Int64(usage.ru_maxrss)
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("tamp-bench: \(message)\n".utf8))
        exit(1)
    }

    static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    // MARK: Child

    /// `--child compress FORMAT STEP THREADS METHOD INPUT... --to DIR` or
    /// `--child extract ARCHIVE --to DIR`. Prints one JSON line.
    static func runChild(_ arguments: [String]) async {
        guard let destination = value(after: "--to", in: arguments) else { fail("child needs --to") }
        let target = URL(fileURLWithPath: destination, isDirectory: true)
        let start = Date()
        let output: URL
        do {
            if arguments[1] == "compress" {
                guard let format = ArchiveFormat(rawValue: arguments[2]),
                      let step = SpeedStep.allCases.first(where: { $0.title == arguments[3] }),
                      let threads = Int(arguments[4]),
                      let engine = registry.engine(for: format) else { fail("bad compress arguments \(arguments)") }
                let method = CompressionMethod(rawValue: arguments[5])
                let items = arguments[6..<(arguments.firstIndex(of: "--to") ?? arguments.count)].map { URL(fileURLWithPath: $0) }
                let request = CompressRequest(
                    items: items,
                    destination: target.appendingPathComponent("bench.\(format.fileExtension)"),
                    step: step,
                    options: ArchiveOptions(threads: threads, method: method)
                )
                output = try await engine.compress(request, progress: { _ in })
            } else {
                let archive = URL(fileURLWithPath: arguments[2])
                guard let extractor = registry.extractor(for: archive) else { fail("nothing opens \(archive.path)") }
                output = try await extractor.extract(ExtractRequest(archive: archive, destinationDirectory: target), progress: { _ in })
            }
        } catch {
            fail("\(arguments[1]) failed: \(TampError(error).localizedDescription)")
        }
        let result = ChildResult(seconds: Date().timeIntervalSince(start), peakBytes: childrenPeakBytes(), output: output.path)
        print(String(decoding: try! JSONEncoder().encode(result), as: UTF8.self))
    }

    static func child(_ arguments: [String]) throws -> ChildResult {
        let process = Process()
        process.executableURL = Bundle.main.executableURL
        process.arguments = ["--child"] + arguments
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { fail("child \(arguments.prefix(4)) exited with \(process.terminationStatus)") }
        return try JSONDecoder().decode(ChildResult.self, from: data)
    }

    // MARK: Parent

    static func measure(format: ArchiveFormat, method: CompressionMethod?, step: SpeedStep, threads: Int,
                        items: [URL], inputBytes: Int64, scratch: URL) throws -> Measurement {
        let fileManager = FileManager.default
        let run = scratch.appendingPathComponent(UUID().uuidString)
        let unpacked = run.appendingPathComponent("unpacked")
        try fileManager.createDirectory(at: unpacked, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: run) }

        let compressed = try child(["compress", format.rawValue, step.title, "\(threads)", method?.rawValue ?? "-"]
            + items.map(\.path) + ["--to", run.path])
        let archive = URL(fileURLWithPath: compressed.output)
        let size = try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let extracted = try child(["extract", archive.path, "--to", unpacked.path])
        let hint = registry.engine(for: format)?.hint(for: step, options: ArchiveOptions(threads: threads, method: method))
        return Measurement(
            format: format.rawValue, method: method?.rawValue, step: step.title, threads: threads,
            inputBytes: inputBytes, outputBytes: Int64(size),
            compressSeconds: compressed.seconds, compressPeakBytes: compressed.peakBytes,
            extractSeconds: extracted.seconds, extractPeakBytes: extracted.peakBytes,
            hintPeakBytes: hint?.peakMemoryBytes ?? 0
        )
    }

    static func runParent(_ arguments: [String]) throws {
        guard let input = value(after: "--input", in: arguments) else { fail("--input DIR is required") }
        let inputURL = URL(fileURLWithPath: input, isDirectory: true)
        let items = try FileManager.default.contentsOfDirectory(at: inputURL, includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let inputBytes = InputSize.totalBytes(of: items)
        let quick = arguments.contains("--quick")
        let formats = value(after: "--formats", in: arguments)
            .map { $0.split(separator: ",").compactMap { ArchiveFormat(rawValue: String($0)) } } ?? registry.availableFormats
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("tamp-bench-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }

        var results: [Measurement] = []
        func record(_ format: ArchiveFormat, _ method: CompressionMethod?, _ step: SpeedStep, _ threads: Int) throws {
            let result = try measure(format: format, method: method, step: step, threads: threads,
                                     items: items, inputBytes: inputBytes, scratch: scratch)
            results.append(result)
            FileHandle.standardError.write(Data(String(
                format: "%@ %@ %@ t%ld: %.1f%% in %.2fs, peak %.0f MB\n",
                format.title, method?.title ?? "", step.title, threads,
                Double(result.outputBytes) / Double(max(1, inputBytes)) * 100, result.compressSeconds,
                Double(result.compressPeakBytes) / 1_048_576
            ).utf8))
        }

        for format in formats {
            // Every step with the default method, then each other method at Normal.
            let steps = format == .tar ? [SpeedStep.store] : SpeedStep.allCases
            for step in steps where !(quick && step == .best && format == .zpaq) {
                try record(format, format.methods.first, step, cores)
            }
            for method in format.methods.dropFirst() {
                try record(format, method, .normal, cores)
            }
            // Thread scaling, for the Estimator.
            guard registry.engine(for: format)?.capabilities.contains(.multithreading) == true, !quick else { continue }
            let counts = Array(Set([1, 2, 4, 8, cores].filter { $0 <= cores })).sorted()
            for threads in counts where threads != cores {
                try record(format, format.methods.first, .normal, threads)
            }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = try encoder.encode(results)
        if let path = value(after: "--json", in: arguments) {
            try json.write(to: URL(fileURLWithPath: path))
        }
        let markdown = report(results, cores: cores, inputBytes: inputBytes)
        if let path = value(after: "--markdown", in: arguments) {
            try Data(markdown.utf8).write(to: URL(fileURLWithPath: path))
        }
        print(markdown)
    }

    /// Adjacent compressing steps closer than 1% in size and 15% in time.
    static func nearlyIdentical(_ rows: [Measurement]) -> [(String, String)] {
        var pairs: [(String, String)] = []
        let compressing = rows.filter { $0.step != SpeedStep.store.title }
        for (a, b) in zip(compressing, compressing.dropFirst()) {
            let size = abs(Double(a.outputBytes - b.outputBytes)) / Double(max(1, a.outputBytes))
            let time = abs(a.compressSeconds - b.compressSeconds) / max(0.01, a.compressSeconds)
            if size < 0.01 && time < 0.15 { pairs.append((a.step, b.step)) }
        }
        return pairs
    }

    static func report(_ results: [Measurement], cores: Int, inputBytes: Int64) -> String {
        func mb(_ bytes: Int64) -> String { String(format: "%.1f", Double(bytes) / 1_048_576) }
        var lines = [
            "# Tamp benchmark",
            "",
            "\(ProcessInfo.processInfo.operatingSystemVersionString), \(cores) cores, "
                + "\(ProcessInfo.processInfo.physicalMemory >> 30) GB RAM, input \(mb(inputBytes)) MB.",
            "Peak is the largest single helper process; a pipeline such as bsdtar into xz adds a few MB for bsdtar.",
            "",
            "| Format | Method | Step | Threads | Ratio | Compress s | MB/s | Peak MB | Hint MB | Extract s | Extract peak MB |",
            "| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
        ]
        for row in results {
            let ratio = Double(row.outputBytes) / Double(max(1, row.inputBytes)) * 100
            let speed = Double(row.inputBytes) / 1_048_576 / max(0.001, row.compressSeconds)
            lines.append("| \(row.format) | \(row.method ?? "") | \(row.step) | \(row.threads) | "
                + String(format: "%.1f%% | %.2f | %.1f | ", ratio, row.compressSeconds, speed)
                + "\(mb(row.compressPeakBytes)) | \(mb(Int64(row.hintPeakBytes))) | "
                + String(format: "%.2f", row.extractSeconds) + " | \(mb(row.extractPeakBytes)) |")
        }
        lines += ["", "## Nearly identical steps", ""]
        let groups = Dictionary(grouping: results.filter { $0.threads == cores }) { "\($0.format) \($0.method ?? "")" }
        var found = false
        for key in groups.keys.sorted() {
            for (a, b) in nearlyIdentical(groups[key] ?? []) {
                lines.append("- \(key): \(a) and \(b)")
                found = true
            }
        }
        if !found { lines.append("None.") }
        return lines.joined(separator: "\n") + "\n"
    }
}

let arguments = CommandLine.arguments
if arguments.count > 1, arguments[1] == "--child" {
    await Bench.runChild(Array(arguments.dropFirst()))
} else {
    do {
        try Bench.runParent(arguments)
    } catch {
        Bench.fail("\(error)")
    }
}
