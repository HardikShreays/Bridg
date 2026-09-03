import SwiftUI
import AppKit

/// View shown in the menu bar popover for quick status and actions.
struct BridgMenuBarView: View {
    @EnvironmentObject var appState: AppState

    /// SwiftUI `Window` scenes are created lazily — they do not exist in
    /// `NSApp.windows` until something opens them. The old code looked the
    /// mirror window up by title and silently did nothing when the lookup
    /// failed, which was every time. `openWindow` is the scene-aware way in.
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Connection status
            HStack {
                Circle()
                    .fill(appState.connectionState.isConnected ? Color.green : Color.orange)
                    .frame(width: 10, height: 10)
                Text(appState.connectionState.displayText)
                    .font(.headline)
            }

            if let device = appState.pairedDeviceName {
                HStack {
                    Image(systemName: "iphone")
                    Text(device)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }

            Divider()

            // Quick actions
            Button(action: { open("main") }) {
                Label("Open Bridg", systemImage: "macwindow")
            }

            Button(action: { open("mirror") }) {
                Label("Open Mirror", systemImage: "rectangle.inset.filled.and.person.filled")
            }
            .disabled(!appState.connectionState.isConnected)

            Button(action: { openFileTransfer() }) {
                Label("Send File", systemImage: "arrow.up.circle")
            }
            .disabled(!appState.connectionState.isConnected)

            Divider()

            // Clipboard quick view
            if let clipboard = appState.lastClipboardContent {
                VStack(alignment: .leading) {
                    Text("Clipboard")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(clipboard)
                        .font(.caption)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }

            Divider()

            settingsButton

            Divider()

            Button("Quit Bridg") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(16)
        .frame(width: 250)
    }

    /// `NSApp.sendAction(Selector(("showSettingsWindow:")))` is a private,
    /// version-specific selector that stopped resolving after macOS 13 — the
    /// button was a no-op on every newer system. `SettingsLink` is the
    /// supported way to open the `Settings` scene; the selector stays only as
    /// the macOS 13 fallback.
    @ViewBuilder
    private var settingsButton: some View {
        if #available(macOS 14.0, *) {
            SettingsLink {
                Label("Settings…", systemImage: "gear")
            }
            .simultaneousGesture(TapGesture().onEnded {
                NSApp.activate(ignoringOtherApps: true)
            })
        } else {
            Button(action: {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                NSApp.activate(ignoringOtherApps: true)
            }) {
                Label("Settings…", systemImage: "gear")
            }
        }
    }

    /// Bridg is `LSUIElement`, so an opened window comes up behind whatever the
    /// user was in unless we activate as well.
    private func open(_ id: String) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openFileTransfer() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK {
            appState.sendFiles(panel.urls)
        }
    }
}
