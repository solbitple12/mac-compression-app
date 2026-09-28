import XCTest
@testable import TampCore

final class FlacEngineTests: EngineTestCase {
    private var engine: FlacEngine!
    private var sourceWAV: URL!

    override var requiredHelpers: [String] { ["flac"] }

    override func setUpWithError() throws {
        try super.setUpWithError()
        engine = FlacEngine()
        sourceWAV = try makeCorpus().appendingPathComponent("media/tone.wav")
    }

    private func compress(source: URL? = nil, step: SpeedStep = .normal, metadata: MetadataHandling = .keep, name: String) async throws -> AudioCompressResult {
        try await engine.compress(
            AudioCompressRequest(source: source ?? sourceWAV, destination: output.appendingPathComponent(name), format: .flac, step: step, metadata: metadata),
            progress: { _ in }
        )
    }

    /// FLAC is always lossless, so decoding the output (through AVFoundation's own
    /// decoder, independent of the bundled flac binary) must give back the exact
    /// same samples as the source WAV, at every speed step.
    func testEveryStepRoundTripsSamplesExactly() async throws {
        let sourceSamples = try audioSamples(of: sourceWAV)
        for step in SpeedStep.allCases {
            let result = try await compress(step: step, name: "tone-\(step.rawValue).flac")
            XCTAssertGreaterThan(result.outputBytes, 0, "\(step.title) wrote an empty file")
            XCTAssertEqual(try audioSamples(of: result.output), sourceSamples, "\(step.title) changed the decoded samples")
        }
    }

    /// An existing FLAC as the source goes through the decode-then-re-encode path,
    /// which must round-trip the same way.
    func testFlacSourceRoundTripsThroughDecode() async throws {
        let first = try await compress(name: "once.flac")
        let sourceSamples = try audioSamples(of: sourceWAV)
        let second = try await engine.compress(
            AudioCompressRequest(source: first.output, destination: output.appendingPathComponent("twice.flac"), format: .flac, step: .best),
            progress: { _ in }
        )
        XCTAssertEqual(try audioSamples(of: second.output), sourceSamples)
    }

    func testResultReportsRealByteCounts() async throws {
        let result = try await compress(name: "sizes.flac")
        XCTAssertEqual(result.inputBytes, 44178)
        XCTAssertGreaterThan(result.outputBytes, 0)
    }
}
