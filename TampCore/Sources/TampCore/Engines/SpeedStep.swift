/// The six fixed positions of the speed slider. Every format maps each step
/// to its own real settings, so the slider behaves the same for all of them.
public enum SpeedStep: Int, CaseIterable, Codable, Sendable, Comparable {
    case store = 0
    case fastest
    case fast
    case normal
    case good
    case best

    public var title: String {
        switch self {
        case .store: "Store"
        case .fastest: "Fastest"
        case .fast: "Fast"
        case .normal: "Normal"
        case .good: "Good"
        case .best: "Best"
        }
    }

    /// Plain-language trade-off shown next to the slider.
    public var summary: String {
        switch self {
        case .store: "no compression, just bundles the files"
        case .fastest: "largest file, very fast"
        case .fast: "fast, good for big folders"
        case .normal: "balanced size and speed"
        case .good: "smaller file, slower"
        case .best: "smallest file, slowest"
        }
    }

    public static func < (lhs: SpeedStep, rhs: SpeedStep) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
