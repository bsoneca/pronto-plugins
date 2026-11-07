package __APPLICATION_ID__

import android.content.ActivityNotFoundException
import android.content.Intent
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
import com.yandex.div.core.expression.variables.DivVariableController
import com.yandex.div.core.view2.Div2View
import com.yandex.div.data.DivParsingEnvironment
import com.yandex.div.data.Variable
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
    // A field's variable lives here, not in a card: a redraw is a new card, and DivKit's reused
    // input keeps typing into the variable it was first bound to. So that variable is one that
    // outlives every card, and what a person types reaches the page from it.
    private val fields = DivVariableController()
    // How many times the screen was drawn: a driver waits until it stops changing before a tap,
    // since a tap across a redraw lands on a view that is gone.
    @Volatile var frames = 0
        private set
    // A debug build started with `browser standin` hands no page to a real browser: it keeps the
    // addresses for its driver, whose scenario runner plays the browser and sends the link back.
    private var standIn = false
    private val trips = mutableListOf<String>()
    @Synchronized fun takeTrips(): List<String> = trips.toList().also { trips.clear() }
    @Synchronized private fun trip(url: String) { trips.add(url) }
    private var base = ""

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val debug = applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0
        base = (intent.getStringExtra("base").takeIf { debug } ?: getString(R.string.pronto_base)).trimEnd('/')
        standIn = debug && intent.getStringExtra("browser") == "standin"
        // Opened by a link to the app's own origin (an App Link), it starts where the link points.
        val path = ownPath(intent.data) ?: intent.getStringExtra("path").takeIf { debug } ?: "/"
        val actor = intent.getStringExtra("actor").takeIf { debug } ?: "me"

        val configuration = DivConfiguration.Builder(GlideDivImageLoader(this))
            .divVariableController(fields)
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

        val started = TerminalEngine(this, base, "$base$path", actor, { runOnUiThread { recreate() } }, { runOnUiThread { finish() } }, { url -> runOnUiThread { open(url) } })
        engine = started
        lifecycleScope.launch { started.tree.collect { if (it.isNotEmpty()) show(JSONObject(it)) } }
        lifecycleScope.launch { started.failure.collect { if (it != null) Log.e("pronto", "the terminal stopped", it) } }
        started.start()
        started.resize((resources.displayMetrics.widthPixels / resources.displayMetrics.density).toInt())
        onBackPressedDispatcher.addCallback(this) { started.back() }
        Driver.attach(this, started, divView)
    }

    private fun open(url: String) {
        if (standIn) { trip(url); return }
        try {
            startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)).addCategory(Intent.CATEGORY_BROWSABLE))
        } catch (e: ActivityNotFoundException) {
            Log.e("pronto", "no browser takes $url", e)
        }
    }

    // A path of the app's own origin, or null: a link of any other origin is not the app's to open.
    private fun ownPath(link: Uri?): String? {
        val origin = Uri.parse(base)
        if (link == null || link.scheme != origin.scheme || link.host != origin.host || link.port != origin.port) return null
        return (link.encodedPath ?: "/") + (link.encodedQuery?.let { "?$it" } ?: "") + (link.encodedFragment?.let { "#$it" } ?: "")
    }

    // Back from the system browser: the activity is the one already running (singleTask), and the
    // link moves its page there, as a navigation the shell hears.
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val link = intent.data ?: return
        if (ownPath(link) != null) engine?.link(link.toString())
    }

    private fun gesture(url: Uri) {
        val id = url.lastPathSegment ?: return
        when (url.host) {
            "tap" -> engine?.tap("click", id)
            "contextmenu" -> engine?.tap("contextmenu", id)
        }
    }

    // The card names its fields' variables and the page's values; they are this screen's, so a
    // value the page changed (a form's reset) is set here, and one a person typed is already there.
    private fun show(card: JSONObject) {
        val variables = card.optJSONArray("variables")
        card.remove("variables")
        for (i in 0 until (variables?.length() ?: 0)) {
            val v = variables!!.getJSONObject(i)
            val name = v.getString("name")
            val value = v.optString("value")
            if (!fields.isDeclared(name)) {
                shown[name] = value
                val field = Variable.StringVariable(name, value)
                field.addObserver { changed ->
                    val now = changed.getValue().toString()
                    if (shown[name] != now) {
                        shown[name] = now
                        engine?.input(name.removePrefix("v_"), now)
                    }
                }
                fields.declare(field)
            } else if (shown[name] != value) {
                shown[name] = value
                fields.get(name)?.set(value)
            }
        }
        divView.setData(DivData(DivParsingEnvironment(ParsingErrorLogger.LOG), card), DivDataTag("screen"))
        frames++
    }

    override fun onDestroy() {
        Driver.detach()
        engine?.close()
        engine = null
        super.onDestroy()
    }
}
