import SwiftUI

@main
struct TampApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Tamp", id: "main") {
            MainView(model: appDelegate.model)
                .frame(minWidth: 480, minHeight: 560)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Choose Files…") { appDelegate.model.chooseFiles() }
                    .keyboardShortcut("o")
            }
        }

        Settings {
            PreferencesView(model: appDelegate.model)
        }
    }
}
