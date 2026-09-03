import SwiftUI

/// Bridg — Android↔Mac Bridge
/// Menu bar app that provides screen mirroring, file transfer,
/// clipboard sync, and notification forwarding.
@main
struct BridgApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        // Menu bar item
        MenuBarExtra("Bridg", systemImage: "iphone.radiowaves.left.and.right") {
            BridgMenuBarView()
                .environmentObject(appState)
        }

        // Main window (accessible from menu bar)
        Window("Bridg", id: "main") {
            ContentView()
                .environmentObject(appState)
        }
        .defaultSize(width: 800, height: 600)

        // Settings
        Settings {
            SettingsView()
                .environmentObject(appState)
        }

        // Mirror window
        Window("Phone Mirror", id: "mirror") {
            MirrorView()
                .environmentObject(appState)
        }
        .defaultSize(width: 400, height: 800)
        .handlesExternalEvents(matching: ["mirror"])
    }
}
