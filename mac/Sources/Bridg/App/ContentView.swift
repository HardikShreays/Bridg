import SwiftUI

/// Main content view shown when opening the Bridg window.
struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTab = "home"

    var body: some View {
        NavigationSplitView {
            // Sidebar
            List {
                // The detail pane only shows Home until another item is picked;
                // without this link there was no way back to it (or its media controls).
                NavigationLink {
                    HomeDetailView()
                        .environmentObject(appState)
                } label: {
                    Label("Home", systemImage: "house")
                }

                Section("Connection") {
                    NavigationLink {
                        ConnectionView()
                            .environmentObject(appState)
                    } label: {
                        Label(appState.connectionState.displayText, systemImage: connectionIcon)
                            .foregroundColor(appState.connectionState.isConnected ? .green : .secondary)
                    }

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

                if appState.nowPlaying != nil {
                    NowPlayingView()
                        .environmentObject(appState)
                        .frame(maxWidth: 520)
                }
            } else if let qr = appState.pairingQRCode {
                Image(nsImage: qr)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(1, contentMode: .fit)
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

            // Dialling works over Bluetooth even when the Wi-Fi link is down, so
            // the actions show whenever a phone is paired, not only when connected.
            if appState.pairedDeviceName != nil {
                PhoneActionsView()
                    .environmentObject(appState)
                    .padding(12)
                    .frame(maxWidth: 520, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(12)
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

struct NotificationHistoryView: View {
    @EnvironmentObject var appState: AppState
    @State private var replyingTo: String?
    @State private var replyText: String = ""

    var body: some View {
        List(appState.notificationHistory) { item in
            VStack(alignment: .leading, spacing: 6) {
                Text(item.title)
                    .font(.headline)
                Text(item.text)
                    .font(.body)
                    .foregroundColor(.secondary)
                Text(item.appLabel)
                    .font(.caption)
                    .foregroundColor(.secondary)

                actionRow(for: item)

                if replyingTo == item.id {
                    HStack {
                        TextField("Reply…", text: $replyText)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { send(item) }
                        Button("Send") { send(item) }
                            .disabled(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .navigationTitle("Notification History")
        .toolbar {
            Button("Clear All") {
                for item in appState.notificationHistory {
                    appState.dismissNotification(id: item.id)
                }
            }
            .disabled(appState.notificationHistory.isEmpty)
        }
    }

    @ViewBuilder
    private func actionRow(for item: NotificationItem) -> some View {
        HStack {
            if item.isCall {
                Button("Answer") { appState.sendCallControl(.answer) }
                Button("Decline") { appState.sendCallControl(.reject) }
                    .tint(.red)
            }
            if item.hasReplyAction {
                Button(replyingTo == item.id ? "Cancel" : "Reply") {
                    replyingTo = (replyingTo == item.id) ? nil : item.id
                    replyText = ""
                }
            }
            if let code = Self.verificationCode(in: item.text) {
                Button("Copy Code") { appState.copyToClipboard(code) }
            }
            Spacer()
            // Clears it on the phone too, so the same alert isn't waiting when
            // you pick the phone back up.
            Button("Delete") { appState.dismissNotification(id: item.id) }
                .tint(.red)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func send(_ item: NotificationItem) {
        let text = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        appState.sendNotificationReply(id: item.id, text: text)
        replyingTo = nil
        replyText = ""
    }

    /// First 4–8 digit run in the text — the common one-time-code shape.
    static func verificationCode(in text: String) -> String? {
        guard let range = text.range(of: #"\b\d{4,8}\b"#, options: .regularExpression) else { return nil }
        return String(text[range])
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

/// Everything about the link to the phone, in one place: who is paired, what
/// state the connection is in, and how to get out of a stuck one.
struct ConnectionView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            Section("Status") {
                HStack {
                    Text("State")
                    Spacer()
                    Text(appState.connectionState.displayText)
                        .foregroundColor(appState.connectionState.isConnected ? .green : .secondary)
                }
            }

            Section("Device") {
                HStack {
                    Text("This Mac")
                    Spacer()
                    Text(Host.current().localizedName ?? "Mac")
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("Paired Phone")
                    Spacer()
                    Text(appState.pairedDeviceName ?? "None")
                        .foregroundColor(.secondary)
                }
            }

            Section {
                if !appState.connectionState.isConnected {
                    Button("Show Pairing QR Code") { appState.startPairing() }
                }
                Button("Unpair Device") { appState.unpairAll() }
                    .disabled(appState.pairedDeviceName == nil)
                    .foregroundColor(.red)
            }

            Section {
                Label {
                    Text("If there is some connection issue, completely restart both apps :)")
                } icon: {
                    Image(systemName: "lightbulb")
                        .foregroundColor(.yellow)
                }
                .font(.callout)
            }

            if appState.pairingQRCode != nil, let qr = appState.pairingQRCode {
                Section("Pair a Phone") {
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            Image(nsImage: qr)
                                .resizable()
                                .interpolation(.none)
                                .aspectRatio(1, contentMode: .fit)
                                .frame(width: 200, height: 200)
                            Text("Open Bridg on your phone and tap \"Pair New Device\"")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Connection")
    }
}

/// Transport controls for whatever the phone is playing (Spotify, Apple Music,
/// YouTube…). Driven by the phone's MediaSession, not by its notification —
/// which is why the player no longer spams the notification list.
struct NowPlayingView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        if let media = appState.nowPlaying {
            HStack(spacing: 16) {
                Image(systemName: "music.note")
                    .font(.title2)
                    .foregroundColor(.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(media.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(media.artist.isEmpty ? media.appLabel : "\(media.artist) — \(media.appLabel)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Button { appState.sendMediaCommand(.previous) } label: {
                    Image(systemName: "backward.fill")
                }
                Button { appState.sendMediaCommand(.playPause) } label: {
                    Image(systemName: media.isPlaying ? "pause.fill" : "play.fill")
                }
                Button { appState.sendMediaCommand(.next) } label: {
                    Image(systemName: "forward.fill")
                }
            }
            .buttonStyle(.bordered)
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(12)
        }
    }
}

/// Phone actions shared by the menu bar popover and the main window: open the
/// copied link on the phone, ring it (and stop), and dial.
struct PhoneActionsView: View {
    @EnvironmentObject var appState: AppState

    /// http(s) link currently on the Mac clipboard, refreshed when the view
    /// appears. NSPasteboard is not observable, and polling it on a timer to
    /// keep one button enabled is not worth the wakeups.
    @State private var copiedLink: String?
    @State private var dialNumber = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // The link you want on your phone is nearly always the one you just
            // copied, so read the pasteboard rather than asking for a text field.
            Button(action: { appState.openOnPhone(url: copiedLink ?? "") }) {
                Label("Open Copied Link on Phone", systemImage: "safari")
            }
            .disabled(!appState.connectionState.isConnected || copiedLink == nil)
            .help(copiedLink ?? "Copy an http(s) link first")

            Button(action: { appState.ringPhone(!appState.isRinging) }) {
                Label(
                    appState.isRinging ? "Stop Ringing" : "Ring Phone",
                    systemImage: appState.isRinging ? "bell.slash" : "bell.and.waves.left.and.right"
                )
            }
            .disabled(!appState.connectionState.isConnected)

            // Dialling rides Bluetooth, not the Wi-Fi link, so it is not gated on
            // the connection state like the actions above.
            HStack {
                TextField("Call a number", text: $dialNumber)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { appState.dial(dialNumber) }
                Button(action: { appState.dial(dialNumber) }) {
                    Image(systemName: "phone.fill")
                }
                .disabled(PhoneDialer.dialable(dialNumber).isEmpty)
                .help("Place the call on your phone over Bluetooth")
            }
            if let status = appState.dialStatus {
                Text(status)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .onAppear { copiedLink = AppState.urlOnPasteboard() }
    }
}
