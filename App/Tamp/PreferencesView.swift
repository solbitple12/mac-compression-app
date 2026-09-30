import SwiftUI
import TampCore

/// The safety thresholds behind the pre-flight checks and the resource monitor,
/// opened with Tamp ▸ Settings… (Cmd-,). Changes apply right away, including
/// to jobs already running.
struct PreferencesView: View {
    let model: AppModel
    @State private var safety: SafetySettings

    init(model: AppModel) {
        self.model = model
        _safety = State(initialValue: model.safety)
    }

    var body: some View {
        Form {
            Section {
                Slider(value: $safety.memoryShare, in: 0.4...0.95, step: 0.05) {
                    Text("Warn above")
                } minimumValueLabel: {
                    Text("40%")
                } maximumValueLabel: {
                    Text("95%")
                }
                Text("Ask before a job whose estimate uses more than \(Int(safety.memoryShare * 100))% of the memory that's free.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Memory")
            }

            Section {
                Stepper(value: $safety.diskReserveMebibytes, in: 100...10240, step: 100) {
                    Text("Keep \(safety.diskReserveMebibytes) MB free")
                }
                Text("Ask before a job that would leave less than this much free space on the output volume.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Disk space")
            }

            Section {
                Stepper(value: $safety.longJobMinutes, in: 1...240, step: 1) {
                    Text("Ask above \(safety.longJobMinutes) minute\(safety.longJobMinutes == 1 ? "" : "s")")
                }
                Text("Ask before starting a job whose estimated time is longer than this.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Long jobs")
            }

            Section {
                Stepper(value: $safety.answerTimeout, in: 15...300, step: 15) {
                    Text("Stop after \(Int(safety.answerTimeout)) seconds unanswered")
                }
                Text("If Tamp pauses jobs to ask what to do and nothing answers, it stops them safely after this long.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Unanswered pauses")
            }

            Button("Restore Defaults") {
                safety = SafetySettings()
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 460)
        .onChange(of: safety) { _, newValue in
            model.updateSafety(newValue)
        }
    }
}

private extension SafetySettings {
    var diskReserveMebibytes: Int {
        get { Int(diskReserveBytes / (1 << 20)) }
        set { diskReserveBytes = Int64(max(1, newValue)) << 20 }
    }

    var longJobMinutes: Int {
        get { Int(longJobSeconds / 60) }
        set { longJobSeconds = TimeInterval(max(1, newValue)) * 60 }
    }
}
