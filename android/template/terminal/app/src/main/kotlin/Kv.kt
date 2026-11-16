package __APPLICATION_ID__

import android.content.Context

// The terminal's storage bridges (__native_kv_*) are always the sealed store (SealedStore.kt: AES-GCM in SQLite under a Keystore key,
// or the unlock's data key): no flag, no plain path. What an earlier build left in plain SharedPreferences moves in once (Adoption).
interface Kv {
    fun get(ns: String, k: String): String?
    fun set(ns: String, k: String, v: String)
    fun del(ns: String, k: String)
    fun clear(ns: String)
    fun keys(ns: String): List<String>
}


// The one-time move of an earlier build's plain preferences into the sealed store, eager, at the store's first use: every namespace the
// actor has in plain preferences is moved (Migration: the plain copy is cleared only after every value landed), and only then is the marker
// written. A move that is interrupted leaves no marker, so the next launch moves what is left and loses nothing; with the marker nothing is
// scanned again. A fresh install has nothing to move and gets the marker at once. No plaintext is written after it: the plain preferences
// are never written again.
object Adoption {
    // Returns the number of values moved. Pure over its actions, so a JVM test runs it (android_cases.json "adoption").
    fun run(marked: Boolean, namespaces: () -> List<String>, move: (String) -> Int, writeMarker: () -> Unit): Int {
        if (marked) return 0
        var moved = 0
        for (ns in namespaces()) moved += move(ns)
        writeMarker()
        return moved
    }
}

// The marker, a file in the app's own directory, one per actor.
class Marker(context: Context, actor: String) {
    private val file = java.io.File(context.filesDir, "sealed-$actor.marker")
    fun exists() = file.exists()
    fun write() {
        file.writeText("sealed\n")
        if (!file.exists()) throw IllegalStateException("the sealed-storage marker could not be written")
    }
}

// Moves what the plain preferences hold into the sealed store, once per namespace, and clears the plain
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
