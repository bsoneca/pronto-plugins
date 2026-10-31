package dev.pronto.hello_android

import android.os.Bundle
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import com.yandex.div.DivDataTag
import com.yandex.div.core.Div2Context
import com.yandex.div.core.DivActionHandler
import com.yandex.div.core.DivConfiguration
import com.yandex.div.core.DivViewFacade
import com.yandex.div.core.view2.Div2View
import com.yandex.div.data.DivParsingEnvironment
import com.yandex.div.glide.GlideDivImageLoader
import com.yandex.div.json.ParsingErrorLogger
import com.yandex.div.json.expressions.ExpressionResolver
import com.yandex.div2.DivAction
import com.yandex.div2.DivData
import kotlinx.coroutines.launch
import org.json.JSONObject

// The program's shell/ is this app's assets (app/build.gradle.kts): its
// handlers and its shell.json reach the engine as pronto checked and emitted
// them. A tap on a pronto:// action goes back to the screen.
class MainActivity : AppCompatActivity() {
    private lateinit var engine: HostEngine

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val handlers = assets.list("handlers").orEmpty()
            .filter { it.endsWith(".js") }
            .associate { it.removeSuffix(".js") to asset("handlers/$it") }
        engine = HostEngine(asset("ses.umd.min.js"), handlers, asset("shell.json"), asset("screen.js"))

        val configuration = DivConfiguration.Builder(GlideDivImageLoader(this))
            .actionHandler(object : DivActionHandler() {
                override fun handleAction(action: DivAction, view: DivViewFacade, resolver: ExpressionResolver): Boolean {
                    val url = action.url?.evaluate(resolver) ?: return super.handleAction(action, view, resolver)
                    if (url.scheme != "pronto") return super.handleAction(action, view, resolver)
                    engine.dispatchAction(url.toString())
                    return true
                }
            })
            .build()
        val divView = Div2View(Div2Context(this, configuration, lifecycleOwner = this))
        setContentView(divView)

        lifecycleScope.launch {
            engine.tree.collect { tree ->
                if (tree.isEmpty()) return@collect
                val env = DivParsingEnvironment(ParsingErrorLogger.LOG)
                divView.setData(DivData(env, JSONObject(tree)), DivDataTag("screen"))
            }
        }
        engine.start()
    }

    override fun onDestroy() {
        engine.close()
        super.onDestroy()
    }

    private fun asset(name: String) = assets.open(name).bufferedReader().use { it.readText() }
}
