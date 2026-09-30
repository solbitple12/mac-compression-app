import Foundation

/// What the person wants most, asked once and remembered (see `SettingsStore`).
public enum RecommendationGoal: String, CaseIterable, Codable, Sendable {
    case fastest
    case smallest
    case losslessOnly
    case opensAnywhere

    public var title: String {
        switch self {
        case .fastest: "Fastest"
        case .smallest: "Smallest"
        case .losslessOnly: "Lossless only"
        case .opensAnywhere: "Opens anywhere"
        }
    }
}

/// What the Scan and Sample stages found about a dropped batch, the Rules
/// stage's input alongside the goal. Pure data: no file I/O happens here.
public struct BatchProfile: Sendable {
    public var files: [FileProfile]

    public init(files: [FileProfile]) {
        self.files = files
    }

    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
    public var fileCount: Int { files.count }

    /// The fraction of total bytes already dense (compressed or encrypted):
    /// re-archiving these rarely shrinks them further.
    public var denseFraction: Double { fractionOfBytes(\.isAlreadyDense) }

    /// The fraction of total bytes that are text-like, which typically
    /// compresses very well.
    public var textFraction: Double { fractionOfBytes { $0.kind == .text } }

    /// The fraction of total bytes that are image, audio or video - formats
    /// with their own re-encode path that usually beats bundling into an archive.
    public var mediaFraction: Double { fractionOfBytes { [.image, .audio, .video].contains($0.kind) } }

    /// True when the batch mixes archives (or already-dense media) with
    /// plain, compressible files - a candidate for a split plan rather than
    /// one blanket recommendation (not yet implemented; see `RecommenderRules`).
    public var isMixed: Bool {
        let kinds = Set(files.map(\.kind))
        return kinds.count > 1 && denseFraction > 0 && denseFraction < 1
    }

    private func fractionOfBytes(_ matches: (FileProfile) -> Bool) -> Double {
        guard totalBytes > 0 else { return 0 }
        let matchingBytes = files.filter(matches).reduce(Int64(0)) { $0 + $1.bytes }
        return Double(matchingBytes) / Double(totalBytes)
    }
}

/// One recommended format and step, with an alternative to offer and a
/// plain-language reason. Predicted size and time aren't here yet - those
/// come from the Estimator once a real batch is on disk (the Trial stage).
public struct Recommendation: Equatable, Sendable {
    public var format: ArchiveFormat
    public var step: SpeedStep
    public var alternative: ArchiveFormat?
    public var reason: String

    public init(format: ArchiveFormat, step: SpeedStep, alternative: ArchiveFormat?, reason: String) {
        self.format = format
        self.step = step
        self.alternative = alternative
        self.reason = reason
    }
}

/// Stage 4: one pure function from a batch profile and a goal to a
/// recommendation, so the rules are unit-tested against fixed profiles with
/// no file I/O (see the architecture plan's Recommender section).
///
/// Two things the plan describes aren't here yet: a genuine media-re-encode
/// suggestion for a mostly-media batch (the dense-content rule below falls
/// back to Store instead), and a true split plan for a mixed batch
/// (`BatchProfile.isMixed` flags this, but the recommendation is still one
/// blanket format for now).
public enum RecommenderRules {
    public static func recommend(profile: BatchProfile, goal: RecommendationGoal) -> Recommendation {
        // "Must open anywhere" forces ZIP outright, overriding every other rule.
        if goal == .opensAnywhere {
            return Recommendation(
                format: .zip, step: .normal, alternative: nil,
                reason: "ZIP opens on every platform without extra software."
            )
        }
        // Already-compressed or encrypted content rarely shrinks further, so
        // packing it without recompressing avoids wasted time for little gain.
        if profile.denseFraction > 0.5 {
            return Recommendation(
                format: .zip, step: .store, alternative: nil,
                reason: "Most of this is already compressed or encrypted, so packing it without recompressing avoids wasted time for little size gain."
            )
        }
        // Every RecommendationGoal case is handled above or below, so this
        // switch is exhaustive with nothing left to fall through to.
        switch goal {
        case .opensAnywhere:
            preconditionFailure("handled above")
        case .losslessOnly:
            return Recommendation(
                format: .zip, step: .normal, alternative: .sevenZip,
                reason: "Every archive format here is lossless; ZIP is the most widely compatible."
            )
        case .smallest:
            if profile.textFraction > 0.6 {
                return Recommendation(
                    format: .zpaq, step: .best, alternative: .tarZst,
                    reason: "Mostly text-like data. ZPAQ's Best step gives the smallest file; zstd Good is much faster for a little more size."
                )
            }
            return Recommendation(
                format: .zpaq, step: .best, alternative: .sevenZip,
                reason: "ZPAQ's Best step gives the smallest archive here, at its slowest speed."
            )
        case .fastest:
            return Recommendation(
                format: .tarZst, step: .fastest, alternative: .zip,
                reason: "Zstandard at Fastest compresses quickly with a reasonable ratio."
            )
        }
    }
}
