package com.jxcode.android.data

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * API keys, encrypted with a key held in the Android keystore.
 *
 * This is the Android counterpart of the macOS build's Keychain storage. Keys
 * are never written to `providers.json`; only the alias is, so a provider list
 * can be exported or logged without leaking credentials.
 *
 * If the keystore is unavailable (some low-end devices, and Work profiles in
 * particular), the store falls back to plain preferences and reports it, so
 * the doctor can surface the real state instead of implying encryption that
 * is not happening.
 */
object SecretStore {

    private const val KEY_ALIAS = "jxcode_provider_keys"
    private const val PREFS = "jxcode_secrets"
    private const val FALLBACK_FLAG = "using_fallback"
    private const val IV_BYTES = 12
    private const val TAG_BITS = 128

    @Volatile
    var usingFallback: Boolean = false
        private set

    fun put(context: Context, alias: String, value: String) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val key = key() ?: run {
            usingFallback = true
            prefs.edit().putString(alias, value).putBoolean(FALLBACK_FLAG, true).apply()
            return
        }
        try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, key)
            val iv = cipher.iv
            val ciphertext = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
            val blob = Base64.encodeToString(iv + ciphertext, Base64.NO_WRAP)
            prefs.edit().putString(alias, blob).apply()
        } catch (e: Exception) {
            usingFallback = true
            prefs.edit().putString(alias, value).putBoolean(FALLBACK_FLAG, true).apply()
        }
    }

    fun get(context: Context, alias: String): String? {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val stored = prefs.getString(alias, null) ?: return null
        usingFallback = prefs.getBoolean(FALLBACK_FLAG, false)
        if (usingFallback) return stored

        val key = key() ?: return stored
        return try {
            val blob = Base64.decode(stored, Base64.NO_WRAP)
            val iv = blob.copyOfRange(0, IV_BYTES)
            val ciphertext = blob.copyOfRange(IV_BYTES, blob.size)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(TAG_BITS, iv))
            String(cipher.doFinal(ciphertext), Charsets.UTF_8)
        } catch (_: Exception) {
            null
        }
    }

    fun delete(context: Context, alias: String) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().remove(alias).apply()
    }

    private fun key(): SecretKey? = try {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        store.getKey(KEY_ALIAS, null) as? SecretKey ?: generate()
    } catch (_: Exception) {
        null
    }

    private fun generate(): SecretKey? = try {
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build()
        )
        generator.generateKey()
    } catch (_: Exception) {
        null
    }
}
