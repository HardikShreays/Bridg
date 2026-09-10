import Foundation
import Network
import CryptoKit

/// Owns the connection lifecycle. The Mac is the *server*: it advertises
/// `_bridg._tcp` over Bonjour and listens; the phone discovers and dials in.
///
/// The previous version both advertised and browsed, so the Mac discovered its
/// own service and dialled itself on every browse update.
final class ConnectionManager {
    static let port: UInt16 = 18920

    /// Three missed ping intervals. The phone answers every ping, so silence
    /// this long means the link is gone even if TCP still believes in it.
    private static let pongTimeout: TimeInterval = 30

    private let keychainManager = KeychainManager()
    private let pairingManager = PairingManager()

    /// Everything network-facing runs here. It used to run on `.main`, which
    /// put per-frame decrypt, protobuf parsing and H.264 sample assembly on the
    /// same thread as SwiftUI — the mirror stuttered because the UI and the
    /// decoder were fighting over one thread.
    private let netQueue = DispatchQueue(label: "com.bridg.net")

    private var listener: NWListener?
    private var connection: NWConnection?
    private let frameBuffer = FrameBuffer()

    private var encryptedTransport: EncryptedTransport?
    private var isRunning = false
    private var pingTimer: Timer?

    /// True once the current connection has completed a handshake. Anything
    /// before that is just a stranger who opened a TCP socket.
    private var isAuthenticated = false

    /// When the current connection last proved it was alive. A phone that
    /// leaves the Wi-Fi network never closes its socket, so without this the
    /// Mac holds a dead connection open and refuses the real reconnect.
    private var lastPongAt = Date()

    /// Token from the QR code currently on screen. Non-nil only while pairing.
    private var activePairingToken: String?

    // Callbacks (delivered on [netQueue]; AppState hops to the main actor).
    var onConnected: ((String) -> Void)?
    var onDisconnected: (() -> Void)?
    var onPaired: ((String) -> Void)?
    var onMessage: ((BridgProtoEnvelope) -> Void)?

    /// Video traffic, delivered synchronously on [netQueue] so decoding never
    /// touches the main thread. Everything else goes through [onMessage].
    var onVideoMessage: ((BridgProtoEnvelope) -> Void)?

    var isConnected: Bool { connection?.state == .ready }

    // MARK: - Lifecycle

    func start() {
        netQueue.async {
            guard !self.isRunning else { return }
            self.isRunning = true
            self.startListening()
        }
    }

    func stop() {
        netQueue.async {
            self.isRunning = false
            self.stopPinging()
            self.listener?.cancel()
            self.connection?.cancel()
            self.listener = nil
            self.connection = nil
            self.encryptedTransport = nil
            self.isAuthenticated = false
        }
    }

    /// Arm pairing: the phone's next PairRequest must carry this token.
    func beginPairing(token: String) {
        netQueue.async { self.activePairingToken = token }
    }

    // MARK: - Sending

    /// `sent` fires once the socket has taken the bytes, or immediately with
    /// `false` if the frame could not go out. Bulk producers use it as their
    /// backpressure signal; everything else ignores it.
    func send(_ envelope: BridgProtoEnvelope, sent: ((Bool) -> Void)? = nil) {
        netQueue.async { self.sendOnQueue(envelope, sent: sent) }
    }

    private func sendOnQueue(_ envelope: BridgProtoEnvelope, sent: ((Bool) -> Void)? = nil) {
        guard let connection, connection.state == .ready else {
            print("Not connected — dropping \(envelope.payload.map(String.init(describing:)) ?? "message")")
            sent?(false)
            return
        }

        do {
            var payload = try envelope.serializedData()

            // Everything after the pairing handshake goes out encrypted.
            if let transport = encryptedTransport {
                guard let sealed = transport.encrypt(payload) else {
                    print("Encryption failed — dropping message")
                    sent?(false)
                    return
                }
                payload = sealed
            }

            connection.send(content: FrameCodec.encode(payload), completion: .contentProcessed { error in
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

            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.port)!)

            listener.service = NWListener.Service(
                name: "Bridg-\(Self.deviceName)",
                type: "_bridg._tcp",
                txtRecord: NWTXTRecord(["name": Self.deviceName])
            )

            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }

            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: print("Listening on port \(Self.port), advertising _bridg._tcp")
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

    private func accept(_ new: NWConnection) {
        // One phone at a time — but an unauthenticated newcomer must not be
        // able to evict a paired phone. Anything on the network can open a
        // socket to this port, and cancelling first meant anything on the
        // network could hang up your phone. A genuine reconnect arrives after
        // the old socket closed (so there is nothing to evict), or once the
        // keepalive below has retired a silently dead one.
        if isAuthenticated, connection != nil {
            print("Refusing \(new.endpoint): already connected to a paired phone")
            new.cancel()
            return
        }

        connection?.cancel()
        frameBuffer.reset()
        encryptedTransport = nil
        isAuthenticated = false
        connection = new

        new.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                print("Phone connected: \(new.endpoint)")
                self.lastPongAt = Date()
                self.onConnected?("\(new.endpoint)")
                self.startPinging()
            case .failed(let error):
                print("Connection failed: \(error)")
                self.teardown(new)
            case .cancelled:
                self.teardown(new)
            default:
                break
            }
        }

        new.start(queue: netQueue)
        receive(on: new)
    }

    private func teardown(_ dead: NWConnection) {
        // Ignore the death rattle of a connection we already replaced.
        guard dead === connection else { return }
        stopPinging()
        connection = nil
        encryptedTransport = nil
        isAuthenticated = false
        frameBuffer.reset()
        onDisconnected?()
    }

    /// The keepalive Timer needs a run loop, and [netQueue] has none — schedule
    /// and invalidate it on main. `send` hops back to the queue on its own.
    private func startPinging() {
        DispatchQueue.main.async {
            self.pingTimer?.invalidate()
            self.pingTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                guard let self, self.isConnected else { return }

                // No answer in three ping intervals: the link is dead even
                // though TCP has not noticed. Retire it so the phone's next
                // reconnect is not refused as a duplicate.
                self.netQueue.async {
                    guard let connection = self.connection else { return }
                    if Date().timeIntervalSince(self.lastPongAt) > Self.pongTimeout {
                        print("No pong in \(Self.pongTimeout)s — dropping a dead connection")
                        connection.cancel()
                    }
                }

                var ping = BridgProtoPing()
                ping.timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
                var envelope = BridgProtoEnvelope()
                envelope.ping = ping
                self.send(envelope)
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

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                self.frameBuffer.append(data)
                self.drainFrames()
            }

            if let error {
                print("Receive error: \(error)")
                self.teardown(connection)
                return
            }

            if isComplete {
                self.teardown(connection)
                return
            }

            self.receive(on: connection)
        }
    }

    private func drainFrames() {
        while true {
            let frame: Data?
            do {
                frame = try frameBuffer.next()
            } catch {
                print("Framing error: \(error) — dropping connection")
                connection?.cancel()
                return
            }
            guard let frame else { return }

            // Pre-pairing frames are plaintext; everything after is sealed.
            let payload: Data
            if let transport = encryptedTransport {
                // A frame that will not open is a replay, a forgery or a key
                // mismatch. None of those get better by reading the next frame.
                guard let opened = transport.decrypt(frame) else {
                    print("Rejected frame — dropping connection")
                    connection?.cancel()
                    return
                }
                payload = opened
            } else {
                payload = frame
            }

            guard let envelope = try? BridgProtoEnvelope(serializedData: payload) else {
                print("Deserialization error — skipping frame")
                continue
            }

            if handleTransportMessage(envelope) { continue }

            // Decode on this queue rather than shipping the frame to the main
            // actor first — that hop is what the mirror's latency was made of.
            switch envelope.payload {
            case .videoFrame, .videoStreamStart, .videoStreamStop, .audioFrame:
                onVideoMessage?(envelope)
            default:
                onMessage?(envelope)
            }
        }
    }

    // MARK: - Handshake + keepalive

    /// Returns true when the message was consumed by the transport layer itself.
    private func handleTransportMessage(_ envelope: BridgProtoEnvelope) -> Bool {
        switch envelope.payload {
        case .pairRequest(let request):
            handlePairRequest(request)
            return true

        case .pairResume(let resume):
            handlePairResume(resume)
            return true

        case .ping(let ping):
            lastPongAt = Date()
            var pong = BridgProtoPong()
            pong.timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
            pong.pingTimestamp = ping.timestamp
            var reply = BridgProtoEnvelope()
            reply.pong = pong
            sendOnQueue(reply)
            return true

        case .pong:
            lastPongAt = Date()
            return true

        default:
            return false
        }
    }

    private func handlePairRequest(_ request: BridgProtoPairRequest) {
        guard let expected = activePairingToken else {
            print("PairRequest with no pairing in progress — ignoring")
            return
        }
        guard var response = pairingManager.handlePairRequest(request, expectedToken: expected) else {
            return // token mismatch, already logged
        }
        guard let info = connectionInfo(initiatorSalt: request.sessionSalt) else { return }

        let peerKey = request.senderPubkey
        guard let sharedKey = keychainManager.deriveSharedSecret(peerPublicKeyData: peerKey, info: info.info) else {
            print("Key agreement failed")
            return
        }

        pairingManager.completePairing(peerPublicKey: peerKey, deviceName: request.deviceName)
        activePairingToken = nil

        // The response is the last plaintext frame and carries our salt, which
        // the phone needs to derive the same key. Encryption starts after it.
        response.sessionSalt = info.ourSalt
        var envelope = BridgProtoEnvelope()
        envelope.pairResponse = response
        sendOnQueue(envelope)

        encryptedTransport = EncryptedTransport(sharedKey: sharedKey, sending: .macToPhone)
        isAuthenticated = true
        onPaired?(request.deviceName)
    }

    private func handlePairResume(_ resume: BridgProtoPairResume) {
        let devices = keychainManager.getPairedDevices()
        guard let device = devices.first(where: {
            Data(SHA256.hash(data: $0.publicKey)) == resume.devicePubkeyHash
        }) else {
            print("PairResume from an unknown device — ignoring")
            return
        }
        guard let info = connectionInfo(initiatorSalt: resume.sessionSalt) else { return }

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
        sendOnQueue(envelope)

        encryptedTransport = EncryptedTransport(sharedKey: sharedKey, sending: .macToPhone)
        isAuthenticated = true
        onPaired?(device.name)
    }

    /// Our fresh salt plus the HKDF info binding this connection's key to both
    /// sides' salts. Nil if the phone sent none — an old build whose key would
    /// repeat on every reconnect, which is exactly what the salts prevent.
    private func connectionInfo(initiatorSalt: Data) -> (ourSalt: Data, info: Data)? {
        guard initiatorSalt.count == SharedSecretKDF.saltLength else {
            print("Handshake carried no session salt — refusing to connect. Update the phone app.")
            connection?.cancel()
            return nil
        }
        let ourSalt = SharedSecretKDF.randomSalt()
        return (ourSalt, SharedSecretKDF.connectionInfo(initiatorSalt: initiatorSalt, responderSalt: ourSalt))
    }

    static var deviceName: String { Host.current().localizedName ?? "Mac" }
}
