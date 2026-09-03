import Foundation
import Security
import CryptoKit

/// Manages X25519 key pairs and paired device identities in the macOS Keychain.
class KeychainManager {
    private let service: String

    /// The service name is injectable so tests can use a throwaway keychain
    /// entry. The test suite used to run against the real "com.bridg" item and
    /// regenerate it, which silently destroyed the running app's identity and
    /// unpaired every device.
    init(service: String = "com.bridg") {
        self.service = service
    }

    // MARK: - Key Pair Management

    /// Generate a new X25519 keypair and persist the private key in Keychain.
    ///
    /// This REPLACES any existing identity, which invalidates every paired
    /// device, so it is only safe to call when there is genuinely no key or the
    /// user has asked to reset. Use `getOrCreatePublicKey()` everywhere else.
    func generateKeyPair() -> Data? {
        // Generate X25519 private key using CryptoKit
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let publicKeyData = privateKey.publicKey.rawRepresentation

        // Store private key in Keychain as a generic password (raw bytes)
        let privateRaw = privateKey.rawRepresentation

        // Delete any existing key first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "privateKey",
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "privateKey",
            kSecValueData as String: privateRaw,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            print("Failed to store private key: \(status)")
            return nil
        }

        return publicKeyData
    }

    /// Get the stored public key, generating a keypair only if none exists yet.
    ///
    /// Any other Keychain failure must NOT fall through to generating a new
    /// identity: doing so silently invalidates every paired device. Only a
    /// genuine errSecItemNotFound means "first run".
    func getOrCreatePublicKey() -> Data {
        if let existing = getPublicKey() {
            return existing
        }

        let status = privateKeyStatus()
        guard status == errSecItemNotFound else {
            print("Keychain unavailable (OSStatus \(status)) — refusing to replace the device identity")
            return Data()
        }

        return generateKeyPair() ?? Data()
    }

    /// Raw lookup status, so callers can tell "no key yet" from "cannot read it".
    private func privateKeyStatus() -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "privateKey",
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil)
    }

    /// Delete the identity and every paired device. Used by "Unpair".
    func resetIdentity() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "privateKey",
        ] as CFDictionary)
        UserDefaults.standard.removeObject(forKey: "paired_devices")
    }

    /// Get the stored public key by re-deriving from the stored private key.
    func getPublicKey() -> Data? {
        guard let privateKeyData = getPrivateKeyData() else { return nil }
        guard let privateKey = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKeyData) else {
            return nil
        }
        return privateKey.publicKey.rawRepresentation
    }

    /// Get the raw private key data from Keychain.
    func getPrivateKeyData() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "privateKey",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return nil
        }

        return data
    }

    /// Derive a shared secret from our private key and a peer's public key
    /// using X25519 ECDH via CryptoKit.
    func deriveSharedSecret(peerPublicKeyData: Data) -> Data? {
        guard let privateKeyData = getPrivateKeyData() else {
            print("No private key found")
            return nil
        }

        guard let privateKey = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKeyData) else {
            print("Failed to restore private key")
            return nil
        }

        guard let peerPublicKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKeyData) else {
            print("Failed to import peer public key")
            return nil
        }

        do {
            let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: peerPublicKey)
            let raw = sharedSecret.withUnsafeBytes { Data($0) }
            return SharedSecretKDF.derive(rawSharedSecret: raw)
        } catch {
            print("Key exchange failed: \(error)")
            return nil
        }
    }

    // MARK: - Paired Device Storage

    /// Store a paired device's public key and name.
    func savePairedDevice(name: String, publicKey: Data) {
        let defaults = UserDefaults.standard
        var devices = getPairedDevices()
        let deviceId = UUID().uuidString

        devices.append(PairedDeviceInfo(id: deviceId, name: name, publicKey: publicKey))
        if let data = try? JSONEncoder().encode(devices) {
            defaults.set(data, forKey: "paired_devices")
        }
    }

    /// Get all paired devices.
    func getPairedDevices() -> [PairedDeviceInfo] {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: "paired_devices"),
              let devices = try? JSONDecoder().decode([PairedDeviceInfo].self, from: data) else {
            return []
        }
        return devices
    }

    /// Get the first paired device's public key (for simple 1:1 pairing).
    func getPairedDevicePublicKey() -> Data? {
        return getPairedDevices().first?.publicKey
    }

    /// Remove a paired device.
    func removePairedDevice(id: String) {
        var devices = getPairedDevices()
        devices.removeAll { $0.id == id }
        if let data = try? JSONEncoder().encode(devices) {
            UserDefaults.standard.set(data, forKey: "paired_devices")
        }
    }

    struct PairedDeviceInfo: Codable {
        let id: String
        let name: String
        let publicKey: Data
    }
}


/// Turns a raw X25519 shared secret into the 32-byte session key.
///
/// Split out of KeychainManager so it can be pinned against the Android side,
/// which reimplements HKDF by hand — the two derivations disagreeing is
/// invisible until every encrypted frame fails to open.
enum SharedSecretKDF {
    /// Must stay in lockstep with KeyManager.deriveSharedSecret on Android.
    static let salt = Data("bridg-session".utf8)

    static func derive(rawSharedSecret: Data) -> Data {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: rawSharedSecret),
            salt: salt,
            info: Data(),
            outputByteCount: 32
        )
        return key.withUnsafeBytes { Data($0) }
    }
}
