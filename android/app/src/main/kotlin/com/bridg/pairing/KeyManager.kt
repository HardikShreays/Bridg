package com.bridg.pairing

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import com.goterl.lazysodium.LazySodiumAndroid
import com.goterl.lazysodium.SodiumAndroid
import java.security.MessageDigest
import java.util.Base64

/**
 * Manages X25519 key pairs for device pairing.
 * Keys are persisted in EncryptedSharedPreferences (AES-256-GCM).
 */
class KeyManager(context: Context) {

    private val sodium = LazySodiumAndroid(SodiumAndroid())

    private val masterKey = MasterKey.Builder(context)
        .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
        .build()

    private val prefs: SharedPreferences = EncryptedSharedPreferences.create(
        context,
        PREFS_FILE,
        masterKey,
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
    )

    /**
     * Generate a new X25519 keypair and persist it.
     * Returns the public key bytes (32 bytes).
     */
    fun generateKeyPair(): ByteArray {
        val publicKey = ByteArray(32)
        val secretKey = ByteArray(32)
        sodium.cryptoKxKeypair(publicKey, secretKey)

        prefs.edit()
            .putString(KEY_PRIVATE, Base64.getEncoder().encodeToString(secretKey))
            .putString(KEY_PUBLIC, Base64.getEncoder().encodeToString(publicKey))
            .apply()
        return publicKey
    }

    fun getOrCreatePublicKey(): ByteArray {
        val stored = prefs.getString(KEY_PUBLIC, null)
        if (stored != null) return Base64.getDecoder().decode(stored)
        return generateKeyPair()
    }

    fun getPrivateKey(): ByteArray {
        val stored = prefs.getString(KEY_PRIVATE, null)
            ?: throw IllegalStateException("No keypair generated")
        return Base64.getDecoder().decode(stored)
    }

    /** SHA-256 of our own public key — what PairResume sends so the Mac can find us. */
    fun getPublicKeyHash(): ByteArray =
        MessageDigest.getInstance("SHA-256").digest(getOrCreatePublicKey())

    /**
     * Derive the session key from our private key and the peer's public key.
     *
     * The raw X25519 output is NOT the session key. The Mac runs it through
     * HKDF-SHA256 (CryptoKit's `hkdfDerivedSymmetricKey`) with salt
     * "bridg-session"; returning the bare scalarmult result here gave the two
     * sides different keys, so every encrypted frame failed to open.
     */
    fun deriveSharedSecret(peerPublicKey: ByteArray): ByteArray {
        val sharedSecret = ByteArray(32)
        sodium.cryptoScalarMult(sharedSecret, getPrivateKey(), peerPublicKey)
        return SessionKdf.deriveSessionKey(sharedSecret)
    }

    fun savePairedDevice(deviceId: String, publicKey: ByteArray, name: String) {
        val editor = prefs.edit()
        val ids = getPairedDeviceIds().toMutableSet()
        ids.add(deviceId)

        editor.putString("$DEVICE_PREFIX$deviceId$SUFFIX_NAME", name)
        editor.putString("$DEVICE_PREFIX$deviceId$SUFFIX_KEY", Base64.getEncoder().encodeToString(publicKey))
        // The old code wrote a count but never the "device_index_N" keys it read
        // back, so getPairedDevices() always returned empty and the phone never
        // knew it was paired.
        editor.putStringSet(DEVICE_IDS, ids)
        editor.apply()
    }

    private fun getPairedDeviceIds(): Set<String> = prefs.getStringSet(DEVICE_IDS, emptySet()) ?: emptySet()

    fun getPairedDevices(): Map<String, PairedDevice> {
        val devices = mutableMapOf<String, PairedDevice>()
        for (id in getPairedDeviceIds()) {
            val key = prefs.getString("$DEVICE_PREFIX$id$SUFFIX_KEY", null) ?: continue
            val name = prefs.getString("$DEVICE_PREFIX$id$SUFFIX_NAME", "") ?: ""
            devices[id] = PairedDevice(publicKey = key, name = name)
        }
        return devices
    }

    /** Public key of the Mac we are paired with, or null. */
    fun getPairedPeerPublicKey(): ByteArray? =
        getPairedDevices().values.firstOrNull()?.let { Base64.getDecoder().decode(it.publicKey) }

    fun removePairedDevice(deviceId: String) {
        val ids = getPairedDeviceIds().toMutableSet()
        ids.remove(deviceId)
        prefs.edit()
            .remove("$DEVICE_PREFIX$deviceId$SUFFIX_NAME")
            .remove("$DEVICE_PREFIX$deviceId$SUFFIX_KEY")
            .putStringSet(DEVICE_IDS, ids)
            .apply()
    }

    /**
     * Last known address of the Mac. Discovery cannot find it on networks where
     * mDNS does not cross subnets, so we fall back to dialling it directly.
     */
    fun getLastHost(): String? = prefs.getString(KEY_LAST_HOST, null)?.ifEmpty { null }

    fun setLastHost(host: String) {
        prefs.edit().putString(KEY_LAST_HOST, host).apply()
    }

    fun getDeviceName(): String =
        prefs.getString(KEY_DEVICE_NAME, null) ?: "${android.os.Build.MANUFACTURER} ${android.os.Build.MODEL}"

    fun setDeviceName(name: String) {
        prefs.edit().putString(KEY_DEVICE_NAME, name).apply()
    }

    data class PairedDevice(val publicKey: String, val name: String)

    companion object {
        private const val PREFS_FILE = "bridg_keys"
        private const val KEY_PRIVATE = "private_key"
        private const val KEY_PUBLIC = "public_key"
        private const val KEY_DEVICE_NAME = "device_name"
        private const val KEY_LAST_HOST = "last_host"
        private const val DEVICE_PREFIX = "device_"
        private const val SUFFIX_NAME = "_name"
        private const val SUFFIX_KEY = "_key"
        private const val DEVICE_IDS = "device_ids"
    }
}
