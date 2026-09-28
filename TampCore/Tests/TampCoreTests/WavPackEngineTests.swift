import XCTest
@testable import TampCore

final class WavPackEngineTests: EngineTestCase {
    private var engine: WavPackEngine!
    private var sourceWAV: URL!

    override var requiredHelpers: [String] { ["wavpack", "wvunpack"] }

    override func setUpWithError() throws {
        try super.setUpWithError()
        engine = WavPackEngine()
        sourceWAV = try makeCorpus().appendingPathComponent("media/tone.wav")
    }

    private func compress(step: SpeedStep = .normal, name: String) async throws -> AudioCompressResult {
        try await engine.compress(
            AudioCompressRequest(source: sourceWAV, destination: output.appendingPathComponent(name), format: .wavpack, step: step),
            progress: { _ in }
        )
    }

    /// WavPack is always lossless. wvunpack decodes the result back to WAV (macOS
    /// has no system WavPack decoder to check against independently, the way FLAC's
    /// tests use AVFoundation), and that WAV's audio data must match the source's
    /// byte for byte.
    func testEveryStepRoundTripsSampleDataExactly() async throws {
        let sourceData = try Self.audioData(of: sourceWAV)
        for step in SpeedStep.allCases {
            let result = try await compress(step: step, name: "tone-\(step.rawValue).wv")
            XCTAssertGreaterThan(result.outputBytes, 0, "\(step.title) wrote an empty file")
            let decoded = try await Self.decode(result.output, into: output.appendingPathComponent("tone-\(step.rawValue)-decoded.wav"))
            XCTAssertEqual(try Self.audioData(of: decoded), sourceData, "\(step.title) changed the decoded audio")
        }
    }

    func testResultReportsRealByteCounts() async throws {
        let result = try await compress(name: "sizes.wv")
        XCTAssertEqual(result.inputBytes, 44178)
        XCTAssertGreaterThan(result.outputBytes, 0)
    }

    private static func decode(_ wv: URL, into wav: URL) async throws -> URL {
        let wvunpack = try HelperLocator.standard.url(for: "wvunpack")
        let result = try await ProcessRunner().run(wvunpack, arguments: ["-y", wv.path, "-o", wav.path])
        guard result.succeeded else {
            throw TampError.other("wvunpack failed: \(result.standardError)")
        }
        return wav
    }

    /// A WAV file's "data" chunk, found by walking its RIFF chunks rather than
    /// assuming a fixed header size, since wvunpack's output chunk layout doesn't
    /// have to match the source file's.
    private static func audioData(of url: URL) throws -> Data {
        let data = try Data(contentsOf: url)
        guard data.count >= 12, data[0..<4] == Data("RIFF".utf8), data[8..<12] == Data("WAVE".utf8) else {
            throw TampError.other("\(url.lastPathComponent) isn't a RIFF/WAVE file")
        }
        var offset = 12
        while offset + 8 <= data.count {
            let id = data[offset..<(offset + 4)]
            let sizeBytes = data[(offset + 4)..<(offset + 8)]
            let size = Int(sizeBytes.enumerated().reduce(UInt32(0)) { $0 | (UInt32($1.element) << (8 * $1.offset)) })
            let bodyStart = offset + 8
            if id == Data("data".utf8) {
                let end = min(data.count, bodyStart + size)
                return data[bodyStart..<end]
            }
            offset = bodyStart + size + (size % 2) // chunks are word-aligned
        }
        throw TampError.other("\(url.lastPathComponent) has no data chunk")
    }
}
