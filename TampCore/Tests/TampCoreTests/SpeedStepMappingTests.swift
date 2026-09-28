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
