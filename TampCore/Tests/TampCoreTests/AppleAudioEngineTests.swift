import AVFoundation
import XCTest
@testable import TampCore

/// No bundled helper for either engine: both run through AVFoundation on every
/// Mac Tamp supports, so no `requiredHelpers`.
final class AppleAudioEngineTests: EngineTestCase {
    private var sourceWAV: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        sourceWAV = try makeCorpus().appendingPathComponent("media/tone.wav")
    }

    func testEveryAACPresetProducesADecodableFile() async throws {
        let engine = AACEngine()
        for preset in QualityPreset.allCases {
            let result = try await engine.compress(
                AudioCompressRequest(source: sourceWAV, destination: output.appendingPathComponent("\(preset.rawValue).m4a"), format: .aac, step: .normal, quality: .preset(preset)),
                progress: { _ in }
            )
            XCTAssertGreaterThan(result.outputBytes, 0, "\(preset.title) wrote an empty file")
            XCTAssertNoThrow(try AVAudioFile(forReading: result.output), "\(preset.title) isn't a decodable AAC file")
        }
    }

    /// ALAC is lossless, so decoding it back must give the exact same samples as
    /// the source WAV.
    func testALACRoundTripsSamplesExactly() async throws {
        let engine = ALACEngine()
        let result = try await engine.compress(
            AudioCompressRequest(source: sourceWAV, destination: output.appendingPathComponent("lossless.m4a"), format: .alac, step: .normal),
            progress: { _ in }
        )
        XCTAssertGreaterThan(result.outputBytes, 0)
        XCTAssertEqual(try audioSamples(of: result.output), try audioSamples(of: sourceWAV))
    }

    func testResultReportsRealByteCounts() async throws {
        let result = try await ALACEngine().compress(
            AudioCompressRequest(source: sourceWAV, destination: output.appendingPathComponent("sizes.m4a"), format: .alac, step: .normal),
            progress: { _ in }
        )
        XCTAssertEqual(result.inputBytes, 44178)
        XCTAssertGreaterThan(result.outputBytes, 0)
    }
}
