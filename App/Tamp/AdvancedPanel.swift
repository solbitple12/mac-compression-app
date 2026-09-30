import SwiftUI
import TampCore

/// The collapsible Advanced panel: a password, splitting, the checks after
/// compressing, and only the tuning settings the current format has.
struct AdvancedPanel: View {
    let model: AppModel
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup("Advanced", isExpanded: $isExpanded) {
            Form {
                if model.takesPassword { passwordSection }
                ForEach(model.advancedOptions, id: \.self) { option in
                    control(for: option)
                }
                if model.canSplit { splitControl }
                if model.canExcludeJunk {
                    Toggle("Leave out Mac-only files (.DS_Store, ._ files)", isOn: bind(\.excludesMacOSJunk))
                }
                Toggle("Check the archive after compressing", isOn: bind(\.verifies))
                Toggle("Move the originals to the Trash afterwards", isOn: bind(\.trashesOriginals))
            }
            .formStyle(.columns)
            .padding(.top, 8)
            // Caps the Form's own natural width so a wide row (the encryption
            // picker's explanatory text, a long block-size list) can't grow
            // past this and drag the whole window's minimum width along with
            // it - windowResizability(.contentMinSize) would otherwise widen
            // the window itself the moment this panel opens.
            .frame(maxWidth: 420, alignment: .leading)
        }
        .accessibilityIdentifier("advancedPanel")
    }

    // MARK: Password

    @ViewBuilder
    private var passwordSection: some View {
        SecureField("Password", text: Binding(get: { model.password }, set: { model.password = $0 }), prompt: Text("None"))
            .accessibilityIdentifier("passwordField")
        SecureField("Confirm", text: Binding(get: { model.passwordConfirmation }, set: { model.passwordConfirmation = $0 }))
            .accessibilityIdentifier("passwordConfirmationField")
        if let problem = model.passwordProblem {
            Text(problem)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    // MARK: Format settings

    @ViewBuilder
    private func control(for option: AdvancedOption) -> some View {
        switch option {
        case .threads:
            let cores = ProcessInfo.processInfo.activeProcessorCount
            Picker("Threads", selection: bind(\.threads)) {
                Text("All \(cores)").tag(Int?.none)
                ForEach(Array(1..<max(2, cores)), id: \.self) { count in
                    Text("\(count)").tag(Int?.some(count))
                }
            }
        case .dictionary:
            Picker("Dictionary", selection: bind(\.advanced.dictionaryMebibytes)) {
                Text("Step's own").tag(Int?.none)
                ForEach([1, 4, 16, 32, 64, 128, 256, 512, 1024], id: \.self) { size in
                    Text(Self.mebibytes(size)).tag(Int?.some(size))
                }
            }
        case .wordSize:
            Picker("Word size", selection: bind(\.advanced.wordSize)) {
                Text("Step's own").tag(Int?.none)
                ForEach([16, 32, 64, 128, 192, 273], id: \.self) { size in
                    Text("\(size)").tag(Int?.some(size))
                }
            }
        case .solid:
            Picker("Solid blocks", selection: bind(\.advanced.solid)) {
                Text("Automatic").tag(SolidMode.automatic)
                Text("Off: each file on its own").tag(SolidMode.off)
                ForEach([16, 64, 256, 1024, 4096], id: \.self) { size in
                    Text(Self.mebibytes(size)).tag(SolidMode.blockMebibytes(size))
                }
            }
        case .executableFilter:
            Toggle("BCJ2 filter for Windows programs", isOn: bind(\.advanced.executableFilter))
        case .encryptFileNames:
            if !model.password.isEmpty {
                Toggle("Encrypt file names too", isOn: bind(\.advanced.encryptFileNames))
            }
        case .zipEncryption:
            if !model.password.isEmpty {
                Picker("Encryption", selection: bind(\.advanced.zipEncryption)) {
                    ForEach(ZipEncryption.allCases, id: \.self) { encryption in
                        Text(encryption.title).tag(encryption)
                    }
                }
                Text(model.choice.advanced.zipEncryption == .aes256
                     ? "Windows Explorer and Archive Utility can't open AES-256; 7-Zip and Keka can."
                     : "ZipCrypto opens anywhere but is easy to break.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .zstdLongWindow:
            Picker("Long-range window", selection: bind(\.advanced.zstdLongWindowLog)) {
                Text("Step's own").tag(Int?.none)
                Text("Off").tag(Int?.some(0))
                ForEach([24, 25, 26, 27], id: \.self) { log in
                    Text(Self.mebibytes(1 << (log - 20))).tag(Int?.some(log))
                }
            }
        case .xzBlockSize:
            Picker("Block size", selection: bind(\.advanced.xzBlockMebibytes)) {
                Text("Automatic").tag(Int?.none)
                ForEach([8, 16, 32, 64, 128, 256], id: \.self) { size in
                    Text(Self.mebibytes(size)).tag(Int?.some(size))
                }
            }
        case .zpaqBlockSize:
            Picker("Block size", selection: bind(\.advanced.zpaqBlockLog)) {
                Text("Automatic").tag(Int?.none)
                ForEach(Array(0...11), id: \.self) { log in
                    Text(Self.mebibytes(1 << log)).tag(Int?.some(log))
                }
            }
        case .brotliLargeWindow:
            Toggle("Large window (256 MB)", isOn: bind(\.advanced.brotliLargeWindow))
        }
    }

    private var splitControl: some View {
        HStack {
            Toggle("Split into parts of", isOn: Binding(
                get: { model.choice.volumeMebibytes != nil },
                set: { on in model.update { $0.volumeMebibytes = on ? ($0.volumeMebibytes ?? 1024) : nil } }
            ))
            TextField("MB", value: Binding(
                get: { model.choice.volumeMebibytes ?? 1024 },
                set: { size in model.update { $0.volumeMebibytes = max(1, size) } }
            ), format: .number)
            .frame(width: 70)
            .disabled(model.choice.volumeMebibytes == nil)
            Text("MB")
        }
    }

    private func bind<Value>(_ keyPath: WritableKeyPath<ArchiveChoice, Value>) -> Binding<Value> {
        Binding(get: { model.choice[keyPath: keyPath] }, set: { value in model.update { $0[keyPath: keyPath] = value } })
    }

    static func mebibytes(_ size: Int) -> String {
        size >= 1024 && size % 1024 == 0 ? "\(size / 1024) GB" : "\(size) MB"
    }
}

/// Asks for the password of an archive being opened.
struct PasswordPrompt: View {
    let request: AppModel.PasswordRequest
    let answer: (String?) -> Void
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(request.wasWrong ? "That password didn't open “\(request.archiveName)”." : "“\(request.archiveName)” is protected.")
                .font(.headline)
            SecureField("Password", text: $password)
                .onSubmit { answer(password) }
                .accessibilityIdentifier("extractPasswordField")
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { answer(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("Open") { answer(password) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty)
            }
        }
        .padding(SheetLayout.padding)
        .frame(width: SheetLayout.compact)
    }
}
