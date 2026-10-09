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
    /// Every paired phone, connected or not. Several can be connected at once.
    @Published var phones: [PhoneState] = []
    /// The phone the buttons act on (ring, open link, files, media). Nil means
    /// "the first connected one".
    @Published var selectedPhoneID: String?
    @Published var isScreenMirroring: Bool = false
    @Published var isClipboardSyncing: Bool = true
    @Published var isNotificationForwarding: Bool = true

    @Published var lastClipboardContent: String?
    /// Aspect ratio of the incoming mirror stream, from its VideoStreamStart.
    @Published var mirrorAspectRatio: CGFloat = 9.0 / 16.0
    @Published var notificationHistory: [NotificationItem] = []
    /// Outcome of the last click-to-call, shown under the dial field.
    @Published var dialStatus: String?
    /// True from Ring Phone until Stop Ringing or the phone's own cutoff.
    @Published var isRinging = false
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
    private let phoneDialer = PhoneDialer()
    // Fed from the network queue alongside video, never from the main actor.
    nonisolated(unsafe) private let audioPlayer = AudioPlayer()
    // Driven from ConnectionManager's network queue, never from the main actor.
    nonisolated(unsafe) private let videoDecoder = VideoDecoder()

    /// Where `MirrorView`'s display layers subscribe for decoded frames.
    nonisolated(unsafe) let videoSinks = VideoSinks()

    /// The phone currently streaming its screen here; video from any other is
    /// dropped (one decoder), and mirror input goes back to this one.
    nonisolated(unsafe) private var mirroringPhoneID: String?

    /// Which phone each outgoing transfer is going to, so a chunk never follows
    /// a selection change to a different phone mid-file. The file sender
    /// streams chunks from a background queue, hence the lock rather than the
    /// main actor.
    nonisolated(unsafe) private var transferTargets: [String: String] = [:]
    nonisolated(unsafe) private var fileTarget: String?
    nonisolated private let transferLock = NSLock()

    init() {
        phones = keychainManager.getPairedDevices().map { PhoneState(device: $0) }
        wireConnection()
        wireFeatures()
        connectionManager.start()

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
    }

    func cancelPairing() {
        connectionManager.beginPairing(token: SharedSecretKDF.randomSalt().base64EncodedString())
        pairingQRCode = nil
    }

    func unpair(_ id: String) {
        keychainManager.removePairedDevice(id: id)
        connectionManager.disconnect(deviceID: id)
        phones.removeAll { $0.id == id }
        if selectedPhoneID == id { selectedPhoneID = nil }
        if phones.isEmpty { startPairing() }
    }

    var hasPairedDevice: Bool { !phones.isEmpty }

    // MARK: - Phones

    /// The phone the window and menu bar show and act on.
    var selectedPhone: PhoneState? {
        phones.first { $0.id == selectedPhoneID } ?? phones.first { $0.connected } ?? phones.first
    }

    // What used to be stored for "the" phone now reads from the selected one,
    // so every existing view keeps working with several phones.
    var pairedDeviceName: String? { selectedPhone?.name }
    var phoneBattery: BatteryState? { selectedPhone?.battery }
    var nowPlaying: MediaItem? { selectedPhone?.nowPlaying }

    var connectionState: ConnectionState {
        if selectedPhone?.connected == true { return .connected }
        if pairingQRCode != nil { return .pairing }
        return phones.isEmpty ? .disconnected : .discovering
    }

    private func update(_ id: String, _ change: (inout PhoneState) -> Void) {
        guard let i = phones.firstIndex(where: { $0.id == id }) else { return }
        change(&phones[i])
    }

    /// Where a button's message goes: the selected phone, if it is connected.
    private func sendToSelected(_ envelope: BridgProtoEnvelope) {
        guard let phone = selectedPhone, phone.connected else { return }
        connectionManager.send(envelope, to: phone.id)
    }

    /// Who this Mac is, for the phones' Devices screens.
    static let selfInfo: BridgProtoDeviceInfo = {
        var info = BridgProtoDeviceInfo()
        info.id = ConnectionManager.hubTag(publicKey: KeychainManager().getOrCreatePublicKey())
        info.name = ConnectionManager.deviceName
        info.platform = .macos
        info.appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let v = ProcessInfo.processInfo.operatingSystemVersion
        info.osVersion = "macOS \(v.majorVersion).\(v.minorVersion)"
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        info.model = String(cString: model)
        return info
    }()

    /// Tell every connected phone which phones this Mac has, so their Devices
    /// screens can show each other.
    private func sharePeers() {
        var list = BridgProtoPeers()
        list.peers = phones.map { $0.asPeer }
        var envelope = BridgProtoEnvelope()
        envelope.peers = list
        connectionManager.broadcast(envelope)
    }

    // MARK: - Outbound actions

    /// Files go to the selected phone.
    func sendFiles(_ urls: [URL]) {
        guard let phone = selectedPhone, phone.connected else { return }
        transferLock.lock()
        fileTarget = phone.id
        transferLock.unlock()
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
        guard let phone = notificationHistory.first(where: { $0.id == id })?.deviceID else { return }
        var action = BridgProtoNotificationAction()
        action.actionID = id
        action.label = text
        var envelope = BridgProtoEnvelope()
        envelope.notifAction = action
        connectionManager.send(envelope, to: phone)
    }

    /// Delete a notification here and on the phone.
    ///
    /// The id is the phone's own StatusBarNotification key, so this clears the
    /// exact notification the Mac was showing rather than a same-app sibling.
    func dismissNotification(id: String) {
        let phone = notificationHistory.first(where: { $0.id == id })?.deviceID
        notificationHistory.removeAll { $0.id == id }
        notificationManager.dismissNotification(id: id)

        guard let phone else { return }
        var dismiss = BridgProtoNotificationDismiss()
        dismiss.id = id
        var envelope = BridgProtoEnvelope()
        envelope.notifDismiss = dismiss
        connectionManager.send(envelope, to: phone)
    }

    /// Play/pause, next, previous on whatever the phone is playing.
    func sendMediaCommand(_ action: BridgProtoMediaCommand.Action) {
        var command = BridgProtoMediaCommand()
        command.action = action
        var envelope = BridgProtoEnvelope()
        envelope.mediaCommand = command
        sendToSelected(envelope)
    }

    /// Put a string on the Mac clipboard (in-app "Copy Code" action).
    func copyToClipboard(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    /// Clears `isRinging` when the phone stops by itself.
    ///
    /// ponytail: the phone never reports its ringing state, so this mirrors its
    /// 30 s cutoff (RemoteActionHandler.RING_TIMEOUT_MS). If the two drift, have
    /// the phone send ring state instead.
    private var ringReset: Task<Void, Never>?

    /// Ring the phone at full volume so you can find it, or stop it.
    func ringPhone(_ ring: Bool = true) {
        var action = BridgProtoRemoteAction()
        action.action = ring ? .ring : .stopRing
        var envelope = BridgProtoEnvelope()
        envelope.remoteAction = action
        sendToSelected(envelope)

        isRinging = ring
        ringReset?.cancel()
        guard ring else { return }
        ringReset = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled else { return }
            self?.isRinging = false
        }
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
        sendToSelected(envelope)
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
    /// Goes to the phone that is ringing — the newest call notification's —
    /// falling back to the selected phone.
    func sendCallControl(_ action: BridgProtoCallControl.Action) {
        var control = BridgProtoCallControl()
        control.action = action
        var envelope = BridgProtoEnvelope()
        envelope.callControl = control
        if let phone = notificationHistory.first(where: { $0.isCall })?.deviceID {
            connectionManager.send(envelope, to: phone)
        } else {
            sendToSelected(envelope)
        }
    }

    /// Have the phone place a call. Goes over Bluetooth Hands-Free, not the
    /// Wi-Fi link, so it works whenever the phone is paired with this Mac.
    func dial(_ number: String) {
        phoneDialer.dial(number)
    }

    /// Input belongs to the phone on the mirror, not whichever is selected.
    private func send(_ event: BridgProtoInputEvent) {
        var envelope = BridgProtoEnvelope()
        envelope.inputEvent = event
        if let phone = mirroringPhoneID {
            connectionManager.send(envelope, to: phone)
        } else {
            sendToSelected(envelope)
        }
    }

    // MARK: - Wiring

    private func wireConnection() {
        connectionManager.onPhoneConnected = { [weak self] device in
            Task { @MainActor in
                guard let self else { return }
                if !self.phones.contains(where: { $0.id == device.id }) {
                    self.phones.append(PhoneState(device: device))
                }
                self.update(device.id) { $0.connected = true; $0.name = device.name }
                // Who we are, then who else is here — for the phone's Devices screen.
                var hello = BridgProtoEnvelope()
                hello.deviceInfo = Self.selfInfo
                self.connectionManager.send(hello, to: device.id)
                self.sharePeers()
            }
        }

        connectionManager.onPhoneDisconnected = { [weak self] id in
            guard let self else { return }
            if self.mirroringPhoneID == id {
                self.mirroringPhoneID = nil
                self.audioPlayer.stop()
                self.videoDecoder.reset()
            }
            Task { @MainActor in
                self.update(id) { $0.connected = false; $0.nowPlaying = nil; $0.peers = [] }
                if self.mirroringPhoneID == nil { self.isScreenMirroring = false }
                self.sharePeers()
            }
        }

        connectionManager.onPaired = { [weak self] device in
            Task { @MainActor in
                guard let self else { return }
                if !self.phones.contains(where: { $0.id == device.id }) {
                    self.phones.append(PhoneState(device: device))
                }
                self.selectedPhoneID = device.id
                self.pairingQRCode = nil
            }
        }

        connectionManager.onMessage = { [weak self] envelope, phone in
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
                MainActor.assumeIsolated { self?.route(envelope, from: phone) }
            }
        }

        // Video arrives on the network queue and is decoded there; only the
        // published UI state hops to the main actor.
        connectionManager.onVideoMessage = { [weak self] envelope, phone in
            guard let self else { return }
            // One decoder, one mirror: the first phone to start streaming owns
            // it until it stops; the rest are dropped (the phone sends its
            // screen to every computer it is connected to).
            if case .videoStreamStart = envelope.payload, self.mirroringPhoneID == nil {
                self.mirroringPhoneID = phone
            }
            guard self.mirroringPhoneID == phone else { return }
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
                self.mirroringPhoneID = nil
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
            self.connectionManager.broadcast(envelope)
        }
        clipboardSync.startMonitoring()

        // The file manager pushes chunks itself; it just needed a way out.
        fileTransferManager.onSendEnvelope = { [weak self] envelope, sent in
            guard let self else { return sent?(false) ?? () }
            // Pin each transfer to the phone it started for.
            let id: String
            switch envelope.payload {
            case .fileStart(let start): id = start.transferID
            case .fileChunk(let chunk): id = chunk.transferID
            case .fileCancel(let cancel): id = cancel.transferID
            default: return sent?(false) ?? ()
            }
            self.transferLock.lock()
            if case .fileStart = envelope.payload, let phone = self.fileTarget { self.transferTargets[id] = phone }
            let target = self.transferTargets[id]
            self.transferLock.unlock()
            guard let target else { return sent?(false) ?? () }
            self.connectionManager.send(envelope, to: target, sent: sent)
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

        phoneDialer.onStatus = { [weak self] status in
            Task { @MainActor in self?.dialStatus = status }
        }

        // Clearing a banner on the Mac clears it on the phone too, so the same
        // alert doesn't greet you again when you pick the phone up.
        notificationManager.onDismiss = { [weak self] id in
            Task { @MainActor in self?.dismissNotification(id: id) }
        }
    }

    /// Route a decoded message from `phone` to the feature that owns it.
    private func route(_ envelope: BridgProtoEnvelope, from phone: String) {
        switch envelope.payload {
        case .clipboard(let update):
            guard isClipboardSyncing else { return }
            clipboardSync.handleRemoteClipboard(update)
            lastClipboardContent = update.imageData.isEmpty ? update.content : "[Image]"
            // Copy on one phone, paste on the other; origin_id rides along so
            // nobody applies their own clip back.
            connectionManager.broadcast(envelope, except: phone)

        case .deviceInfo(let info):
            update(phone) { $0.info = info }

        case .peers(let list):
            update(phone) { $0.peers = list.peers }

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
                    isCall: event.isCall,
                    deviceID: phone
                ),
                at: 0
            )

        case .notifDismiss(let dismiss):
            notificationManager.dismissNotification(id: dismiss.id)
            notificationHistory.removeAll { $0.id == dismiss.id }

        case .deviceStatus(let status):
            update(phone) {
                $0.battery = BatteryState(
                    percent: Int(status.batteryPercent),
                    isCharging: status.charging,
                    isLow: status.batteryLow
                )
            }
            sharePeers()

        case .mediaState(let state):
            let playing: MediaItem? = state.active
                ? MediaItem(
                    appLabel: state.appLabel,
                    title: state.title,
                    artist: state.artist,
                    isPlaying: state.playing
                )
                : nil
            update(phone) { $0.nowPlaying = playing }

        case .fileStart(let start):
            fileTransferManager.handleTransferStart(start)

        case .fileChunk(let chunk):
            var ack = BridgProtoEnvelope()
            ack.fileAck = fileTransferManager.handleFileChunk(chunk)
            connectionManager.send(ack, to: phone)

        case .fileAck(let ack):
            fileTransferManager.handleAck(ack)

        default:
            print("Unhandled message: \(String(describing: envelope.payload))")
        }
    }

    struct PhoneState: Identifiable {
        let id: String
        var name: String
        /// Same id the phone's own app and every other computer use for it.
        let tag: String
        var connected = false
        var battery: BatteryState?
        var nowPlaying: MediaItem?
        /// What the phone says about itself; nil from phone builds before 0.5.
        var info: BridgProtoDeviceInfo?
        /// The computers this phone is linked to, as it last reported.
        var peers: [BridgProtoPeer] = []

        init(device: KeychainManager.PairedDeviceInfo) {
            id = device.id
            name = device.name
            tag = ConnectionManager.hubTag(publicKey: device.publicKey)
        }

        var asPeer: BridgProtoPeer {
            var peer = BridgProtoPeer()
            var info = self.info ?? BridgProtoDeviceInfo()
            if info.id.isEmpty { info.id = tag }
            if info.name.isEmpty { info.name = name }
            if info.platform == .unspecified { info.platform = .android }
            peer.info = info
            peer.connected = connected
            peer.batteryPercent = Int32(battery?.percent ?? -1)
            peer.charging = battery?.isCharging ?? false
            return peer
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
    /// The phone it came from; replies and dismissals go back there.
    let deviceID: String
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
