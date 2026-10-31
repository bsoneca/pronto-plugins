package __APPLICATION_ID__

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import android.util.Base64
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricManager.Authenticators.BIOMETRIC_STRONG
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import kotlinx.coroutines.suspendCancellableCoroutine
import java.security.GeneralSecurityException
import java.security.KeyStore
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

// Why the vault stayed shut, in words the screen shows as they are; `lost`
// when its key is gone and only erasing it opens the app again, `canceled`
// when the person dismissed the prompt and needs telling nothing.
class Locked(message: String, val lost: Boolean = false, val canceled: Boolean = false) : Exception(message)

// The device tables' key. A random AES-256 data key seals every row; the
// Keystore holds only the key that wraps it, which signs nothing, never leaves
// the secure hardware and answers one strong-biometric prompt per use. One
// unlock therefore opens the whole vault, and the data key lives only in the
// unlocked process's memory. Enrolling a new fingerprint or face destroys the
// wrapping key, and with it the vault: no second factor can open it.
object Seal {
    private const val ALIAS = "pronto.device.wrap"
    private const val PREFS = "pronto.device"
    private const val TAG_BITS = 128

    // Asks for a strong biometric and returns the data key: wrapping a new one
    // the first time, unwrapping the stored one after.
    suspend fun unlock(activity: FragmentActivity, title: String): SecretKey {
        when (BiometricManager.from(activity).canAuthenticate(BIOMETRIC_STRONG)) {
            BiometricManager.BIOMETRIC_SUCCESS -> {}
            BiometricManager.BIOMETRIC_ERROR_NONE_ENROLLED -> throw Locked("Enroll a fingerprint or face in Settings first.")
            else -> throw Locked("This phone has no strong biometric to unlock with.")
        }
        val prefs = activity.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val wrapped = prefs.getString("wrapped", null)?.let { Base64.decode(it, Base64.NO_WRAP) }
        val iv = prefs.getString("iv", null)?.let { Base64.decode(it, Base64.NO_WRAP) }
        // Rows with no key to open them are a lost vault, never a fresh one.
        if ((wrapped == null || iv == null) && activity.getDatabasePath(RowStore.FILE).exists()) {
            throw Locked("The vault's key is missing from this phone.", lost = true)
        }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        try {
            if (wrapped == null || iv == null) cipher.init(Cipher.ENCRYPT_MODE, wrappingKey(fresh = true))
            else cipher.init(Cipher.DECRYPT_MODE, wrappingKey(fresh = false), GCMParameterSpec(TAG_BITS, iv))
        } catch (e: KeyPermanentlyInvalidatedException) {
            throw Locked("The biometrics on this phone changed, so the vault's key is gone.", lost = true)
        }
        val authed = prompt(activity, title, cipher)
        // Some keystores report a dead key here rather than at init.
        val data = try {
            if (wrapped != null) authed.doFinal(wrapped)
            else ByteArray(32).also(SecureRandom()::nextBytes).also { data ->
                val sealed = authed.doFinal(data)
                // Written before any row is: a key lost to a crash here would
                // leave rows nothing can open.
                check(prefs.edit()
                    .putString("wrapped", Base64.encodeToString(sealed, Base64.NO_WRAP))
                    .putString("iv", Base64.encodeToString(authed.iv, Base64.NO_WRAP))
                    .commit())
            }
        } catch (e: GeneralSecurityException) {
            throw Locked("The vault's key no longer opens it.", lost = true)
        }
        return SecretKeySpec(data, "AES").also { data.fill(0) }
    }

    // Forgets the vault for good: its rows and both keys.
    fun erase(context: Context) {
        context.deleteDatabase(RowStore.FILE)
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().clear().apply()
        KeyStore.getInstance("AndroidKeyStore").apply { load(null) }.deleteEntry(ALIAS)
    }

    private fun wrappingKey(fresh: Boolean): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        if (!fresh) return ks.getKey(ALIAS, null) as? SecretKey ?: throw Locked("The vault's key is missing from this phone.", lost = true)
        val spec = KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .setUserAuthenticationRequired(true)
            .setInvalidatedByBiometricEnrollment(true)
            .apply {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) setUserAuthenticationParameters(0, KeyProperties.AUTH_BIOMETRIC_STRONG)
                else @Suppress("DEPRECATION") setUserAuthenticationValidityDurationSeconds(-1)
            }
            .build()
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run { init(spec); generateKey() }
    }

    private suspend fun prompt(activity: FragmentActivity, title: String, cipher: Cipher): Cipher =
        suspendCancellableCoroutine { cont ->
            val prompt = BiometricPrompt(activity, ContextCompat.getMainExecutor(activity), object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                    cont.resume(requireNotNull(result.cryptoObject?.cipher))
                }

                override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                    val canceled = errorCode == BiometricPrompt.ERROR_USER_CANCELED ||
                        errorCode == BiometricPrompt.ERROR_NEGATIVE_BUTTON || errorCode == BiometricPrompt.ERROR_CANCELED
                    cont.resumeWithException(Locked(errString.toString(), canceled = canceled))
                }
            })
            val info = BiometricPrompt.PromptInfo.Builder()
                .setTitle(title)
                .setNegativeButtonText(activity.getString(android.R.string.cancel))
                .setAllowedAuthenticators(BIOMETRIC_STRONG)
                .build()
            prompt.authenticate(info, BiometricPrompt.CryptoObject(cipher))
            cont.invokeOnCancellation { prompt.cancelAuthentication() }
        }
}

// The `device` tables on disk: one row per (table, id), each body AES-GCM
// sealed under the data key with the pair as associated data, so a body moved
// to another row fails to open rather than reading as that row.
class RowStore(context: Context, private val key: SecretKey) : AutoCloseable {
    companion object {
        const val FILE = "device.db"
        private const val TAG_BITS = 128
    }

    private val db = object : SQLiteOpenHelper(context, FILE, null, 1) {
        override fun onCreate(db: SQLiteDatabase) {
            db.execSQL("CREATE TABLE row (entity TEXT NOT NULL, id TEXT NOT NULL, iv BLOB NOT NULL, body BLOB NOT NULL, PRIMARY KEY (entity, id))")
        }

        override fun onUpgrade(db: SQLiteDatabase, old: Int, new: Int) = error("no schema after version 1")
    }.writableDatabase

    fun load(entity: String): List<String> =
        db.query("row", arrayOf("id", "iv", "body"), "entity = ?", arrayOf(entity), null, null, null).use { c ->
            buildList {
                while (c.moveToNext()) {
                    val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                    try {
                        cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(TAG_BITS, c.getBlob(1)))
                        cipher.updateAAD("$entity/${c.getString(0)}".toByteArray())
                        add(String(cipher.doFinal(c.getBlob(2))))
                    } catch (e: GeneralSecurityException) {
                        throw Locked("A row of the vault does not open with its key.", lost = true)
                    }
                }
            }
        }

    fun put(entity: String, id: String, json: String) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key)
        cipher.updateAAD("$entity/$id".toByteArray())
        val body = cipher.doFinal(json.toByteArray())
        db.insertWithOnConflict("row", null, ContentValues().apply {
            put("entity", entity); put("id", id); put("iv", cipher.iv); put("body", body)
        }, SQLiteDatabase.CONFLICT_REPLACE)
    }

    fun drop(entity: String, id: String) {
        db.delete("row", "entity = ? AND id = ?", arrayOf(entity, id))
    }

    override fun close() = db.close()
}
