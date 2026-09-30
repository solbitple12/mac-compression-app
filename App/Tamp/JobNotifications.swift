import AppKit
import TampCore
import UserNotifications

/// A local notification when a job finishes or fails while Tamp isn't the
/// frontmost app - so a batch left running in the background doesn't go unnoticed.
enum JobNotifications {
    /// Asked once, the first time a job could have notified; declining just means
    /// later completions stay silent; Tamp never asks again itself.
    private static var didRequestAuthorization = false

    static func notify(_ snapshot: JobSnapshot) {
        guard !NSApp.isActive else { return }
        let center = UNUserNotificationCenter.current()
        requestAuthorizationIfNeeded(center)

        let content = UNMutableNotificationContent()
        switch snapshot.state {
        case .finished:
            content.title = "Done"
            content.body = snapshot.displayTitle
        case let .failed(error):
            content.title = "Couldn't finish"
            content.body = "\(snapshot.title): \(error.localizedDescription)"
        case .queued, .running, .cancelled:
            return
        }
        let request = UNNotificationRequest(identifier: snapshot.id.description, content: content, trigger: nil)
        center.add(request)
    }

    private static func requestAuthorizationIfNeeded(_ center: UNUserNotificationCenter) {
        guard !didRequestAuthorization else { return }
        didRequestAuthorization = true
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}
