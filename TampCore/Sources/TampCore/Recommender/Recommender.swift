import Foundation

/// The rules stage's pick, with real Estimator numbers standing in for its
/// plain-language guess, and the same for its alternative when one still
/// fits after the memory/disk checks.
public struct RecommendationResult: Sendable {
    public var recommendation: Recommendation
    public var estimate: Estimate
    public var alternativeEstimate: Estimate?
}

/// Ties the recommender's four stages together (see the architecture plan's
/// Recommender section): `RecommenderScan` and its entropy sampling build the
/// batch profile, `RecommenderRules` picks a format and step, and this runs
/// the real `Estimator` on that pick - the Trial stage - dropping any
/// candidate whose RAM or disk estimate would trip the pre-flight checks
/// before returning what's left, so the recommendation never needs its own
/// safety warning.
public enum Recommender {
    /// - Parameter destination: where the archive would be written, for the disk check.
    /// - Returns: nil when nothing survives the checks (or there's nothing to scan).
    public static func recommend(
        items: [URL], goal: RecommendationGoal, registry: EngineRegistry,
        estimator: Estimator, destination: URL, safety: SafetySettings = SafetySettings()
    ) async throws -> RecommendationResult? {
        let files = RecommenderScan.profiles(for: items)
        guard !files.isEmpty, let inputProfile = InputProfile.scan(items) else { return nil }
        let recommendation = RecommenderRules.recommend(profile: BatchProfile(files: files), goal: goal)

        if let primary = try await fittingEstimate(
            format: recommendation.format, step: recommendation.step, profile: inputProfile,
            registry: registry, estimator: estimator, destination: destination, safety: safety
        ) {
            var alternativeEstimate: Estimate?
            if let alternative = recommendation.alternative {
                alternativeEstimate = try await fittingEstimate(
                    format: alternative, step: recommendation.step, profile: inputProfile,
                    registry: registry, estimator: estimator, destination: destination, safety: safety
                )
            }
            return RecommendationResult(recommendation: recommendation, estimate: primary, alternativeEstimate: alternativeEstimate)
        }

        // The top pick isn't available in this build, or tripped a safety
        // check; promote its alternative, if it has one and that one fits.
        guard let alternative = recommendation.alternative,
              let promotedEstimate = try await fittingEstimate(
                  format: alternative, step: recommendation.step, profile: inputProfile,
                  registry: registry, estimator: estimator, destination: destination, safety: safety
              )
        else { return nil }
        var promoted = recommendation
        promoted.format = alternative
        promoted.alternative = nil
        promoted.reason += " (The usual pick didn't fit your Mac's available memory or disk space.)"
        return RecommendationResult(recommendation: promoted, estimate: promotedEstimate, alternativeEstimate: nil)
    }

    private static func fittingEstimate(
        format: ArchiveFormat, step: SpeedStep, profile: InputProfile,
        registry: EngineRegistry, estimator: Estimator, destination: URL, safety: SafetySettings
    ) async throws -> Estimate? {
        guard let engine = registry.engine(for: format) else { return nil }
        guard let estimate = try await estimator.estimate(for: profile, engine: engine, step: step, options: ArchiveOptions()) else {
            return nil
        }
        let available = SystemResources.availableMemory()
        if Preflight.memoryProblem(peakMemoryBytes: estimate.peakMemoryBytes, availableMemoryBytes: available, settings: safety) != nil {
            return nil
        }
        if Preflight.diskProblem(outputBytes: estimate.outputBytes.upperBound, verifyBytes: 0, destination: destination, settings: safety) != nil {
            return nil
        }
        return estimate
    }
}
