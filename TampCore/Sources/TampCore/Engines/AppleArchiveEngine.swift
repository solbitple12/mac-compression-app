import AppleArchive
import Foundation
import System

/// Apple Archive settings. The format has algorithms rather than levels, so the
/// steps pick an algorithm and a block size.
public struct AppleArchiveParameters: Equatable, Sendable {
    public enum Algorithm: String, Sendable {
        case none, lz4, lzfse, zlib, lzma

        var compression: ArchiveCompression {
            switch self {
            case .none: .none
            case .lz4: .lz4
            case .lzfse: .lzfse
            case .zlib: .zlib
            case .lzma: .lzma
            }
        }
    }

    public var algorithm: Algorithm
    /// Each block is compressed on its own, one per thread.
    public var blockBytes: Int
    public var threads: Int
}

public struct AppleArchiveMapping: SpeedStepMapping {
    public init() {}

    public var format: ArchiveFormat { .appleArchive }
    public var capabilities: EngineCapabilities { [.multithreading] }

    public func parameters(for step: SpeedStep, options: ArchiveOptions) -> AppleArchiveParameters {
        let mebibyte = 1 << 20
        let (algorithm, block): (AppleArchiveParameters.Algorithm, Int) = switch step {
        case .store: (.none, 4 * mebibyte)
        case .fastest: (.lz4, 4 * mebibyte)
        case .fast: (.lzfse, 4 * mebibyte)
        case .normal: (.zlib, 4 * mebibyte)
        case .good: (.lzma, 4 * mebibyte)
        case .best: (.lzma, 16 * mebibyte)
        }
        return AppleArchiveParameters(algorithm: algorithm, blockBytes: block, threads: options.threads)
    }

    public func hint(for step: SpeedStep, options: ArchiveOptions) -> StepHint {
        var notes = ["Opens only on macOS 11 and later"]
        if step == .best { notes.insert("Best differs from Good only in block size", at: 0) }
        return StepHint(
            step: step,
            summary: step.summary,
            peakMemoryBytes: Self.memory(for: parameters(for: step, options: options)),
            outputExtension: format.fileExtension,
            notes: notes
        )
    }

    /// Each thread holds a block in and a block out; LZMA's match finder adds about
    /// eleven times its dictionary, which is at most a block. The benchmark refines these.
    static func memory(for parameters: AppleArchiveParameters) -> UInt64 {
        let block = UInt64(parameters.blockBytes)
        let threads = UInt64(max(1, parameters.threads))
        let perThread: UInt64 = switch parameters.algorithm {
        case .none: 0
        case .lzma: 13 * block
        default: 2 * block + .mebibyte
        }
        return 32 * .mebibyte + threads * perThread
    }
}

/// Apple Archive (.aar) through Apple's AppleArchive framework, in-process. Keeps
/// everything macOS stores about a file: permissions, flags, dates, extended
/// attributes, ACLs, symbolic and hard links.
public struct AppleArchiveEngine: ArchiveEngine {
    /// The fields `aa archive` stores by default.
    static let fields = "TYP,PAT,LNK,DEV,DAT,MOD,FLG,MTM,BTM,CTM,XAT,ACL,HLC,CLC,UID,GID"
    /// An uncompressed archive starts with one of these; a compressed one with "pbz".
    static let rawSignatures = ["AA01", "YAA1"].map { Array($0.utf8) }
    static let compressedSignature = Array("pbz".utf8)

    private let mapping = AppleArchiveMapping()

    public init() {}

    public var format: ArchiveFormat { mapping.format }
    public var capabilities: EngineCapabilities { mapping.capabilities }

    public func parameters(for step: SpeedStep, options: ArchiveOptions) -> AppleArchiveParameters {
        mapping.parameters(for: step, options: options)
    }

    public func hint(for step: SpeedStep, options: ArchiveOptions) -> StepHint {
        mapping.hint(for: step, options: options)
    }

    public func compress(_ request: CompressRequest, progress: @escaping ProgressHandler) async throws -> URL {
        try request.checkNamesAreUnique()
        if let password = request.password, !password.isEmpty {
            throw TampError.other("Tamp can't protect Apple Archives with a password. Choose 7Z, ZIP or Disk Image for that.")
        }
        for item in request.items where !FileManager.default.fileExists(atPath: item.path) {
            throw TampError.fileNotFound(path: item.path)
        }
        var destination = request.destination
        if destination.pathExtension.lowercased() != format.fileExtension {
            destination.appendPathExtension(format.fileExtension)
        }
        let parameters = parameters(for: request.step, options: request.options)
        let items = request.items
        let excludesJunk = request.excludesMacOSJunk
        let totalBytes = InputSize.totalBytes(of: items)

        return try await SafeOutput.write(to: destination, fileExtension: format.fileExtension) { temporary in
            try await BlockingWork.run { flag in
                let monitor = StreamMonitor(totalBytes: totalBytes, flag: flag, progress: progress)
                try Self.write(items, to: temporary, parameters: parameters, excludesJunk: excludesJunk, monitor: monitor)
            }
        }
    }

    public func extract(_ request: ExtractRequest, progress: @escaping ProgressHandler) async throws -> URL {
        let archive = request.archive
        let totalBytes = Int64((try? archive.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let threads = ProcessInfo.processInfo.activeProcessorCount
        return try await SafeOutput.extract(
            into: request.destinationDirectory,
            baseName: archive.deletingPathExtension().lastPathComponent
        ) { staging in
            try await BlockingWork.run { flag in
                let monitor = StreamMonitor(totalBytes: totalBytes, flag: flag, progress: progress)
                try Self.read(archive, into: staging, threads: threads, monitor: monitor)
            }
        }
    }

    // MARK: Writing

    static func write(_ items: [URL], to archive: URL, parameters: AppleArchiveParameters,
                      excludesJunk: Bool, monitor: StreamMonitor) throws {
        guard let keySet = ArchiveHeader.FieldKeySet(fields) else { throw TampError.other("Apple Archive rejected its field list") }
        guard let file = ArchiveByteStream.fileStream(
            path: FilePath(archive.path), mode: .writeOnly, options: [.create, .exclusiveCreate],
            permissions: FilePermissions(rawValue: 0o644)
        ) else { throw TampError.permissionDenied(path: archive.path) }
        var streams: [ArchiveByteStream] = [file]
        var encoder: ArchiveStream?
        defer {
            // Only reached with streams left open on failure; each close is tried once.
            try? encoder?.close()
            for stream in streams.reversed() { try? stream.close() }
        }

        var output = file
        if parameters.algorithm != .none {
            guard let compressor = ArchiveByteStream.compressionStream(
                using: parameters.algorithm.compression, writingTo: file,
                blockSize: parameters.blockBytes, threadCount: parameters.threads
            ) else { throw TampError.other("Apple Archive couldn't start compressing") }
            streams.append(compressor)
            output = compressor
        }
        guard let counted = ArchiveByteStream.customStream(instance: CountingStream(output, monitor: monitor)) else {
            throw TampError.other("Apple Archive couldn't start writing")
        }
        streams.append(counted)
        guard let opened = ArchiveStream.encodeStream(writingTo: counted, threadCount: parameters.threads) else {
            throw TampError.other("Apple Archive couldn't start writing")
        }
        encoder = opened

        let filter: ArchiveHeader.EntryFilter = { message, path, _ in
            if monitor.flag.isCancelled { return .cancel }
            switch message {
            case .searchExclude, .searchPruneDirectory:
                return excludesJunk && isMacOSJunk(path.lastComponent?.string ?? "") ? .skip : .ok
            default:
                return .ok
            }
        }
        // writeDirectoryContents only archives folders, so files and links given on their
        // own are cloned into one scratch folder on their volume and archived from there,
        // with the scratch folder itself left out.
        var scratch: URL?
        defer { if let scratch { try? FileManager.default.removeItem(at: scratch) } }
        let skipRoot: ArchiveHeader.EntryFilter = { message, path, data in
            if message == .searchExclude, path.string.isEmpty || path.string == "." { return .skip }
            return filter(message, path, data)
        }
        do {
            for item in items {
                let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values?.isDirectory != true || values?.isSymbolicLink == true {
                    if scratch == nil {
                        scratch = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                              appropriateFor: item, create: true)
                    }
                    try cloneItem(item, into: scratch!)
                    continue
                }
                // Stored as the folder's name, then its contents below that.
                try opened.writeDirectoryContents(
                    archiveFrom: FilePath(item.deletingLastPathComponent().path),
                    path: FilePath(item.lastPathComponent),
                    keySet: keySet, selectUsing: filter, threadCount: parameters.threads
                )
            }
            if let scratch {
                try opened.writeDirectoryContents(archiveFrom: FilePath(scratch.path), keySet: keySet,
                                                  selectUsing: skipRoot, threadCount: parameters.threads)
            }
            encoder = nil
            try opened.close()
            while let stream = streams.popLast() { try stream.close() }
        } catch {
            if monitor.flag.isCancelled { throw CancellationError() }
            throw TampError.other("Apple Archive couldn't write the archive (\(error))")
        }
    }

    /// A copy-on-write clone on APFS, so even a large file costs nothing; a full copy elsewhere.
    /// Keeps the item's attributes, and copies a symbolic link rather than its target.
    static func cloneItem(_ item: URL, into folder: URL) throws {
        let target = folder.appendingPathComponent(item.lastPathComponent)
        guard copyfile(item.path, target.path, nil, copyfile_flags_t(COPYFILE_CLONE)) == 0 else {
            throw TampError.permissionDenied(path: item.path)
        }
    }

    static func isMacOSJunk(_ name: String) -> Bool {
        name == ".DS_Store" || name.hasPrefix("._") || name == "__MACOSX"
    }

    // MARK: Reading

    static func read(_ archive: URL, into staging: URL, threads: Int, monitor: StreamMonitor) throws {
        let isCompressed = hasPrefix(compressedSignature, archive)
        guard isCompressed || rawSignatures.contains(where: { hasPrefix($0, archive) }) else { throw TampError.corruptArchive }
        guard let file = ArchiveByteStream.fileStream(
            path: FilePath(archive.path), mode: .readOnly, options: [], permissions: FilePermissions(rawValue: 0o644)
        ) else { throw TampError.fileNotFound(path: archive.path) }
        var streams: [ArchiveByteStream] = [file]
        var archiveStreams: [ArchiveStream] = []
        defer {
            for stream in archiveStreams.reversed() { try? stream.close() }
            for stream in streams.reversed() { try? stream.close() }
        }
        guard let counted = ArchiveByteStream.customStream(instance: CountingStream(file, monitor: monitor)) else {
            throw TampError.corruptArchive
        }
        streams.append(counted)
        var input = counted
        if isCompressed {
            guard let decompressor = ArchiveByteStream.decompressionStream(readingFrom: counted, threadCount: threads) else {
                throw TampError.corruptArchive
            }
            streams.append(decompressor)
            input = decompressor
        }
        let guardian = PathGuard()
        let filter: ArchiveHeader.EntryFilter = { _, _, data in
            if monitor.flag.isCancelled { return .cancel }
            guard case let .header(header)? = data else { return .ok }
            return guardian.allows(header) ? .ok : .cancel
        }
        guard let decoder = ArchiveStream.decodeStream(readingFrom: input, selectUsing: filter, threadCount: threads) else {
            throw TampError.corruptArchive
        }
        archiveStreams.append(decoder)
        guard let extractor = ArchiveStream.extractStream(
            extractingTo: FilePath(staging.path), flags: [.ignoreOperationNotPermitted], threadCount: threads
        ) else { throw TampError.permissionDenied(path: staging.path) }
        archiveStreams.append(extractor)

        do {
            _ = try ArchiveStream.process(readingFrom: decoder, writingTo: extractor)
            while let stream = archiveStreams.popLast() { try stream.close() }
            while let stream = streams.popLast() { try stream.close() }
        } catch {
            if monitor.flag.isCancelled { throw CancellationError() }
            if guardian.rejected {
                throw TampError.other("This archive holds an item that would land outside its folder, so Tamp stopped.")
            }
            throw TampError.corruptArchive
        }
    }

    static func looksLikeAppleArchive(_ url: URL) -> Bool {
        ([compressedSignature] + rawSignatures).contains { hasPrefix($0, url) }
    }

    static func hasPrefix(_ prefix: [UInt8], _ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: prefix.count)).map { Array($0) == prefix } ?? false
    }
}

/// Stops an extraction before an entry that would land outside the destination:
/// an absolute path, a ".." component, or a path through a symbolic link the
/// archive created earlier.
final class PathGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var links = Set<String>()
    private var didReject = false

    var rejected: Bool { lock.withLock { didReject } }

    func allows(_ header: ArchiveHeader) -> Bool {
        var path = ""
        var isLink = false
        for field in header {
            switch field {
            case let .string(key, value) where key == ArchiveHeader.FieldKey("PAT"):
                path = value
            case let .uint(key, value) where key == ArchiveHeader.FieldKey("TYP"):
                isLink = value == UInt64(ArchiveHeader.EntryType.link.rawValue)
            default:
                break
            }
        }
        return allows(path: path, isLink: isLink)
    }

    func allows(path: String, isLink: Bool) -> Bool {
        lock.withLock { () -> Bool in
            let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            var safe = !path.hasPrefix("/") && !components.contains("..")
            if safe {
                for end in components.indices.dropLast() where links.contains(components[...end].joined(separator: "/")) {
                    safe = false
                }
            }
            if !safe { didReject = true }
            if safe, isLink { links.insert(components.joined(separator: "/")) }
            return safe
        }
    }
}

/// Counts the bytes an Apple Archive stream passes on, for progress, and stops it
/// when the job is cancelled.
final class CountingStream: ArchiveByteStreamProtocol {
    private let inner: ArchiveByteStream
    private let monitor: StreamMonitor

    init(_ inner: ArchiveByteStream, monitor: StreamMonitor) {
        self.inner = inner
        self.monitor = monitor
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        try monitor.checkCancellation()
        let count = try inner.read(into: buffer)
        monitor.add(count)
        return count
    }

    func read(into buffer: UnsafeMutableRawBufferPointer, atOffset offset: Int64) throws -> Int {
        try monitor.checkCancellation()
        let count = try inner.read(into: buffer, atOffset: offset)
        monitor.add(count)
        return count
    }

    func write(from buffer: UnsafeRawBufferPointer) throws -> Int {
        try monitor.checkCancellation()
        let count = try inner.write(from: buffer)
        monitor.add(count)
        return count
    }

    func write(from buffer: UnsafeRawBufferPointer, atOffset offset: Int64) throws -> Int {
        try monitor.checkCancellation()
        let count = try inner.write(from: buffer, atOffset: offset)
        monitor.add(count)
        return count
    }

    func seek(toOffset offset: Int64, relativeTo origin: FileDescriptor.SeekOrigin) throws -> Int64 {
        try inner.seek(toOffset: offset, relativeTo: origin)
    }

    func cancel() {
        inner.cancel()
    }

    /// The owner closes the wrapped stream, in order with the others.
    func close() throws {}
}

/// Progress and cancellation for work that runs outside Swift concurrency.
final class StreamMonitor: @unchecked Sendable {
    let flag: CancellationFlag
    private let totalBytes: Int64
    private let progress: ProgressHandler
    private let lock = NSLock()
    private var bytes: Int64 = 0
    private var reported: Int64 = 0

    init(totalBytes: Int64, flag: CancellationFlag, progress: @escaping ProgressHandler) {
        self.totalBytes = totalBytes
        self.flag = flag
        self.progress = progress
    }

    /// Also where a job paused by the resource monitor waits, between buffers.
    func checkCancellation() throws {
        let flag = flag
        flag.control?.waitWhilePaused(isCancelled: { flag.isCancelled })
        if flag.isCancelled { throw CancellationError() }
    }

    func add(_ count: Int) {
        let fraction = lock.withLock { () -> Double? in
            bytes += Int64(count)
            // About every megabyte, so progress doesn't cost more than the work.
            guard bytes - reported >= 1 << 20 else { return nil }
            reported = bytes
            return min(1, Double(bytes) / Double(max(1, totalBytes)))
        }
        if let fraction { progress(fraction) }
    }
}

final class CancellationFlag: @unchecked Sendable {
    /// The job's control, carried to the work's own thread, where task-locals don't reach.
    let control: JobControl?
    private let lock = NSLock()
    private var cancelled = false

    init(control: JobControl? = JobControl.current) {
        self.control = control
    }

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() {
        lock.withLock { cancelled = true }
    }
}

/// Runs blocking work, such as a framework call that can take minutes, on its own
/// thread, and raises the flag it checks when the job is cancelled.
enum BlockingWork {
    static func run(_ body: @escaping @Sendable (CancellationFlag) throws -> Void) async throws {
        let flag = CancellationFlag()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                Thread.detachNewThread {
                    continuation.resume(with: Result { try body(flag) })
                }
            }
        } onCancel: {
            flag.cancel()
        }
        try Task.checkCancellation()
    }
}
