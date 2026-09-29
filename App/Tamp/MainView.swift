import SwiftUI
import TampCore

struct MainView: View {
    let model: AppModel

    var body: some View {
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
            HStack {
                Text(destinationText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(startTitle) { model.start() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                    .disabled(!model.canStart)
            }
            Divider()
            JobListView(model: model)
        }
        .padding(20)
        .confirmationDialog(
            "Move the originals to the Trash after compressing?",
            isPresented: Binding(get: { model.isConfirmingTrash }, set: { model.isConfirmingTrash = $0 })
        ) {
            Button("Compress, Then Move to Trash", role: .destructive) { model.approve(.trash) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They go to the Trash only if the archive is written\(model.choice.verifies ? " and checks out" : ""). You can put them back from there.")
        }
        .sheet(item: Binding(get: { model.passwordRequest }, set: { if $0 == nil { model.answerPasswordRequest(nil) } })) { request in
            PasswordPrompt(request: request) { model.answerPasswordRequest($0) }
        }
        .sheet(item: Binding(get: { model.startQuestion }, set: { if $0 == nil { model.dismissStartQuestion() } })) { question in
            StartQuestionView(question: question, model: model)
        }
        .sheet(isPresented: Binding(get: { model.resourceStatus.isAwaitingAnswer }, set: { _ in })) {
            PausedJobsView(model: model)
                .interactiveDismissDisabled()
        }
        .alert(
            "Tamp stopped to protect your Mac",
            isPresented: Binding(get: { model.automaticStopSummary != nil }, set: { if !$0 { model.dismissAutomaticStopSummary() } })
        ) {
            Button("OK") { model.dismissAutomaticStopSummary() }
        } message: {
            Text(model.automaticStopSummary ?? "")
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
        case let .extract(archives): archives.count == 1 ? "Extract" : "Extract \(archives.count)"
        case .compress, nil: "Compress"
        }
    }

    private var destinationText: String {
        isExtracting ? "Extracts next to each archive" : "Saves next to the originals"
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
        VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { Double(step.rawValue) },
                    set: { step = SpeedStep(rawValue: Int($0.rounded())) ?? step }
                ),
                in: 0...Self.lastIndex,
                step: 1
            ) {
                Text("Speed")
            }
            .accessibilityValue("\(step.title), \(step.summary)")
            .accessibilityIdentifier("speedSlider")

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
