package __APPLICATION_ID__

import android.content.Context

// A release build offers no passkeys yet: a native Android passkey's clientData origin is
// `android:apk-key-hash:...`, which the door (mecha) does not accept, so `navigator.credentials` stays
// undefined and the interpreter offers none. Debug builds have a software authenticator (src/debug).
object Passkeys {
    const val available = false

    class Refused(val name: String, message: String) : Exception(message)

    fun run(context: Context, actor: String, base: String, kind: String, options: String): String =
        throw Refused("NotSupportedError", "this build has no passkeys")
}
