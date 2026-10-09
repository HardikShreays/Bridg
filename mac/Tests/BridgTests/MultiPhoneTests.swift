import XCTest
import CryptoKit
import Darwin
@testable import Bridg

/// A phone, as far as the Mac can tell: a TCP socket speaking the real
/// handshake and the real sealed transport. Blocking POSIX I/O keeps it simple.
private final class FakePhone {
    let key: Curve25519.KeyAgreement.PrivateKey
    let name: String
    private var fd: Int32 = -1
    private var transport: EncryptedTransport?

    init(_ name: String, key: Curve25519.KeyAgreement.PrivateKey = .init()) {
        self.name = name
        self.key = key
    }

    deinit { if fd >= 0 { close(fd) } }

    func dial(_ port: UInt16) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard r == 0 else { throw NSError(domain: "dial", code: Int(errno)) }
    }

    private func write(_ payload: Data) {
        let framed = FrameCodec.encode(payload)
        _ = framed.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, framed.count) }
    }

    private func readExact(_ n: Int) -> Data? {
        var out = Data()
        var buf = [UInt8](repeating: 0, count: n)
        while out.count < n {
            let got = recv(fd, &buf, n - out.count, 0)
            if got <= 0 { return nil }
            out.append(contentsOf: buf[0..<got])
        }
        return out
    }

    /// Nil on timeout or a closed socket.
    func readFrame(timeout: Int = 2) -> Data? {
        var tv = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        guard let len = readExact(4) else { return nil }
        let n = len.reduce(0) { ($0 << 8) | Int($1) }
        return n == 0 ? Data() : readExact(n)
    }

    /// True once the Mac has hung up on us.
    func isClosedByPeer() -> Bool {
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var byte: UInt8 = 0
        return recv(fd, &byte, 1, 0) == 0
    }

    private func derive(mac: Data, ourSalt: Data, theirSalt: Data, as key: Curve25519.KeyAgreement.PrivateKey) throws {
        let raw = try key.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: mac)).withUnsafeBytes { Data($0) }
        let session = SharedSecretKDF.derive(rawSharedSecret: raw, info: SharedSecretKDF.connectionInfo(initiatorSalt: ourSalt, responderSalt: theirSalt))
        transport = EncryptedTransport(sharedKey: session, sending: .phoneToMac)
    }

    func pair(port: UInt16, token: String, mac: Data) throws {
        try dial(port)
        let salt = SharedSecretKDF.randomSalt()
        var req = BridgProtoPairRequest()
        req.senderPubkey = key.publicKey.rawRepresentation
        req.deviceName = name
        req.pairingToken = token
        req.sessionSalt = salt
        var env = BridgProtoEnvelope()
        env.pairRequest = req
        write(try env.serializedData())
        let reply = try BridgProtoEnvelope(serializedBytes: readFrame() ?? Data())
        try derive(mac: mac, ourSalt: salt, theirSalt: reply.pairResponse.sessionSalt, as: key)
    }

    /// `claiming` lets a stranger present someone else's (public) key hash.
    func resume(port: UInt16, mac: Data, claiming: Data? = nil) throws {
        try dial(port)
        let salt = SharedSecretKDF.randomSalt()
        var res = BridgProtoPairResume()
        res.devicePubkeyHash = Data(SHA256.hash(data: claiming ?? key.publicKey.rawRepresentation))
        res.sessionSalt = salt
        var env = BridgProtoEnvelope()
        env.pairResume = res
        write(try env.serializedData())
        let reply = try BridgProtoEnvelope(serializedBytes: readFrame() ?? Data())
        try derive(mac: mac, ourSalt: salt, theirSalt: reply.pairResumeAck.sessionSalt, as: key)
    }

    /// No session key: what a stranger on the network sends.
    func sendPlain(_ env: BridgProtoEnvelope) throws {
        write(try env.serializedData())
    }

    func sendSealed(_ env: BridgProtoEnvelope) throws {
        write(transport!.encrypt(try env.serializedData())!)
    }

    /// Next non-keepalive message, or nil.
    func readSealed(timeout: Int = 2) -> BridgProtoEnvelope? {
        while let frame = readFrame(timeout: timeout) {
            guard let plain = transport?.decrypt(frame),
                  let env = try? BridgProtoEnvelope(serializedBytes: plain) else { return nil }
            if case .ping = env.payload { continue }
            return env
        }
        return nil
    }

    func sayHello() throws {
        var status = BridgProtoDeviceStatus()
        status.batteryPercent = 50
        var env = BridgProtoEnvelope()
        env.deviceStatus = status
        try sendSealed(env)
    }
}

final class MultiPhoneTests: XCTestCase {
    private var keychain: KeychainManager!
    private var hub: ConnectionManager!
    private var port: UInt16 = 0
    private var mac = Data()

    private let lock = NSLock()
    private var connected: [String] = []
    private var disconnected: [String] = []
    private var paired: [String: String] = [:] // name → id
    private var messages: [(String, BridgProtoEnvelope)] = []

    override func setUp() {
        keychain = KeychainManager(service: "com.bridg.tests.hub.\(UUID().uuidString)")
        mac = keychain.getOrCreatePublicKey()
        port = UInt16.random(in: 41000...59000)
        hub = ConnectionManager(port: port, keychainManager: keychain, advertise: false)
        hub.onPhoneConnected = { d in self.lock.withLock { self.connected.append(d.id) } }
        hub.onPhoneDisconnected = { id in self.lock.withLock { self.disconnected.append(id) } }
        hub.onPaired = { d in self.lock.withLock { self.paired[d.name] = d.id } }
        hub.onMessage = { e, id in self.lock.withLock { self.messages.append((id, e)) } }
        hub.start()
        Thread.sleep(forTimeInterval: 0.3) // listener up
    }

    override func tearDown() {
        hub.stop()
        keychain.resetIdentity()
    }

    private func eventually(_ what: String, _ check: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if lock.withLock(check) { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTFail("timed out waiting for \(what)")
    }

    private func pairAndConnect(_ phone: FakePhone) throws -> String {
        let token = UUID().uuidString
        hub.beginPairing(token: token)
        Thread.sleep(forTimeInterval: 0.05)
        try phone.pair(port: port, token: token, mac: mac)
        try phone.sayHello()
        eventually("\(phone.name) connected") { paired[phone.name].map(connected.contains) ?? false }
        return lock.withLock { paired[phone.name]! }
    }

    private func clip(_ text: String) -> BridgProtoEnvelope {
        var update = BridgProtoClipboardUpdate()
        update.content = text
        var env = BridgProtoEnvelope()
        env.clipboard = update
        return env
    }

    func testTwoPhonesConnectAtOnceAndMessagesGoToTheRightOne() throws {
        let a = FakePhone("Phone A"), b = FakePhone("Phone B")
        let idA = try pairAndConnect(a)
        let idB = try pairAndConnect(b)
        XCTAssertNotEqual(idA, idB)
        XCTAssertTrue(lock.withLock { connected.contains(idA) && connected.contains(idB) && disconnected.isEmpty },
                      "the second phone must not knock the first off")

        // Each phone's messages are attributed to it.
        eventually("both hellos") { Set(messages.map(\.0)) == [idA, idB] }

        // A targeted send reaches only its phone.
        hub.send(clip("for A"), to: idA)
        XCTAssertEqual(a.readSealed()?.clipboard.content, "for A")
        XCTAssertNil(b.readSealed(timeout: 1))

        // A broadcast reaches both, minus the excluded one.
        hub.broadcast(clip("everyone but B"), except: idB)
        XCTAssertEqual(a.readSealed()?.clipboard.content, "everyone but B")
        XCTAssertNil(b.readSealed(timeout: 1))
    }

    /// Re-pairing the same phone keeps one entry, not a twin.
    func testRepairingAPhoneKeepsOneEntry() throws {
        let key = Curve25519.KeyAgreement.PrivateKey()
        let first = try pairAndConnect(FakePhone("Phone A", key: key))
        lock.withLock { paired = [:] }
        let second = try pairAndConnect(FakePhone("Phone A", key: key))
        XCTAssertEqual(first, second)
        XCTAssertEqual(keychain.getPairedDevices().count, 1)
    }

    func testAReconnectReplacesTheOldSessionQuietly() throws {
        let a = FakePhone("Phone A")
        let id = try pairAndConnect(a)

        // The phone dropped off Wi-Fi without closing; it now comes back.
        let again = FakePhone("Phone A", key: a.key)
        try again.resume(port: port, mac: mac)
        try again.sayHello()
        eventually("second session confirmed") { connected.filter { $0 == id }.count == 2 }

        XCTAssertTrue(a.isClosedByPeer(), "the stale socket is closed")
        XCTAssertTrue(lock.withLock { !disconnected.contains(id) }, "the phone never looked gone")
        hub.send(clip("to the new one"), to: id)
        XCTAssertEqual(again.readSealed()?.clipboard.content, "to the new one")
    }

    /// The key hash in PairResume is public. Presenting it gets a stranger the
    /// plaintext ack, but without the phone's private key its first sealed
    /// frame cannot open — so it must never displace the real phone.
    func testAStrangerWithThePhonesHashCannotTakeItsSession() throws {
        let a = FakePhone("Phone A")
        let id = try pairAndConnect(a)

        let stranger = FakePhone("Mallory")
        try stranger.resume(port: port, mac: mac, claiming: a.key.publicKey.rawRepresentation)
        try stranger.sayHello()
        XCTAssertTrue(stranger.isClosedByPeer(), "a frame that won't open drops the stranger")

        XCTAssertTrue(lock.withLock { connected == [id] && disconnected.isEmpty })
        hub.send(clip("still yours"), to: id)
        XCTAssertEqual(a.readSealed()?.clipboard.content, "still yours")
    }

    func testPlaintextBeforeTheHandshakeIsDropped() throws {
        let stranger = FakePhone("Mallory")
        try stranger.dial(port)
        try stranger.sendPlain(clip("pasted into your Mac"))
        XCTAssertTrue(stranger.isClosedByPeer())
        XCTAssertTrue(lock.withLock { messages.isEmpty })
    }
}
