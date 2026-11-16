package __APPLICATION_ID__

import android.content.Context

// The terminal's storage bridges (__native_kv_*) over one of two stores. The sealed store (SealedStore.kt: AES-GCM in SQLite
// under a Keystore key) is behind a build-time switch, `pronto_sealed` (android.json's "sealedStorage"): on in the debug,
// rehearsal and local builds, off in a release until a later flip. While it is off the plain SharedPreferences the earlier
// builds wrote are used as they were. An app that asks for an unlock (Unlock.kt) has no plain path: its data key is the seal.
interface Kv {
    fun get(ns: String, k: String): String?
    fun set(ns: String, k: String, v: String)
    fun del(ns: String, k: String)
    fun clear(ns: String)
    fun keys(ns: String): List<String>
}

object Storage {
    // Which store a build uses: "sealed" or "plain".
    fun choose(switch: String, unlock: Boolean): String = if (unlock || switch == "on") "sealed" else "plain"
}

// What the earlier builds did: plain SharedPreferences, one file per actor and namespace.
class PlainStore(private val context: Context, private val actor: String) : Kv {
    private fun prefs(ns: String) = context.getSharedPreferences("terminal-$actor-$ns", Context.MODE_PRIVATE)
    override fun get(ns: String, k: String): String? = prefs(ns).getString(k, null)
    override fun set(ns: String, k: String, v: String) = prefs(ns).edit().putString(k, v).apply()
    override fun del(ns: String, k: String) = prefs(ns).edit().remove(k).apply()
    override fun clear(ns: String) = prefs(ns).edit().clear().apply()
    override fun keys(ns: String): List<String> = prefs(ns).all.keys.toList()
}

// Turning the switch on moves what the plain preferences hold into the sealed store, once per namespace, and clears the plain
// copy only when every value has landed: a failed write leaves the plain preferences as they were, and a namespace is not counted as
// moved until the clear succeeded. Pure over its three actions, so a JVM test runs it (android_cases.json "migration").
class Migration {
    private val moved = HashSet<String>()

    // Returns the number of values moved. `atomic` runs the puts as one unit (a SQLite transaction on a phone).
    fun once(ns: String, plain: () -> Map<String, Any?>, put: (String, String) -> Unit, clearPlain: () -> Boolean, atomic: (() -> Unit) -> Unit): Int {
        if (ns in moved) return 0
        val old = plain().filterValues { it is String }.mapValues { it.value as String }
        if (old.isEmpty()) {
            moved.add(ns)
            return 0
        }
        atomic { for ((k, v) in old) put(k, v) }
        if (!clearPlain()) throw IllegalStateException("the plain preferences of $ns could not be cleared")
        moved.add(ns)
        return old.size
    }
}
