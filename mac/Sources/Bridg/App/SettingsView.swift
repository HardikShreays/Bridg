import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("autoConnect") private var autoConnect = true
    @AppStorage("clipboardSync") private var clipboardSync = true
    @AppStorage("notificationForwarding") private var notificationForwarding = true
    @AppStorage("clipboardHistorySize") private var clipboardHistorySize = 20
    @AppStorage("mirrorQuality") private var mirrorQuality = "medium"

    var body: some View {
        Form {
            // General
            Section("General") {
                Toggle("Auto-connect to paired device", isOn: $autoConnect)
                Toggle("Start on login", isOn: .constant(false))
                    .help("Add Bridg to Login Items in System Settings > General > Login Items")
            }

            // Features
            Section("Features") {
                Toggle("Clipboard sync", isOn: $clipboardSync)
                    .onChange(of: clipboardSync) { newValue in
                        appState.isClipboardSyncing = newValue
                    }

                Toggle("Notification forwarding", isOn: $notificationForwarding)
                    .onChange(of: notificationForwarding) { newValue in
                        appState.isNotificationForwarding = newValue
                    }
            }

            // Clipboard
            Section("Clipboard") {
                Picker("History size", selection: $clipboardHistorySize) {
                    Text("10 items").tag(10)
                    Text("20 items").tag(20)
                    Text("50 items").tag(50)
                    Text("100 items").tag(100)
                }
            }

            // Screen Mirror
            Section("Screen Mirror") {
                Picker("Quality", selection: $mirrorQuality) {
                    Text("Low (480p)").tag("low")
                    Text("Medium (720p)").tag("medium")
                    Text("High (1080p)").tag("high")
                }
            }

            // Device Info
            Section("Device") {
                HStack {
                    Text("Device Name")
                    Spacer()
                    Text(Host.current().localizedName ?? "Mac")
                        .foregroundColor(.secondary)
                }

                if let device = appState.pairedDeviceName {
                    HStack {
                        Text("Paired Device")
                        Spacer()
                        Text(device)
                            .foregroundColor(.secondary)
                    }
                }

                Button("Unpair Device") {
                    appState.unpairAll()
                }
                .disabled(appState.pairedDeviceName == nil)
                .foregroundColor(.red)
            }

            // About
            Section("About") {
                HStack {
                    Text("Version")
                    Spacer()
                    Text("0.1.0")
                        .foregroundColor(.secondary)
                }

                Link("View on GitHub", destination: URL(string: "https://github.com/bridg/bridg")!)
            }
        }
        .formStyle(.grouped)
        .frame(width: 450, height: 500)
        .navigationTitle("Settings")
    }
}
