package __APPLICATION_ID__

import android.view.View
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import java.net.InetAddress
import java.net.ServerSocket
import kotlin.concurrent.thread

// integrate@android's eyes: on loopback in a debug build, reached through adb
// forward. A line in, a line out: {"probe": selector} answers the DOM's elements;
// {"bounds": id} the drawn view's rectangle on screen, so a tap is the system's own.
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

    fun detach() {
        server?.close()
        server = null
    }
}
