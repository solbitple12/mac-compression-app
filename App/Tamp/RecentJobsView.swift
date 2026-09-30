import SwiftUI
import TampCore

/// Finished jobs kept across launches, so a person can jump back to something
/// they compressed earlier without re-dragging it in. Each entry just opens
/// its output in Finder - if it's since been moved, renamed or deleted,
/// Finder's own "can't find" behavior is what shows, same as any stale alias.
struct RecentJobsMenu: View {
    let model: AppModel
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    var body: some View {
        Menu("Recent") {
            ForEach(model.recentJobs) { job in
                Button {
                    model.showInFinder(job.output)
                } label: {
                    Text("\(job.title) — \(Self.relativeFormatter.localizedString(for: job.finishedAt, relativeTo: Date()))")
                }
            }
            Divider()
            Button("Clear Recent") { model.clearRecentJobs() }
        }
        .fixedSize()
        .accessibilityIdentifier("recentJobsMenu")
    }
}
