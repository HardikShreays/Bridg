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
    private let videoDecoder = VideoDecoder()

    /// Where `MirrorView`'s display layers subscribe for decoded frames.
    let videoSinks = VideoSinks()

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

    func sendSwipe(from start: CGPoint, to end: CGPoint) {
        var event = BridgProtoInputEvent()
        event.type = .swipe
        event.x = Float(start.x)
        event.y = Float(start.y)
        event.x2 = Float(end.x)
        event.y2 = Float(end.y)
        event.timestamp = UInt64(Date().timeIntervalSince1970 * 1_000_000)
        send(event)
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
            Task { @MainActor in
                self?.connectionState = .discovering
                self?.isScreenMirroring = false
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
            Task { @MainActor in self?.route(envelope) }
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
        fileTransferManager.onSendEnvelope = { [weak self] envelope in
            self?.connectionManager.send(envelope)
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

        notificationManager.onReply = { [weak self] notificationId, actionId, text in
            var action = BridgProtoNotificationAction()
            action.actionID = actionId
            action.label = text
            var envelope = BridgProtoEnvelope()
            envelope.notifAction = action
            self?.connectionManager.send(envelope)
            _ = notificationId
        }

        notificationManager.onCallAction = { [weak self] action in
            self?.sendCallControl(action)
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
                    hasReplyAction: event.hasReplyAction_p
                ),
                at: 0
            )

        case .notifDismiss(let dismiss):
            notificationManager.dismissNotification(id: dismiss.id)

        case .fileStart(let start):
            fileTransferManager.handleTransferStart(start)

        case .fileChunk(let chunk):
            var ack = BridgProtoEnvelope()
            ack.fileAck = fileTransferManager.handleFileChunk(chunk)
            connectionManager.send(ack)

        case .fileAck(let ack):
            fileTransferManager.handleAck(ack)

        case .videoStreamStart(let start):
            isScreenMirroring = true
            if start.width > 0, start.height > 0 {
                mirrorAspectRatio = CGFloat(start.width) / CGFloat(start.height)
            }
            videoDecoder.configure(spsPps: start.spsPps)

        // Without this case every encoded frame fell through to `default` and
        // was printed and dropped — the mirror could never show anything.
        case .videoFrame(let frame):
            videoDecoder.decode(
                nalUnits: frame.nalUnits,
                pts: Int64(frame.pts),
                isKeyframe: frame.isKeyframe
            )

        case .videoStreamStop:
            isScreenMirroring = false
            videoDecoder.reset()

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
