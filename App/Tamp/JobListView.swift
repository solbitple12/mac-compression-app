import SwiftUI
import TampCore

struct JobListView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Jobs")
                    .font(.headline)
                Spacer()
                if model.hasFinishedJobs {
                    Button("Clear Finished") { model.clearFinishedJobs() }
                        .buttonStyle(.link)
                }
            }
            if model.jobs.isEmpty {
                Text("Nothing running.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                List(model.jobs.reversed()) { job in
                    JobRow(job: job, model: model)
                }
                .listStyle(.inset)
            }
        }
        .frame(maxHeight: .infinity)
    }
}

struct JobRow: View {
    let job: JobSnapshot
    let model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(job.displayTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                status
            }
            Spacer(minLength: 8)
            actions
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var status: some View {
        switch job.state {
        case .queued:
            Text("Waiting…")
                .font(.caption)
                .foregroundStyle(.secondary)
        case let .running(progress):
            if let progress {
                ProgressView(value: progress.totalBytes > 0 ? progress.fractionCompleted : 0)
                    .accessibilityLabel(job.displayTitle)
                Text(ProgressText.status(progress))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .accessibilityLabel(job.displayTitle)
                Text("Starting…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .finished:
            Label("Done", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case let .failed(error):
            Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        case .cancelled:
            Text(TampError.cancelled.localizedDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var actions: some View {
        if !job.state.isFinal {
            Button {
                model.cancel(job.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .help("Stop this job")
            .accessibilityLabel("Stop")
        } else if job.state == .finished, let output = job.output {
            Button("Show in Finder") { model.showInFinder(output) }
        }
    }
}
