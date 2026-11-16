package __APPLICATION_ID__

import android.content.Context

// The terminal's storage bridges (__native_kv_*) over one of two stores. The sealed store (SealedStore.kt: AES-GCM in SQLite
// under a Keystore key) is behind the app's pronto-flags flag (named in res/values/sealed_flag.xml, which the app's generate writes from its CUE, and read over the door's /ofrep/), and
// the choice is sticky and one way (Storage.pick): once a phone has adopted the sealed store a marker file says so, and the
// sealed store is used from then on, whatever the flag says or whether the phone is offline; sealed data never goes back to plain.
// While there is no marker and the flag's value is false (the declared default when the door cannot be reached), the plain SharedPreferences the earlier
// builds wrote are used as they were. An app that asks for an unlock (Unlock.kt) has no plain path: its data key is the seal.
interface Kv {
    fun get(ns: String, k: String): String?
    fun set(ns: String, k: String, v: String)
    fun del(ns: String, k: String)
    fun clear(ns: String)
    fun keys(ns: String): List<String>
}

// The last well-formed answer of each flag, kept across launches: what a launch that cannot get an answer uses.
interface FlagCache {
    fun get(key: String): Boolean?
    fun put(key: String, value: Boolean)
}

class PrefsFlagCache(context: Context) : FlagCache {
    private val prefs = context.getSharedPreferences("terminal-flags", Context.MODE_PRIVATE)
    override fun get(key: String): Boolean? = if (prefs.contains(key)) prefs.getBoolean(key, false) else null
    override fun put(key: String, value: Boolean) {
        if (!prefs.edit().putBoolean(key, value).commit()) throw IllegalStateException("the flag $key could not be kept")
    }
}

// The flags' values as the build knew them (res/raw/flags_snapshot.json, which the app's generate writes from the CUE the flags are
// pushed from): an explicit, versioned value for a launch that has no answer and no cache yet, never a default. The build fails
// when the flag a build names has no value in it (build.gradle.kts), and Flag.resolve fails on a missing one.
interface FlagSnapshot {
    fun get(key: String): Boolean?
}

class RawFlagSnapshot(context: Context) : FlagSnapshot {
    private val flags = Snapshot.parse(context.resources.openRawResource(R.raw.flags_snapshot).bufferedReader().use { it.readText() })
    override fun get(key: String): Boolean? = flags[key]
}

object Snapshot {
    // {"version": 1, "source": "...", "flags": {"<key>": true|false}}; anything else fails.
    fun parse(json: String): Map<String, Boolean> {
        val o = org.json.JSONObject(json).getJSONObject("flags")
        return o.keys().asSequence().associateWith { (o.get(it) as? Boolean) ?: throw org.json.JSONException("the snapshot's value of $it is not a boolean") }
    }
}

// OpenFeature's evaluation details: the value, the reason it has it, and, when no answer gave it, the cause. The reason is the
// answer's own, or CACHED (the last well-formed answer), or SNAPSHOT (the build's value, on a launch with neither). Storage only ever
// sees the explicit value.
data class FlagDetails(val value: Boolean, val reason: String, val errorCode: String? = null)

object Storage {
    // "sealed": the marker is there (the flag is not asked). "adopt": no marker and the flag's value is true: write the marker, then
    // use the sealed store (what the plain preferences hold moves in per namespace, Migration, and an interrupted move resumes on the
    // next launch because the marker is already there). "plain": no marker and the value is false.
    fun pick(marker: Boolean, flag: Boolean): String = if (marker) "sealed" else if (flag) "adopt" else "plain"
}

// What asking the door gave: a well-formed boolean answer, or why there is none (unreachable, an error answer, a value of another
// type, not JSON). A failed or malformed answer is not a value.
sealed class Answer {
    data class Value(val value: Boolean, val reason: String) : Answer()
    data class Failed(val cause: String) : Answer()
}

// A flag over the remote evaluation protocol (OFREP), as the page reads it: POST <base>/ofrep/v1/evaluate/flags/<key>.
object Flag {
    fun parse(body: String): Answer = try {
        val o = org.json.JSONObject(body)
        when (val v = o.opt("value")) {
            is Boolean -> Answer.Value(v, o.optString("reason", "UNKNOWN"))
            null -> Answer.Failed("no value in the answer: ${o.optString("errorCode", body)}")
            else -> Answer.Failed("the value is not a boolean: $v")
        }
    } catch (e: org.json.JSONException) {
        Answer.Failed("the answer is not JSON: ${e.message}")
    }

    fun ask(post: () -> String): Answer = try {
        parse(post())
    } catch (e: java.io.IOException) {
        Answer.Failed("the door did not answer: ${e.message}")
    }

    // Only a well-formed answer is a value, and it updates `cache`. A failed one is reported (the app's log) with its cause and the cache
    // stays as it was: the value is the cache's, else the build's snapshot. With neither it fails: a build without the flag's value
    // does not exist (build.gradle.kts), so this is a build that was not made by generate.
    fun resolve(key: String, answer: Answer, cache: FlagCache, snapshot: FlagSnapshot, report: (String) -> Unit): FlagDetails = when (answer) {
        is Answer.Value -> {
            cache.put(key, answer.value)
            FlagDetails(answer.value, answer.reason)
        }
        is Answer.Failed -> {
            val kept = cache.get(key)
            val value = kept ?: snapshot.get(key) ?: throw IllegalStateException("the flag $key has no answer, no cached value and no value in the build's snapshot: ${answer.cause}")
            val reason = if (kept != null) "CACHED" else "SNAPSHOT"
            report("PRONTO FLAG $key $reason, value $value: ${answer.cause}")
            FlagDetails(value, reason, answer.cause)
        }
    }

    fun evaluate(key: String, post: () -> String, cache: FlagCache, snapshot: FlagSnapshot, report: (String) -> Unit): FlagDetails =
        resolve(key, ask(post), cache, snapshot, report)

    fun read(base: String, key: String, cache: FlagCache, snapshot: FlagSnapshot, timeoutMs: Int = 3000): FlagDetails = evaluate(key, {
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
    }, cache, snapshot) { android.util.Log.e("pronto", it) }
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
