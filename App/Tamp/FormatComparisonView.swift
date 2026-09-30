import SwiftUI
import TampCore

/// "Compare Formats": the size, time and memory `Estimator` probe finds for a
/// few formats at once, side by side, so a format can be picked by the actual
/// trade-off rather than one recommendation.
struct FormatComparisonView: View {
    let rows: [AppModel.FormatComparisonRow]
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Compare Formats at \(model.effectiveStep.title)")
                .font(.headline)
            List(rows) { row in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.format.title)
                        Text(row.estimate.hintText(step: model.effectiveStep))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button("Use") { model.chooseComparedFormat(row.format) }
                }
            }
            .listStyle(.inset)
            .frame(minWidth: 420, minHeight: 200)
            HStack {
                Spacer()
                Button("Close") { model.dismissFormatComparison() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(SheetLayout.padding)
    }
}
