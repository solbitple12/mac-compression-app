import SwiftUI
import TampCore

/// Asked before a job starts when it may not fit in memory or on disk, or will take long.
struct StartQuestionView: View {
    let question: AppModel.StartQuestion
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch question {
            case let .memory(needed, available, fix):
                Text("This job may need more memory than is free")
                    .font(.headline)
                Text("\(model.effectiveStep.title) with \(model.choice.options.threads) threads could use about \(EstimateText.memory(needed)), and \(EstimateText.memory(available)) is free. Other apps may slow down, and Tamp will pause the job if memory runs out.")
                    .fixedSize(horizontal: false, vertical: true)
                if let lower = fix.lowerStep {
                    Button("Use \(lower.step.title) (about \(EstimateText.memory(lower.memory)))") {
                        model.useStep(lower.step, approving: .memory)
                    }
                    .accessibilityIdentifier("useLowerStep")
                }
                if let fewer = fix.fewerThreads {
                    Button("Use \(fewer.threads) thread\(fewer.threads == 1 ? "" : "s") (about \(EstimateText.memory(fewer.memory)))") {
                        model.useThreads(fewer.threads)
                    }
                    .accessibilityIdentifier("useFewerThreads")
                }
                buttons(continueTitle: "Continue Anyway", approval: .memory)
            case let .disk(needed, free, volume):
                Text("“\(volume)” may run out of space")
                    .font(.headline)
                Text("The archive\(model.choice.verifies ? ", its check" : "") and a safety margin need up to \(EstimateText.file(needed)), and \(EstimateText.file(free)) is free. If space runs short, Tamp pauses the job and asks what to do.")
                    .fixedSize(horizontal: false, vertical: true)
                buttons(continueTitle: "Continue Anyway", approval: .disk)
            case let .longJob(estimate):
                Text("This will take \(EstimateText.duration(estimate.seconds))")
                    .font(.headline)
                Text("\(model.effectiveStep.title) on this input is slow. A faster step saves time for a somewhat larger archive.")
                    .fixedSize(horizontal: false, vertical: true)
                if let faster = model.fasterOption {
                    Button("Use \(faster.step.title): \(EstimateText.duration(faster.estimate.seconds)), \(EstimateText.size(faster.estimate.outputBytes))") {
                        model.useStep(faster.step, approving: .longJob)
                    }
                    .accessibilityIdentifier("useFasterStep")
                } else if model.isFindingFasterOption {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Looking for a faster step…").foregroundStyle(.secondary)
                    }
                } else {
                    Text("Even Fastest takes longer than that.").foregroundStyle(.secondary)
                }
                buttons(continueTitle: "Start Anyway", approval: .longJob)
            case let .mediaMemory(needed, available):
                Text("This batch may need more memory than is free")
                    .font(.headline)
                Text("It could use about \(EstimateText.memory(needed)), and \(EstimateText.memory(available)) is free. Other apps may slow down, and Tamp will pause a job if memory runs out.")
                    .fixedSize(horizontal: false, vertical: true)
                buttons(continueTitle: "Continue Anyway", approval: .memory)
            case let .mediaDisk(needed, free, volume):
                Text("“\(volume)” may run out of space")
                    .font(.headline)
                Text("These files and a safety margin need up to \(EstimateText.file(needed)), and \(EstimateText.file(free)) is free. If space runs short, Tamp pauses the batch and asks what to do.")
                    .fixedSize(horizontal: false, vertical: true)
                buttons(continueTitle: "Continue Anyway", approval: .disk)
            }
        }
        .padding(SheetLayout.padding)
        .frame(width: SheetLayout.standard, alignment: .leading)
    }

    private func buttons(continueTitle: String, approval: AppModel.StartApproval) -> some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { model.dismissStartQuestion() }
                .keyboardShortcut(.cancelAction)
            Button(continueTitle) { model.approve(approval) }
                .keyboardShortcut(.defaultAction)
        }
    }
}

/// Shown while the resource monitor has paused jobs: resume, stop safely, or restart lower.
struct PausedJobsView: View {
    let model: AppModel

    var body: some View {
        let status = model.resourceStatus
        VStack(alignment: .leading, spacing: 14) {
            Label("Tamp paused \(status.pausedJobs.count == 1 ? "a job" : "\(status.pausedJobs.count) jobs")", systemImage: "pause.circle.fill")
                .font(.headline)
            Text(status.reason ?? "Memory or disk space is running short.")
            Text("A paused job keeps the memory it already holds; only stopping frees it.")
                .foregroundStyle(.secondary)
            if let seconds = status.secondsUntilAutomaticStop {
                Text("If this isn't answered, the job stops safely in \(Int(seconds.rounded())) s.")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .monospacedDigit()
            }
            HStack {
                if let option = model.restartOption {
                    Button(restartTitle(option)) {
                        model.restartPausedJobs()
                    }
                    .help("About \(EstimateText.memory(option.memory)) of memory")
                    .accessibilityIdentifier("restartLower")
                }
                Spacer()
                Button("Stop Safely", role: .destructive) { model.stopPausedJobs() }
                    .accessibilityIdentifier("stopSafely")
                Button("Resume") { model.resumePausedJobs() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("resumePaused")
            }
        }
        .padding(SheetLayout.padding)
        .frame(width: SheetLayout.wide, alignment: .leading)
    }

    /// "Restart at Fast, 2 threads" for an archive job, "Restart at Fast" for
    /// a media item, which has no thread count.
    private func restartTitle(_ option: AppModel.RestartOption) -> String {
        guard let threads = option.threads else { return "Restart at \(option.step.title)" }
        return "Restart at \(option.step.title), \(threads) thread\(threads == 1 ? "" : "s")"
    }
}

/// The RAM gauge and, at the warning level, the yellow banner, above the job list.
struct ResourceBanner: View {
    let status: ResourceStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Gauge(value: Double(status.jobFootprintBytes), in: 0...Double(max(1, status.physicalMemoryBytes))) {
                Text("Memory")
            } currentValueLabel: {
                Text("\(EstimateText.memory(status.jobFootprintBytes)) of \(EstimateText.memory(status.physicalMemoryBytes))")
                    .monospacedDigit()
            }
            .gaugeStyle(.accessoryLinear)
            .tint(status.level == .normal ? Color.accentColor : .orange)
            .accessibilityIdentifier("memoryGauge")
            if status.level != .normal, let reason = status.reason {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.yellow.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityIdentifier("resourceWarning")
            }
        }
    }
}
