import Cocoa
import UniformTypeIdentifiers

/// Finder's Quick Action "Compress with Tamp" (right-click, the Preview pane,
/// and the Touch Bar): collects the selected files' URLs and hands them to
/// the main app through the same door Dock drop and Open With use
/// (AppDelegate.application(_:open:)), then completes right away. App
/// Extensions are short-lived and always sandboxed, so the actual compress
/// or extract job - which can run for minutes and needs the full job queue,
/// resource monitor and helper tools - always happens in Tamp itself, never here.
final class ActionRequestHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let providers = context.inputItems
            .compactMap { $0 as? NSExtensionItem }
            .flatMap { $0.attachments ?? [] }
            .filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }

        guard !providers.isEmpty else {
            context.completeRequest(returningItems: nil, completionHandler: nil)
            return
        }

        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []

        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                defer { group.leave() }
                let url: URL?
                switch item {
                case let data as Data: url = URL(dataRepresentation: data, relativeTo: nil)
                case let direct as URL: url = direct
                default: url = nil
                }
                guard let url else { return }
                lock.lock()
                urls.append(url)
                lock.unlock()
            }
        }

        group.notify(queue: .main) {
            if !urls.isEmpty, let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "io.github.solbitple12.Tamp") {
                NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
            }
            context.completeRequest(returningItems: nil, completionHandler: nil)
        }
    }
}
