import Foundation
import TampCore

/// "Recommend for me": asks the goal once and remembers it, then runs
/// TampCore's Recommender (scan, sample, trial, rules) on the pending items
/// and shows what it found as a card the person can accept or dismiss.
extension AppModel {
    /// Only a plain archive-compress batch has a recommendation; extracting
    /// and a media batch don't.
    var canRecommend: Bool {
        if case .compress? = pendingAction, mediaItems.isEmpty { return true }
        return false
    }

    /// Opens the goal picker the first time, then runs directly on every
    /// later request, per the architecture plan ("asked once and remembered").
    func requestRecommendation() {
        guard canRecommend else { return }
        guard settings.recommendationGoal != nil else {
            isChoosingGoal = true
            return
        }
        runRecommendation()
    }

    func chooseGoal(_ goal: RecommendationGoal) {
        settings.recommendationGoal = goal
        isChoosingGoal = false
        runRecommendation()
    }

    func changeGoal() {
        isChoosingGoal = true
    }

    func dismissGoalPicker() {
        isChoosingGoal = false
    }

    private func runRecommendation() {
        guard case let .compress(items)? = pendingAction, let goal = settings.recommendationGoal else { return }
        recommendationTask?.cancel()
        recommendationResult = nil
        recommendationError = nil
        isRecommending = true
        let registry = registry
        let estimator = estimator
        let safety = safety
        let destination = ArchivePlanner.destination(for: items, format: choice.format).deletingLastPathComponent()
        recommendationTask = Task { [weak self] in
            do {
                let result = try await Recommender.recommend(
                    items: items, goal: goal, registry: registry, estimator: estimator, destination: destination, safety: safety
                )
                guard !Task.isCancelled else { return }
                if let result {
                    self?.recommendationResult = result
                } else {
                    self?.recommendationError = "Tamp couldn't find a format that fits safely on this Mac for these files."
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.recommendationError = TampError(error).localizedDescription
            }
            self?.isRecommending = false
        }
    }

    /// Sets the format picker and slider to the recommendation, which the
    /// person can still nudge afterward.
    func acceptRecommendation() {
        guard let result = recommendationResult else { return }
        select(format: result.recommendation.format)
        select(step: result.recommendation.step)
        recommendationResult = nil
    }

    func dismissRecommendation() {
        recommendationTask?.cancel()
        recommendationResult = nil
        isRecommending = false
    }

    func dismissRecommendationError() {
        recommendationError = nil
    }
}
