import Foundation

/// The status line under a running job: "42% · 38.1 MB/s · 0:12 elapsed · about 2 min left".
public enum ProgressText {
    public static func status(_ progress: JobProgress) -> String {
        var parts: [String] = []
        if progress.totalBytes > 0 {
            parts.append("\(Int((progress.fractionCompleted * 100).rounded(.down)))%")
        }
        if progress.bytesPerSecond > 0 {
            let speed = ByteCountFormatter.string(fromByteCount: Int64(progress.bytesPerSecond), countStyle: .file)
            parts.append("\(speed)/s")
        }
        parts.append("\(clock(progress.elapsed)) elapsed")
        if let remaining = progress.estimatedTimeRemaining {
            parts.append(timeLeft(remaining))
        }
        return parts.joined(separator: " · ")
    }

    /// "0:07", "12:30" or "1:02:03".
    public static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded(.down))
        let (hours, minutes, secs) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    /// Rounded up, so the estimate errs toward finishing early.
    public static func timeLeft(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<1: return "almost done"
        case ..<60: return "less than a minute left"
        case ..<3600: return "about \(Int((seconds / 60).rounded(.up))) min left"
        default:
            let minutes = Int((seconds / 60).rounded(.up))
            let (hours, rest) = (minutes / 60, minutes % 60)
            return rest == 0 ? "about \(hours) h left" : "about \(hours) h \(rest) min left"
        }
    }
}
