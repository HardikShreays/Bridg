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

    private var listener: NWListener?
    private var connection: NWConnection?
    private let frameBuffer = FrameBuffer()

    private var encryptedTransport: EncryptedTransport?
    private var isRunning = false
    private var pingTimer: Timer?

    /// Token from the QR code currently on screen. Non-nil only while pairing.
    private var activePairingToken: String?

    // Callbacks (delivered on the main queue).
    var onConnected: ((String) -> Void)?
    var onDisconnected: (() -> Void)?
    var onPaired: ((String) -> Void)?
    var onMessage: ((BridgProtoEnvelope) -> Void)?

    var isConnected: Bool { connection?.state == .ready }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        startListening()
    }

    func stop() {
        isRunning = false
        pingTimer?.invalidate()
        pingTimer = nil
        listener?.cancel()
        connection?.cancel()
        listener = nil
        connection = nil
        encryptedTransport = nil
    }

    /// Arm pairing: the phone's next PairRequest must carry this token.
    func beginPairing(token: String) {
        activePairingToken = token
    }

    // MARK: - Sending

    func send(_ envelope: BridgProtoEnvelope) {
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

            listener.start(queue: .main)
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

        new.start(queue: .main)
        receive(on: new)
    }

    private func teardown(_ dead: NWConnection) {
        // Ignore the death rattle of a connection we already replaced.
        guard dead === connection else { return }
        pingTimer?.invalidate()
        pingTimer = nil
        connection = nil
        encryptedTransport = nil
        frameBuffer.reset()
        onDisconnected?()
    }

    private func startPinging() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self, self.isConnected else { return }
            var ping = BridgProtoPing()
            ping.timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
            var envelope = BridgProtoEnvelope()
            envelope.ping = ping
            self.send(envelope)
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

            if !handleTransportMessage(envelope) {
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
            send(reply)
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
        send(envelope)

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
        send(envelope)

        onPaired?(device.name)
    }

    static var deviceName: String { Host.current().localizedName ?? "Mac" }
}
