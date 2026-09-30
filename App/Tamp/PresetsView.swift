import SwiftUI
import TampCore

/// One click applies a saved format+step+advanced setup; the menu also offers
/// saving the current settings and deleting a saved preset.
struct PresetsMenu: View {
    let model: AppModel
    @State private var isNaming = false

    var body: some View {
        Menu("Presets") {
            if model.presets.isEmpty {
                Text("No presets yet")
            } else {
                ForEach(model.presets) { preset in
                    Button(preset.name) { model.applyPreset(preset) }
                }
                Divider()
                Menu("Delete") {
                    ForEach(model.presets) { preset in
                        Button(preset.name) { model.deletePreset(preset) }
                    }
                }
            }
            Divider()
            Button("Save Current Settings…") { isNaming = true }
        }
        .fixedSize()
        .accessibilityIdentifier("presetsMenu")
        .sheet(isPresented: $isNaming) {
            SavePresetView(model: model, isPresented: $isNaming)
        }
    }
}

private struct SavePresetView: View {
    let model: AppModel
    @Binding var isPresented: Bool
    @State private var name = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Save Current Settings as a Preset")
                .font(.headline)
            Text("\(model.choice.format.title), \(model.effectiveStep.title)")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("Preset Name", text: $name)
                .focused($isFocused)
                .onSubmit(save)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
        .onAppear { isFocused = true }
    }

    private func save() {
        model.saveCurrentAsPreset(named: name)
        isPresented = false
    }
}
