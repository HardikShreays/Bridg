import Foundation
import Combine
import AppKit
import CoreMedia

/// Central observable state, and the single owner of the connection.
///
/// Previously AppDelegate and AppState each built their own ConnectionManager
/// and nobody ever set `onMessage`, so incoming frames went nowhere — which is
/// why every feature looked dead.
@MainActor
final class AppState: ObservableObject {
    @Published var connectionState: ConnectionState = .disconnected
    @Published var pairedDeviceName: String?
    @Published var isScreenMirroring: Bool = false
    @Published var isClipboardSyncing: Bool = true
    @Published var isNotificationForwarding: Bool = true

    @Published var lastClipboardContent: String?
    /// Aspect ratio of the incoming mirror stream, from its VideoStreamStart.
    @Published var mirrorAspectRatio: CGFloat = 9.0 / 16.0
    @Published var notificationHistory: [NotificationItem] = []
    /// What the phone is playing right now, or nil when nothing is.
    @Published var nowPlaying: MediaItem?

    /// Phone battery, as last reported. Nil until the phone says.
    @Published var phoneBattery: BatteryState?
    @Published var activeTransfers: [TransferInfo] = []
    /// Set on any failed transfer so `FileTransferView` can show it, instead
    /// of the transfer just silently disappearing from the list.
    @Published var lastTransferError: String?

    /// QR image shown while pairing, plus the token the phone must echo back.
    @Published var pairingQRCode: NSImage?

    private let keychainManager = KeychainManager()
    private let pairingManager = PairingManager()
    let connectionManager = ConnectionManager()
    private let clipboardSync = ClipboardSync()
    private let notificationManager = NotificationManager()
    private let fileTransferManager = FileTransferManager()
    // Fed from the network queue alongside video, never from the main actor.
    nonisolated(unsafe) private let audioPlayer = AudioPlayer()
    // Driven from ConnectionManager's network queue, never from the main actor.
    nonisolated(unsafe) private let videoDecoder = VideoDecoder()

    /// Where `MirrorView`'s display layers subscribe for decoded frames.
    nonisolated(unsafe) let videoSinks = VideoSinks()

    init() {
        pairedDeviceName = keychainManager.getPairedDevices().first?.name
        wireConnection()
        wireFeatures()
        connectionManager.start()
        connectionState = .discovering

        // Nothing paired yet means the only useful thing this app can show is
        // the QR code, so show it without making the user find a button first.
        if !hasPairedDevice { startPairing() }
    }

    // MARK: - Pairing

    /// Generate a fresh token + QR for the phone to scan.
    func startPairing() {
        let token = pairingManager.generatePairingToken()
        connectionManager.beginPairing(token: token)
        pairingQRCode = pairingManager.generateQRCode(from: pairingManager.createQrContent(token: token))
        connectionState = .pairing
    }

    func unpairAll() {
        for device in keychainManager.getPairedDevices() {
            keychainManager.removePairedDevice(id: device.id)
        }
        pairedDeviceName = nil
        startPairing()
    }

    var hasPairedDevice: Bool { keychainManager.getPairedDevicePublicKey() != nil }

    // MARK: - Outbound actions

    func sendFiles(_ urls: [URL]) {
        fileTransferManager.handleDroppedFiles(urls)
    }

    /// Coordinates are normalized 0...1; the phone's accessibility service
    /// multiplies them back up by its own display metrics.
    func sendTap(x: CGFloat, y: CGFloat) {
        var event = BridgProtoInputEvent()
        event.type = .tap
        event.x = Float(x)
        event.y = Float(y)
        event.timestamp = UInt64(Date().timeIntervalSince1970 * 1_000_000)
        send(event)
    }

    /// Back / Home / Recents — the phone's accessibility service maps these to
    /// the matching global actions. Needed because swipe-up gesture nav can't
    /// be driven reliably from a mirrored surface.
    func sendKey(_ type: BridgProtoInputEvent.EventType) {
        var event = BridgProtoInputEvent()
        event.type = type
        event.timestamp = UInt64(Date().timeIntervalSince1970 * 1_000_000)
        send(event)
    }

    /// `durationMs` of 0 lets the phone pick its default. Trackpad scrolls pass
    /// a short duration so they register as flicks rather than slow drags.
    func sendSwipe(from start: CGPoint, to end: CGPoint, durationMs: Int32 = 0) {
        var event = BridgProtoInputEvent()
        event.type = .swipe
        event.x = Float(start.x)
        event.y = Float(start.y)
        event.x2 = Float(end.x)
        event.y2 = Float(end.y)
        event.durationMs = durationMs
        event.timestamp = UInt64(Date().timeIntervalSince1970 * 1_000_000)
        send(event)
    }

    func sendLongPress(x: CGFloat, y: CGFloat) {
        var event = BridgProtoInputEvent()
        event.type = .longPress
        event.x = Float(x)
        event.y = Float(y)
        event.timestamp = UInt64(Date().timeIntervalSince1970 * 1_000_000)
        send(event)
    }

    /// Trackpad pinch: two fingers around `center`, moving from `startSpan` to
    /// `endSpan` apart (both a fraction of the phone's screen width).
    func sendPinch(center: CGPoint, startSpan: CGFloat, endSpan: CGFloat, durationMs: Int32 = 0) {
        var event = BridgProtoInputEvent()
        event.type = .pinch
        event.x = Float(center.x)
        event.y = Float(center.y)
        event.x2 = Float(startSpan)
        event.y2 = Float(endSpan)
        event.durationMs = durationMs
        event.timestamp = UInt64(Date().timeIntervalSince1970 * 1_000_000)
        send(event)
    }

    /// Characters typed on the Mac keyboard while the mirror has focus.
    func sendText(_ text: String) {
        var event = BridgProtoInputEvent()
        event.type = .textInput
        event.text = text
        event.timestamp = UInt64(Date().timeIntervalSince1970 * 1_000_000)
        send(event)
    }

    /// Editing keys (backspace, return) as Android keycodes.
    func sendKeycode(_ keycode: Int32) {
        var event = BridgProtoInputEvent()
        event.type = .keyDown
        event.keycode = keycode
        event.timestamp = UInt64(Date().timeIntervalSince1970 * 1_000_000)
        send(event)
    }

    /// Send a typed reply to a phone notification (used by both the system
    /// notification's Reply button and the in-app Notifications list).
    func sendNotificationReply(id: String, text: String) {
        var action = BridgProtoNotificationAction()
        action.actionID = id
        action.label = text
        var envelope = BridgProtoEnvelope()
        envelope.notifAction = action
        connectionManager.send(envelope)
    }

    /// Delete a notification here and on the phone.
    ///
    /// The id is the phone's own StatusBarNotification key, so this clears the
    /// exact notification the Mac was showing rather than a same-app sibling.
    func dismissNotification(id: String) {
        notificationHistory.removeAll { $0.id == id }
        notificationManager.dismissNotification(id: id)

        var dismiss = BridgProtoNotificationDismiss()
        dismiss.id = id
        var envelope = BridgProtoEnvelope()
        envelope.notifDismiss = dismiss
        connectionManager.send(envelope)
    }

    /// Play/pause, next, previous on whatever the phone is playing.
    func sendMediaCommand(_ action: BridgProtoMediaCommand.Action) {
        var command = BridgProtoMediaCommand()
        command.action = action
        var envelope = BridgProtoEnvelope()
        envelope.mediaCommand = command
        connectionManager.send(envelope)
    }

    /// Put a string on the Mac clipboard (in-app "Copy Code" action).
    func copyToClipboard(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    /// Ring the phone at full volume so you can find it.
    func ringPhone(_ ring: Bool = true) {
        var action = BridgProtoRemoteAction()
        action.action = ring ? .ring : .stopRing
        var envelope = BridgProtoEnvelope()
        envelope.remoteAction = action
        connectionManager.send(envelope)
    }

    /// Push a link to the phone. Returns false if the string is not one we
    /// will send — the phone refuses anything but http(s) anyway, so failing
    /// here lets the UI stay honest instead of silently dropping it.
    @discardableResult
    func openOnPhone(url: String) -> Bool {
        guard Self.isSendableURL(url) else { return false }

        var action = BridgProtoRemoteAction()
        action.action = .openURL
        action.url = url
        var envelope = BridgProtoEnvelope()
        envelope.remoteAction = action
        connectionManager.send(envelope)
        return true
    }

    /// The http(s) URL currently on the Mac clipboard, if there is one.
    static func urlOnPasteboard() -> String? {
        guard let string = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return isSendableURL(string) ? string : nil
    }

    /// Must agree with RemoteActionHandler.isAllowedUrl on the phone.
    ///
    /// Pure string validation, so it is deliberately off the main actor — that
    /// is what lets the test suite call it directly.
    nonisolated static func isSendableURL(_ raw: String) -> Bool {
        guard let components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty else { return false }
        return true
    }

    /// Answer / hang up / mute / speaker on the phone's current call.
    /// The incoming call itself surfaces as a normal forwarded notification.
    func sendCallControl(_ action: BridgProtoCallControl.Action) {
        var control = BridgProtoCallControl()
        control.action = action
        var envelope = BridgProtoEnvelope()
        envelope.callControl = control
        connectionManager.send(envelope)
    }

    private func send(_ event: BridgProtoInputEvent) {
        var envelope = BridgProtoEnvelope()
        envelope.inputEvent = event
        connectionManager.send(envelope)
    }

    // MARK: - Wiring

    private func wireConnection() {
        connectionManager.onConnected = { [weak self] _ in
            Task { @MainActor in self?.connectionState = .connected }
        }

        connectionManager.onDisconnected = { [weak self] in
            self?.audioPlayer.stop()
            Task { @MainActor in
                self?.connectionState = .discovering
                self?.isScreenMirroring = false
                self?.nowPlaying = nil
            }
        }

        connectionManager.onPaired = { [weak self] name in
            Task { @MainActor in
                self?.pairedDeviceName = name
                self?.pairingQRCode = nil
                self?.connectionState = .connected
            }
        }

        connectionManager.onMessage = { [weak self] envelope in
            // FIFO, deliberately — not `Task { @MainActor in ... }`.
            //
            // An unstructured Task per envelope carries no ordering guarantee,
            // so under load the main actor could run them in a different order
            // than they arrived. File transfer is a strictly ordered stream and
            // rejects a chunk that doesn't start where the last one ended, so a
            // single reordered pair failed the transfer and deleted the
            // half-written file — "sometimes it works" being the tell.
            // DispatchQueue.main is FIFO, which is what this stream needs.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.route(envelope) }
            }
        }

        // Video arrives on the network queue and is decoded there; only the
        // published UI state hops to the main actor.
        connectionManager.onVideoMessage = { [weak self] envelope in
            guard let self else { return }
            switch envelope.payload {
            case .videoStreamStart(let start):
                self.videoDecoder.configure(spsPps: start.spsPps)
                Task { @MainActor in
                    self.isScreenMirroring = true
                    if start.width > 0, start.height > 0 {
                        self.mirrorAspectRatio = CGFloat(start.width) / CGFloat(start.height)
                    }
                }
            case .videoFrame(let frame):
                self.videoDecoder.decode(
                    nalUnits: frame.nalUnits,
                    pts: Int64(frame.pts),
                    isKeyframe: frame.isKeyframe
                )
            case .audioFrame(let frame):
                self.audioPlayer.play(
                    pcm: frame.pcm,
                    sampleRate: frame.sampleRate,
                    channels: frame.channels
                )
            case .videoStreamStop:
                self.videoDecoder.reset()
                self.audioPlayer.stop()
                Task { @MainActor in self.isScreenMirroring = false }
            default:
                break
            }
        }
    }

    private func wireFeatures() {
        clipboardSync.onClipboardChanged = { [weak self] update in
            guard let self, self.isClipboardSyncing else { return }
            var envelope = BridgProtoEnvelope()
            envelope.clipboard = update
            self.connectionManager.send(envelope)
        }
        clipboardSync.startMonitoring()

        // The file manager pushes chunks itself; it just needed a way out.
        fileTransferManager.onSendEnvelope = { [weak self] envelope, sent in
            guard let self else { return sent?(false) ?? () }
            self.connectionManager.send(envelope, sent: sent)
        }
        fileTransferManager.onTransferStarted = { [weak self] id, filename, size, isOutgoing in
            Task { @MainActor in
                self?.activeTransfers.append(
                    TransferInfo(
                        id: id, filename: filename, totalSize: size, bytesTransferred: 0,
                        direction: isOutgoing ? .outgoing : .incoming
                    )
                )
            }
        }
        fileTransferManager.onTransferProgress = { [weak self] id, sent, _ in
            Task { @MainActor in
                guard let index = self?.activeTransfers.firstIndex(where: { $0.id == id }) else { return }
                self?.activeTransfers[index].bytesTransferred = sent
            }
        }
        fileTransferManager.onTransferCompleted = { [weak self] id, _ in
            Task { @MainActor in self?.activeTransfers.removeAll { $0.id == id } }
        }
        // Errors used to only print to the console — a failed transfer just
        // vanished from the list with nothing to tell the user why.
        fileTransferManager.onTransferError = { [weak self] id, message in
            Task { @MainActor in
                self?.activeTransfers.removeAll { $0.id == id }
                self?.lastTransferError = message
                print("Transfer \(id) failed: \(message)")
            }
        }

        videoDecoder.onSampleBuffer = { [weak self] sampleBuffer in
            self?.videoSinks.emit(sampleBuffer)
        }

        notificationManager.onReply = { [weak self] notificationId, _, text in
            self?.sendNotificationReply(id: notificationId, text: text)
        }

        notificationManager.onCallAction = { [weak self] action in
            self?.sendCallControl(action)
        }

        // Clearing a banner on the Mac clears it on the phone too, so the same
        // alert doesn't greet you again when you pick the phone up.
        notificationManager.onDismiss = { [weak self] id in
            Task { @MainActor in self?.dismissNotification(id: id) }
        }
    }

    /// Route a decoded message to the feature that owns it.
    private func route(_ envelope: BridgProtoEnvelope) {
        switch envelope.payload {
        case .clipboard(let update):
            guard isClipboardSyncing else { return }
            clipboardSync.handleRemoteClipboard(update)
            lastClipboardContent = update.content

        case .notification(let event):
            guard isNotificationForwarding else { return }
            notificationManager.displayNotification(event)
            notificationHistory.insert(
                NotificationItem(
                    id: event.id,
                    packageName: event.packageName,
                    appLabel: event.appLabel,
                    title: event.title,
                    text: event.text,
                    timestamp: Date(timeIntervalSince1970: Double(event.timestamp) / 1000),
                    hasReplyAction: event.hasReplyAction_p,
                    isCall: event.isCall
                ),
                at: 0
            )

        case .notifDismiss(let dismiss):
            notificationManager.dismissNotification(id: dismiss.id)
            notificationHistory.removeAll { $0.id == dismiss.id }

        case .deviceStatus(let status):
            phoneBattery = BatteryState(
                percent: Int(status.batteryPercent),
                isCharging: status.charging,
                isLow: status.batteryLow
            )

        case .mediaState(let state):
            nowPlaying = state.active
                ? MediaItem(
                    appLabel: state.appLabel,
                    title: state.title,
                    artist: state.artist,
                    isPlaying: state.playing
                )
                : nil

        case .fileStart(let start):
            fileTransferManager.handleTransferStart(start)

        case .fileChunk(let chunk):
            var ack = BridgProtoEnvelope()
            ack.fileAck = fileTransferManager.handleFileChunk(chunk)
            connectionManager.send(ack)

        case .fileAck(let ack):
            fileTransferManager.handleAck(ack)

        default:
            print("Unhandled message: \(String(describing: envelope.payload))")
        }
    }

    enum ConnectionState: Equatable {
        case disconnected, discovering, connecting, connected, pairing
        case error(String)

        var displayText: String {
            switch self {
            case .disconnected: return "Disconnected"
            case .discovering: return "Waiting for phone…"
            case .connecting: return "Connecting…"
            case .connected: return "Connected"
            case .pairing: return "Scan the QR code with your phone"
            case .error(let msg): return "Error: \(msg)"
            }
        }

        var isConnected: Bool { self == .connected }
    }
}

struct NotificationItem: Identifiable {
    let id: String
    let packageName: String
    let appLabel: String
    let title: String
    let text: String
    let timestamp: Date
    let hasReplyAction: Bool
    let isCall: Bool
}

struct BatteryState: Equatable {
    let percent: Int
    let isCharging: Bool
    let isLow: Bool

    /// SF Symbols has a battery glyph per quarter, plus a charging variant.
    var symbolName: String {
        if isCharging { return "battery.100.bolt" }
        switch percent {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }
}

struct MediaItem: Equatable {
    let appLabel: String
    let title: String
    let artist: String
    let isPlaying: Bool
}

struct TransferInfo: Identifiable {
    let id: String
    let filename: String
    let totalSize: Int64
    var bytesTransferred: Int64
    let direction: Direction

    enum Direction: Equatable { case incoming, outgoing }

    var progress: Double {
        guard totalSize > 0 else { return 0 }
        return Double(bytesTransferred) / Double(totalSize)
    }
}
