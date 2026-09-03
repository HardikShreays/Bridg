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
        return plaintext
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
