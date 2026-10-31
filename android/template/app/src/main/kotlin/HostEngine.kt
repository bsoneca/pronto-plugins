package __APPLICATION_ID__

import android.util.Log
import com.dokar.quickjs.QuickJs
import com.dokar.quickjs.binding.function
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancel
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant
import java.util.UUID
import java.util.concurrent.Executors

// omnishell's QuickJsOmnishellEngine contract (start, dispatchAction, a UI
// tree flow) over host.js's row store. `device` tables come in unsealed as
// `persisted` and go out through `store`; nothing else touches the disk. With
// no screen the engine is headless: a service asks one handler through `ask`.
class HostEngine(
    private val ses: String,
    private val host: String,
    private val handlers: Map<String, String>,
    private val shell: String,
    private val screen: String?,
    private val persisted: Map<String, List<String>>,
    private val store: RowStore?,
    private val signers: (String) -> List<String>,
) : AutoCloseable {
    private val executor = Executors.newSingleThreadExecutor { Thread(it, "pronto-quickjs").apply { isDaemon = true } }
    private val dispatcher = executor.asCoroutineDispatcher()
    private val _tree = MutableStateFlow("")
    val tree: StateFlow<String> = _tree
    // The first throw out of start or a tap: the screen cannot go on, so the
    // host locks rather than show rows a half-run update left behind.
    private val _failure = MutableStateFlow<Throwable?>(null)
    val failure: StateFlow<Throwable?> = _failure
    private val scope = CoroutineScope(SupervisorJob() + dispatcher + CoroutineExceptionHandler { _, e ->
        Log.e("pronto", "engine failed", e)
        _failure.value = e
    })
    private lateinit var qjs: QuickJs

    fun start(): Job = scope.launch {
        qjs = QuickJs.create(dispatcher)
        qjs.function("__emitUiAst") { args -> _tree.value = args[0] as String }
        qjs.function("__log") { args -> Log.i("pronto", args.joinToString(" ")) }
        qjs.function("__storePut") { args -> requireNotNull(store).put(args[0] as String, args[1] as String, args[2] as String) }
        qjs.function("__storeDrop") { args -> requireNotNull(store).drop(args[0] as String, args[1] as String) }
        qjs.function("__signers") { args -> signers(args[0] as String).joinToString(",") }
        val tables = JSONObject(persisted.mapValues { (_, rs) -> JSONArray(rs.map(::JSONObject)) })
        // quickjs-kt converts a script's completion value back to Kotlin and
        // throws on a symbol, so every script here ends in undefined.
        for ((name, code) in listOf(
            "shell.json" to "globalThis.__shell = $shell; undefined",
            "persisted.json" to "globalThis.__persisted = $tables; undefined",
            "host.js" to host,
            "ses.umd.min.js" to "$ses\n;undefined",
            "handlers.js" to "globalThis.__handlers = ${JSONObject(handlers)}; undefined",
            if (screen != null) "screen.js" to "$screen\n;undefined"
            else "lockdown.js" to "lockdown({ errorTaming: \"unsafe\" }); undefined",
        )) {
            Log.i("pronto", "evaluating $name")
            qjs.evaluate<Any?>(code, name, false)
        }
    }

    fun dispatchAction(url: String) = scope.launch {
        val call = "__dispatchAction(${JSONObject.quote(url)}, ${JSONObject.quote(Instant.now().toString())}, ${JSONObject.quote(UUID.randomUUID().toString())}); undefined"
        qjs.evaluate<Any?>(call, "action.js", false)
    }

    // A handler's reply to `event` over the current rows, with `stated` tables
    // standing in for theirs. Runs after start, on the engine's one thread.
    suspend fun ask(handler: String, reads: List<String>, stated: JSONObject, event: JSONObject): JSONObject =
        withContext(dispatcher) {
            val call = "__ask(${JSONObject.quote(handler)}, ${JSONArray(reads)}, ${JSONObject.quote(stated.toString())}, ${JSONObject.quote(event.toString())})"
            JSONObject(qjs.evaluate<String>(call, "ask.js", false))
        }

    // Queued work is dropped, and the runtime closes on its own thread behind
    // whatever script is running, so nothing evaluates after close returns and
    // the store can be closed next.
    // Commits updates as a screen's commit does, refusals included; null when
    // all were kept.
    suspend fun commit(table: String, updates: JSONArray): JSONObject? = withContext(dispatcher) {
        val call = "__commit(${JSONObject.quote(table)}, ${JSONObject.quote(updates.toString())})"
        qjs.evaluate<String>(call, "commit.js", false).let { if (it == "null") null else JSONObject(it) }
    }

    override fun close() {
        scope.cancel()
        executor.submit { if (::qjs.isInitialized) qjs.close() }.get()
        executor.shutdown()
    }
}
