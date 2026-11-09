package __APPLICATION_ID__

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Log
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

// The seal, a pure function of a key: AES-256/GCM, a fresh nonce per value, and the value's own
// address (actor, namespace, key) as associated data, so a sealed value moved to another row, or
// another actor's, opens as nothing. The blob is nonce followed by ciphertext and tag. The nonce
// is read back from the cipher, so a Keystore key (which picks it) and a software key (a JVM unit
// test's) take the same path.
object Seal {
    private const val TAG_BITS = 128
    private const val NONCE_BYTES = 12

    fun address(actor: String, ns: String, k: String) = "$actor\u0000$ns\u0000$k".toByteArray(Charsets.UTF_8)

    fun seal(key: SecretKey, ad: ByteArray, plain: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key)
        cipher.updateAAD(ad)
        return cipher.iv + cipher.doFinal(plain)
    }

    // Null when the blob is not what `seal` made for this key and address.
    fun open(key: SecretKey, ad: ByteArray, blob: ByteArray): ByteArray? {
        if (blob.size < NONCE_BYTES + TAG_BITS / 8) return null
        return try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(TAG_BITS, blob, 0, NONCE_BYTES))
            cipher.updateAAD(ad)
            cipher.doFinal(blob, NONCE_BYTES, blob.size - NONCE_BYTES)
        } catch (e: java.security.GeneralSecurityException) {
            null
        }
    }
}

// The terminal's storage bridges (__native_kv_*): every value sealed at rest in SQLite under an
// AndroidKeyStore key that never leaves the Keystore. omnishell keeps the app's `device` tables in
// localStorage, so what a phone holds of them is ciphertext. A value that fails to open reads as
// absent, and is logged once; nothing here throws at the page.
class SealedStore(private val context: Context, private val actor: String) {
    private val db: SQLiteDatabase = object : SQLiteOpenHelper(context, "terminal-sealed.db", null, 1) {
        override fun onCreate(db: SQLiteDatabase) {
            db.execSQL("CREATE TABLE kv(ns TEXT NOT NULL, actor TEXT NOT NULL, k TEXT NOT NULL, v BLOB NOT NULL, PRIMARY KEY(ns, actor, k))")
        }
        override fun onUpgrade(db: SQLiteDatabase, from: Int, to: Int) {}
    }.writableDatabase
    private val key: SecretKey by lazy { keystoreKey() }
    private val migrated = HashSet<String>()
    private val refused = HashSet<String>()

    @Synchronized
    fun get(ns: String, k: String): String? {
        migrate(ns)
        db.rawQuery("SELECT v FROM kv WHERE ns = ? AND actor = ? AND k = ?", arrayOf(ns, actor, k)).use { c ->
            if (!c.moveToFirst()) return null
            val plain = Seal.open(key, Seal.address(actor, ns, k), c.getBlob(0))
            if (plain == null) {
                if (refused.add("$ns/$k")) Log.w("pronto", "PRONTO STORE refused $ns/$k")
                return null
            }
            return String(plain, Charsets.UTF_8)
        }
    }

    @Synchronized
    fun set(ns: String, k: String, v: String) {
        migrate(ns)
        put(ns, k, v)
    }

    @Synchronized
    fun del(ns: String, k: String) {
        migrate(ns)
        db.delete("kv", "ns = ? AND actor = ? AND k = ?", arrayOf(ns, actor, k))
    }

    @Synchronized
    fun clear(ns: String) {
        migrate(ns)
        db.delete("kv", "ns = ? AND actor = ?", arrayOf(ns, actor))
    }

    @Synchronized
    fun keys(ns: String): List<String> {
        migrate(ns)
        db.rawQuery("SELECT k FROM kv WHERE ns = ? AND actor = ?", arrayOf(ns, actor)).use { c ->
            val out = ArrayList<String>()
            while (c.moveToNext()) out.add(c.getString(0))
            return out
        }
    }

    private fun put(ns: String, k: String, v: String) {
        val row = ContentValues().apply {
            put("ns", ns); put("actor", actor); put("k", k)
            put("v", Seal.seal(key, Seal.address(actor, ns, k), v.toByteArray(Charsets.UTF_8)))
        }
        db.insertWithOnConflict("kv", null, row, SQLiteDatabase.CONFLICT_REPLACE)
    }

    // What an earlier build left in plain SharedPreferences moves in on the namespace's first use,
    // and the preferences are cleared: sealing must not leave the plain copy behind.
    private fun migrate(ns: String) {
        if (!migrated.add(ns)) return
        val prefs = context.getSharedPreferences("terminal-$actor-$ns", Context.MODE_PRIVATE)
        val old = prefs.all
        if (old.isEmpty()) return
        db.beginTransaction()
        try {
            for ((k, v) in old) if (v is String) put(ns, k, v)
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
        prefs.edit().clear().commit()
    }

    private fun keystoreKey(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        val spec = KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setKeySize(256)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setUserAuthenticationRequired(false)
            .setRandomizedEncryptionRequired(true)
            .build()
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run { init(spec); generateKey() }
    }

    companion object {
        const val ALIAS = "pronto-terminal-store"
    }
}
