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

    /// http(s) link currently on the Mac clipboard, refreshed when the popover
    /// opens. NSPasteboard is not observable, and polling it on a timer to keep
    /// one menu item enabled is not worth the wakeups.
    @State private var copiedLink: String?

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

                    if let battery = appState.phoneBattery {
                        Spacer()
                        Label("\(battery.percent)%", systemImage: battery.symbolName)
                            .font(.subheadline)
                            .foregroundColor(battery.isLow && !battery.isCharging ? .red : .secondary)
                            .help(battery.isCharging ? "Charging" : "On battery")
                    }
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

            // The link you want on your phone is nearly always the one you just
            // copied, so read the pasteboard rather than asking for a text field.
            Button(action: { appState.openOnPhone(url: copiedLink ?? "") }) {
                Label("Open Copied Link on Phone", systemImage: "safari")
            }
            .disabled(!appState.connectionState.isConnected || copiedLink == nil)
            .help(copiedLink ?? "Copy an http(s) link first")

            Button(action: { appState.ringPhone() }) {
                Label("Ring Phone", systemImage: "bell.and.waves.left.and.right")
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
        .onAppear { copiedLink = AppState.urlOnPasteboard() }
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
