import Foundation

/// Every failure a job can end with, each with a message a person can act on.
public enum TampError: Error, Equatable, Sendable {
    case cancelled
    case diskFull
    case outOfMemory
    case permissionDenied(path: String?)
    case wrongPassword
    case passwordRequired
    case corruptArchive
    case fileNotFound(path: String?)
    case helperMissing(name: String)
    case toolFailed(tool: String, exitCode: Int32, message: String)
    case other(String)
}

extension TampError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .cancelled:
            "Stopped. No partial files were left behind."
        case .diskFull:
            "The disk is full. Free up space or choose another destination."
        case .outOfMemory:
            "There isn't enough memory for these settings. Try a lower speed step or fewer threads."
        case let .permissionDenied(path):
            "Tamp doesn't have permission to use \(Self.displayName(path) ?? "this location"). Allow it in System Settings > Privacy & Security, or choose another folder."
        case .wrongPassword:
            "The password is wrong."
        case .passwordRequired:
            "This archive is encrypted. Enter its password to open it."
        case .corruptArchive:
            "This archive is damaged and can't be read completely."
        case let .fileNotFound(path):
            "\(Self.displayName(path) ?? "A file") no longer exists."
        case let .helperMissing(name):
            "Tamp is missing its \(name) component. Reinstall Tamp to restore it."
        case let .toolFailed(tool, exitCode, message):
            message.isEmpty
                ? "\(tool) stopped with error code \(exitCode)."
                : "\(tool) stopped with error code \(exitCode): \(message)"
        case let .other(message):
            message
        }
    }

    private static func displayName(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return "\u{201C}\(URL(fileURLWithPath: path).lastPathComponent)\u{201D}"
    }
}

extension TampError {
    /// Wraps any error thrown inside a job.
    public init(_ error: Error) {
        switch error {
        case let tamp as TampError:
            self = tamp
        case is CancellationError:
            self = .cancelled
        case let cocoa as CocoaError:
            switch cocoa.code {
            case .fileWriteOutOfSpace: self = .diskFull
            case .fileWriteNoPermission, .fileReadNoPermission: self = .permissionDenied(path: cocoa.filePath)
            case .fileNoSuchFile, .fileReadNoSuchFile: self = .fileNotFound(path: cocoa.filePath)
            default: self = .other(cocoa.localizedDescription)
            }
        case let posix as POSIXError:
            switch posix.code {
            case .ENOSPC: self = .diskFull
            case .ENOMEM: self = .outOfMemory
            case .EACCES, .EPERM: self = .permissionDenied(path: nil)
            case .ENOENT: self = .fileNotFound(path: nil)
            default: self = .other(posix.localizedDescription)
            }
        default:
            self = .other(error.localizedDescription)
        }
    }

    /// Maps a helper's exit code and error output to a specific error.
    /// The patterns cover 7zz, libarchive and the compressor tools' messages.
    public static func classify(tool: String, exitCode: Int32, standardError: String) -> TampError {
        let text = standardError.lowercased()
        func mentions(_ patterns: String...) -> Bool {
            patterns.contains { text.contains($0) }
        }
        if mentions("no space left on device", "disk full", "not enough space") {
            return .diskFull
        }
        // 7zz uses exit code 8 for "not enough memory".
        if exitCode == 8 || mentions("not enough memory", "cannot allocate memory", "out of memory") {
            return .outOfMemory
        }
        if mentions("wrong password") {
            return .wrongPassword
        }
        // 7zz reports a password prompt that got no answer as a break (exit code 255).
        if mentions("break signaled") {
            return .passwordRequired
        }
        if mentions("permission denied", "operation not permitted", "access is denied") {
            return .permissionDenied(path: nil)
        }
        if mentions("data error", "crc failed", "headers error", "unexpected end", "data corruption",
                    "truncated", "damaged", "can not open the file as archive", "premature end",
                    "unknown frame descriptor", "unrecognized archive format", "corrupt",
                    "decompression failed", "file format not recognized", "integrity") {
            return .corruptArchive
        }
        // avifenc's underlying SVT-AV1 encoder prints a multi-line "Svt[info]:" banner
        // (version, build config, thread count) to stderr before anything else, even
        // on success; skip those so a real failure further down isn't hidden behind
        // banner noise. SVT's own errors and warnings use the same prefix with a
        // different tag ("Svt[error]:", "Svt[warning]:") and are kept.
        //
        // ffmpeg does the same on every run, always to stderr, always before any
        // real error: an unindented "ffmpeg version ..." line (traced against
        // ffmpeg's own show_banner()/print_program_info() in fftools/opt_common.c),
        // then several indented lines ("built with", "configuration:", one or two
        // per linked library) that this function's own trimming already strips the
        // indentation from, so they're matched by their fixed text instead.
        let ffmpegBannerPrefixes = [
            "ffmpeg version ", "built with ", "configuration: ",
            "libavutil", "libavcodec", "libavformat", "libavdevice", "libavfilter", "libswscale", "libswresample",
        ]
        let firstLine = standardError
            .split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { line in
                !line.isEmpty && !line.hasPrefix("Svt[info]:") && !ffmpegBannerPrefixes.contains { line.hasPrefix($0) }
            } ?? ""
        return .toolFailed(tool: tool, exitCode: exitCode, message: String(firstLine.prefix(200)))
    }
}
