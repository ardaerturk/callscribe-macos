import SwiftUI

@main
struct CallScribeApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(controller: appDelegate.controller)
        }
    }
}
