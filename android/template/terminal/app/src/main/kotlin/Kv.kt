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

// OpenFeature's evaluation details: the value, the reason it has it, and, when the evaluation failed, the error. A flag that cannot
// be evaluated has the value of its declared default (the app's flags_spec.cue), reason "ERROR" and the cause in `errorCode`: the
// same contract the page's flags have (an OFREP error evaluates to the default). Storage only ever sees the explicit value.
data class FlagDetails(val value: Boolean, val reason: String, val errorCode: String? = null)

object Storage {
    // "sealed": the marker is there (the flag is not asked). "adopt": no marker and the flag's value is true: write the marker, then
    // use the sealed store (what the plain preferences hold moves in per namespace, Migration, and an interrupted move resumes on the
    // next launch because the marker is already there). "plain": no marker and the value is false.
    fun pick(marker: Boolean, flag: Boolean): String = if (marker) "sealed" else if (flag) "adopt" else "plain"
}

// A flag over the remote evaluation protocol (OFREP), as the page reads it: POST <base>/ofrep/v1/evaluate/flags/<key>.
object Flag {
    // The details an answer carries; for anything but a boolean value (an error answer, a value of another type, not JSON) the
    // declared `default`, reason ERROR and the cause.
    fun parse(body: String, default: Boolean): FlagDetails = try {
        val o = org.json.JSONObject(body)
        when (val v = o.opt("value")) {
            is Boolean -> FlagDetails(v, o.optString("reason", "UNKNOWN"))
            null -> FlagDetails(default, "ERROR", "no value in the answer: ${o.optString("errorCode", body)}")
            else -> FlagDetails(default, "ERROR", "the value is not a boolean: $v")
        }
    } catch (e: org.json.JSONException) {
        FlagDetails(default, "ERROR", "the answer is not JSON: ${e.message}")
    }

    // Asks through `post` (the HTTP call, so a test can make it fail); a failure is the default with reason ERROR, and every ERROR
    // is reported (the app's log) with the key and the cause.
    fun evaluate(key: String, default: Boolean, post: () -> String, report: (String) -> Unit): FlagDetails {
        val details = try {
            parse(post(), default)
        } catch (e: java.io.IOException) {
            FlagDetails(default, "ERROR", "the door did not answer: ${e.message}")
        }
        if (details.reason == "ERROR") report("PRONTO FLAG $key ERROR, value ${details.value} (the declared default): ${details.errorCode}")
        return details
    }

    fun read(base: String, key: String, default: Boolean, timeoutMs: Int = 3000): FlagDetails = evaluate(key, default, {
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
