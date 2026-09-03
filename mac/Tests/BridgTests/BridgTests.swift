import XCTest
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

        XCTAssertEqual(a.deriveSharedSecret(peerPublicKeyData: bPub),
                       b.deriveSharedSecret(peerPublicKeyData: aPub))
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

    /// The Android side derives its session key with a hand-written HKDF-SHA256.
    /// These vectors were computed independently (Python hmac/hashlib) so that a
    /// drift in either implementation fails here rather than as a silent
    /// "decryption failed" at runtime.
    func testHKDFMatchesTheVectorAndroidDerives() {
        let ikm = Data((0..<32).map { UInt8($0) })
        let derived = SharedSecretKDF.derive(rawSharedSecret: ikm)

        XCTAssertEqual(
            derived.map { String(format: "%02x", $0) }.joined(),
            "7e6f4ddb23319902fb5c5f3a72ec81ac8a9ddf4847463d093ff44fa72da1b3e3"
        )
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
}
