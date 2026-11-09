package __APPLICATION_ID__

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Test
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey

// The seal over a software key: the JVM has no AndroidKeyStore, and the seal takes any SecretKey.
class SealTest {
    private fun key(): SecretKey = KeyGenerator.getInstance("AES").run { init(256); generateKey() }
    private val ad = Seal.address("guest", "device", "best")
    private val plain = "ana 41s".toByteArray()

    @Test
    fun aSealedValueOpensToWhatWasSealed() {
        val k = key()
        assertArrayEquals(plain, Seal.open(k, ad, Seal.seal(k, ad, plain)))
    }

    @Test
    fun theBlobIsNonceThenCiphertextAndHidesTheValue() {
        val k = key()
        val blob = Seal.seal(k, ad, plain)
        assertEquals(12 + plain.size + 16, blob.size)
        assertEquals(-1, String(blob, Charsets.ISO_8859_1).indexOf("ana"))
    }

    @Test
    fun everySealUsesAFreshNonce() {
        val k = key()
        assertNotEquals(Seal.seal(k, ad, plain).toList().take(12), Seal.seal(k, ad, plain).toList().take(12))
    }

    @Test
    fun anotherAddressIsRefused() {
        val k = key()
        val blob = Seal.seal(k, ad, plain)
        assertNull(Seal.open(k, Seal.address("guest", "device", "other"), blob))
        assertNull(Seal.open(k, Seal.address("someone", "device", "best"), blob))
        assertNull(Seal.open(k, Seal.address("guest", "session", "best"), blob))
    }

    @Test
    fun aFlippedByteIsRefused() {
        val k = key()
        val blob = Seal.seal(k, ad, plain)
        for (i in blob.indices) {
            val bad = blob.copyOf().also { it[i] = (it[i].toInt() xor 1).toByte() }
            assertNull("byte $i", Seal.open(k, ad, bad))
        }
    }

    @Test
    fun anotherKeyAndATruncatedBlobAreRefused() {
        val blob = Seal.seal(key(), ad, plain)
        assertNull(Seal.open(key(), ad, blob))
        assertNull(Seal.open(key(), ad, ByteArray(5)))
    }
}
