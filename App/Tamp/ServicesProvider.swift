import AppKit

/// Backs Finder's right-click Services submenu entry "Open with Tamp",
/// declared in project.yml's NSServices. Compress or extract is decided the
/// same way a Dock drop or window drop decides it, in `AppModel.add(_:)`.
@MainActor
final class ServicesProvider: NSObject {
    let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    @objc(openWithTamp:userData:error:)
    func openWithTamp(_ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? []
        guard !urls.isEmpty else {
            error.pointee = "Tamp couldn't read anything from the selection." as NSString
            return
        }
        model.add(urls)
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows { window.makeKeyAndOrderFront(nil) }
    }
}
