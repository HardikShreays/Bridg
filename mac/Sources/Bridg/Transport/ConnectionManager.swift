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
        }
    }

    /// Arm pairing: the phone's next PairRequest must carry this token.
    func beginPairing(token: String) {
        netQueue.async { self.activePairingToken = token }
    }

    // MARK: - Sending

    func send(_ envelope: BridgProtoEnvelope) {
        netQueue.async { self.sendOnQueue(envelope) }
    }

    private func sendOnQueue(_ envelope: BridgProtoEnvelope) {
        guard let connection, connection.state == .ready else {
            print("Not connected — dropping \(envelope.payload.map(String.init(describing:)) ?? "message")")
            return
        }

        do {
            var payload = try envelope.serializedData()

            // Everything after the pairing handshake goes out encrypted.
            if let transport = encryptedTransport {
                guard let sealed = transport.encrypt(payload) else {
                    print("Encryption failed — dropping message")
                    return
                }
                payload = sealed
            }

            connection.send(content: FrameCodec.encode(payload), completion: .contentProcessed { error in
                if let error { print("Send error: \(error)") }
            })
        } catch {
            print("Serialization error: \(error)")
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
        // One phone at a time: drop any stale connection first.
        connection?.cancel()
        frameBuffer.reset()
        encryptedTransport = nil
        connection = new

        new.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                print("Phone connected: \(new.endpoint)")
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
                guard let opened = transport.decrypt(frame) else { continue }
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
            case .videoFrame, .videoStreamStart, .videoStreamStop:
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
            var pong = BridgProtoPong()
            pong.timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
            pong.pingTimestamp = ping.timestamp
            var reply = BridgProtoEnvelope()
            reply.pong = pong
            sendOnQueue(reply)
            return true

        case .pong:
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
        guard let response = pairingManager.handlePairRequest(request, expectedToken: expected) else {
            return // token mismatch, already logged
        }

        let peerKey = request.senderPubkey
        guard let sharedKey = keychainManager.deriveSharedSecret(peerPublicKeyData: peerKey) else {
            print("Key agreement failed")
            return
        }

        pairingManager.completePairing(peerPublicKey: peerKey, deviceName: request.deviceName)
        activePairingToken = nil

        // The response itself is the last plaintext frame; encryption starts after.
        var envelope = BridgProtoEnvelope()
        envelope.pairResponse = response
        sendOnQueue(envelope)

        encryptedTransport = EncryptedTransport(sharedKey: sharedKey, sending: .macToPhone)
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

        guard let sharedKey = keychainManager.deriveSharedSecret(peerPublicKeyData: device.publicKey) else {
            print("Key agreement failed on resume")
            return
        }

        // Turn on encryption first: the ack goes out sealed, so the phone
        // decrypting it is proof enough that both sides hold the same key.
        encryptedTransport = EncryptedTransport(sharedKey: sharedKey, sending: .macToPhone)

        var ack = BridgProtoPairResumeAck()
        ack.accepted = true
        var envelope = BridgProtoEnvelope()
        envelope.pairResumeAck = ack
        sendOnQueue(envelope)

        onPaired?(device.name)
    }

    static var deviceName: String { Host.current().localizedName ?? "Mac" }
}
