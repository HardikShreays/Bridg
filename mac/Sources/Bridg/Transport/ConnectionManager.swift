import Foundation
import Network
import CryptoKit

/// Owns every connection. The Mac is the *server*: it advertises `_bridg._tcp`
/// over Bonjour and listens; phones discover it and dial in — several at once,
/// each in its own sealed session.
///
/// The previous version both advertised and browsed, so the Mac discovered its
/// own service and dialled itself on every browse update.
final class ConnectionManager {
    static let port: UInt16 = 18920

    /// Three missed ping intervals. A phone answers every ping, so silence this
    /// long means the link is gone even if TCP still believes in it — and a
    /// stranger who opened a socket and never handshook is dropped as well.
    private static let silenceTimeout: TimeInterval = 30

    /// ponytail: fixed cap so a flood of strangers can't pin memory; per-address
    /// limits if Bridg ever listens beyond a home LAN.
    private static let maxConnections = 16

    private let keychainManager: KeychainManager
    private let pairingManager: PairingManager
    private let listenPort: UInt16
    private let advertise: Bool

    /// Everything network-facing runs here. It used to run on `.main`, which
    /// put per-frame decrypt, protobuf parsing and H.264 sample assembly on the
    /// same thread as SwiftUI — the mirror stuttered because the UI and the
    /// decoder were fighting over one thread.
    let netQueue = DispatchQueue(label: "com.bridg.net")

    private var listener: NWListener?
    private var isRunning = false
    private var pingTimer: Timer?

    /// One accepted socket. It speaks for a phone once its handshake names one,
    /// and *is* that phone's session once its first sealed frame opens.
    private final class PeerSession {
        let connection: NWConnection
        let frameBuffer = FrameBuffer()
        var transport: EncryptedTransport?
        var device: KeychainManager.PairedDeviceInfo?
        /// The phone proved it holds the key: a sealed frame opened.
        var confirmed = false
        var lastHeardAt = Date()

        init(_ connection: NWConnection) { self.connection = connection }
    }

    private var peers: [ObjectIdentifier: PeerSession] = [:]
    /// Device id → the confirmed session serving that phone right now.
    private var sessions: [String: ObjectIdentifier] = [:]

    /// Token from the QR code currently on screen. Non-nil only while pairing.
    private var activePairingToken: String?

    // Callbacks, delivered on [netQueue]; AppState hops to the main actor.
    var onPhoneConnected: ((KeychainManager.PairedDeviceInfo) -> Void)?
    var onPhoneDisconnected: ((String) -> Void)?
    var onPaired: ((KeychainManager.PairedDeviceInfo) -> Void)?
    /// Everything but video, with the id of the phone it came from.
    var onMessage: ((BridgProtoEnvelope, String) -> Void)?
    /// Video traffic, delivered synchronously on [netQueue] so decoding never
    /// touches the main thread.
    var onVideoMessage: ((BridgProtoEnvelope, String) -> Void)?

    /// `port` and `keychainManager` are injectable so tests can run a real
    /// instance against a throwaway identity without touching the app's.
    init(port: UInt16 = ConnectionManager.port, keychainManager: KeychainManager = KeychainManager(), advertise: Bool = true) {
        self.listenPort = port
        self.keychainManager = keychainManager
        self.pairingManager = PairingManager(keychainManager: keychainManager)
        self.advertise = advertise
    }

    // MARK: - Lifecycle

    func start() {
        netQueue.async {
            guard !self.isRunning else { return }
            self.isRunning = true
            self.startListening()
            self.startPinging()
        }
    }

    func stop() {
        netQueue.async {
            self.isRunning = false
            self.stopPinging()
            self.listener?.cancel()
            self.listener = nil
            for peer in self.peers.values { peer.connection.cancel() }
            self.peers.removeAll()
            self.sessions.removeAll()
        }
    }

    /// Arm pairing: the next PairRequest must carry this token.
    func beginPairing(token: String) {
        netQueue.async { self.activePairingToken = token }
    }

    /// Drop a phone's live session, e.g. after unpairing it.
    func disconnect(deviceID: String) {
        netQueue.async {
            guard let oid = self.sessions[deviceID] else { return }
            self.peers[oid]?.connection.cancel()
        }
    }

    // MARK: - Sending

    /// Send to one phone. `sent` fires once the socket has taken the bytes, or
    /// immediately with `false` if the frame could not go out. Bulk producers
    /// use it as their backpressure signal; everything else ignores it.
    func send(_ envelope: BridgProtoEnvelope, to deviceID: String, sent: ((Bool) -> Void)? = nil) {
        netQueue.async {
            guard let oid = self.sessions[deviceID], let peer = self.peers[oid] else {
                print("Phone \(deviceID) not connected — dropping \(envelope.payload.map(String.init(describing:)) ?? "message")")
                sent?(false)
                return
            }
            self.sendOnQueue(envelope, to: peer, sent: sent)
        }
    }

    /// Send to every connected phone, optionally skipping the one it came from.
    func broadcast(_ envelope: BridgProtoEnvelope, except deviceID: String? = nil) {
        netQueue.async {
            for (id, oid) in self.sessions where id != deviceID {
                if let peer = self.peers[oid] { self.sendOnQueue(envelope, to: peer) }
            }
        }
    }

    private func sendOnQueue(_ envelope: BridgProtoEnvelope, to peer: PeerSession, sent: ((Bool) -> Void)? = nil) {
        guard peer.connection.state == .ready else {
            sent?(false)
            return
        }
        do {
            var payload = try envelope.serializedData()
            // Everything after the pairing handshake goes out encrypted.
            if let transport = peer.transport {
                guard let sealed = transport.encrypt(payload) else {
                    print("Encryption failed — dropping message")
                    sent?(false)
                    return
                }
                payload = sealed
            }
            peer.connection.send(content: FrameCodec.encode(payload), completion: .contentProcessed { error in
                if let error { print("Send error: \(error)") }
                sent?(error == nil)
            })
        } catch {
            print("Serialization error: \(error)")
            sent?(false)
        }
    }

    // MARK: - Bonjour + listening

    private func startListening() {
        do {
            let params = NWParameters.tcp
            params.includePeerToPeer = true
            (params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.noDelay = true

            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: listenPort)!)

            if advertise {
                listener.service = NWListener.Service(
                    name: "Bridg-\(Self.deviceName)",
                    type: "_bridg._tcp",
                    txtRecord: NWTXTRecord([
                        "name": Self.deviceName,
                        // Lets a phone paired with several computers dial only its
                        // own and know which one it reached.
                        "id": Self.hubTag(publicKey: keychainManager.getOrCreatePublicKey()),
                    ])
                )
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }

            listener.stateUpdateHandler = { [listenPort] state in
                switch state {
                case .ready: print("Listening on port \(listenPort), advertising _bridg._tcp")
                case .failed(let error): print("Listener failed: \(error)")
                default: break
                }
            }

            listener.start(queue: netQueue)
            self.listener = listener
        } catch {
            print("Failed to create listener: \(error)")
        }
    }

    private func accept(_ connection: NWConnection) {
        // Accepting a newcomer never touches an existing session: anything on
        // the network can open this port, and it used to be able to hang up
        // your phone just by connecting.
        guard peers.count < Self.maxConnections else {
            print("Refusing \(connection.endpoint): too many connections")
            connection.cancel()
            return
        }
        let peer = PeerSession(connection)
        let oid = ObjectIdentifier(peer)
        peers[oid] = peer

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                peer.lastHeardAt = Date()
            case .failed(let error):
                print("Connection failed: \(error)")
                self.teardown(oid)
            case .cancelled:
                self.teardown(oid)
            default:
                break
            }
        }

        connection.start(queue: netQueue)
        receive(oid)
    }

    private func teardown(_ oid: ObjectIdentifier) {
        guard let peer = peers.removeValue(forKey: oid) else { return }
        peer.connection.cancel()
        // Only the session currently serving a phone takes the phone with it; a
        // session already replaced by a newer one just goes quietly.
        if let id = peer.device?.id, sessions[id] == oid {
            sessions[id] = nil
            print("Phone disconnected: \(peer.device?.name ?? id)")
            onPhoneDisconnected?(id)
        }
    }

    /// The keepalive Timer needs a run loop, and [netQueue] has none — schedule
    /// and invalidate it on main, do the work on the queue.
    private func startPinging() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pingTimer?.invalidate()
            self.pingTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                self?.netQueue.async { self?.keepAlive() }
            }
        }
    }

    private func keepAlive() {
        var ping = BridgProtoPing()
        ping.timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        var envelope = BridgProtoEnvelope()
        envelope.ping = ping

        for peer in peers.values {
            // Silent too long: the link is dead even though TCP has not
            // noticed, or it is a stranger that never handshook.
            if Date().timeIntervalSince(peer.lastHeardAt) > Self.silenceTimeout {
                print("Nothing heard in \(Self.silenceTimeout)s — dropping \(peer.connection.endpoint)")
                peer.connection.cancel()
            } else if peer.transport != nil {
                sendOnQueue(envelope, to: peer)
            }
        }
    }

    private func stopPinging() {
        DispatchQueue.main.async {
            self.pingTimer?.invalidate()
            self.pingTimer = nil
        }
    }

    // MARK: - Receiving

    private func receive(_ oid: ObjectIdentifier) {
        guard let peer = peers[oid] else { return }
        peer.connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, self.peers[oid] != nil else { return }

            if let data, !data.isEmpty {
                peer.frameBuffer.append(data)
                self.drainFrames(oid)
            }
            if let error {
                print("Receive error: \(error)")
                self.teardown(oid)
                return
            }
            if isComplete {
                self.teardown(oid)
                return
            }
            self.receive(oid)
        }
    }

    private func drainFrames(_ oid: ObjectIdentifier) {
        while let peer = peers[oid] {
            let frame: Data?
            do {
                frame = try peer.frameBuffer.next()
            } catch {
                print("Framing error: \(error) — dropping connection")
                peer.connection.cancel()
                return
            }
            guard let frame else { return }

            // Pre-pairing frames are plaintext; everything after is sealed.
            let payload: Data
            if let transport = peer.transport {
                // A frame that will not open is a replay, a forgery or a key
                // mismatch. None of those get better by reading the next frame.
                guard let opened = transport.decrypt(frame) else {
                    print("Rejected frame — dropping connection")
                    peer.connection.cancel()
                    return
                }
                payload = opened
                if !peer.confirmed { confirm(oid, peer) }
            } else {
                payload = frame
            }

            guard let envelope = try? BridgProtoEnvelope(serializedData: payload) else {
                print("Deserialization error — skipping frame")
                continue
            }

            // Before the session key exists the only thing a peer may say is
            // the handshake. Anything on the LAN can open this port, and a
            // plaintext clipboard, notification or file frame used to reach the
            // feature handlers as if it came from the paired phone.
            if peer.transport == nil, !Self.allowedBeforeHandshake(envelope) {
                print("Plaintext \(envelope.payload.map(String.init(describing:)) ?? "frame") before the handshake — dropping connection")
                peer.connection.cancel()
                return
            }

            peer.lastHeardAt = Date()
            if handleTransportMessage(envelope, oid, peer) { continue }
            guard peer.confirmed, let id = peer.device?.id else { continue }

            // Decode on this queue rather than shipping the frame to the main
            // actor first — that hop is what the mirror's latency was made of.
            switch envelope.payload {
            case .videoFrame, .videoStreamStart, .videoStreamStop, .audioFrame:
                onVideoMessage?(envelope, id)
            default:
                onMessage?(envelope, id)
            }
        }
    }

    /// The first sealed frame opened: this socket really is the phone it named
    /// in its handshake. Only now may it take over from an older session for the
    /// same phone. PairResume is plaintext and carries a public key hash, so
    /// letting it evict would let anyone on the network kick a phone off.
    private func confirm(_ oid: ObjectIdentifier, _ peer: PeerSession) {
        guard let device = peer.device else { return }
        peer.confirmed = true
        // Point the phone at this session first: the old one's teardown then
        // sees it no longer serves the phone and goes without reporting it gone.
        let old = sessions[device.id]
        sessions[device.id] = oid
        if let old, old != oid { peers[old]?.connection.cancel() }
        print("Phone connected: \(device.name)")
        onPhoneConnected?(device)
    }

    // MARK: - Handshake + keepalive

    /// The only frames a peer may send before the session is encrypted.
    static func allowedBeforeHandshake(_ envelope: BridgProtoEnvelope) -> Bool {
        switch envelope.payload {
        case .pairRequest, .pairResume: return true
        default: return false
        }
    }

    /// Returns true when the message was consumed by the transport layer itself.
    private func handleTransportMessage(_ envelope: BridgProtoEnvelope, _ oid: ObjectIdentifier, _ peer: PeerSession) -> Bool {
        switch envelope.payload {
        case .pairRequest(let request):
            if peer.transport == nil { handlePairRequest(request, peer) }
            return true

        case .pairResume(let resume):
            if peer.transport == nil { handlePairResume(resume, peer) }
            return true

        case .ping(let ping):
            var pong = BridgProtoPong()
            pong.timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
            pong.pingTimestamp = ping.timestamp
            var reply = BridgProtoEnvelope()
            reply.pong = pong
            sendOnQueue(reply, to: peer)
            return true

        case .pong:
            return true

        default:
            return false
        }
    }

    private func handlePairRequest(_ request: BridgProtoPairRequest, _ peer: PeerSession) {
        guard let expected = activePairingToken else {
            print("PairRequest with no pairing in progress — ignoring")
            return
        }
        guard var response = pairingManager.handlePairRequest(request, expectedToken: expected) else {
            return // token mismatch, already logged
        }
        guard let info = connectionInfo(initiatorSalt: request.sessionSalt, peer) else { return }

        let peerKey = request.senderPubkey
        guard let sharedKey = keychainManager.deriveSharedSecret(peerPublicKeyData: peerKey, info: info.info) else {
            print("Key agreement failed")
            return
        }

        let device = pairingManager.completePairing(peerPublicKey: peerKey, deviceName: request.deviceName)
        activePairingToken = nil

        // The response is the last plaintext frame and carries our salt, which
        // the phone needs to derive the same key. Encryption starts after it.
        response.sessionSalt = info.ourSalt
        var envelope = BridgProtoEnvelope()
        envelope.pairResponse = response
        sendOnQueue(envelope, to: peer)

        peer.device = device
        peer.transport = EncryptedTransport(sharedKey: sharedKey, sending: .macToPhone)
        onPaired?(device)
    }

    private func handlePairResume(_ resume: BridgProtoPairResume, _ peer: PeerSession) {
        guard let device = keychainManager.getPairedDevices().first(where: {
            Data(SHA256.hash(data: $0.publicKey)) == resume.devicePubkeyHash
        }) else {
            print("PairResume from an unknown device — ignoring")
            return
        }
        guard let info = connectionInfo(initiatorSalt: resume.sessionSalt, peer) else { return }

        guard let sharedKey = keychainManager.deriveSharedSecret(peerPublicKeyData: device.publicKey, info: info.info) else {
            print("Key agreement failed on resume")
            return
        }

        // The ack goes out in the clear because it carries the salt the phone
        // needs to derive this connection's key — it cannot open a sealed one.
        // It is the last plaintext frame; encryption starts immediately after.
        var ack = BridgProtoPairResumeAck()
        ack.accepted = true
        ack.sessionSalt = info.ourSalt
        var envelope = BridgProtoEnvelope()
        envelope.pairResumeAck = ack
        sendOnQueue(envelope, to: peer)

        peer.device = device
        peer.transport = EncryptedTransport(sharedKey: sharedKey, sending: .macToPhone)
    }

    /// Our fresh salt plus the HKDF info binding this connection's key to both
    /// sides' salts. Nil if the phone sent none — an old build whose key would
    /// repeat on every reconnect, which is exactly what the salts prevent.
    private func connectionInfo(initiatorSalt: Data, _ peer: PeerSession) -> (ourSalt: Data, info: Data)? {
        guard initiatorSalt.count == SharedSecretKDF.saltLength else {
            print("Handshake carried no session salt — refusing to connect. Update the phone app.")
            peer.connection.cancel()
            return nil
        }
        let ourSalt = SharedSecretKDF.randomSalt()
        return (ourSalt, SharedSecretKDF.connectionInfo(initiatorSalt: initiatorSalt, responderSalt: ourSalt))
    }

    static var deviceName: String { Host.current().localizedName ?? "Mac" }

    /// Hex of the first 8 bytes of SHA-256(public key), advertised as TXT `id`.
    /// Must match KeyManager.hubTag on Android.
    static func hubTag(publicKey: Data) -> String {
        SHA256.hash(data: publicKey).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
