package __APPLICATION_ID__

import android.content.Context
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.net.URI
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.Signature
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.PKCS8EncodedKeySpec

// A software authenticator for debug builds, so scenarios can sign up and in with a passkey on an
// emulator that has none. It behaves as a platform authenticator that is always present and always
// verifies the user: EC P-256 keys (ES256, COSE alg -7), "none" attestation, AAGUID of zeros, flags
// UP|UV (|AT on create), a sign count. The clientDataJSON carries the app's base origin, as a browser at
// that door would send, so the door's pinned WEBAUTHN_ORIGIN accepts it. Credentials are kept per actor
// in SharedPreferences, so a restart keeps them. Release builds have none (src/release).
object Passkeys {
    const val available = true

    /** A ceremony that ends as a browser's would: `name` is the DOMException's. */
    class Refused(val name: String, message: String) : Exception(message)

    private val random = SecureRandom()
    private const val FLAGS_UP_UV = 0x05
    private const val FLAG_AT = 0x40

    private fun b64u(b: ByteArray) = Base64.encodeToString(b, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
    private fun unb64u(s: String) = Base64.decode(s, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
    private fun sha256(b: ByteArray) = MessageDigest.getInstance("SHA-256").digest(b)

    private fun store(context: Context, actor: String) = context.getSharedPreferences("passkeys-$actor", Context.MODE_PRIVATE)

    @Synchronized
    fun run(context: Context, actor: String, base: String, kind: String, options: String): String {
        val o = JSONObject(options)
        val origin = URI(base).let { u -> "${u.scheme}://${u.host}${if (u.port >= 0) ":${u.port}" else ""}" }
        val host = URI(base).host
        return when (kind) {
            "create" -> create(store(context, actor), origin, host, o)
            "get" -> get(store(context, actor), origin, host, o)
            else -> throw Refused("NotSupportedError", "no such ceremony: $kind")
        }
    }

    // The relying party's id must be the page's host or a parent domain of it.
    private fun rpOf(asked: String?, host: String): String {
        val rp = asked?.takeIf { it.isNotEmpty() } ?: host
        if (host != rp && !host.endsWith(".$rp")) throw Refused("SecurityError", "the relying party $rp is not the origin's domain")
        return rp
    }

    private fun clientData(type: String, challenge: String, origin: String) =
        JSONObject().put("type", type).put("challenge", challenge).put("origin", origin).put("crossOrigin", false).toString().toByteArray()

    private fun create(prefs: android.content.SharedPreferences, origin: String, host: String, o: JSONObject): String {
        val rp = rpOf(o.optJSONObject("rp")?.optString("id"), host)
        val params = o.optJSONArray("pubKeyCredParams")
        if (params != null && params.length() > 0 && (0 until params.length()).none { params.getJSONObject(it).optInt("alg") == -7 }) {
            throw Refused("NotSupportedError", "only ES256 is offered here")
        }
        val excluded = o.optJSONArray("excludeCredentials") ?: JSONArray()
        for (i in 0 until excluded.length()) {
            val have = prefs.getString(excluded.getJSONObject(i).getString("id"), null)?.let(::JSONObject)
            if (have != null && have.getString("rp") == rp) throw Refused("InvalidStateError", "the authenticator already holds one of the excluded credentials")
        }
        val pair = KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1")) }.generateKeyPair()
        val id = ByteArray(32).also(random::nextBytes)
        val point = (pair.public as ECPublicKey).w
        val cose = ByteArrayOutputStream().apply {
            map(5); int(1); int(2); int(3); int(-7); int(-1); int(1)
            int(-2); bytes(fixed(point.affineX.toByteArray())); int(-3); bytes(fixed(point.affineY.toByteArray()))
        }.toByteArray()
        val authData = ByteArrayOutputStream().apply {
            write(sha256(rp.toByteArray())); write(FLAGS_UP_UV or FLAG_AT); write(counter(0))
            write(ByteArray(16)); write(id.size shr 8); write(id.size and 0xff); write(id); write(cose)
        }.toByteArray()
        val attestation = ByteArrayOutputStream().apply {
            map(3); text("fmt"); text("none"); text("attStmt"); map(0); text("authData"); bytes(authData)
        }.toByteArray()
        prefs.edit().putString(b64u(id), JSONObject().put("rp", rp).put("key", b64u(pair.private.encoded)).put("user", o.getJSONObject("user").getString("id")).put("count", 0).put("at", System.currentTimeMillis()).toString()).apply()
        return JSONObject()
            .put("id", b64u(id)).put("rawId", b64u(id)).put("type", "public-key").put("authenticatorAttachment", "platform")
            .put("clientExtensionResults", JSONObject())
            .put("response", JSONObject()
                .put("clientDataJSON", b64u(clientData("webauthn.create", o.getString("challenge"), origin)))
                .put("attestationObject", b64u(attestation))
                .put("transports", JSONArray(listOf("internal"))))
            .toString()
    }

    private fun get(prefs: android.content.SharedPreferences, origin: String, host: String, o: JSONObject): String {
        val rp = rpOf(o.optString("rpId"), host)
        val allowed = o.optJSONArray("allowCredentials")?.let { a -> (0 until a.length()).map { a.getJSONObject(it).getString("id") } } ?: emptyList()
        // The newest credential for this relying party, among those allowed when the page names some.
        val (id, held) = prefs.all.entries
            .mapNotNull { (k, v) -> (v as? String)?.let { k to JSONObject(it) } }
            .filter { (k, v) -> v.getString("rp") == rp && (allowed.isEmpty() || k in allowed) }
            .maxByOrNull { (_, v) -> v.getLong("at") } ?: throw Refused("NotAllowedError", "no passkey for $rp on this device")
        val count = held.getInt("count") + 1
        prefs.edit().putString(id, held.put("count", count).toString()).apply()
        val client = clientData("webauthn.get", o.getString("challenge"), origin)
        val authData = sha256(rp.toByteArray()) + byteArrayOf(FLAGS_UP_UV.toByte()) + counter(count)
        val key = KeyFactory.getInstance("EC").generatePrivate(PKCS8EncodedKeySpec(unb64u(held.getString("key"))))
        val signature = Signature.getInstance("SHA256withECDSA").run { initSign(key); update(authData + sha256(client)); sign() }
        return JSONObject()
            .put("id", id).put("rawId", id).put("type", "public-key").put("authenticatorAttachment", "platform")
            .put("clientExtensionResults", JSONObject())
            .put("response", JSONObject()
                .put("clientDataJSON", b64u(client))
                .put("authenticatorData", b64u(authData))
                .put("signature", b64u(signature))
                .put("userHandle", held.getString("user")))
            .toString()
    }

    private fun counter(n: Int) = byteArrayOf((n ushr 24).toByte(), (n ushr 16).toByte(), (n ushr 8).toByte(), n.toByte())

    // A coordinate as exactly 32 bytes: BigInteger's two's-complement form may carry a leading zero or lack bytes.
    private fun fixed(b: ByteArray): ByteArray {
        val v = if (b.size > 32) b.copyOfRange(b.size - 32, b.size) else b
        return ByteArray(32 - v.size) + v
    }

    // CBOR (RFC 8949), the little of it a COSE key and an attestation object use.
    private fun ByteArrayOutputStream.head(major: Int, n: Int) {
        val m = major shl 5
        when {
            n < 24 -> write(m or n)
            n < 256 -> { write(m or 24); write(n) }
            else -> { write(m or 25); write(n shr 8); write(n and 0xff) }
        }
    }
    private fun ByteArrayOutputStream.int(n: Int) = if (n >= 0) head(0, n) else head(1, -1 - n)
    private fun ByteArrayOutputStream.bytes(b: ByteArray) { head(2, b.size); write(b) }
    private fun ByteArrayOutputStream.text(s: String) { val b = s.toByteArray(); head(3, b.size); write(b) }
    private fun ByteArrayOutputStream.map(n: Int) = head(5, n)
}
