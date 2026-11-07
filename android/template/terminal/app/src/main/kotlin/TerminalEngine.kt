package __APPLICATION_ID__

import android.content.Context
import android.icu.text.DateFormat
import android.icu.text.DisplayContext
import android.icu.text.NumberFormat
import android.icu.text.PluralRules
import android.icu.util.TimeZone
import android.icu.util.ULocale
import android.util.Log
import com.dokar.quickjs.QuickJs
import com.dokar.quickjs.binding.function
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.security.SecureRandom
import java.util.Date
import java.util.Locale
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

// omnishell's engine contract (start, a UI tree flow, dispatch) with the bridges
// a terminal owes the interpreter: fetch, timers, storage, Intl, the clock's zone.
// One thread runs JS. Every bridge answers by a later evaluate on that thread,
// so a long poll holds nothing but its own socket.
class TerminalEngine(
    private val context: Context,
    private val base: String,
    private val start: String,
    private val actor: String,
    private val onReload: () -> Unit,
    private val onExit: () -> Unit,
    // A page of another origin: the host takes it to the system browser.
    private val onOpen: (String) -> Unit,
) : AutoCloseable {
    private val js = Executors.newSingleThreadExecutor { Thread(null, it, "pronto-quickjs", 16L * 1024 * 1024).apply { isDaemon = true } }
    private val dispatcher = js.asCoroutineDispatcher()
    private val net = Executors.newCachedThreadPool { Thread(it, "pronto-net").apply { isDaemon = true } }
    private val _tree = MutableStateFlow("")
    val tree: StateFlow<String> = _tree
    private val _failure = MutableStateFlow<Throwable?>(null)
    val failure: StateFlow<Throwable?> = _failure
    private val scope = CoroutineScope(SupervisorJob() + dispatcher + CoroutineExceptionHandler { _, e ->
        Log.e("pronto", "terminal failed", e)
        _failure.value = e
    })
    private val timers = ConcurrentHashMap<Long, Job>()
    private val requests = ConcurrentHashMap<Long, HttpURLConnection>()
    private val random = SecureRandom()
    private lateinit var qjs: QuickJs

    private fun prefs(ns: String) = context.getSharedPreferences("terminal-$actor-$ns", Context.MODE_PRIVATE)

    private fun asset(name: String) = context.assets.open(name).bufferedReader().use { it.readText() }

    // A file the program ships answers at the address it has on the web: the
    // shell's under /shell/, its catalogues under /messages/ or /shell/messages/.
    private fun packaged(url: String): String? {
        if (!url.startsWith("$base/")) return null
        val path = URL(url).path.removePrefix("/")
        val name = when {
            path.startsWith("shell/messages/") -> path.removePrefix("shell/")
            path.startsWith("shell/") -> path.removePrefix("shell/")
            path.startsWith("messages/") -> path
            else -> return null
        }
        return runCatching { asset(name) }.getOrNull()
    }

    private fun call(fn: String, vararg args: String) = scope.launch {
        qjs.evaluate<Any?>("$fn(${args.joinToString(",")}); undefined", "bridge.js", false)
    }

    private fun bridge() {
        qjs.function("__native_log") { a -> Log.i("pronto", "${a[0]}: ${a[1]}") }
        qjs.function("__native_emit") { a -> _tree.value = a[0] as String }
        qjs.function("__native_base") { _ -> base }
        qjs.function("__native_start") { _ -> start }
        qjs.function("__native_uuid") { _ -> UUID.randomUUID().toString() }
        qjs.function("__native_random") { a -> JSONArray(ByteArray((a[0] as Number).toInt()).also(random::nextBytes).map { it.toInt() and 0xff }).toString() }
        qjs.function("__native_locale") { _ -> Locale.getDefault().toLanguageTag() }
        qjs.function("__native_zone") { _ -> java.util.TimeZone.getDefault().id }
        qjs.function("__native_reload") { _ -> onReload() }
        qjs.function("__native_exit") { _ -> onExit() }
        qjs.function("__native_open") { a -> onOpen(a[0] as String); null }
        qjs.function("__native_asset") { a -> asset(a[0] as String) }
        qjs.function("__native_timer") { a ->
            val id = (a[0] as Number).toLong()
            val ms = (a[1] as Number).toLong()
            timers[id] = scope.launch {
                delay(ms)
                timers.remove(id)
                qjs.evaluate<Any?>("__onTimer($id); undefined", "timer.js", false)
            }
            null
        }
        qjs.function("__native_clear") { a -> timers.remove((a[0] as Number).toLong())?.cancel(); null }
        qjs.function("__native_kv_get") { a -> prefs(a[0] as String).getString(a[1] as String, null) }
        qjs.function("__native_kv_set") { a -> prefs(a[0] as String).edit().putString(a[1] as String, a[2] as String).apply(); null }
        qjs.function("__native_kv_del") { a -> prefs(a[0] as String).edit().remove(a[1] as String).apply(); null }
        qjs.function("__native_kv_clear") { a -> prefs(a[0] as String).edit().clear().apply(); null }
        qjs.function("__native_kv_keys") { a -> JSONArray(prefs(a[0] as String).all.keys.toList()).toString() }
        qjs.function("__native_intl") { a -> intl(a[0] as String, a[1] as String, JSONObject(a[2] as String), a[3] as String) }
        qjs.function("__native_fetch") { a ->
            fetch((a[0] as Number).toLong(), a[1] as String, a[2] as String, JSONObject(a[3] as String), a[4] as String?)
            null
        }
        qjs.function("__native_fetch_abort") { a -> requests.remove((a[0] as Number).toLong())?.let { c -> net.execute { c.disconnect() } }; null }
    }

    private fun fetch(id: Long, url: String, method: String, headers: JSONObject, body: String?) {
        net.execute {
            try {
                val shipped = if (method == "GET") packaged(url) else null
                if (shipped != null) {
                    val type = if (url.substringBefore('?').endsWith(".json")) "application/json" else "text/plain"
                    call("__onFetch", "$id", "200", JSONObject.quote(JSONObject().put("content-type", type).toString()), JSONObject.quote(shipped))
                    return@execute
                }
                val c = URL(url).openConnection() as HttpURLConnection
                requests[id] = c
                c.requestMethod = method
                c.connectTimeout = 15_000
                c.readTimeout = 70_000
                c.instanceFollowRedirects = true
                for (k in headers.keys()) c.setRequestProperty(k, headers.getString(k))
                if (body != null) {
                    c.doOutput = true
                    c.outputStream.use { it.write(body.toByteArray()) }
                }
                val status = c.responseCode
                val text = (if (status < 400) c.inputStream else c.errorStream)?.bufferedReader()?.use { it.readText() } ?: ""
                val out = JSONObject()
                for ((k, v) in c.headerFields) if (k != null) out.put(k.lowercase(), v.joinToString(", "))
                requests.remove(id)
                call("__onFetch", "$id", "$status", JSONObject.quote(out.toString()), JSONObject.quote(text))
            } catch (e: Exception) {
                requests.remove(id)
                call("__onFetchFailed", "$id", JSONObject.quote(e.message ?: e.javaClass.name))
            }
        }
    }

    private fun intl(kind: String, tag: String, o: JSONObject, value: String): String {
        val locale = ULocale.forLanguageTag(tag.ifEmpty { Locale.getDefault().toLanguageTag() })
        return when (kind) {
            "canonical" -> locale.toLanguageTag()
            "plural" -> PluralRules.forLocale(locale).select(value.toDouble())
            "number" -> NumberFormat.getInstance(locale).apply {
                if (o.has("maximumFractionDigits")) maximumFractionDigits = o.getInt("maximumFractionDigits")
                if (o.has("minimumFractionDigits")) minimumFractionDigits = o.getInt("minimumFractionDigits")
            }.format(value.toDouble())
            "date" -> {
                val f = DateFormat.getInstanceForSkeleton(skeleton(o), locale)
                f.setContext(DisplayContext.CAPITALIZATION_NONE)
                if (o.has("timeZone")) f.timeZone = TimeZone.getTimeZone(o.getString("timeZone"))
                f.format(Date(value.toDouble().toLong()))
            }
            else -> throw IllegalArgumentException("Intl: $kind")
        }
    }

    // Intl's options as ICU's skeleton: the two speak the same CLDR.
    private fun skeleton(o: JSONObject): String = buildString {
        o.optString("year").let { if (it == "numeric") append("y") else if (it == "2-digit") append("yy") }
        o.optString("month").let { append(when (it) { "numeric" -> "M"; "2-digit" -> "MM"; "short" -> "MMM"; "long" -> "MMMM"; "narrow" -> "MMMMM"; else -> "" }) }
        o.optString("day").let { if (it == "numeric") append("d") else if (it == "2-digit") append("dd") }
        o.optString("weekday").let { append(when (it) { "short" -> "E"; "long" -> "EEEE"; "narrow" -> "EEEEE"; else -> "" }) }
        val h24 = o.optString("hourCycle") == "h23" || o.optBoolean("hour12", true).not()
        o.optString("hour").let { if (it.isNotEmpty()) append(if (h24) (if (it == "2-digit") "HH" else "H") else (if (it == "2-digit") "hh" else "h")) }
        o.optString("minute").let { if (it.isNotEmpty()) append("mm") }
        o.optString("second").let { if (it.isNotEmpty()) append("ss") }
        if (isEmpty()) append("yMd")
    }

    fun start(): Job = scope.launch {
        qjs = QuickJs.create(dispatcher)
        qjs.maxStackSize = 12L * 1024 * 1024
        bridge()
        // quickjs-kt converts a script's completion value back to Kotlin and
        // throws on a symbol, so every script here ends in undefined.
        for (name in listOf("prelude.js", "ses.umd.min.js", "terminal.js")) {
            val began = System.currentTimeMillis()
            qjs.evaluate<Any?>("${asset(name)}\n;undefined", name, false)
            Log.i("pronto", "evaluated $name in ${System.currentTimeMillis() - began} ms")
        }
    }

    fun tap(kind: String, id: String) = call("__onTap", JSONObject.quote(kind), JSONObject.quote(id))
    fun input(id: String, value: String) = call("__onInput", JSONObject.quote(id), JSONObject.quote(value))
    fun back() = call("__goBack")
    // A link the OS handed the app, back from the system browser (or opened from elsewhere).
    fun link(url: String) = call("__onLink", JSONObject.quote(url))
    fun resize(dp: Int) = call("__onResize", "$dp")

    // The driver's question over the live DOM, in a debug build.
    suspend fun probe(selector: String): String = withContext(dispatcher) {
        qjs.evaluate<String>("__probe(${JSONObject.quote(selector)})", "probe.js", false)
    }

    override fun close() {
        scope.cancel()
        requests.values.forEach { c -> net.execute { c.disconnect() } }
        js.submit { if (::qjs.isInitialized) qjs.close() }.get()
        js.shutdown()
        net.shutdown()
    }
}
