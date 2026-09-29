import XCTest
@testable import TampCore

/// The path the per-item media panel takes: a dropped image, audio or video
/// file becomes its own queued job, independent of any other pending item -
/// unlike `ArchiveJobsTests`, where every dropped item bundles into one archive.
final class MediaJobsTests: EngineTestCase {
    override var requiredHelpers: [String] { ["oxipng", "flac", "ffmpeg"] }

    func testDroppedImageIsCompressedAsItsOwnJob() async throws {
        let corpus = try makeCorpus()
        let source = corpus.appendingPathComponent("media/diagram.png")
        let queue = JobQueue()
        let engine = OxipngEngine()
        let destination = MediaPlanner.destination(for: source, fileExtension: ImageFormat.png.fileExtension)
        let request = ImageCompressRequest(source: source, destination: destination, format: .png, step: .normal)
        let id = await MediaJobs.compress(request, engine: engine, on: queue)
        let done = await queue.waitUntilDone(id)
        XCTAssertEqual(done?.state, .finished)
        XCTAssertEqual(done?.displayTitle, "Compressed “diagram.png” as PNG")
        let output = try XCTUnwrap(done?.output)
        XCTAssertEqual(output.lastPathComponent, "diagram 2.png", "the source is already diagram.png, so the output takes the next free name")
        XCTAssertTrue(fileManager.fileExists(atPath: output.path))
    }

    func testDroppedAudioIsCompressedAsItsOwnJob() async throws {
        let corpus = try makeCorpus()
        let source = corpus.appendingPathComponent("media/tone.wav")
        let queue = JobQueue()
        let engine = FlacEngine()
        let destination = MediaPlanner.destination(for: source, fileExtension: AudioFormat.flac.fileExtension)
        let request = AudioCompressRequest(source: source, destination: destination, format: .flac, step: .normal)
        let id = await MediaJobs.compress(request, engine: engine, on: queue)
        let done = await queue.waitUntilDone(id)
        XCTAssertEqual(done?.state, .finished)
        XCTAssertEqual(done?.displayTitle, "Compressed “tone.wav” as FLAC")
        let output = try XCTUnwrap(done?.output)
        XCTAssertEqual(output.lastPathComponent, "tone.flac")
        XCTAssertTrue(fileManager.fileExists(atPath: output.path))
    }

    func testDroppedVideoIsCompressedAsItsOwnJob() async throws {
        let corpus = try makeCorpus()
        let source = corpus.appendingPathComponent("media/clip.mp4")
        let queue = JobQueue()
        let engine = H264Engine()
        let destination = MediaPlanner.destination(for: source, fileExtension: VideoFormat.h264.fileExtension)
        let request = VideoCompressRequest(source: source, destination: destination, format: .h264, step: .normal)
        let id = await MediaJobs.compress(request, engine: engine, on: queue)
        let done = await queue.waitUntilDone(id)
        XCTAssertEqual(done?.state, .finished)
        XCTAssertEqual(done?.displayTitle, "Compressed “clip.mp4” as H.264")
        let output = try XCTUnwrap(done?.output)
        XCTAssertEqual(output.lastPathComponent, "clip 2.mp4", "the source is already clip.mp4, so the output takes the next free name")
        XCTAssertTrue(fileManager.fileExists(atPath: output.path))
    }

    /// Two items dropped together must not collide with each other's output or
    /// job, the way archive items collide into a single bundled job on purpose.
    func testEachDroppedItemGetsItsOwnJobAndOutput() async throws {
        let corpus = try makeCorpus()
        let queue = JobQueue()
        let source = corpus.appendingPathComponent("media/diagram.png")
        let engine = OxipngEngine()
        let firstDestination = output.appendingPathComponent("first.png")
        let secondDestination = output.appendingPathComponent("second.png")
        async let first = MediaJobs.compress(
            ImageCompressRequest(source: source, destination: firstDestination, format: .png, step: .normal), engine: engine, on: queue
        )
        async let second = MediaJobs.compress(
            ImageCompressRequest(source: source, destination: secondDestination, format: .png, step: .normal), engine: engine, on: queue
        )
        let ids = await [first, second]
        XCTAssertEqual(Set(ids).count, 2, "two dropped items produce two distinct jobs")
        for id in ids {
            let done = await queue.waitUntilDone(id)
            XCTAssertEqual(done?.state, .finished)
        }
        XCTAssertTrue(fileManager.fileExists(atPath: firstDestination.path))
        XCTAssertTrue(fileManager.fileExists(atPath: secondDestination.path))
    }
}
