import SwiftUI
import TampCore

/// Asked once, before the first "Recommend for me", then remembered.
struct GoalPickerView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What matters most to you?")
                .font(.headline)
            ForEach(RecommendationGoal.allCases, id: \.self) { goal in
                Button {
                    model.chooseGoal(goal)
                } label: {
                    Text(goal.title)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Button("Cancel", role: .cancel) { model.dismissGoalPicker() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(20)
        .frame(width: 320)
    }
}

/// The recommended format and step, its estimate, an alternative when there
/// is one, and a plain-language reason - "Accept" sets the format picker and
/// slider, which the person can still nudge afterward.
struct RecommendationCardView: View {
    let result: RecommendationResult
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recommended: \(result.recommendation.format.title)")
                .font(.headline)
            Text(result.estimate.hintText(step: result.recommendation.step))
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(result.recommendation.reason)
                .fixedSize(horizontal: false, vertical: true)
            if let alternative = result.recommendation.alternative, let alternativeEstimate = result.alternativeEstimate {
                Text("Alternative: \(alternative.title) - \(alternativeEstimate.hintText(step: result.recommendation.step))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Change Goal") { model.changeGoal() }
                    .buttonStyle(.link)
                Spacer()
                Button("Dismiss", role: .cancel) { model.dismissRecommendation() }
                    .keyboardShortcut(.cancelAction)
                Button("Accept") { model.acceptRecommendation() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
