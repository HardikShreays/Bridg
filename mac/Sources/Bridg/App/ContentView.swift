import SwiftUI

/// Main content view shown when opening the Bridg window.
struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTab = "home"

    var body: some View {
        NavigationSplitView {
            // Sidebar
            List {
                Section("Connection") {
                    Label(appState.connectionState.displayText, systemImage: connectionIcon)
                        .foregroundColor(appState.connectionState.isConnected ? .green : .secondary)

                    if let deviceName = appState.pairedDeviceName {
                        Label(deviceName, systemImage: "iphone")
                    }
                }

                Section("Features") {
                    NavigationLink {
                        MirrorView()
                            .environmentObject(appState)
                    } label: {
                        Label("Screen Mirror", systemImage: "rectangle.inset.filled.and.person.filled")
                    }

                    NavigationLink {
                        NotificationHistoryView()
                            .environmentObject(appState)
                    } label: {
                        Label("Notifications", systemImage: "bell")
                            .badge(appState.notificationHistory.count)
                    }

                    NavigationLink {
                        ClipboardHistoryView()
                            .environmentObject(appState)
                    } label: {
                        Label("Clipboard", systemImage: "doc.on.clipboard")
                    }

                    NavigationLink {
                        FileTransferView()
                            .environmentObject(appState)
                    } label: {
                        Label("File Transfer", systemImage: "arrow.up.arrow.down.circle")
                    }
                }

                Section("Settings") {
                    NavigationLink {
                        SettingsView()
                            .environmentObject(appState)
                    } label: {
                        Label("Settings", systemImage: "gear")
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
            .listStyle(.sidebar)
        } detail: {
            // Default detail view
            HomeDetailView()
                .environmentObject(appState)
        }
        .navigationTitle("Bridg")
    }

    private var connectionIcon: String {
        switch appState.connectionState {
        case .connected: return "checkmark.circle.fill"
        case .disconnected: return "xmark.circle"
        case .discovering, .connecting, .pairing: return "arrow.triangle.2.circlepath"
        case .error: return "exclamationmark.triangle"
        }
    }
}

struct HomeDetailView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "iphone.radiowaves.left.and.right")
                .font(.system(size: 64))
                .foregroundColor(.accentColor)

            Text("Bridg")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text(appState.connectionState.displayText)
                .font(.title3)
                .foregroundColor(.secondary)

            if appState.connectionState.isConnected {
                HStack(spacing: 30) {
                    FeatureCard(
                        icon: "rectangle.inset.filled.and.person.filled",
                        title: "Mirror",
                        subtitle: "Screen mirroring"
                    )
                    FeatureCard(
                        icon: "bell",
                        title: "Notifications",
                        subtitle: "Phone alerts"
                    )
                    FeatureCard(
                        icon: "doc.on.clipboard",
                        title: "Clipboard",
                        subtitle: "Sync copy/paste"
                    )
                    FeatureCard(
                        icon: "arrow.up.arrow.down.circle",
                        title: "Files",
                        subtitle: "Transfer files"
                    )
                }
                .padding(.top, 20)
            } else if let qr = appState.pairingQRCode {
                Image(nsImage: qr)
                    .interpolation(.none)
                    .frame(width: 300, height: 300)
                Text("Open Bridg on your phone and tap \"Pair New Device\"")
                    .font(.callout)
                    .foregroundColor(.secondary)
            } else {
                Button("Start Pairing") {
                    appState.startPairing()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            Spacer()
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct FeatureCard: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title)
                .foregroundColor(.accentColor)
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(width: 120, height: 120)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(12)
    }
}

// Stub views for navigation destinations
struct NotificationHistoryView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        List(appState.notificationHistory) { item in
            VStack(alignment: .leading) {
                Text(item.title)
                    .font(.headline)
                Text(item.text)
                    .font(.body)
                    .foregroundColor(.secondary)
                Text(item.appLabel)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("Notification History")
    }
}

struct ClipboardHistoryView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack {
            if let content = appState.lastClipboardContent {
                Text(content)
                    .padding()
            } else {
                Text("No clipboard content synced yet")
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("Clipboard History")
    }
}

struct FileTransferView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack {
            if let error = appState.lastTransferError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Text(error)
                        .font(.caption)
                    Spacer()
                    Button("Dismiss") { appState.lastTransferError = nil }
                        .buttonStyle(.plain)
                        .font(.caption)
                }
                .padding(8)
                .background(Color.red.opacity(0.1))
                .cornerRadius(6)
            }

            if appState.activeTransfers.isEmpty {
                Text("No active transfers")
                    .foregroundColor(.secondary)
            } else {
                List(appState.activeTransfers) { transfer in
                    HStack {
                        Image(systemName: transfer.direction == .outgoing ? "arrow.up.circle" : "arrow.down.circle")
                            .foregroundColor(.secondary)
                        Text(transfer.filename)
                        Spacer()
                        ProgressView(value: transfer.progress)
                            .frame(width: 100)
                        Text("\(Int(transfer.progress * 100))%")
                    }
                }
            }

            Button("Send File") {
                let panel = NSOpenPanel()
                panel.allowsMultipleSelection = true
                panel.canChooseDirectories = false
                if panel.runModal() == .OK {
                    appState.sendFiles(panel.urls)
                }
            }
            .disabled(!appState.connectionState.isConnected)
        }
        .padding(.top, appState.lastTransferError != nil ? 8 : 0)
        .navigationTitle("File Transfer")
    }
}
