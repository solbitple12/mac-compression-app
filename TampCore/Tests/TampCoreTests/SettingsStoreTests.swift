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

    func testRemembersTheMethodForEachFormat() {
        var choice = ArchiveChoice(format: .zip, step: .good)
        XCTAssertEqual(choice.method(for: .zip), .deflate)
        XCTAssertEqual(choice.method(for: .sevenZip), .lzma2)
        XCTAssertNil(choice.method(for: .tarZst))
        choice.setMethod(.zstd, for: .zip)
        choice.setMethod(.ppmd, for: .sevenZip)
        store.archiveChoice = choice
        let restored = SettingsStore(defaults: defaults).archiveChoice
        XCTAssertEqual(restored.method(for: .zip), .zstd)
        XCTAssertEqual(restored.method(for: .sevenZip), .ppmd)
        XCTAssertEqual(restored.options.method, .zstd)
    }

    func testChoicesSavedBeforeMethodsExistedStillLoad() {
        defaults.set(Data(#"{"format":"sevenZip","step":4}"#.utf8), forKey: SettingsStore.Key.archiveChoice)
        XCTAssertEqual(store.archiveChoice, ArchiveChoice(format: .sevenZip, step: .good))
        XCTAssertEqual(store.archiveChoice.method(for: .sevenZip), .lzma2)
        XCTAssertNil(store.archiveChoice.outputNamePattern)
    }

    func testAdvancedSettingsAreRememberedButNotForEveryFormat() {
        var choice = ArchiveChoice(format: .sevenZip, step: .best)
        choice.advanced.dictionaryMebibytes = 64
        choice.advanced.solid = .off
        choice.threads = 2
        choice.excludesMacOSJunk = false
        choice.volumeMebibytes = 100
        choice.verifies = true
        choice.trashesOriginals = true
        choice.outputNamePattern = "{name}-compressed"
        store.archiveChoice = choice
        let restored = SettingsStore(defaults: defaults).archiveChoice
        XCTAssertEqual(restored, choice)
        XCTAssertEqual(restored.outputNamePattern, "{name}-compressed")
        XCTAssertEqual(restored.options.threads, 2)
        XCTAssertEqual(restored.options.advanced.dictionaryMebibytes, 64)
        XCTAssertEqual(restored.volumeBytes, 100 << 20)
        // Only 7Z and ZIP (without Zstandard) split.
        var zstd = restored
        zstd.format = .zip
        zstd.setMethod(.zstd, for: .zip)
        XCTAssertNil(zstd.volumeBytes)
        zstd.format = .tarXz
        XCTAssertNil(zstd.volumeBytes)
    }

    func testOlderChoicesGetTheSafeDefaults() {
        defaults.set(Data(#"{"format":"zip","step":2,"methods":{"zip":"lzma"}}"#.utf8), forKey: SettingsStore.Key.archiveChoice)
        let choice = store.archiveChoice
        XCTAssertTrue(choice.excludesMacOSJunk)
        XCTAssertFalse(choice.verifies)
        XCTAssertFalse(choice.trashesOriginals)
        XCTAssertNil(choice.volumeMebibytes)
        XCTAssertNil(choice.threads)
        XCTAssertEqual(choice.advanced, AdvancedOptions())
        XCTAssertEqual(choice.method(for: .zip), .lzma)
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

    func testMediaChoiceStartsEmpty() {
        XCTAssertEqual(store.mediaChoice, MediaChoice())
    }

    func testMediaChoiceIsRememberedPerKind() {
        var choice = MediaChoice()
        choice.imageFormat = .webp
        choice.imageQuality = .preset(.veryHigh)
        choice.imageMetadata = .stripLocation
        choice.audioFormat = .opus
        choice.videoFormat = .av1
        store.mediaChoice = choice
        let restored = SettingsStore(defaults: defaults).mediaChoice
        XCTAssertEqual(restored, choice)
    }

    func testMediaChoiceUnreadableDataFallsBackToEmpty() {
        defaults.set("not data", forKey: SettingsStore.Key.mediaChoice)
        XCTAssertEqual(store.mediaChoice, MediaChoice())
    }

    func testMediaChoiceSavedBeforeNewerFieldsExistedStillLoads() {
        defaults.set(Data(#"{"imageFormat":"png"}"#.utf8), forKey: SettingsStore.Key.mediaChoice)
        let choice = store.mediaChoice
        XCTAssertEqual(choice.imageFormat, .png)
        XCTAssertNil(choice.audioFormat)
        XCTAssertNil(choice.videoQuality)
    }

    func testRecommendationGoalStartsUnanswered() {
        XCTAssertNil(store.recommendationGoal)
    }

    func testRecommendationGoalIsRememberedUntilCleared() {
        store.recommendationGoal = .smallest
        XCTAssertEqual(SettingsStore(defaults: defaults).recommendationGoal, .smallest)
        store.recommendationGoal = nil
        XCTAssertNil(store.recommendationGoal)
    }

    func testSafetySettingsStartAtTheBuiltInDefaults() {
        XCTAssertEqual(store.safetySettings, SafetySettings())
    }

    func testSafetySettingsAreRemembered() {
        var settings = SafetySettings()
        settings.memoryShare = 0.5
        settings.longJobSeconds = 10 * 60
        store.safetySettings = settings
        XCTAssertEqual(SettingsStore(defaults: defaults).safetySettings, settings)
    }

    func testSafetySettingsSavedBeforeNewerFieldsExistedStillLoad() {
        defaults.set(Data(#"{"memoryShare":0.5}"#.utf8), forKey: SettingsStore.Key.safetySettings)
        let settings = store.safetySettings
        XCTAssertEqual(settings.memoryShare, 0.5)
        XCTAssertEqual(settings.longJobSeconds, SafetySettings().longJobSeconds)
    }

    func testPresetsStartEmpty() {
        XCTAssertEqual(store.presets, [])
    }

    func testPresetsAreRememberedInOrder() {
        let choice = ArchiveChoice(format: .sevenZip, step: .best)
        let preset = ArchivePreset(name: "Max Compression", choice: choice)
        store.presets = [preset]
        XCTAssertEqual(SettingsStore(defaults: defaults).presets, [preset])
    }

    func testPresetApplyKeepsTheRestOfTheChoice() {
        var choice = ArchiveChoice(format: .zip, step: .fastest)
        choice.verifies = true
        choice.trashesOriginals = true
        let preset = ArchivePreset(name: "Best 7Z", choice: ArchiveChoice(format: .sevenZip, step: .best))
        let applied = preset.apply(to: choice)
        XCTAssertEqual(applied.format, .sevenZip)
        XCTAssertEqual(applied.step, .best)
        XCTAssertTrue(applied.verifies)
        XCTAssertTrue(applied.trashesOriginals)
    }

    func testUnfinishedBatchIsRememberedUntilCleared() {
        XCTAssertEqual(store.unfinishedBatch, [])
        let archives = [URL(fileURLWithPath: "/tmp/a.zip"), URL(fileURLWithPath: "/tmp/b.7z")]
        store.unfinishedBatch = archives
        XCTAssertEqual(SettingsStore(defaults: defaults).unfinishedBatch.map(\.path), archives.map(\.path))
        store.unfinishedBatch = []
        XCTAssertEqual(store.unfinishedBatch, [])
    }

    func testRecentJobsStartEmpty() {
        XCTAssertEqual(store.recentJobs, [])
    }

    func testRecentJobsAreRememberedNewestFirstAndCapped() {
        store.noteRecentJob(title: "Compressed “A”", output: URL(fileURLWithPath: "/tmp/a.zip"))
        store.noteRecentJob(title: "Compressed “B”", output: URL(fileURLWithPath: "/tmp/b.zip"))
        let reloaded = SettingsStore(defaults: defaults).recentJobs
        XCTAssertEqual(reloaded.map(\.title), ["Compressed “B”", "Compressed “A”"])
        XCTAssertEqual(reloaded.first?.output.path, "/tmp/b.zip")

        for index in 0..<30 {
            store.noteRecentJob(title: "Job \(index)", output: URL(fileURLWithPath: "/tmp/many/\(index).zip"))
        }
        XCTAssertEqual(store.recentJobs.count, SettingsStore.recentJobLimit)
        XCTAssertEqual(store.recentJobs.first?.title, "Job 29")
    }

    func testRecentFormatsAreRememberedNewestFirstDedupedAndCapped() {
        XCTAssertEqual(store.recentFormats, [])
        store.noteFormatUsed(.zip)
        store.noteFormatUsed(.sevenZip)
        store.noteFormatUsed(.zip)
        // Using zip again moves it back to the front rather than appearing twice.
        XCTAssertEqual(SettingsStore(defaults: defaults).recentFormats, [.zip, .sevenZip])

        store.noteFormatUsed(.tarZst)
        store.noteFormatUsed(.tarXz)
        XCTAssertEqual(store.recentFormats.count, SettingsStore.recentFormatLimit)
        XCTAssertEqual(store.recentFormats, [.tarXz, .tarZst, .zip])
    }
}
