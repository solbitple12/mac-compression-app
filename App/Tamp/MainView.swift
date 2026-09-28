import SwiftUI
import TampCore

struct MainView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            DropZone(model: model)
            ArchiveSettingsView(model: model)
                .disabled(isExtracting)
                .opacity(isExtracting ? 0.5 : 1)
            HStack {
                Text(destinationText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(startTitle) { model.start() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                    .disabled(model.pendingAction == nil)
            }
            Divider()
            JobListView(model: model)
        }
        .padding(20)
    }

    private var isExtracting: Bool {
        if case .extract = model.pendingAction { true } else { false }
    }

    private var startTitle: String {
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
                    Text(hint.text)
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
