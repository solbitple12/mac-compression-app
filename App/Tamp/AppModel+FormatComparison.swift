import Foundation
import TampCore

/// "Compare Formats": runs the same Estimator probe behind the size/time hint
/// across a few formats at once, side by side, rather than committing to
/// Recommend's single pick - useful when the person already knows roughly
/// what they want and just wants to see the trade-off.
extension AppModel {
    struct FormatComparisonRow: Identifiable, Sendable {
        let id = UUID()
        var format: ArchiveFormat
        var estimate: Estimate
    }

    /// Only a plain archive-compress batch has something to compare.
    var canCompareFormats: Bool { canRecommend }

    func compareFormats() {
        guard canCompareFormats, case let .compress(items)? = pendingAction else { return }
        formatComparisonTask?.cancel()
        formatComparison = nil
        formatComparisonError = nil
        isComparingFormats = true
        let registry = registry
        let estimator = estimator
        let step = choice.step
        let candidates = Self.comparisonCandidates(current: choice.format, available: registry.availableFormats)
        formatComparisonTask = Task { [weak self] in
            guard let profile = InputProfile.scan(items) else {
                self?.formatComparisonError = "Tamp couldn't read these files to compare formats."
                self?.isComparingFormats = false
                return
            }
            var rows: [FormatComparisonRow] = []
            for format in candidates {
                guard !Task.isCancelled else { return }
                guard let engine = registry.engine(for: format) else { continue }
                if let estimate = try? await estimator.estimate(for: profile, engine: engine, step: step, options: ArchiveOptions()) {
                    rows.append(FormatComparisonRow(format: format, estimate: estimate))
                }
            }
            guard !Task.isCancelled else { return }
            if rows.isEmpty {
                self?.formatComparisonError = "Tamp couldn't estimate any format for these files."
            } else {
                self?.formatComparison = rows
            }
            self?.isComparingFormats = false
        }
    }

    /// The current format first, then a few common ones worth showing beside
    /// it - small and fixed, so comparing stays quick rather than probing
    /// every format this build can write.
    static func comparisonCandidates(current: ArchiveFormat, available: [ArchiveFormat]) -> [ArchiveFormat] {
        var seen = Set<ArchiveFormat>()
        var result: [ArchiveFormat] = []
        for format in [current, .zip, .sevenZip, .tarZst] where available.contains(format) {
            if seen.insert(format).inserted { result.append(format) }
        }
        return result
    }

    /// Sets the format picker to one of the compared rows, keeping the step
    /// already used for the comparison.
    func chooseComparedFormat(_ format: ArchiveFormat) {
        select(format: format)
        formatComparison = nil
    }

    func dismissFormatComparison() {
        formatComparisonTask?.cancel()
        formatComparisonTask = nil
        isComparingFormats = false
        formatComparison = nil
    }

    func dismissFormatComparisonError() {
        formatComparisonError = nil
    }
}
