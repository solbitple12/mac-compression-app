import XCTest
@testable import TampCore

/// Pure logic, no helpers needed: kind detection, default formats and destination naming.
final class MediaPlannerTests: XCTestCase {
    func testKindIsDetectedByExtensionCaseInsensitively() {
        XCTAssertEqual(MediaPlanner.kind(of: URL(fileURLWithPath: "/photo.JPG")), .image)
        XCTAssertEqual(MediaPlanner.kind(of: URL(fileURLWithPath: "/scan.png")), .image)
        XCTAssertEqual(MediaPlanner.kind(of: URL(fileURLWithPath: "/song.flac")), .audio)
        // WAV and AIFF are source-only formats, but still recognized as audio.
        XCTAssertEqual(MediaPlanner.kind(of: URL(fileURLWithPath: "/tone.WAV")), .audio)
        XCTAssertEqual(MediaPlanner.kind(of: URL(fileURLWithPath: "/clip.mp4")), .video)
        XCTAssertEqual(MediaPlanner.kind(of: URL(fileURLWithPath: "/clip.webm")), .video)
        XCTAssertNil(MediaPlanner.kind(of: URL(fileURLWithPath: "/archive.zip")))
        XCTAssertNil(MediaPlanner.kind(of: URL(fileURLWithPath: "/notes.txt")))
    }

    func testDefaultImageFormatKeepsTheSourceFormatWhenAvailable() {
        let url = URL(fileURLWithPath: "/photo.png")
        XCTAssertEqual(MediaPlanner.defaultImageFormat(for: url, available: [.jpeg, .png, .webp]), .png)
        XCTAssertEqual(MediaPlanner.defaultImageFormat(for: url, available: [.jpeg, .webp]), .jpeg, "falls back to the first available format")
        XCTAssertNil(MediaPlanner.defaultImageFormat(for: url, available: []))
    }

    func testDefaultAudioFormatPrefersFLACForSourceOnlyFiles() {
        let wav = URL(fileURLWithPath: "/tone.wav")
        XCTAssertEqual(MediaPlanner.defaultAudioFormat(for: wav, available: [.mp3, .flac, .opus]), .flac)
        XCTAssertEqual(MediaPlanner.defaultAudioFormat(for: wav, available: [.mp3, .opus]), .mp3, "falls back to the first available format without FLAC")
        let flac = URL(fileURLWithPath: "/song.flac")
        XCTAssertEqual(MediaPlanner.defaultAudioFormat(for: flac, available: [.mp3, .flac]), .flac, "keeps the source format when available")
    }

    func testDefaultVideoFormatPrefersH264() {
        XCTAssertEqual(MediaPlanner.defaultVideoFormat(available: [.vp9, .h264, .av1]), .h264)
        XCTAssertEqual(MediaPlanner.defaultVideoFormat(available: [.vp9, .av1]), .vp9, "falls back to the first available format without H.264")
        XCTAssertNil(MediaPlanner.defaultVideoFormat(available: []))
    }

    func testDestinationSitsBesideTheSourceWithTheNewExtension() {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("MediaPlannerTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let source = tempDirectory.appendingPathComponent("photo.jpg")
        let destination = MediaPlanner.destination(for: source, fileExtension: "webp")
        XCTAssertEqual(destination.deletingLastPathComponent().standardizedFileURL, tempDirectory.standardizedFileURL)
        XCTAssertEqual(destination.lastPathComponent, "photo.webp")
    }

    func testDestinationAvoidsAnExistingFile() throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("MediaPlannerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let source = tempDirectory.appendingPathComponent("photo.jpg")
        try Data().write(to: tempDirectory.appendingPathComponent("photo.webp"))
        let destination = MediaPlanner.destination(for: source, fileExtension: "webp")
        XCTAssertEqual(destination.lastPathComponent, "photo 2.webp")
    }
}
