package __APPLICATION_ID__

import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Test
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey

// The seal over a software key (the JVM has no AndroidKeyStore; the seal takes any SecretKey), over the cases in
// android_cases.json (android/cases.cue): each case names its check.
class SealTest {
    private val seal = Cases.all.getJSONObject("seal")
    private fun key(): SecretKey = KeyGenerator.getInstance("AES").run { init(256); generateKey() }
    private fun address(o: JSONObject) = Seal.address(o.getString("actor"), o.getString("ns"), o.getString("key"))
    private val ad = address(seal.getJSONObject("address"))
    private val plain = seal.getString("plain").toByteArray()

    @Test
    fun theCases() {
        for (c in Cases.list(seal.getJSONArray("cases"))) {
            val why = c.getString("why")
            val k = key()
            val blob = Seal.seal(k, ad, plain)
            when (val check = c.getString("check")) {
                "opens" -> assertArrayEquals(why, plain, Seal.open(k, ad, blob))
                "shape" -> {
                    assertEquals(why, c.getInt("size"), blob.size)
                    assertEquals(why, -1, String(blob, Charsets.ISO_8859_1).indexOf(c.getString("absent")))
                }
                "freshNonce" -> assertNotEquals(why, blob.toList().take(c.getInt("nonce")), Seal.seal(k, ad, plain).toList().take(c.getInt("nonce")))
                "otherAddress" -> assertNull(why, Seal.open(k, address(c.getJSONObject("address")), blob))
                "flipped" -> for (i in blob.indices) {
                    val bad = blob.copyOf().also { it[i] = (it[i].toInt() xor 1).toByte() }
                    assertNull("$why: byte $i", Seal.open(k, ad, bad))
                }
                "otherKey" -> assertNull(why, Seal.open(key(), ad, blob))
                "truncated" -> assertNull(why, Seal.open(k, ad, ByteArray(c.getInt("bytes"))))
                else -> throw AssertionError("$why: no check named $check")
            }
        }
    }
}
