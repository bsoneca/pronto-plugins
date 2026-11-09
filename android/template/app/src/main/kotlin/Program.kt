package __APPLICATION_ID__

import android.content.Context
import org.json.JSONObject

// The program as the app's assets carry it: the shell/ pronto checked and
// emitted, the host's own scripts, and the app's screen and autofill contract.
class Program(private val context: Context) {
    private val assets = context.assets
    val ses = asset("ses.umd.min.js")
    val host = asset("host.js")
    val shell = asset("shell.json")
    val screen = asset("screen.js")
    val handlers = assets.list("handlers").orEmpty()
        .filter { it.endsWith(".js") }
        .associate { it.removeSuffix(".js") to asset("handlers/$it") }

    // Which tables the store bridge keeps: the program's `device` ones.
    val deviceTables: List<String> = JSONObject(shell).optJSONObject("local")?.let { local ->
        local.keys().asSequence().filter { local.getString(it) == "device" }.toList()
    }.orEmpty()

    // autofill.json: which handler answers a fill, the tables it reads, and
    // the vault's columns a dataset is drawn from. Absent, nothing fills.
    val autofill: Autofill? = assets.list("").orEmpty().takeIf { "autofill.json" in it }
        ?.let { Autofill(JSONObject(asset("autofill.json"))) }

    fun engine(store: RowStore, withScreen: Boolean) = HostEngine(
        ses, host, handlers, shell,
        if (withScreen) screen else null,
        deviceTables.associateWith(store::load),
        store,
        { Signer.of(context.packageManager, it) },
    )

    private fun asset(name: String) = assets.open(name).bufferedReader().use { it.readText() }
}
