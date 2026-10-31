package __APPLICATION_ID__

import android.content.Intent
import android.content.pm.ApplicationInfo
import android.net.Uri
import android.os.Bundle
import android.provider.Settings
import android.view.View
import android.view.WindowManager
import android.view.autofill.AutofillManager
import androidx.appcompat.app.AppCompatActivity
import androidx.core.widget.NestedScrollView
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
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
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject

// The program's shell/ is this app's assets (app/build.gradle.kts): its
// handlers and its shell.json reach the engine as pronto checked and emitted
// them. The screen runs only while the device tables are unlocked; leaving the
// app locks them again. A tap on a pronto:// action goes to the screen, one on
// pronto-host:// to the host.
class MainActivity : AppCompatActivity() {
    private lateinit var divView: Div2View
    private var engine: HostEngine? = null
    private var store: RowStore? = null
    private var showing: Job? = null
    private var unlocking: Job? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // A vault's screen stays out of screenshots and the recents thumbnail,
        // except in a debug build, whose screenshots are the journal's evidence.
        if (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE == 0) {
            window.setFlags(WindowManager.LayoutParams.FLAG_SECURE, WindowManager.LayoutParams.FLAG_SECURE)
        }
        val configuration = DivConfiguration.Builder(GlideDivImageLoader(this))
            .actionHandler(object : DivActionHandler() {
                override fun handleAction(action: DivAction, view: DivViewFacade, resolver: ExpressionResolver): Boolean {
                    val url = action.url?.evaluate(resolver) ?: return super.handleAction(action, view, resolver)
                    when (url.scheme) {
                        "pronto" -> { forget(); engine?.dispatchAction(url.toString()) }
                        "pronto-host" -> host(url)
                        else -> return super.handleAction(action, view, resolver)
                    }
                    return true
                }
            })
            .build()
        divView = Div2View(Div2Context(this, configuration, lifecycleOwner = this))
        // The vault's own fields are not the system's to fill or to save:
        // another password manager would be handed every secret typed here.
        // Android 14 may open a session on them anyway, so forget() cancels it
        // before anything could commit it.
        divView.importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS
        // The host scrolls, so a screen is a plain container: a DivKit gallery
        // is a RecyclerView, whose recycled inputs keep typing into the
        // variable of the field they were bound to before a redraw.
        val scroll = NestedScrollView(this).apply { isFillViewport = true; addView(divView) }
        // Edge to edge is the only mode from Android 15: the card keeps clear of
        // the system bars, and of the keyboard while a field has it.
        ViewCompat.setOnApplyWindowInsetsListener(scroll) { view, insets ->
            val clear = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.ime())
            view.setPadding(clear.left, clear.top, clear.right, clear.bottom)
            WindowInsetsCompat.CONSUMED
        }
        setContentView(scroll)
    }

    override fun onStart() {
        super.onStart()
        if (engine == null) unlock()
    }

    override fun onStop() {
        lock()
        super.onStop()
    }

    // Runs on the main thread, as lock() does, so a stop cancels an unlock
    // still waiting on the prompt and none opens the vault behind the screen.
    private fun unlock() {
        if (unlocking?.isActive == true) return
        show(locked(null))
        unlocking = lifecycleScope.launch {
            try {
                val opened = RowStore(this@MainActivity, Seal.unlock(this@MainActivity, "Unlock ${applicationInfo.loadLabel(packageManager)}"))
                val started = try {
                    Program(this@MainActivity).engine(opened, withScreen = true)
                } catch (e: Exception) {
                    opened.close()
                    throw e
                }
                store = opened
                engine = started
                showing = launch {
                    launch { started.failure.collect { if (it != null) { lock(); show(locked(Locked("The vault stopped: ${it.message}"))) } } }
                    started.tree.collect { if (it.isNotEmpty()) show(JSONObject(it)) }
                }
                started.start()
            } catch (e: Locked) {
                show(locked(e))
            }
        }
    }

    // Drops the system's autofill session over this screen without saving it.
    private fun forget() = getSystemService(AutofillManager::class.java)?.cancel()

    private fun lock() {
        forget()
        unlocking?.cancel()
        unlocking = null
        showing?.cancel()
        engine?.close()
        store?.close()
        showing = null
        engine = null
        store = null
        show(locked(null))
    }

    private fun host(url: Uri) {
        when (url.host) {
            "unlock" -> unlock()
            "autofill" -> startActivity(Intent(Settings.ACTION_REQUEST_SET_AUTOFILL_SERVICE, Uri.parse("package:$packageName")))
            "erase" -> { lock(); Seal.erase(this); unlock() }
        }
    }

    private fun show(card: JSONObject) {
        divView.setData(DivData(DivParsingEnvironment(ParsingErrorLogger.LOG), card), DivDataTag("screen"))
    }

    // The host's own card while the screen cannot run: why, and what to press.
    private fun locked(why: Locked?): JSONObject {
        val label = applicationInfo.loadLabel(packageManager).toString()
        val autofillOn = getSystemService(AutofillManager::class.java)?.hasEnabledAutofillServices() == true
        fun text(s: String, size: Int, color: String) = JSONObject()
            .put("type", "text").put("text", s).put("font_size", size).put("text_color", color)
            .put("text_alignment_horizontal", "center").put("margins", JSONObject().put("bottom", 16))
        fun button(s: String, url: String) = text(s, 18, "#21005D")
            .put("paddings", JSONObject().put("top", 14).put("bottom", 14))
            .put("border", JSONObject().put("corner_radius", 16))
            .put("background", JSONArray().put(JSONObject().put("type", "solid").put("color", "#E8DEF8")))
            .put("actions", JSONArray().put(JSONObject().put("log_id", url).put("url", url)))
        val items = JSONArray()
            .put(text(label, 32, "#1D1B20"))
            .put(text(why?.message ?: "Locked", 16, "#79747E"))
            .put(button("Unlock", "pronto-host://unlock"))
        if (!autofillOn) items.put(button("Use $label for autofill", "pronto-host://autofill"))
        if (why?.lost == true) items.put(button("Start a new, empty vault", "pronto-host://erase"))
        return JSONObject().put("log_id", "locked").put("states", JSONArray().put(JSONObject().put("state_id", 0).put("div", JSONObject()
            .put("type", "container").put("orientation", "vertical")
            .put("content_alignment_vertical", "center").put("height", JSONObject().put("type", "match_parent"))
            .put("paddings", JSONObject().put("left", 32).put("right", 32))
            .put("background", JSONArray().put(JSONObject().put("type", "solid").put("color", "#FEF7FF")))
            .put("items", items))))
    }
}
