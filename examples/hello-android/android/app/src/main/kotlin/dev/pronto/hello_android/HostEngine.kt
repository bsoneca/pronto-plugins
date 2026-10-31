package dev.pronto.hello_android

import android.util.Log
import com.dokar.quickjs.QuickJs
import com.dokar.quickjs.binding.function
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import org.json.JSONObject
import java.util.concurrent.Executors

// omnishell's QuickJsOmnishellEngine contract (start, dispatchAction, a UI
// tree flow) without its storage and network bridges, whose SQLite is JDBC
// and has no Android build yet. The screen sees the program's handlers as
// __handlers (name → source, caged by the screen in a Compartment each) and
// its shell.json as __shell.
class HostEngine(
    private val ses: String,
    private val handlers: Map<String, String>,
    private val shell: String,
    private val screen: String,
) : AutoCloseable {
    private val executor = Executors.newSingleThreadExecutor { Thread(it, "pronto-quickjs").apply { isDaemon = true } }
    private val scope = CoroutineScope(SupervisorJob() + executor.asCoroutineDispatcher())
    private val _tree = MutableStateFlow("")
    val tree: StateFlow<String> = _tree
    private lateinit var qjs: QuickJs

    fun start() = scope.launch {
        qjs = QuickJs.create(executor.asCoroutineDispatcher())
        qjs.function("__emitUiAst") { args -> _tree.value = args[0] as String }
        qjs.function("__log") { args -> Log.i("pronto", args.joinToString(" ")) }
        // quickjs-kt converts a script's completion value back to Kotlin and
        // throws on a symbol, so every script here ends in undefined.
        for ((name, code) in listOf(
            "host.js" to HOST,
            "ses.umd.min.js" to "$ses\n;undefined",
            "handlers.js" to "globalThis.__handlers = ${JSONObject(handlers)}; undefined",
            "shell.json" to "globalThis.__shell = $shell; undefined",
            "screen.js" to "$screen\n;undefined",
        )) {
            Log.i("pronto", "evaluating $name")
            qjs.evaluate<Any?>(code, name, false)
        }
    }

    fun dispatchAction(url: String) = scope.launch {
        qjs.evaluate<Any?>("__dispatchAction(${JSONObject.quote(url)}); undefined", "action.js", false)
    }

    override fun close() {
        if (::qjs.isInitialized) qjs.close()
        executor.shutdown()
    }

    private companion object {
        // What the host owes before SES loads: a console, and
        // Iterator.prototype's faux accessors as data properties, since
        // QuickJS's getters throw on an undefined receiver and SES 1.15 calls
        // them bare.
        val HOST = """
            globalThis.console = Object.fromEntries(["log", "info", "warn", "error", "debug"].map((k) => [k, (...a) => __log(k, ...a.map(String))]));
            for (const [key, value] of [["constructor", Iterator], [Symbol.toStringTag, "Iterator"]]) {
              Object.defineProperty(Iterator.prototype, key, { value, writable: true, enumerable: false, configurable: true });
            }
            const handlers = [];
            globalThis.onAction = (h) => { handlers.push(h); };
            globalThis.__dispatchAction = (url) => { for (const h of handlers) h(url); };
            globalThis.emitUiAst = (ast) => __emitUiAst(typeof ast === "string" ? ast : JSON.stringify(ast));
            undefined
        """.trimIndent()
    }
}
