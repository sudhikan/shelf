import SwiftUI

@main
struct ShelfApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Shelf", systemImage: "dock.rectangle") {
            MenuBarContent()
        }

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        LaunchAtLogin.handOffToAgentIfNeeded()
        SingleInstance.exitIfAlreadyRunning()
        LaunchAtLogin.enableByDefaultOnce()
        DockController.shared.start()
        AppleDock.startEnforcing()
        ClipboardService.shared.start()
        GlobalHotKey.register()
    }
}

private struct MenuBarContent: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Show Dock") { DockController.shared.reveal() }
        Button(DockEditor.shared.isEditing ? "Done Editing" : "Edit Dock") {
            DockController.shared.reveal()
            DockEditor.shared.toggle()
        }
        Button("Settings…") {
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")
        Divider()
        Button("Quit Shelf") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
