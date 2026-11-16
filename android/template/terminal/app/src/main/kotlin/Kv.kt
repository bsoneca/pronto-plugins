package __APPLICATION_ID__

import android.content.Context

// The terminal's storage bridges (__native_kv_*) over one of two stores. The sealed store (SealedStore.kt: AES-GCM in SQLite
// under a Keystore key) is behind the app's pronto-flags flag (named in res/values/sealed_flag.xml, which the app's generate writes from its CUE, and read over the door's /ofrep/), and
// the choice is sticky and one way (Storage.pick): once a phone has adopted the sealed store a marker file says so, and the
// sealed store is used from then on, whatever the flag says or whether the phone is offline; sealed data never goes back to plain.
// While there is no marker and the flag is off or unknown (an unreachable door, a timeout), the plain SharedPreferences the earlier
// builds wrote are used as they were. An app that asks for an unlock (Unlock.kt) has no plain path: its data key is the seal.
interface Kv {
    fun get(ns: String, k: String): String?
    fun set(ns: String, k: String, v: String)
    fun del(ns: String, k: String)
    fun clear(ns: String)
    fun keys(ns: String): List<String>
}

// What asking the flag gave: On, Off, or Unknown with its cause. Never a null: a failure to ask is a result the caller branches on.
sealed class FlagResult {
    object On : FlagResult()
    object Off : FlagResult()
    data class Unknown(val cause: String) : FlagResult()
}

object Storage {
    // "sealed": the marker is there (the flag is not asked). "adopt": no marker and the flag is On: write the marker, then use the
    // sealed store (what the plain preferences hold moves in per namespace, Migration, and an interrupted move resumes on the next
    // launch because the marker is already there). "plain": no marker and the flag Off or Unknown. Unknown is a stated fallback that
    // keeps the current state for this launch only: no marker, no move, nothing dropped, and the flag is asked again next launch;
    // it never adopts sealed storage. Refusing to start instead would leave a phone that is offline on its first launch unusable.
    fun pick(marker: Boolean, flag: FlagResult?): String = when {
        marker -> "sealed"
        flag is FlagResult.On -> "adopt"
        else -> "plain"
    }
}

// A flag over the remote evaluation protocol (OFREP), as the page reads it: POST <base>/ofrep/v1/evaluate/flags/<key>.
object Flag {
    // The boolean an answer carries; Unknown, with why, for anything else (an error answer, a value that is not a boolean, not JSON).
    fun parse(body: String): FlagResult = try {
        when (val v = org.json.JSONObject(body).opt("value")) {
            true -> FlagResult.On
            false -> FlagResult.Off
            else -> FlagResult.Unknown(if (v == null) "no value in the answer: $body" else "the value is not a boolean: $v")
        }
    } catch (e: org.json.JSONException) {
        FlagResult.Unknown("the answer is not JSON: ${e.message}")
    }

    // Asks through `post` (the HTTP call, so a test can make it fail) and says every Unknown through `report`, with its cause.
    fun evaluate(key: String, post: () -> String, report: (String) -> Unit): FlagResult {
        val result = try {
            parse(post())
        } catch (e: java.io.IOException) {
            FlagResult.Unknown("the door did not answer: ${e.message}")
        }
        if (result is FlagResult.Unknown) report("PRONTO FLAG $key unknown: ${result.cause}")
        return result
    }

    fun read(base: String, key: String, timeoutMs: Int = 3000): FlagResult = evaluate(key, {
        val c = java.net.URL("$base/ofrep/v1/evaluate/flags/$key").openConnection() as java.net.HttpURLConnection
        try {
            c.connectTimeout = timeoutMs
            c.readTimeout = timeoutMs
            c.requestMethod = "POST"
            c.doOutput = true
            c.setRequestProperty("Content-Type", "application/json")
            c.outputStream.use { it.write("{\"context\":{}}".toByteArray()) }
            if (c.responseCode != 200) throw java.io.IOException("the door answered ${c.responseCode}")
            c.inputStream.bufferedReader().readText()
        } finally {
            c.disconnect()
        }
    }) { android.util.Log.e("pronto", it) }
}

// The phone's one-way choice, a file in the app's own directory: written before the move starts, so a move that is interrupted
// is finished by the next launch whatever the flag then says.
class Marker(context: Context) {
    private val file = java.io.File(context.filesDir, "sealed.marker")
    fun exists() = file.exists()
    fun write() {
        file.writeText("sealed\n")
        if (!file.exists()) throw IllegalStateException("the sealed-storage marker could not be written")
    }
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
