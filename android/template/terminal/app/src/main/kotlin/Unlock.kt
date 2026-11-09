package __APPLICATION_ID__

import android.content.Context
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

// Why the app stays shut, in words shown as they are: `lost` when its key is gone and its stored
// data can no longer be opened, `canceled` when the person dismissed the prompt.
class Locked(message: String, val lost: Boolean = false, val canceled: Boolean = false) : Exception(message)

// The terminal's unlock (android.json's "unlock": "biometric"). The sealed storage's key is then a
// random AES-256 data key, wrapped by an AndroidKeyStore key that answers one strong-biometric
// prompt per use and is destroyed when a new fingerprint or face is enrolled. One prompt per
// process opens it, and the data key lives only in that process's memory. Without the option the
// storage keeps its own key (SealedStore), and nobody is prompted.
//
// The wrap is a pure function of an initialised cipher, so a JVM test (UnlockTest) runs it on a
// software key; only the prompt that authorises the Keystore's cipher needs a phone.
object Unlock {
    const val FILE = "terminal-unlocked.db"
    private const val ALIAS = "pronto-terminal-unlock"
    private const val PREFS = "pronto.terminal.unlock"
    private const val TAG_BITS = 128
    private const val NONCE_BYTES = 12
    private val AD = "pronto.terminal.unlock".toByteArray(Charsets.UTF_8)

    enum class State { FRESH, SEALED, LOST }

    // Rows with no wrapped key to open them are a lost store, never a fresh one.
    fun state(rows: Boolean, wrapped: ByteArray?): State = when {
        wrapped != null -> State.SEALED
        rows -> State.LOST
        else -> State.FRESH
    }

    fun encryptor(key: SecretKey): Cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key) }

    // Null when the blob is too short to carry a nonce and a tag.
    fun decryptor(key: SecretKey, wrapped: ByteArray): Cipher? {
        if (wrapped.size < NONCE_BYTES + TAG_BITS / 8) return null
        return Cipher.getInstance("AES/GCM/NoPadding").apply {
            init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(TAG_BITS, wrapped, 0, NONCE_BYTES))
        }
    }

    // The wrapped data key: the cipher's nonce, then the sealed key and its tag.
    fun wrapWith(authed: Cipher, data: ByteArray): ByteArray {
        authed.updateAAD(AD)
        return authed.iv + authed.doFinal(data)
    }

    // Null when the blob is not what wrapWith made under this key.
    fun unwrapWith(authed: Cipher, wrapped: ByteArray): SecretKey? = try {
        authed.updateAAD(AD)
        val data = authed.doFinal(wrapped, NONCE_BYTES, wrapped.size - NONCE_BYTES)
        SecretKeySpec(data, "AES").also { data.fill(0) }
    } catch (e: GeneralSecurityException) {
        null
    }

    // Asks for a strong biometric once and answers the data key: a new one wrapped the first time,
    // the stored one unwrapped after.
    suspend fun open(activity: FragmentActivity, title: String): SecretKey {
        when (BiometricManager.from(activity).canAuthenticate(BIOMETRIC_STRONG)) {
            BiometricManager.BIOMETRIC_SUCCESS -> {}
            BiometricManager.BIOMETRIC_ERROR_NONE_ENROLLED -> throw Locked("Enroll a fingerprint or face in Settings first.")
            else -> throw Locked("This phone has no strong biometric to unlock with.")
        }
        val prefs = activity.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val wrapped = prefs.getString("wrapped", null)?.let { Base64.decode(it, Base64.NO_WRAP) }
        val state = state(activity.getDatabasePath(FILE).exists(), wrapped)
        if (state == State.LOST) throw Locked("The key to this app's data is missing from this phone.", lost = true)
        val cipher = try {
            if (wrapped == null) encryptor(wrappingKey(fresh = true))
            else decryptor(wrappingKey(fresh = false), wrapped) ?: throw Locked("The key to this app's data is damaged.", lost = true)
        } catch (e: KeyPermanentlyInvalidatedException) {
            throw Locked("The biometrics on this phone changed, so the key to this app's data is gone.", lost = true)
        }
        val authed = prompt(activity, title, cipher)
        if (wrapped != null) return unwrapWith(authed, wrapped) ?: throw Locked("The key no longer opens this app's data.", lost = true)
        val data = ByteArray(32).also(SecureRandom()::nextBytes)
        val sealed = try {
            wrapWith(authed, data)
        } catch (e: GeneralSecurityException) {
            throw Locked("The phone refused to seal a new key.")
        }
        // Written before any row is: a key lost to a crash here would leave rows nothing opens.
        check(prefs.edit().putString("wrapped", Base64.encodeToString(sealed, Base64.NO_WRAP)).commit())
        return SecretKeySpec(data, "AES").also { data.fill(0) }
    }

    private fun wrappingKey(fresh: Boolean): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        if (!fresh) return ks.getKey(ALIAS, null) as? SecretKey ?: throw Locked("The key to this app's data is missing from this phone.", lost = true)
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
