import Foundation

/// How long a compress job should take, how big its archive should be, and how
/// much memory it should use, as ranges when the samples disagree.
public struct Estimate: Equatable, Sendable {
    public var seconds: ClosedRange<Double>
    public var outputBytes: ClosedRange<Int64>
    public var peakMemoryBytes: UInt64
    /// From earlier jobs only, before a probe of this input has finished.
    public var isRough: Bool

    public init(seconds: ClosedRange<Double>, outputBytes: ClosedRange<Int64>, peakMemoryBytes: UInt64, isRough: Bool = false) {
        self.seconds = seconds
        self.outputBytes = outputBytes
        self.peakMemoryBytes = peakMemoryBytes
        self.isRough = isRough
    }

    /// The figure to plan with: the geometric middle of the range.
    public var likelySeconds: Double {
        (max(0, seconds.lowerBound) * max(0, seconds.upperBound)).squareRoot()
    }

    /// For example "Best: ~4 min · ~350 MB · uses ~2.1 GB RAM", with "(rough)" when
    /// it comes from earlier jobs only.
    public func hintText(step: SpeedStep) -> String {
        var parts = ["\(step.title): \(EstimateText.duration(seconds))", EstimateText.size(outputBytes),
                     "uses ~\(EstimateText.memory(peakMemoryBytes)) RAM"]
        if isRough { parts[0] += " (rough)" }
        return parts.joined(separator: " · ")
    }
}

/// Plain-language figures for estimates. A single figure appears only when the
/// range is within 25%; otherwise both ends are shown.
public enum EstimateText {
    static let singleFigureSpread = 1.25

    /// "under a second", "~40 s", "~4 min", "about 3 to 5 min", "~1 h 20 min".
    public static func duration(_ range: ClosedRange<Double>) -> String {
        let low = max(0, range.lowerBound)
        let high = max(low, range.upperBound)
        if high < 1 { return "under a second" }
        if low <= 0 || high / low <= singleFigureSpread {
            return "~" + duration((low * high).squareRoot().clamped(min: 1))
        }
        let (lowText, lowUnit) = durationParts(low)
        let (highText, highUnit) = durationParts(high)
        if lowUnit == highUnit, !lowUnit.isEmpty {
            return lowText == highText ? "~\(highText) \(highUnit)" : "about \(lowText) to \(highText) \(highUnit)"
        }
        return "about \(duration(low)) to \(duration(high))"
    }

    /// One duration without a range: "40 s", "4 min", "1 h 20 min".
    public static func duration(_ seconds: Double) -> String {
        let (text, unit) = durationParts(seconds)
        return unit.isEmpty ? text : "\(text) \(unit)"
    }

    /// The number and unit apart, so a range can share the unit. Hours carry
    /// their minutes in the number and have no separate unit.
    static func durationParts(_ seconds: Double) -> (String, String) {
        switch seconds {
        case ..<1: return ("1", "s")
        case ..<60: return ("\(Int(seconds.rounded()))", "s")
        case ..<(60 * 60 - 30): return ("\(max(1, Int((seconds / 60).rounded())))", "min")
        default:
            let minutes = Int((seconds / 60).rounded())
            let hours = minutes / 60
            let rest = minutes % 60
            if hours >= 10 || rest == 0 { return ("\(Int((seconds / 3600).rounded()))", "h") }
            return ("\(hours) h \(rest) min", "")
        }
    }

    /// "~350 MB", or "300 to 400 MB" when the range is wider than 25%.
    public static func size(_ range: ClosedRange<Int64>) -> String {
        let low = max(0, range.lowerBound)
        let high = max(low, range.upperBound)
        if low == 0 || Double(high) / Double(low) <= singleFigureSpread {
            return "~" + file(Int64((Double(low) * Double(high)).squareRoot().rounded()).clamped(min: high == 0 ? 0 : 1))
        }
        return "\(file(low)) to \(file(high))"
    }

    public static func file(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    public static func memory(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory)
    }
}

extension Comparable {
    func clamped(min lower: Self) -> Self {
        Swift.max(lower, self)
    }
}
