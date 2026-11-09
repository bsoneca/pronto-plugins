package __APPLICATION_ID__

import android.app.assist.AssistStructure
import android.content.pm.PackageManager
import android.os.Build
import android.text.InputType
import android.view.View
import android.view.autofill.AutofillId
import java.security.MessageDigest
import org.json.JSONArray
import org.json.JSONObject

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

// autofill.json: which handler answers a fill, the tables it reads, and the vault's columns a
// dataset is drawn from. Both modes read it: the vault's host and the terminal ask the same handler.
class Autofill(json: JSONObject) {
    val handler: String = json.getString("handler")
    val reads: List<String> = json.getJSONArray("reads").let { a -> List(a.length(), a::getString) }
    val probe: String = json.getString("probe")
    val candidate: String = json.getString("candidate")
    val vault: String = json.getString("vault")
    val title: String = json.getString("title")
    val username: String = json.getString("username")
    val secret: String = json.getString("secret")
    // The vault's pin column and the probe's signer column: an app login fills
    // only an app signed as it was, and an unpinned one is pinned on first fill.
    val signer: String = json.getString("signer")
    val signers: String = json.getString("signers")
}

// The ask itself, the same in both modes: the probe stated as the handler's input, the logins it
// picked read back from its reply, and the pins an app's first fill writes. Pure over JSON, so a
// JVM test (AskTest) holds it; only running the handler needs an engine.
object Ask {
    // The event a fill sends: the stated tables changed, as a mutation would.
    fun event(): JSONObject = JSONObject().put("type", "mutation")

    // Only an app has certificates; a site's probe states none.
    fun stated(c: Autofill, probe: Probe, signers: List<String>): JSONObject = JSONObject()
        .put(c.probe, JSONArray().put(JSONObject().put("id", c.probe).put("kind", probe.kind).put("target", probe.target)
            .put(c.signers, signers.joinToString(","))))
        .put(c.candidate, JSONArray())

    // The ids of the logins the handler stated as candidates, in its order; nothing else it wrote.
    fun picks(c: Autofill, reply: JSONObject): List<String> =
        (reply.optJSONArray("updates") ?: JSONArray()).let { u -> List(u.length(), u::getJSONObject) }
            .filter { it.optString("op") == "put" && it.optString("entity") == c.candidate }
            .map { it.getString("id") }

    // Trust on first use: an app login with no pin yet is pinned, behind the prompt just answered,
    // to the app asking. A site's login, or one already pinned, is left as it is.
    fun pins(c: Autofill, probe: Probe, signers: List<String>, chosen: List<JSONObject>): JSONArray = JSONArray(
        chosen.filter { probe.kind == "app" && it.optString(c.signer).isEmpty() && signers.isNotEmpty() }
            .map { JSONObject().put("op", "patch").put("id", it.getString("id")).put("row", JSONObject().put(c.signer, signers.first())) },
    )
}

// One request's facts, read off the asking screen's view tree.
class Request(val packageName: String, val probe: Probe?, val username: AutofillId?, val password: AutofillId?) {
    val ids get() = listOfNotNull(username, password)

    companion object {
        fun read(structure: AssistStructure): Request {
            val fields = mutableListOf<Field<AutofillId>>()
            // A node's page is the nearest one declared at or above it: a frame
            // inside a page declares its own.
            fun walk(node: AssistStructure.ViewNode, outer: String?, outerScheme: String?) {
                val domain = node.webDomain ?: outer
                val scheme = (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P && node.webDomain != null) node.webScheme else null) ?: outerScheme
                val id = node.autofillId
                if (id != null && node.autofillType == View.AUTOFILL_TYPE_TEXT) {
                    val attrs = node.htmlInfo?.attributes.orEmpty().associate { it.first to it.second }
                    fields += Field(id, domain, scheme, node.autofillHints.orEmpty().toList(), node.inputType, attrs["type"], attrs["name"], node.idEntry)
                }
                for (i in 0 until node.childCount) walk(node.getChildAt(i), domain, scheme)
            }
            for (i in 0 until structure.windowNodeCount) walk(structure.getWindowNodeAt(i).rootViewNode, null, null)
            val pkg = structure.activityComponent.packageName
            val targets = Fill.targets(fields)
            val asking = fields.firstOrNull { it.id == targets.password } ?: fields.firstOrNull { it.id == targets.username }
            return Request(pkg, Fill.probe(pkg, asking), targets.username, targets.password)
        }
    }
}
