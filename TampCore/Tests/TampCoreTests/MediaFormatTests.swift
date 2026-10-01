import XCTest
@testable import TampCore

/// Pure logic, no helpers needed: format detection and the quality/lossless rules.
final class MediaFormatTests: XCTestCase {
    func testImageFormatIsDetectedByExtensionCaseInsensitively() {
        XCTAssertEqual(MediaEngineRegistry.imageFormat(of: URL(fileURLWithPath: "/photo.JPG")), .jpeg)
        XCTAssertEqual(MediaEngineRegistry.imageFormat(of: URL(fileURLWithPath: "/photo.jpeg")), .jpeg)
        XCTAssertEqual(MediaEngineRegistry.imageFormat(of: URL(fileURLWithPath: "/scan.png")), .png)
        XCTAssertEqual(MediaEngineRegistry.imageFormat(of: URL(fileURLWithPath: "/pic.heic")), .heic)
        XCTAssertNil(MediaEngineRegistry.imageFormat(of: URL(fileURLWithPath: "/notes.txt")))
    }

    func testAudioFormatIsDetectedByExtension() {
        XCTAssertEqual(MediaEngineRegistry.audioFormat(of: URL(fileURLWithPath: "/song.flac")), .flac)
        XCTAssertEqual(MediaEngineRegistry.audioFormat(of: URL(fileURLWithPath: "/song.mp3")), .mp3)
        XCTAssertEqual(MediaEngineRegistry.audioFormat(of: URL(fileURLWithPath: "/song.m4a")), .alac)
        // WAV and AIFF are re-encode sources only, never a target format.
        XCTAssertNil(MediaEngineRegistry.audioFormat(of: URL(fileURLWithPath: "/song.wav")))
    }

    func testOnlyPNGIsAlwaysLossless() {
        for format in ImageFormat.allCases {
            XCTAssertEqual(format.isAlwaysLossless, format == .png)
        }
    }

    func testOnlyAlwaysLosslessAudioFormatsAreMarkedSo() {
        let expected: Set<AudioFormat> = [.flac, .alac, .wavpack]
        for format in AudioFormat.allCases {
            XCTAssertEqual(format.isAlwaysLossless, expected.contains(format))
        }
    }

    func testFormatsThatSupportLosslessImageEncoding() {
        let expected: Set<ImageFormat> = [.jpeg, .png, .webp, .jxl]
        for format in ImageFormat.allCases {
            XCTAssertEqual(format.supportsLossless, expected.contains(format))
        }
    }

    func testSavingsFractionFromResult() {
        let result = ImageCompressResult(output: URL(fileURLWithPath: "/out.jpg"), inputBytes: 1000, outputBytes: 400)
        XCTAssertEqual(result.savingsFraction, 0.6, accuracy: 0.0001)
    }

    func testSavingsFractionIsZeroForEmptyInput() {
        let result = AudioCompressResult(output: URL(fileURLWithPath: "/out.flac"), inputBytes: 0, outputBytes: 0)
        XCTAssertEqual(result.savingsFraction, 0)
    }

    func testEmptyRegistryOffersNoFormatsYet() {
        let registry = MediaEngineRegistry()
        XCTAssertTrue(registry.availableImageFormats.isEmpty)
        XCTAssertTrue(registry.availableAudioFormats.isEmpty)
        XCTAssertTrue(registry.availableVideoFormats.isEmpty)
    }

    func testVideoFormatIsDetectedByExtension() {
        XCTAssertEqual(MediaEngineRegistry.videoFormat(of: URL(fileURLWithPath: "/clip.webm")), .vp9)
        // MP4/MOV/MKV can each hold several codecs, so the extension alone
        // can't say which: these are re-encode sources, never a detected target.
        XCTAssertNil(MediaEngineRegistry.videoFormat(of: URL(fileURLWithPath: "/clip.mp4")))
        XCTAssertNil(MediaEngineRegistry.videoFormat(of: URL(fileURLWithPath: "/clip.mov")))
    }

    func testVideoSavingsFractionFromResult() {
        let result = VideoCompressResult(output: URL(fileURLWithPath: "/out.mp4"), inputBytes: 1000, outputBytes: 250)
        XCTAssertEqual(result.savingsFraction, 0.75, accuracy: 0.0001)
    }

    func testEveryMetadataHandlingHasATitle() {
        for handling in MetadataHandling.allCases {
            XCTAssertFalse(handling.title.isEmpty, "\(handling)")
        }
    }
}
