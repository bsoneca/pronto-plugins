package __APPLICATION_ID__

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey

// The unlock's wrap over a software key: the JVM has no AndroidKeyStore and no prompt, and the wrap
// takes any initialised cipher, which on a phone is the one the prompt authorised.
class UnlockTest {
    private fun key(): SecretKey = KeyGenerator.getInstance("AES").run { init(256); generateKey() }
    private val data = ByteArray(32) { it.toByte() }

    @Test
    fun aWrappedKeyUnwrapsToTheSameKey() {
        val wrap = key()
        val blob = Unlock.wrapWith(Unlock.encryptor(wrap), data)
        val opened = Unlock.unwrapWith(requireNotNull(Unlock.decryptor(wrap, blob)), blob)
        assertArrayEquals(data, requireNotNull(opened).encoded)
        assertEquals("AES", opened.algorithm)
    }

    @Test
    fun theWrapIsNonceThenSealedKeyAndHidesIt() {
        val blob = Unlock.wrapWith(Unlock.encryptor(key()), data)
        assertEquals(12 + 32 + 16, blob.size)
        for (i in 0..blob.size - 32) assertEquals(false, blob.copyOfRange(i, i + 32).contentEquals(data))
    }

    @Test
    fun anotherWrappingKeyIsRefused() {
        val blob = Unlock.wrapWith(Unlock.encryptor(key()), data)
        assertNull(Unlock.unwrapWith(requireNotNull(Unlock.decryptor(key(), blob)), blob))
    }

    @Test
    fun aFlippedByteIsRefused() {
        val wrap = key()
        val blob = Unlock.wrapWith(Unlock.encryptor(wrap), data)
        for (i in blob.indices) {
            val bad = blob.copyOf().also { it[i] = (it[i].toInt() xor 1).toByte() }
            assertNull("byte $i", Unlock.unwrapWith(requireNotNull(Unlock.decryptor(wrap, bad)), bad))
        }
    }

    @Test
    fun aBlobTooShortForANonceAndTagHasNoDecryptor() {
        assertNull(Unlock.decryptor(key(), ByteArray(27)))
        assertNotNull(Unlock.decryptor(key(), ByteArray(28)))
    }

    @Test
    fun rowsWithNoWrappedKeyAreLostNeverFresh() {
        assertEquals(Unlock.State.FRESH, Unlock.state(rows = false, wrapped = null))
        assertEquals(Unlock.State.LOST, Unlock.state(rows = true, wrapped = null))
        assertEquals(Unlock.State.SEALED, Unlock.state(rows = true, wrapped = ByteArray(60)))
        assertEquals(Unlock.State.SEALED, Unlock.state(rows = false, wrapped = ByteArray(60)))
    }
}
