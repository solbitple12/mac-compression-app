import XCTest
@testable import TampCore

final class SpeedStepTests: XCTestCase {
    func testSixStepsInSliderOrder() {
        XCTAssertEqual(SpeedStep.allCases.map(\.title), ["Store", "Fastest", "Fast", "Normal", "Good", "Best"])
        XCTAssertEqual(SpeedStep.allCases, SpeedStep.allCases.sorted())
    }

    func testStepsRoundTripThroughCodable() throws {
        let data = try JSONEncoder().encode(SpeedStep.good)
        XCTAssertEqual(try JSONDecoder().decode(SpeedStep.self, from: data), .good)
    }
}

final class ArchiveFormatTests: XCTestCase {
    func testPickerGroups() {
        XCTAssertEqual(ArchiveFormat.formats(in: .compatible), [.zip, .tar, .tarGz])
        XCTAssertEqual(ArchiveFormat.formats(in: .fast), [.tarZst, .tarLz4])
        XCTAssertEqual(ArchiveFormat.formats(in: .highRatio), [.sevenZip, .tarBz2, .tarXz, .tarLz, .tarBr])
        XCTAssertEqual(ArchiveFormat.formats(in: .extreme), [.zpaq])
        XCTAssertEqual(ArchiveFormat.formats(in: .macOSNative), [.appleArchive, .dmg])
    }

    func testEveryFormatIsInExactlyOneGroup() {
        let grouped = FormatGroup.allCases.flatMap { ArchiveFormat.formats(in: $0) }
        XCTAssertEqual(Set(grouped), Set(ArchiveFormat.allCases))
        XCTAssertEqual(grouped.count, ArchiveFormat.allCases.count)
    }

    func testExtensionsAreUnique() {
        let extensions = ArchiveFormat.allCases.map(\.fileExtension)
        XCTAssertEqual(Set(extensions).count, extensions.count)
    }
}

final class ZipMappingTests: XCTestCase {
    let mapping = ZipMapping()

    func testLevelsPerStep() {
        let levels = SpeedStep.allCases.map { mapping.parameters(for: $0, options: ArchiveOptions(threads: 4)).level }
        XCTAssertEqual(levels, [0, 1, 3, 5, 7, 9])
    }

    func testSevenZipArguments() {
        let parameters = mapping.parameters(for: .normal, options: ArchiveOptions(threads: 8))
        XCTAssertEqual(parameters.sevenZipArguments, ["-tzip", "-mm=Deflate", "-mx=5", "-mmt=8"])
    }

    func testStoreUsesCopyMethod() {
        let parameters = mapping.parameters(for: .store, options: ArchiveOptions(threads: 1))
        XCTAssertEqual(parameters.sevenZipArguments, ["-tzip", "-mm=Copy", "-mx=0", "-mmt=1"])
    }

    func testHintKeepsZipExtensionOnEveryStep() {
        for step in SpeedStep.allCases {
            XCTAssertEqual(mapping.hint(for: step, options: ArchiveOptions(threads: 2)).outputExtension, "zip")
        }
    }
}

final class TarZstMappingTests: XCTestCase {
    let mapping = TarZstMapping()
    let options = ArchiveOptions(threads: 4)

    private func zstd(_ step: SpeedStep) -> ZstdParameters? {
        if case let .zstd(parameters) = mapping.parameters(for: step, options: options) {
            return parameters
        }
        return nil
    }

    func testStoreWritesPlainTar() {
        XCTAssertEqual(mapping.parameters(for: .store, options: options), .plainTar)
        XCTAssertEqual(mapping.hint(for: .store, options: options).outputExtension, "tar")
    }

    func testLevelsPerStep() {
        let levels = SpeedStep.allCases.dropFirst().compactMap { zstd($0)?.level }
        XCTAssertEqual(levels, [1, 3, 9, 15, 22])
    }

    func testBestUsesUltraAndCompatibleLongWindow() {
        XCTAssertEqual(zstd(.best)?.cliArguments, ["--ultra", "-22", "--long=27", "-T4"])
        XCTAssertEqual(zstd(.good)?.cliArguments, ["-15", "--long=27", "-T4"])
        XCTAssertEqual(zstd(.normal)?.cliArguments, ["-9", "-T4"])
    }

    func testWindowNeverExceedsWhatStockZstdDecodes() {
        for step in SpeedStep.allCases {
            if let window = zstd(step)?.longWindowLog {
                XCTAssertLessThanOrEqual(window, ZstdParameters.maxCompatibleWindowLog)
            }
        }
    }

    func testMemoryGrowsWithStepAndThreads() {
        // Store writes a plain tar, so only the compressing steps are compared.
        let memory = SpeedStep.allCases.dropFirst().map { mapping.hint(for: $0, options: options).peakMemoryBytes }
        XCTAssertEqual(memory, memory.sorted())
        let oneThread = mapping.hint(for: .best, options: ArchiveOptions(threads: 1)).peakMemoryBytes
        XCTAssertEqual(mapping.hint(for: .best, options: options).peakMemoryBytes, oneThread * 4)
    }

    func testHintTextNamesTheStep() {
        let text = mapping.hint(for: .best, options: options).text
        XCTAssertTrue(text.hasPrefix("Best: smallest file, slowest, uses about "), text)
        XCTAssertTrue(text.hasSuffix(" RAM"), text)
    }

    func testThreadsNeverDropBelowOne() {
        XCTAssertEqual(ArchiveOptions(threads: 0).threads, 1)
    }
}

final class TarMappingTests: XCTestCase {
    let options = ArchiveOptions(threads: 4)

    private func compression(_ format: ArchiveFormat, _ step: SpeedStep) -> TarCompression {
        TarMapping(format: format).parameters(for: step, options: options)
    }

    func testEachFormatsToolAndLevels() {
        XCTAssertEqual(compression(.tarGz, .fastest), .tool(name: "pigz", arguments: ["-1", "-p", "4", "-c"]))
        XCTAssertEqual(compression(.tarGz, .best), .tool(name: "pigz", arguments: ["-11", "-p", "4", "-c"]))
        XCTAssertEqual(compression(.tarBz2, .normal), .tool(name: "pbzip2", arguments: ["-6", "-p4", "-c"]))
        XCTAssertEqual(compression(.tarXz, .fastest), .tool(name: "xz", arguments: ["-0", "-T4", "--memlimit-compress=50%", "-q", "-Q", "-c"]))
        XCTAssertEqual(compression(.tarXz, .best), .tool(name: "xz", arguments: ["-9e", "-T4", "--memlimit-compress=50%", "-q", "-Q", "-c"]))
        XCTAssertEqual(compression(.tarZst, .normal), .tool(name: "zstd", arguments: ["-9", "-T4", "-q", "-c"]))
        XCTAssertEqual(compression(.tarBr, .best), .tool(name: "brotli", arguments: ["-q", "11", "-w", "24", "-c"]))
        XCTAssertEqual(compression(.tarLz4, .best), .libarchiveFilter(name: "lz4", level: 9))
        XCTAssertEqual(compression(.tarLz, .fastest), .libarchiveFilter(name: "lzip", level: 0))
    }

    func testStoreAndPlainTarWriteNoCompression() {
        for format in [ArchiveFormat.tarGz, .tarBz2, .tarXz, .tarZst, .tarLz4, .tarLz, .tarBr] {
            XCTAssertEqual(compression(format, .store), TarCompression.plainTar, format.title)
            XCTAssertEqual(TarMapping(format: format).hint(for: .store, options: options).outputExtension, "tar")
            XCTAssertEqual(TarMapping(format: format).hint(for: .fast, options: options).outputExtension, format.fileExtension)
        }
        for step in SpeedStep.allCases {
            XCTAssertEqual(compression(.tar, step), TarCompression.plainTar)
            let hint = TarMapping(format: .tar).hint(for: step, options: options)
            XCTAssertEqual(hint.step, .store)
            XCTAssertEqual(hint.notes, ["TAR bundles files without compressing"])
        }
    }

    func testLevelsNeverRepeatAcrossCompressingSteps() {
        for format in [ArchiveFormat.tarGz, .tarBz2, .tarXz, .tarLz4, .tarLz, .tarBr] {
            let steps = SpeedStep.allCases.dropFirst().map { compression(format, $0) }
            XCTAssertEqual(Set(steps.map { "\($0)" }).count, steps.count, format.title)
        }
    }

    func testMemoryGrowsWithTheStep() {
        // One thread: with more, xz's thread cut can make Best need less than Good.
        let options = ArchiveOptions(threads: 1)
        for format in [ArchiveFormat.tarGz, .tarBz2, .tarXz, .tarZst, .tarLz, .tarBr] {
            let memory = SpeedStep.allCases.dropFirst().map { TarMapping(format: format).hint(for: $0, options: options).peakMemoryBytes }
            XCTAssertEqual(memory, memory.sorted(), format.title)
        }
    }

    func testXzMemoryMatchesItsManual() {
        // xz -9 with 8 threads was measured at about 10 GB before xz lowers the thread count.
        XCTAssertEqual(TarMapping.xzMemoryPerThread(preset: 9), (674 + 9 * 64) * .mebibyte)
        XCTAssertEqual(TarMapping.lzmaMemory(preset: 6), 94 * .mebibyte)
        // Never more than half the RAM, because xz lowers its thread count to fit.
        let best = TarMapping(format: .tarXz).hint(for: .best, options: ArchiveOptions(threads: 64)).peakMemoryBytes
        XCTAssertLessThanOrEqual(best, max(ProcessInfo.processInfo.physicalMemory / 2, TarMapping.xzMemoryPerThread(preset: 9)) + TarMapping.tarMemory)
    }

    func testOnlyThreadedToolsClaimMultithreading() {
        XCTAssertTrue(TarMapping(format: .tarXz).capabilities.contains(.multithreading))
        XCTAssertFalse(TarMapping(format: .tarLz4).capabilities.contains(.multithreading))
        XCTAssertFalse(TarMapping(format: .tarBr).capabilities.contains(.multithreading))
    }
}
