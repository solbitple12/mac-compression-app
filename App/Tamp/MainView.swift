import SwiftUI
import TampCore

struct MainView: View {
    let model: AppModel

    // Split into several small chains, and `content` pulled out on its own:
    // one `body` combining all of this app's sheets and alerts in a single
    // expression is too much for the type checker to solve in reasonable time.
    var body: some View {
        content
            .confirmationDialog(
                "Move the originals to the Trash after compressing?",
                isPresented: Binding(get: { model.isConfirmingTrash }, set: { model.isConfirmingTrash = $0 })
            ) {
                Button("Compress, Then Move to Trash", role: .destructive) { model.approve(.trash) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("They go to the Trash only if the archive is written\(model.choice.verifies ? " and checks out" : ""). You can put them back from there.")
            }
            .jobSheets(model: model)
            .previewSheets(model: model)
            .recommenderSheets(model: model)
            .errorAlerts(model: model)
    }

    private var content: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    DropZone(model: model)
                    if !model.mediaItems.isEmpty {
                        MediaBatchView(model: model)
                    } else {
                        Group {
                            ArchiveSettingsView(model: model)
                            AdvancedPanel(model: model)
                        }
                        .disabled(isExtracting)
                        .opacity(isExtracting ? 0.5 : 1)
                    }
                }
                .padding(20)
            }
            HStack {
                Text(destinationText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if !model.recentJobs.isEmpty {
                    RecentJobsMenu(model: model)
                }
                Spacer()
                if model.canCompareFormats {
                    Button {
                        model.compareFormats()
                    } label: {
                        if model.isComparingFormats {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Compare Formats")
                        }
                    }
                    .disabled(model.isComparingFormats)
                }
                if model.canRecommend {
                    Button {
                        model.requestRecommendation()
                    } label: {
                        if model.isRecommending {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Recommend for Me")
                        }
                    }
                    .disabled(model.isRecommending)
                }
                Button(startTitle) { model.start() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                    .disabled(!model.canStart)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            Divider()
                .padding(.top, 12)
            JobListView(model: model)
                .padding(20)
        }
    }

    private var isExtracting: Bool {
        if case .extract = model.pendingAction { true } else { false }
    }

    private var startTitle: String {
        if !model.mediaItems.isEmpty {
            return model.mediaItems.count == 1 ? "Compress" : "Compress \(model.mediaItems.count)"
        }
        switch model.pendingAction {
        case let .extract(archives): return archives.count == 1 ? "Extract" : "Extract \(archives.count)"
        case .compress, nil: return "Compress"
        }
    }

    private var destinationText: String {
        isExtracting ? "Extracts next to each archive" : "Saves next to the originals"
    }
}

/// Each group below is its own function, not more of `MainView.body`, because
/// the type checker times out solving one expression with this many `.sheet`
/// and `.alert` calls chained together.
private extension View {
    /// Sheets a job itself asks for while running or about to start.
    func jobSheets(model: AppModel) -> some View {
        sheet(item: Binding(get: { model.passwordRequest }, set: { if $0 == nil { model.answerPasswordRequest(nil) } })) { request in
            PasswordPrompt(request: request) { model.answerPasswordRequest($0) }
        }
        .sheet(item: Binding(get: { model.startQuestion }, set: { if $0 == nil { model.dismissStartQuestion() } })) { question in
            StartQuestionView(question: question, model: model)
        }
        .sheet(isPresented: Binding(get: { model.resourceStatus.isAwaitingAnswer }, set: { _ in })) {
            PausedJobsView(model: model)
                .interactiveDismissDisabled()
        }
    }

    /// A generated clip, an archive's contents, or a size/time comparison - each on demand, not tied to starting a job.
    func previewSheets(model: AppModel) -> some View {
        sheet(item: Binding(get: { model.mediaPreview }, set: { if $0 == nil { model.dismissMediaPreview() } })) { preview in
            MediaPreviewView(preview: preview) { model.dismissMediaPreview() }
        }
        .sheet(item: Binding(get: { model.archiveContentsPreview }, set: { if $0 == nil { model.dismissArchiveContentsPreview() } })) { preview in
            ArchiveContentsPreviewView(preview: preview) { model.dismissArchiveContentsPreview() }
        }
        .sheet(isPresented: Binding(get: { model.formatComparison != nil }, set: { if !$0 { model.dismissFormatComparison() } })) {
            if let rows = model.formatComparison {
                FormatComparisonView(rows: rows, model: model)
            }
        }
    }

    /// "Recommend for me": the goal picker, then its result.
    func recommenderSheets(model: AppModel) -> some View {
        sheet(isPresented: Binding(get: { model.isChoosingGoal }, set: { if !$0 { model.dismissGoalPicker() } })) {
            GoalPickerView(model: model)
        }
        .sheet(isPresented: Binding(get: { model.recommendationResult != nil }, set: { if !$0 { model.dismissRecommendation() } })) {
            if let result = model.recommendationResult {
                RecommendationCardView(result: result, model: model)
            }
        }
    }

    /// Every plain "something went wrong" alert.
    func errorAlerts(model: AppModel) -> some View {
        alert(
            "Tamp couldn't recommend a format",
            isPresented: Binding(get: { model.recommendationError != nil }, set: { if !$0 { model.dismissRecommendationError() } })
        ) {
            Button("OK") { model.dismissRecommendationError() }
        } message: {
            Text(model.recommendationError ?? "")
        }
        .alert(
            "Tamp stopped to protect your Mac",
            isPresented: Binding(get: { model.automaticStopSummary != nil }, set: { if !$0 { model.dismissAutomaticStopSummary() } })
        ) {
            Button("OK") { model.dismissAutomaticStopSummary() }
        } message: {
            Text(model.automaticStopSummary ?? "")
        }
        .alert(
            "Tamp couldn't compare formats",
            isPresented: Binding(get: { model.formatComparisonError != nil }, set: { if !$0 { model.dismissFormatComparisonError() } })
        ) {
            Button("OK") { model.dismissFormatComparisonError() }
        } message: {
            Text(model.formatComparisonError ?? "")
        }
        .alert(
            "Tamp couldn't list what's inside",
            isPresented: Binding(get: { model.archiveContentsError != nil }, set: { if !$0 { model.dismissArchiveContentsError() } })
        ) {
            Button("OK") { model.dismissArchiveContentsError() }
        } message: {
            Text(model.archiveContentsError ?? "")
        }
        .alert(
            "Tamp couldn't make a preview",
            isPresented: Binding(get: { model.previewError != nil }, set: { if !$0 { model.dismissPreviewError() } })
        ) {
            Button("OK") { model.dismissPreviewError() }
        } message: {
            Text(model.previewError ?? "")
        }
    }
}

/// The format picker, the method picker for ZIP and 7Z, the six-step speed slider
/// and the hint beneath it.
struct ArchiveSettingsView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Format", selection: Binding(get: { model.choice.format }, set: { model.select(format: $0) })) {
                ForEach(FormatGroup.allCases, id: \.self) { group in
                    let formats = model.registry.availableFormats.filter { $0.group == group }
                    if !formats.isEmpty {
                        Section(group.title) {
                            ForEach(formats, id: \.self) { format in
                                Text(format.title).tag(format)
                            }
                        }
                    }
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .accessibilityIdentifier("formatPicker")

            PresetsMenu(model: model)

            if let method = model.method, !model.methods.isEmpty {
                Picker("Method", selection: Binding(get: { method }, set: { model.select(method: $0) })) {
                    ForEach(model.methods, id: \.self) { candidate in
                        Text(candidate.title).tag(candidate)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityIdentifier("methodPicker")
            }

            // Plain TAR has nothing to tune, so its slider stays on Store.
            SpeedSlider(step: Binding(get: { model.effectiveStep }, set: { model.select(step: $0) }))
                .disabled(!model.hasSpeedSteps)

            if let hint = model.hint {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.hintText ?? hint.text)
                        .accessibilityIdentifier("stepHint")
                    ForEach(hint.notes, id: \.self) { note in
                        Label(note, systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// Six fixed stops from Store to Best, with a clickable label under each.
struct SpeedSlider: View {
    @Binding var step: SpeedStep

    private static let steps = SpeedStep.allCases
    private static let lastIndex = Double(steps.count - 1)

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Text("Speed")
                Slider(
                    value: Binding(
                        get: { Double(step.rawValue) },
                        set: { step = SpeedStep(rawValue: Int($0.rounded())) ?? step }
                    ),
                    in: 0...Self.lastIndex,
                    step: 1
                )
                .accessibilityLabel("Speed")
                .accessibilityValue("\(step.title), \(step.summary)")
                .accessibilityIdentifier("speedSlider")
            }

            HStack(spacing: 0) {
                ForEach(Self.steps, id: \.self) { candidate in
                    Button(candidate.title) { step = candidate }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .fontWeight(candidate == step ? .semibold : .regular)
                        .foregroundStyle(candidate == step ? Color.accentColor : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .accessibilityHidden(true)
                }
            }
        }
    }
}
