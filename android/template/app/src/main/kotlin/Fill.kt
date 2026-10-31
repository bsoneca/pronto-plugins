package __APPLICATION_ID__

import android.content.pm.PackageManager
import android.os.Build
import android.text.InputType
import java.security.MessageDigest

// What asks to be filled: a site, named by its domain, or an app, by its package.
data class Probe(val kind: String, val target: String)

// One text field of the screen asking, as the framework describes it, with
// the domain and scheme of the page or frame that drew it.
data class Field<Id>(
    val id: Id,
    val domain: String? = null,
    val scheme: String? = null,
    val hints: List<String> = emptyList(),
    val inputType: Int = 0,
    val htmlType: String? = null,
    val htmlName: String? = null,
    val idEntry: String? = null,
)

data class Targets<Id>(val username: Id?, val password: Id?)

// An installed app's signing certificates as the tokens a probe states: the
// current signer's SHA-256 first ('+'-joined when the app has several), then
// each certificate it rotated from, which Android verified when the rotation
// was installed. A login's pin is one such token.
object Signer {
    fun tokens(current: List<ByteArray>, past: List<ByteArray>): List<String> {
        val now = current.map(::sha256).sorted().joinToString("+")
        return (listOf(now) + past.map(::sha256)).filter { it.isNotEmpty() }.distinct()
    }

    // Empty for a package this phone does not have, or cannot see.
    fun of(pm: PackageManager, pkg: String): List<String> = try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val info = pm.getPackageInfo(pkg, PackageManager.GET_SIGNING_CERTIFICATES).signingInfo
            when {
                info == null -> emptyList()
                info.hasMultipleSigners() -> tokens(info.apkContentsSigners.map { it.toByteArray() }, emptyList())
                // Oldest first, the current signer last.
                else -> info.signingCertificateHistory.map { it.toByteArray() }.let { h -> tokens(h.takeLast(1), h.dropLast(1)) }
            }
        } else {
            @Suppress("DEPRECATION")
            tokens(pm.getPackageInfo(pkg, PackageManager.GET_SIGNATURES).signatures.orEmpty().map { it.toByteArray() }, emptyList())
        }
    } catch (e: PackageManager.NameNotFoundException) {
        emptyList()
    }

    private fun sha256(bytes: ByteArray) =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
}

// The host's facts about an autofill request. Which login fills it is the
// program's handler's to say; these only decide what the request is.
object Fill {
    // A web domain is a browser's word for its own page. Any other app reports
    // whatever its WebView loaded, so from it a domain would let an app pose as
    // the site; its own package is all it is ever trusted to be.
    val BROWSERS = setOf(
        "com.android.chrome", "com.chrome.beta", "com.chrome.dev", "com.chrome.canary",
        "org.mozilla.firefox", "org.mozilla.firefox_beta", "org.mozilla.fenix", "org.mozilla.focus",
        "com.brave.browser", "com.microsoft.emmx", "com.sec.android.app.sbrowser",
        "com.opera.browser", "com.duckduckgo.mobile.android", "com.vivaldi.browser",
    )

    // What asks, judged by the field that takes the secret, or null when
    // nothing may be filled: a page served over plain http, where anyone on
    // the network could have written the form.
    fun probe(packageName: String, field: Field<*>?): Probe? {
        if (field?.scheme.equals("http", ignoreCase = true)) return null
        val domain = field?.domain?.trim()?.lowercase()?.substringBefore(':')?.trimEnd('.')
        return if (!domain.isNullOrEmpty() && packageName in BROWSERS) Probe("web", domain)
        else Probe("app", packageName.lowercase())
    }

    // The username is taken only from the password's own page or frame: an
    // embedded frame from elsewhere is not the site the secret was saved for.
    fun <Id> targets(fields: List<Field<Id>>): Targets<Id> {
        val password = fields.firstOrNull(::isPassword)
        val same = fields.filter { password == null || it.domain == password.domain }
        val username = same.firstOrNull { it !== password && isUsername(it) }
            ?: password?.let { p -> same.takeWhile { it !== p }.lastOrNull { !isPassword(it) } }
        return Targets(username?.id, password?.id)
    }

    private fun variation(f: Field<*>) =
        if (f.inputType and InputType.TYPE_MASK_CLASS == InputType.TYPE_CLASS_TEXT) f.inputType and InputType.TYPE_MASK_VARIATION else -1

    private fun isPassword(f: Field<*>) =
        f.hints.any { it.contains("password", ignoreCase = true) } ||
            f.htmlType.equals("password", ignoreCase = true) ||
            variation(f) in setOf(
                InputType.TYPE_TEXT_VARIATION_PASSWORD,
                InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD,
                InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD,
            )

    private fun isUsername(f: Field<*>) =
        f.hints.any { h -> listOf("username", "email").any { h.contains(it, ignoreCase = true) } } ||
            f.htmlType.equals("email", ignoreCase = true) ||
            variation(f) in setOf(InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS, InputType.TYPE_TEXT_VARIATION_WEB_EMAIL_ADDRESS) ||
            listOfNotNull(f.htmlName, f.idEntry).any { n -> listOf("user", "email", "login").any { n.contains(it, ignoreCase = true) } }
}
