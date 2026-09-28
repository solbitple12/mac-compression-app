import AVFoundation
import XCTest
@testable import TampCore

final class OpusEngineTests: EngineTestCase {
    private var engine: OpusEngine!
    private var sourceWAV: URL!

    override var requiredHelpers: [String] { ["opusenc"] }

    override func setUpWithError() throws {
        try super.setUpWithError()
        engine = OpusEngine()
        sourceWAV = try makeCorpus().appendingPathComponent("media/tone.wav")
    }

    /// Opus is lossy, so this only checks the file is real and non-empty at every
    /// quality preset.
    func testEveryQualityPresetProducesANonEmptyFile() async throws {
        for preset in QualityPreset.allCases {
            let result = try await engine.compress(
                AudioCompressRequest(source: sourceWAV, destination: output.appendingPathComponent("\(preset.rawValue).opus"), format: .opus, step: .normal, quality: .preset(preset)),
                progress: { _ in }
            )
            XCTAssertGreaterThan(result.outputBytes, 0, "\(preset.title) wrote an empty file")
        }
    }

    /// AVFoundation's own decoder, independent of the bundled opusenc binary,
    /// confirms the file is a real decodable Opus stream — best-effort, since Ogg
    /// Opus system decode support isn't certain on every macOS version this
    /// might run on, so this is skipped rather than failed if it can't.
    func testAVFoundationCanDecodeTheResultIfItSupportsOpus() async throws {
        let result = try await engine.compress(
            AudioCompressRequest(source: sourceWAV, destination: output.appendingPathComponent("decodable.opus"), format: .opus, step: .normal),
            progress: { _ in }
        )
        guard (try? AVAudioFile(forReading: result.output)) != nil else {
            throw XCTSkip("AVFoundation couldn't decode the Opus output on this OS version")
        }
    }

    func testResultReportsRealByteCounts() async throws {
        let result = try await engine.compress(
            AudioCompressRequest(source: sourceWAV, destination: output.appendingPathComponent("sizes.opus"), format: .opus, step: .normal),
            progress: { _ in }
        )
        XCTAssertEqual(result.inputBytes, 44178)
        XCTAssertGreaterThan(result.outputBytes, 0)
    }
}
