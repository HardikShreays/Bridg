import Foundation
import CryptoKit

/// ChaCha20-Poly1305 (IETF) AEAD for the transport layer.
///
/// Must stay byte-compatible with the Android side, which uses libsodium's
/// `crypto_aead_chacha20poly1305_ietf_*`. CryptoKit's `ChaChaPoly` is that same
/// construction: 32-byte key, 12-byte nonce, 16-byte tag.
final class EncryptedTransport {
    /// Both directions share one key, so both sides must not draw from the same
    /// nonce space — a repeated (key, nonce) pair breaks ChaCha20-Poly1305 badly.
    /// The first nonce byte tags the direction and keeps the spaces disjoint.
    enum Direction: UInt8 {
        case macToPhone = 0x00
        case phoneToMac = 0x01
    }

    private let symmetricKey: SymmetricKey
    private let sendDirection: Direction
    private var nonceCounter: UInt64 = 0
    private let lock = NSLock()

    /// Highest counter accepted from the peer, so a replayed frame is refused.
    private var lastPeerCounter: UInt64 = 0

    /// The peer sends on the direction we do not.
    private var receiveDirection: Direction { sendDirection == .macToPhone ? .phoneToMac : .macToPhone }

    init(sharedKey: Data, sending: Direction = .macToPhone) {
        self.symmetricKey = SymmetricKey(data: sharedKey)
        self.sendDirection = sending
    }

    /// Returns nonce (12 bytes) + ciphertext + 16-byte Poly1305 tag.
    func encrypt(_ plaintext: Data) -> Data? {
        guard let sealed = try? ChaChaPoly.seal(plaintext, using: symmetricKey, nonce: nextNonce()) else {
            return nil
        }
        var result = Data(sealed.nonce)
        result.append(sealed.ciphertext)
        result.append(sealed.tag)
        return result
    }

    /// Input must be: nonce (12) + ciphertext + tag (16).
    func decrypt(_ encrypted: Data) -> Data? {
        let nonceSize = 12
        let tagSize = 16
        guard encrypted.count >= nonceSize + tagSize,
              let nonce = try? ChaChaPoly.Nonce(data: encrypted.prefix(nonceSize)) else { return nil }
        guard let counter = checkNonce(encrypted.prefix(nonceSize)) else { return nil }

        let body = encrypted.dropFirst(nonceSize)
        guard let box = try? ChaChaPoly.SealedBox(
            nonce: nonce,
            ciphertext: body.prefix(body.count - tagSize),
            tag: body.suffix(tagSize)
        ) else { return nil }

        guard let plaintext = try? ChaChaPoly.open(box, using: symmetricKey) else {
            print("Decryption failed — wrong key or tampered frame")
            return nil
        }

        // Only now, with the tag verified. Advancing on an unauthenticated
        // nonce would let anyone who can write to the socket send one forged
        // frame with a huge counter and wedge every real frame after it.
        commit(counter: counter)
        return plaintext
    }

    /// Reject anything the peer cannot legitimately have just sent.
    ///
    /// Both directions share one key, so a frame of ours reflected back at us
    /// decrypts perfectly — the direction byte is what tells the two apart. And
    /// because the transport rides on ordered TCP, a counter that does not
    /// strictly increase is a replayed or reordered frame, never a normal one.
    ///
    /// This is defence in depth: the per-connection salt already means a frame
    /// captured from an earlier session cannot open under this session's key.
    private func checkNonce<C: Collection>(_ nonce: C) -> UInt64? where C.Element == UInt8 {
        let bytes = Array(nonce)
        guard bytes.count == 12 else { return nil }

        guard bytes[0] == receiveDirection.rawValue else {
            print("Frame carries our own direction byte — reflected")
            return nil
        }

        let counter = bytes[4..<12].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        lock.lock()
        defer { lock.unlock() }
        guard counter > lastPeerCounter else {
            print("Nonce counter did not advance (\(counter) <= \(lastPeerCounter)) — replayed")
            return nil
        }
        return counter
    }

    private func commit(counter: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        lastPeerCounter = max(lastPeerCounter, counter)
    }

    private func nextNonce() -> ChaChaPoly.Nonce {
        lock.lock()
        defer { lock.unlock() }

        nonceCounter += 1
        var bytes = [UInt8](repeating: 0, count: 12)
        bytes[0] = sendDirection.rawValue
        // Bytes 4..11 hold the big-endian counter; 1..3 stay zero.
        let counter = nonceCounter.bigEndian
        withUnsafeBytes(of: counter) { ptr in
            for i in 0..<8 { bytes[4 + i] = ptr[i] }
        }
        return try! ChaChaPoly.Nonce(data: Data(bytes))
    }
}
