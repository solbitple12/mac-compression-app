import XCTest
@testable import TampCore

final class SettingsStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: SettingsStore!

    override func setUpWithError() throws {
        suiteName = "TampTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        store = SettingsStore(defaults: defaults)
    }

    override func tearDown() {
        defaults?.removePersistentDomain(forName: suiteName)
    }

    func testStartsAtZipNormal() {
        XCTAssertEqual(store.archiveChoice, ArchiveChoice(format: .zip, step: .normal))
    }

    func testRemembersTheLastChoice() {
        store.archiveChoice = ArchiveChoice(format: .tarZst, step: .best)
        XCTAssertEqual(SettingsStore(defaults: defaults).archiveChoice, ArchiveChoice(format: .tarZst, step: .best))
    }

    func testUnreadableDataFallsBackToTheDefault() {
        defaults.set(Data(#"{"format":"rar5","step":9}"#.utf8), forKey: SettingsStore.Key.archiveChoice)
        XCTAssertEqual(store.archiveChoice, .default)
        defaults.set("not data", forKey: SettingsStore.Key.archiveChoice)
        XCTAssertEqual(store.archiveChoice, .default)
    }

    func testAFormatThisBuildCantWriteFallsBackButKeepsTheStep() {
        store.archiveChoice = ArchiveChoice(format: .sevenZip, step: .good)
        XCTAssertEqual(store.archiveChoice(availableFormats: [.zip, .tarZst]), ArchiveChoice(format: .zip, step: .good))
        XCTAssertEqual(store.archiveChoice(availableFormats: [.tarZst]), ArchiveChoice(format: .tarZst, step: .good))
        XCTAssertEqual(store.archiveChoice(availableFormats: [.sevenZip, .zip]).format, .sevenZip)
    }

    func testRecentOutputDirectoriesAreDedupedNewestFirstAndCapped() {
        let a = URL(fileURLWithPath: "/tmp/a", isDirectory: true)
        let b = URL(fileURLWithPath: "/tmp/b", isDirectory: true)
        store.noteOutputDirectory(a)
        store.noteOutputDirectory(b)
        store.noteOutputDirectory(URL(fileURLWithPath: "/tmp/./a"))
        XCTAssertEqual(store.recentOutputDirectories.map(\.path), ["/tmp/a", "/tmp/b"])
        for index in 0..<30 {
            store.noteOutputDirectory(URL(fileURLWithPath: "/tmp/many/\(index)"))
        }
        XCTAssertEqual(store.recentOutputDirectories.count, SettingsStore.recentDirectoryLimit)
        XCTAssertEqual(store.recentOutputDirectories.first?.path, "/tmp/many/29")
    }
}
