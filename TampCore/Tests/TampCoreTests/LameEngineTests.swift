import AVFoundation
import XCTest
@testable import TampCore

final class LameEngineTests: EngineTestCase {
    private var engine: LameEngine!
    private var sourceWAV: URL!

    override var requiredHelpers: [String] { ["lame"] }

    override func setUpWithError() throws {
        try super.setUpWithError()
        engine = LameEngine()
        sourceWAV = try makeCorpus().appendingPathComponent("media/tone.wav")
    }

    /// MP3 is lossy, so this only checks the file is a real, decodable MP3 at
    /// every quality preset, using AVFoundation's own decoder (independent of the
    /// bundled lame binary).
    func testEveryQualityPresetProducesADecodableFile() async throws {
        for preset in QualityPreset.allCases {
            let result = try await engine.compress(
                AudioCompressRequest(source: sourceWAV, destination: output.appendingPathComponent("\(preset.rawValue).mp3"), format: .mp3, step: .normal, quality: .preset(preset)),
                progress: { _ in }
            )
            XCTAssertGreaterThan(result.outputBytes, 0, "\(preset.title) wrote an empty file")
            XCTAssertNoThrow(try AVAudioFile(forReading: result.output), "\(preset.title) isn't a decodable MP3 file")
        }
    }

    func testResultReportsRealByteCounts() async throws {
        let result = try await engine.compress(
            AudioCompressRequest(source: sourceWAV, destination: output.appendingPathComponent("sizes.mp3"), format: .mp3, step: .normal),
            progress: { _ in }
        )
        XCTAssertEqual(result.inputBytes, 44144)
        XCTAssertGreaterThan(result.outputBytes, 0)
    }
}
