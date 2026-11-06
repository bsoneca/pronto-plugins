package __APPLICATION_ID__

import android.content.pm.ApplicationInfo
import android.net.Uri
import android.os.Bundle
import android.util.Log
import androidx.activity.addCallback
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.widget.NestedScrollView
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

// The app's screen: the terminal draws here, and a gesture goes back to it. The
// program is the app's assets; a debug build may be pointed elsewhere by its
// starter (`base`, `path`, `actor`), for a scenario against a local stack.
class MainActivity : AppCompatActivity() {
    private lateinit var divView: Div2View
    private var engine: TerminalEngine? = null
    private val shown = HashMap<String, String>()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val debug = applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0
        val base = intent.getStringExtra("base").takeIf { debug } ?: getString(R.string.pronto_base)
        val path = intent.getStringExtra("path").takeIf { debug } ?: "/"
        val actor = intent.getStringExtra("actor").takeIf { debug } ?: "me"

        val configuration = DivConfiguration.Builder(GlideDivImageLoader(this))
            .actionHandler(object : DivActionHandler() {
                override fun handleAction(action: DivAction, view: DivViewFacade, resolver: ExpressionResolver): Boolean {
                    val url = action.url?.evaluate(resolver) ?: return super.handleAction(action, view, resolver)
                    if (url.scheme != "pronto") return super.handleAction(action, view, resolver)
                    gesture(url)
                    return true
                }
            })
            .build()
        divView = Div2View(Div2Context(this, configuration, lifecycleOwner = this))
        // The host scrolls, so a screen is a plain container: a DivKit gallery
        // is a RecyclerView, whose recycled inputs keep typing into the
        // variable of the field they were bound to before a redraw.
        val scroll = NestedScrollView(this).apply { isFillViewport = true; addView(divView) }
        ViewCompat.setOnApplyWindowInsetsListener(scroll) { view, insets ->
            val clear = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.ime())
            view.setPadding(clear.left, clear.top, clear.right, clear.bottom)
            WindowInsetsCompat.CONSUMED
        }
        setContentView(scroll)

        val started = TerminalEngine(this, base.trimEnd('/'), "${base.trimEnd('/')}$path", actor, { runOnUiThread { recreate() } }, { runOnUiThread { finish() } })
        engine = started
        lifecycleScope.launch { started.tree.collect { if (it.isNotEmpty()) show(JSONObject(it)) } }
        lifecycleScope.launch { started.failure.collect { if (it != null) Log.e("pronto", "the terminal stopped", it) } }
        started.start()
        started.resize((resources.displayMetrics.widthPixels / resources.displayMetrics.density).toInt())
        onBackPressedDispatcher.addCallback(this) { started.back() }
        Driver.attach(this, started, divView)
    }

    private fun gesture(url: Uri) {
        val id = url.lastPathSegment ?: return
        when (url.host) {
            "tap" -> engine?.tap("click", id)
            "contextmenu" -> engine?.tap("contextmenu", id)
            "input" -> {
                val value = url.getQueryParameter("value") ?: ""
                shown["v_$id"] = value
                engine?.input(id, value)
            }
        }
    }

    // DivKit keeps a card's variables across a redraw, so a value the program
    // changed (a form's reset) is set here; one a person typed is already there.
    private fun show(card: JSONObject) {
        divView.setData(DivData(DivParsingEnvironment(ParsingErrorLogger.LOG), card), DivDataTag("screen"))
        val variables = card.optJSONArray("variables") ?: return
        for (i in 0 until variables.length()) {
            val v = variables.getJSONObject(i)
            val name = v.getString("name")
            val value = v.optString("value")
            if (shown[name] != value) {
                shown[name] = value
                divView.setVariable(name, value)
            }
        }
    }

    override fun onDestroy() {
        Driver.detach()
        engine?.close()
        engine = null
        super.onDestroy()
    }
}
