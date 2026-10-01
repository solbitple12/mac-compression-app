import SwiftUI
import TampCore

/// The menu bar extra: a quick way to compress something or jump back to a
/// recent output without opening the main window first. Bundled files still
/// run through the window's own sheets (a password prompt, a safety
/// question), so choosing files here brings the window forward too.
struct MenuBarContentView: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Compress Files…") { chooseAndCompress() }
        Button("Open Tamp") { openMainWindow() }
            .keyboardShortcut("t")
        if !model.recentJobs.isEmpty {
            Divider()
            ForEach(model.recentJobs.prefix(5)) { job in
                Button(job.title) { model.showInFinder(job.output) }
            }
        }
        Divider()
        Button("Quit Tamp") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func openMainWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Picks files or folders, then compresses them with whatever format and
    /// speed step are currently selected - the same choice the window shows.
    private func chooseAndCompress() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Compress"
        panel.message = "Choose files or folders to compress with the current format and speed."
        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls
            openMainWindow()
            Task { @MainActor in
                model.add(urls)
                // add(urls) checks the drop (archive vs. compress) in the background.
                while model.isCheckingItems {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                model.start()
            }
        }
    }
}
