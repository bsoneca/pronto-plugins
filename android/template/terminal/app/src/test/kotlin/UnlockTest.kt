package __APPLICATION_ID__

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey

// The unlock's wrap over a software key (the JVM has no AndroidKeyStore and no prompt; the wrap takes any initialised
// cipher, which on a phone is the one the prompt authorised), over the cases in android_cases.json (android/cases.cue).
class UnlockTest {
    private val unlock = Cases.all.getJSONObject("unlock")
    private fun key(): SecretKey = KeyGenerator.getInstance("AES").run { init(256); generateKey() }
    private val data = ByteArray(unlock.getInt("bytes")) { it.toByte() }

    @Test
    fun theWrap() {
        for (c in Cases.list(unlock.getJSONArray("wrap"))) {
            val why = c.getString("why")
            val wrap = key()
            val blob = Unlock.wrapWith(Unlock.encryptor(wrap), data)
            when (val check = c.getString("check")) {
                "roundtrip" -> {
                    val opened = requireNotNull(Unlock.unwrapWith(requireNotNull(Unlock.decryptor(wrap, blob)), blob))
                    assertArrayEquals(why, data, opened.encoded)
                    assertEquals(why, "AES", opened.algorithm)
                }
                "shape" -> {
                    assertEquals(why, c.getInt("size"), blob.size)
                    for (i in 0..blob.size - data.size) assertEquals(why, false, blob.copyOfRange(i, i + data.size).contentEquals(data))
                }
                "otherKey" -> assertNull(why, Unlock.unwrapWith(requireNotNull(Unlock.decryptor(key(), blob)), blob))
                "flipped" -> for (i in blob.indices) {
                    val bad = blob.copyOf().also { it[i] = (it[i].toInt() xor 1).toByte() }
                    assertNull("$why: byte $i", Unlock.unwrapWith(requireNotNull(Unlock.decryptor(wrap, bad)), bad))
                }
                "decryptor" -> {
                    val d = Unlock.decryptor(wrap, ByteArray(c.getInt("bytes")))
                    if (c.getBoolean("has")) assertNotNull(why, d) else assertNull(why, d)
                }
                else -> throw AssertionError("$why: no check named $check")
            }
        }
    }

    @Test
    fun theState() {
        for (c in Cases.list(unlock.getJSONArray("state"))) {
            val wrapped = if (c.isNull("wrapped")) null else ByteArray(c.getInt("wrapped"))
            assertEquals(c.getString("why"), Unlock.State.valueOf(c.getString("want")), Unlock.state(rows = c.getBoolean("rows"), wrapped = wrapped))
        }
    }
}
