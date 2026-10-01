#if DEBUG
import Foundation
import TampCore

/// Lets the UI smoke test (App/TampUITests) start Tamp with items already added
/// and with settings kept apart from the real ones. Debug builds only.
enum UITestHooks {
    private static let environment = ProcessInfo.processInfo.environment

    /// Settings in their own defaults domain, so a test run leaves yours alone.
    static var settings: SettingsStore? {
        guard let suite = environment["TAMP_UI_TEST_DEFAULTS"], let defaults = UserDefaults(suiteName: suite) else {
            return nil
        }
        if environment["TAMP_UI_TEST_RESET_DEFAULTS"] == "1" {
            defaults.removePersistentDomain(forName: suite)
        }
        return SettingsStore(defaults: defaults)
    }

    /// Items to add at launch, as if they'd been dropped: one path per line.
    static var itemsToAdd: [URL] {
        (environment["TAMP_UI_TEST_ADD"] ?? "")
            .split(separator: "\n")
            .map { URL(fileURLWithPath: String($0)) }
    }
}
#endif
