package __APPLICATION_ID__

import android.content.Context
import android.view.View
import android.view.inputmethod.InputMethodManager
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import java.net.InetAddress
import java.net.ServerSocket
import kotlin.concurrent.thread

// integrate@android's eyes: on loopback in a debug build, reached through adb
// forward. A line in, a line out: {"probe": selector} answers the DOM's elements;
// {"bounds": id} the drawn view's rectangle on screen, so a tap is the system's own;
// {"where": true} the page's address; {"session": true} the token, id and guest-ness of the session it holds;
// {"click": selector} a script's click on the DOM's element, whatever the screen shows;
// {"fetches": n} the requests the page made from number n on, and what they answered;
// {"frames": true} how many times the screen was drawn; {"hideKeyboard": true} puts the keyboard away, as a person would, without a key the app reads.
object Driver {
    private var server: ServerSocket? = null

    fun attach(activity: MainActivity, engine: TerminalEngine, root: View) {
        detach()
        val socket = ServerSocket(8765, 8, InetAddress.getByName("127.0.0.1"))
        server = socket
        thread(isDaemon = true, name = "pronto-driver") {
            while (!socket.isClosed) {
                val c = runCatching { socket.accept() }.getOrNull() ?: break
                thread(isDaemon = true) {
                    c.use {
                        val line = it.getInputStream().bufferedReader().readLine() ?: return@use
                        val q = JSONObject(line)
                        val answer = when {
                            q.has("probe") -> runBlocking { engine.probe(q.getString("probe")) }
                            q.has("bounds") -> bounds(activity, root, q.getString("bounds"))
                            q.has("hideKeyboard") -> hideKeyboard(activity, root)
                            q.has("where") -> runBlocking { engine.where() }
                            q.has("session") -> runBlocking { engine.session() }
                            q.has("click") -> runBlocking { engine.domClick(q.getString("click")) }
                            q.has("fetches") -> engine.fetches(q.getInt("fetches"))
                            q.has("frames") -> activity.frames.toString()
                            // The pages the app left for since last asked (a stand-in browser's start).
                            q.has("trips") -> org.json.JSONArray(activity.takeTrips()).toString()
                            else -> "null"
                        }
                        it.getOutputStream().write((answer + "\n").toByteArray())
                    }
                }
            }
        }
    }

    private fun bounds(activity: MainActivity, root: View, id: String): String {
        var out = "null"
        val done = java.util.concurrent.CountDownLatch(1)
        activity.runOnUiThread {
            root.findViewWithTag<View>(id)?.takeIf { it.isShown }?.let { v ->
                val at = IntArray(2)
                v.getLocationOnScreen(at)
                out = JSONObject().put("x", at[0]).put("y", at[1]).put("w", v.width).put("h", v.height).toString()
            }
            done.countDown()
        }
        done.await()
        return out
    }

    private fun hideKeyboard(activity: MainActivity, root: View): String {
        val done = java.util.concurrent.CountDownLatch(1)
        activity.runOnUiThread {
            val ime = activity.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
            ime.hideSoftInputFromWindow(root.windowToken, 0)
            activity.currentFocus?.clearFocus()
            done.countDown()
        }
        done.await()
        return "true"
    }

    fun detach() {
        server?.close()
        server = null
    }
}
