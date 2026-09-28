import AppKit

/// Owns the app model, and stops running jobs safely before Tamp quits.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel = {
        #if DEBUG
        if let settings = UITestHooks.settings { return AppModel(settings: settings) }
        #endif
        return AppModel()
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.removeStalePartialFiles()
        #if DEBUG
        let items = UITestHooks.itemsToAdd
        if !items.isEmpty { model.add(items) }
        #endif
    }

    /// Tamp stays open with its window closed, like Keka; clicking the Dock icon brings the window back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = model.activeJobCount
        guard running > 0 else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = running == 1 ? "A job is still running." : "\(running) jobs are still running."
        alert.informativeText = "Quitting stops them. Tamp removes their unfinished files, and your originals stay as they are."
        alert.addButton(withTitle: "Stop and Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }

        Task {
            await model.stopAllJobs()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
