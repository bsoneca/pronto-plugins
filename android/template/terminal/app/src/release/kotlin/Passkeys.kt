package __APPLICATION_ID__

import android.content.Context
import androidx.credentials.CreatePublicKeyCredentialRequest
import androidx.credentials.CreatePublicKeyCredentialResponse
import androidx.credentials.CredentialManager
import androidx.credentials.GetCredentialRequest
import androidx.credentials.GetPublicKeyCredentialOption
import androidx.credentials.PublicKeyCredential
import androidx.credentials.exceptions.CreateCredentialCancellationException
import androidx.credentials.exceptions.CreateCredentialException
import androidx.credentials.exceptions.GetCredentialCancellationException
import androidx.credentials.exceptions.GetCredentialException
import androidx.credentials.exceptions.NoCredentialException
import androidx.credentials.exceptions.publickeycredential.CreatePublicKeyCredentialDomException
import androidx.credentials.exceptions.publickeycredential.GetPublicKeyCredentialDomException
import kotlinx.coroutines.runBlocking

// A release build's passkeys are the device's, through Credential Manager: the page's WebAuthn options
// go to it as their JSON, and its answer comes back as the JSON a browser's credential serializes to.
// The client data names the app's signing certificate (`android:apk-key-hash:...`), not a page: the
// door admits it for the certificates android/android.json's `signing` lists (capabilities.auth.android),
// and Android lets the app use the door's relying party for the same ones (the door's assetlinks.json).
// Debug builds have a software authenticator instead (src/debug), so scenarios run on an emulator.
object Passkeys {
    const val available = true

    /** A ceremony that ends as a browser's would: `name` is the DOMException's. */
    class Refused(val name: String, message: String) : Exception(message)

    /** Called off the main thread (TerminalEngine's executor), with the activity that shows the sheet. */
    fun run(context: Context, actor: String, base: String, kind: String, options: String): String = runBlocking {
        val manager = CredentialManager.create(context)
        when (kind) {
            "create" -> try {
                val made = manager.createCredential(context, CreatePublicKeyCredentialRequest(options))
                (made as? CreatePublicKeyCredentialResponse)?.registrationResponseJson
                    ?: throw Refused("NotAllowedError", "the device made no passkey")
            } catch (e: CreateCredentialCancellationException) {
                throw Refused("NotAllowedError", e.message ?: "the person cancelled")
            } catch (e: CreatePublicKeyCredentialDomException) {
                throw Refused(e.domError::class.simpleName ?: "NotAllowedError", e.message ?: "refused")
            } catch (e: CreateCredentialException) {
                throw Refused("NotAllowedError", e.message ?: e.type)
            }
            "get" -> try {
                val got = manager.getCredential(context, GetCredentialRequest(listOf(GetPublicKeyCredentialOption(options))))
                (got.credential as? PublicKeyCredential)?.authenticationResponseJson
                    ?: throw Refused("NotAllowedError", "the device offered no passkey")
            } catch (e: GetCredentialCancellationException) {
                throw Refused("NotAllowedError", e.message ?: "the person cancelled")
            } catch (e: NoCredentialException) {
                throw Refused("NotAllowedError", e.message ?: "no passkey for this app on this device")
            } catch (e: GetPublicKeyCredentialDomException) {
                throw Refused(e.domError::class.simpleName ?: "NotAllowedError", e.message ?: "refused")
            } catch (e: GetCredentialException) {
                throw Refused("NotAllowedError", e.message ?: e.type)
            }
            else -> throw Refused("NotSupportedError", "no such ceremony: $kind")
        }
    }
}
