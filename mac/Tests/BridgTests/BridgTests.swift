import XCTest
import AVFoundation
import CryptoKit
@testable import Bridg

final class BridgTests: XCTestCase {

    /// Runs against a throwaway keychain service. Pointing this at the real
    /// "com.bridg" item made `swift test` regenerate the running app's identity
    /// and silently unpair every device.
    func testKeychainManagerKeyPairGeneration() {
        let service = "com.bridg.tests.\(UUID().uuidString)"
        let manager = KeychainManager(service: service)
        defer { manager.resetIdentity() }

        let publicKey = manager.generateKeyPair()
        XCTAssertEqual(publicKey?.count, 32) // X25519 public key is 32 bytes

        // A second call must return the same identity, not mint a new one.
        XCTAssertEqual(manager.getOrCreatePublicKey(), publicKey)
    }

    /// Two peers must agree on the session key, or every frame fails to open.
    func testSharedSecretIsSymmetric() {
        let a = KeychainManager(service: "com.bridg.tests.a.\(UUID().uuidString)")
        let b = KeychainManager(service: "com.bridg.tests.b.\(UUID().uuidString)")
        defer { a.resetIdentity(); b.resetIdentity() }

        let aPub = a.getOrCreatePublicKey()
        let bPub = b.getOrCreatePublicKey()

        // Both ends of one connection see the same pair of salts, in the same
        // order — the phone's first, because the phone always dials in.
        let info = SharedSecretKDF.connectionInfo(
            initiatorSalt: SharedSecretKDF.randomSalt(),
            responderSalt: SharedSecretKDF.randomSalt()
        )

        XCTAssertEqual(a.deriveSharedSecret(peerPublicKeyData: bPub, info: info),
                       b.deriveSharedSecret(peerPublicKeyData: aPub, info: info))
    }

    func testPairingManagerQRContentRoundTrips() {
        let manager = PairingManager()
        let token = manager.generatePairingToken()
        let content = manager.createQrContent(token: token)

        XCTAssertTrue(content.hasPrefix("bridg://pair/"))

        // The phone parses this exact string; if it stops round-tripping, pairing dies.
        let parsed = manager.parseQrContent(content)
        XCTAssertEqual(parsed?.token, token)
        XCTAssertEqual(parsed?.publicKey.count, 32)
    }

    // MARK: - Framing

    func testFrameBufferReassemblesSplitAndBatchedFrames() {
        let a = Data("first".utf8)
        let b = Data("second".utf8)
        let stream = FrameCodec.encode(a) + FrameCodec.encode(b)

        // Feed the stream one byte at a time — the worst case TCP can hand us.
        let buffer = FrameBuffer()
        var recovered: [Data] = []
        for byte in stream {
            buffer.append(Data([byte]))
            while let frame = ((try? buffer.next()) ?? nil) { recovered.append(frame) }
        }
        XCTAssertEqual(recovered, [a, b])

        // And the opposite extreme: both frames arriving in a single read.
        let batched = FrameBuffer()
        batched.append(stream)
        XCTAssertEqual(try batched.next(), a)
        XCTAssertEqual(try batched.next(), b)
        XCTAssertNil(try batched.next())
    }

    func testFrameBufferRejectsOversizedLength() {
        var bogus = Data([0xFF, 0xFF, 0xFF, 0xFF])
        bogus.append(Data(count: 8))
        let buffer = FrameBuffer()
        buffer.append(bogus)
        XCTAssertThrowsError(try buffer.next())
    }

    // MARK: - Cross-platform crypto

    private static let ikmVector = Data((0..<32).map { UInt8($0) })
    private static let initiatorSaltVector = Data((0xa0...0xaf).map { UInt8($0) })
    private static let responderSaltVector = Data((0xb0...0xbf).map { UInt8($0) })

    /// The Android side derives its session key with a hand-written HKDF-SHA256.
    /// These vectors were computed independently (Python hmac/hashlib) so that a
    /// drift in either implementation fails here rather than as a silent
    /// "decryption failed" at runtime.
    func testHKDFMatchesTheVectorAndroidDerives() {
        let derived = SharedSecretKDF.derive(
            rawSharedSecret: Self.ikmVector,
            info: SharedSecretKDF.connectionInfo(
                initiatorSalt: Self.initiatorSaltVector,
                responderSalt: Self.responderSaltVector
            )
        )

        XCTAssertEqual(
            derived.map { String(format: "%02x", $0) }.joined(),
            "9bcc4b236bef52d412a912466352d92779a5e878648cf7f60f9c12f4c26e6b63"
        )
    }

    /// The phone is always the initiator. Concatenating the two salts the other
    /// way round gives a different key, so both sides must agree on the order —
    /// and disagreeing is invisible until every frame fails to open.
    func testSaltOrderIsPartOfTheContract() {
        let forward = SharedSecretKDF.derive(
            rawSharedSecret: Self.ikmVector,
            info: SharedSecretKDF.connectionInfo(
                initiatorSalt: Self.initiatorSaltVector, responderSalt: Self.responderSaltVector)
        )
        let reversed = SharedSecretKDF.derive(
            rawSharedSecret: Self.ikmVector,
            info: SharedSecretKDF.connectionInfo(
                initiatorSalt: Self.responderSaltVector, responderSalt: Self.initiatorSaltVector)
        )
        XCTAssertNotEqual(forward, reversed)
    }

    /// The reason the salts exist at all.
    ///
    /// Both identity keys are long-term, so the raw ECDH secret is the same on
    /// every connection, and the nonce counter restarts at zero each time. If
    /// the session key did not change too, connection #2 would encrypt with the
    /// exact (key, nonce) pairs connection #1 already used — which leaks the XOR
    /// of the two plaintexts and the Poly1305 authentication key.
    func testSessionKeyDiffersPerConnectionForOneIdentityPair() {
        let sameEcdhSecretEveryTime = Self.ikmVector

        var keys = Set<Data>()
        for _ in 0..<50 {
            // What each side actually does at the start of a connection.
            let info = SharedSecretKDF.connectionInfo(
                initiatorSalt: SharedSecretKDF.randomSalt(),
                responderSalt: SharedSecretKDF.randomSalt()
            )
            keys.insert(SharedSecretKDF.derive(rawSharedSecret: sameEcdhSecretEveryTime, info: info))
        }
        XCTAssertEqual(keys.count, 50)
        XCTAssertEqual(SharedSecretKDF.randomSalt().count, SharedSecretKDF.saltLength)
    }

    /// CryptoKit's ChaChaPoly must be byte-identical to libsodium's
    /// crypto_aead_chacha20poly1305_ietf_*, including our nonce layout.
    func testChaChaPolyWireFormatMatchesLibsodium() throws {
        let key = Data([
            0x7e, 0x6f, 0x4d, 0xdb, 0x23, 0x31, 0x99, 0x02, 0xfb, 0x5c, 0x5f, 0x3a, 0x72, 0xec, 0x81, 0xac,
            0x8a, 0x9d, 0xdf, 0x48, 0x47, 0x46, 0x3d, 0x09, 0x3f, 0xf4, 0x4f, 0xa7, 0x2d, 0xa1, 0xb3, 0xe3
        ])
        // Direction 0x01 (phone→Mac), counter 1 — what Android puts on its first frame.
        let nonce = Data([0x01, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x01])
        let expectedSealed = Data([
            0x52, 0x17, 0x4d, 0x74, 0x2b, 0x47, 0x91, 0x04, 0x77, 0xb5, 0x9c, 0x41,
            0xbb, 0x84, 0xc0, 0xb6, 0x41, 0x24, 0x29, 0x38, 0x38
        ])

        let box = try ChaChaPoly.seal(
            Data("bridg".utf8),
            using: SymmetricKey(data: key),
            nonce: try ChaChaPoly.Nonce(data: nonce)
        )
        XCTAssertEqual(box.ciphertext + box.tag, expectedSealed)

        // And the transport must open a frame framed exactly the way Android sends it.
        let transport = EncryptedTransport(sharedKey: key, sending: .macToPhone)
        XCTAssertEqual(transport.decrypt(nonce + expectedSealed), Data("bridg".utf8))
    }

    func testEncryptedTransportRoundTripAcrossDirections() {
        let key = Data(repeating: 0x42, count: 32)
        let mac = EncryptedTransport(sharedKey: key, sending: .macToPhone)
        let phone = EncryptedTransport(sharedKey: key, sending: .phoneToMac)

        let message = Data("hello from the mac".utf8)
        let sealed = mac.encrypt(message)
        XCTAssertEqual(phone.decrypt(sealed!), message)

        // Both sides share one key, so their nonce spaces must not overlap.
        let macNonce = mac.encrypt(message)!.prefix(12)
        let phoneNonce = phone.encrypt(message)!.prefix(12)
        XCTAssertNotEqual(macNonce, phoneNonce)
    }

    /// A captured frame replayed at the same receiver must not open a second
    /// time, and neither must one of our own frames reflected back at us —
    /// both sides share a key, so the tag alone cannot tell them apart.
    func testEncryptedTransportRejectsReplayAndReflection() {
        let key = Data(repeating: 0x42, count: 32)
        let mac = EncryptedTransport(sharedKey: key, sending: .macToPhone)
        let phone = EncryptedTransport(sharedKey: key, sending: .phoneToMac)

        let first = mac.encrypt(Data("one".utf8))!
        let second = mac.encrypt(Data("two".utf8))!

        XCTAssertEqual(phone.decrypt(first), Data("one".utf8))
        XCTAssertEqual(phone.decrypt(second), Data("two".utf8))

        // Replay of a frame already accepted.
        XCTAssertNil(phone.decrypt(first))
        XCTAssertNil(phone.decrypt(second))

        // Reflection: the Mac's own frame handed back to the Mac.
        XCTAssertNil(mac.decrypt(mac.encrypt(Data("three".utf8))!))

        // A genuine later frame still gets through.
        XCTAssertEqual(phone.decrypt(mac.encrypt(Data("four".utf8))!), Data("four".utf8))
    }

    /// A forged frame must not be able to poison the replay counter. Advancing
    /// it before checking the tag would let anyone who can write to the socket
    /// push one junk frame with a huge counter and wedge every real frame after.
    func testForgedFrameDoesNotAdvanceTheReplayCounter() {
        let key = Data(repeating: 0x42, count: 32)
        let mac = EncryptedTransport(sharedKey: key, sending: .macToPhone)
        let phone = EncryptedTransport(sharedKey: key, sending: .phoneToMac)

        // Well-formed nonce, direction correct, counter enormous — garbage body.
        var forged = Data([0x00, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        forged.append(Data(repeating: 0xAB, count: 32))
        XCTAssertNil(phone.decrypt(forged))

        // The real next frame, counter 1, must still be accepted.
        XCTAssertEqual(phone.decrypt(mac.encrypt(Data("real".utf8))!), Data("real".utf8))
    }

    // MARK: - Remote actions

    /// The phone refuses anything but http(s) — see RemoteActionHandler
    /// .isAllowedUrl, whose own test pins these same cases. If the two drift,
    /// the Mac sends links the phone silently throws away.
    func testOnlyHttpURLsAreSentToThePhone() {
        XCTAssertTrue(AppState.isSendableURL("https://example.com"))
        XCTAssertTrue(AppState.isSendableURL("http://example.com/a?b=c#d"))
        XCTAssertTrue(AppState.isSendableURL("  https://example.com  "))
        XCTAssertTrue(AppState.isSendableURL("HTTPS://example.com"))

        XCTAssertFalse(AppState.isSendableURL("intent://scan/#Intent;scheme=zxing;end"))
        XCTAssertFalse(AppState.isSendableURL("file:///etc/passwd"))
        XCTAssertFalse(AppState.isSendableURL("javascript:alert(1)"))
        XCTAssertFalse(AppState.isSendableURL("tel:+15551234"))
        XCTAssertFalse(AppState.isSendableURL("example.com"))
        XCTAssertFalse(AppState.isSendableURL("https://"))
        XCTAssertFalse(AppState.isSendableURL(""))
        XCTAssertFalse(AppState.isSendableURL("not a url at all"))
    }

    /// The menu bar picks its glyph from the percentage; an off-by-one in the
    /// ranges shows a full battery at 12%.
    func testBatterySymbolTracksTheLevel() {
        func symbol(_ percent: Int, charging: Bool = false) -> String {
            BatteryState(percent: percent, isCharging: charging, isLow: false).symbolName
        }

        XCTAssertEqual(symbol(0), "battery.0")
        XCTAssertEqual(symbol(12), "battery.0")
        XCTAssertEqual(symbol(13), "battery.25")
        XCTAssertEqual(symbol(50), "battery.50")
        XCTAssertEqual(symbol(75), "battery.75")
        XCTAssertEqual(symbol(100), "battery.100")

        // Charging wins over the level: that is the state you want to see.
        XCTAssertEqual(symbol(5, charging: true), "battery.100.bolt")
    }

    /// Deinterleaving is the one piece of real logic in the mirror's audio
    /// path: get the channel order or the endianness wrong and playback is
    /// swapped or noise, with nothing to point at.
    func testAudioPlayerDeinterleavesLittleEndianPCM() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        // Two stereo frames: L=+16384, R=-16384 then L=0, R=32767 (max).
        let samples: [Int16] = [16384, -16384, 0, 32767]
        var pcm = Data()
        for sample in samples {
            let bits = UInt16(bitPattern: sample)
            pcm.append(UInt8(bits & 0xFF))
            pcm.append(UInt8(bits >> 8))
        }

        let buffer = AudioPlayer().makeBuffer(from: pcm, format: format)
        XCTAssertNotNil(buffer)
        XCTAssertEqual(buffer?.frameLength, 2)

        let channels = buffer!.floatChannelData!
        XCTAssertEqual(channels[0][0], 0.5, accuracy: 0.0001)
        XCTAssertEqual(channels[1][0], -0.5, accuracy: 0.0001)
        XCTAssertEqual(channels[0][1], 0.0, accuracy: 0.0001)
        XCTAssertEqual(channels[1][1], 1.0, accuracy: 0.0001)
    }
}
