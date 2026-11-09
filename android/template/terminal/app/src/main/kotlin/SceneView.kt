package __APPLICATION_ID__

import android.content.Context
import android.graphics.Color
import android.media.MediaPlayer
import android.opengl.GLES20
import android.opengl.GLSurfaceView
import android.opengl.Matrix
import android.util.Log
import android.view.View
import com.yandex.div.core.DivCustomContainerViewAdapter
import com.yandex.div.core.state.DivStatePath
import com.yandex.div.core.view2.Div2View
import com.yandex.div.json.expressions.ExpressionResolver
import com.yandex.div2.DivCustom
import java.io.File
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import javax.microedition.khronos.egl.EGLConfig
import javax.microedition.khronos.opengles.GL10
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin
import org.json.JSONObject

// A hatch's 3D scene (the hatch contract's "Contract v3"), drawn natively. compile.js turns a scene element into
// one DivKit custom div, "pronto-scene", whose custom_props are the typed scene; this adapter makes a
// SceneView of it, as the Unity host's ProntoScene draws the same nodes: the six primitives at Unity's sizes, a
// directional light, Unity's left-handed transforms, a camera, and the anims and audio of the nodes that appeared.
class SceneAdapter(private val context: Context) : DivCustomContainerViewAdapter {
    override fun isCustomTypeSupported(type: String) = type == "pronto-scene"

    override fun createView(div: DivCustom, divView: Div2View, expressionResolver: ExpressionResolver, path: DivStatePath): View =
        SceneView(context).also { it.bind(div.customProps ?: JSONObject()) }

    override fun bindView(view: View, div: DivCustom, divView: Div2View, expressionResolver: ExpressionResolver, path: DivStatePath) {
        (view as SceneView).bind(div.customProps ?: JSONObject())
    }

    override fun release(view: View, div: DivCustom) {
        (view as SceneView).stopSounds()
    }
}

private class Model(val key: String, val shape: String, val color: Int, val pos: FloatArray, val rot: FloatArray, val scale: FloatArray)

private class Anim(val key: String, val target: String, val duration: Float, val delta: FloatArray, val spin: Float, val loop: Boolean)

private class Camera(val pos: FloatArray, val look: FloatArray, val fov: Float)

private class SceneData(val background: Int, val camera: Camera, val models: List<Model>, val anims: List<Anim>, val audios: List<JSONObject>)

private fun floats(o: JSONObject, vararg names: String) = FloatArray(names.size) { o.optDouble(names[it], 0.0).toFloat() }

private fun colour(hex: String, otherwise: Int) = if (Regex("#[0-9a-fA-F]{6}").matches(hex)) Color.parseColor(hex) else otherwise

private fun parse(props: JSONObject): SceneData {
    val c = props.optJSONObject("camera") ?: JSONObject()
    val camera = Camera(floats(c, "x", "y", "z"), floats(c, "lookX", "lookY", "lookZ"), c.optDouble("fov", 45.0).toFloat())
    val models = ArrayList<Model>()
    val ms = props.optJSONArray("models")
    for (i in 0 until (ms?.length() ?: 0)) {
        val m = ms!!.getJSONObject(i)
        val prefab = m.optString("prefab")
        if (prefab.isNotEmpty() && told.add("prefab $prefab")) Log.i("pronto", "PRONTO SCENE prefab $prefab not on Android")
        models.add(Model(m.optString("key"), m.optString("shape").ifEmpty { "cube" }, colour(m.optString("color"), 0xFFCCCCCC.toInt()),
            floats(m, "x", "y", "z"), floats(m, "rx", "ry", "rz"), floats(m, "sx", "sy", "sz")))
    }
    val anims = ArrayList<Anim>()
    val an = props.optJSONArray("anims")
    for (i in 0 until (an?.length() ?: 0)) {
        val a = an!!.getJSONObject(i)
        anims.add(Anim(a.optString("key"), a.optString("target"), a.optDouble("duration", 0.5).toFloat(), floats(a, "dx", "dy", "dz"), a.optDouble("spin", 0.0).toFloat(), a.optBoolean("loop")))
    }
    val au = props.optJSONArray("audios")
    return SceneData(colour(props.optString("background"), 0xFF212B38.toInt()), camera, models, anims, List(au?.length() ?: 0) { au!!.getJSONObject(it) })
}

// What was already logged: a missing asset is said once, not at every bind.
private val told = HashSet<String>()

class SceneView(context: Context) : GLSurfaceView(context) {
    private val renderer = SceneRenderer(this)
    // The keys of the last bind: a node whose key is not among them has appeared, so its anim runs and its audio plays.
    private var keys = emptySet<String>()
    private val players = ArrayList<MediaPlayer>()

    init {
        setEGLContextClientVersion(2)
        setEGLConfigChooser(8, 8, 8, 8, 16, 0)
        setRenderer(renderer)
        renderMode = RENDERMODE_WHEN_DIRTY
    }

    fun bind(props: JSONObject) {
        val scene = parse(props)
        val now = scene.anims.map { it.key }.toSet() + List(scene.audios.size) { scene.audios[it].optString("key") }
        val fresh = now - keys
        keys = now
        queueEvent { renderer.set(scene, scene.anims.filter { it.key in fresh }) }
        requestRender()
        for (a in scene.audios) if (a.optString("key") in fresh) play(a)
        Log.i("pronto", "PRONTO SCENE drew ${scene.models.size} models")
    }

    // The clip is the APK asset unity/audio/<clip>.wav or .ogg, played once (or looped).
    private fun play(audio: JSONObject) {
        val clip = audio.optString("clip")
        for (ext in listOf("wav", "ogg")) {
            val file = File(context.cacheDir, "scene-$clip.$ext")
            try {
                if (!file.exists()) context.assets.open("unity/audio/$clip.$ext").use { input -> file.outputStream().use { input.copyTo(it) } }
            } catch (e: IOException) {
                file.delete()
                continue
            }
            val volume = audio.optDouble("volume", 1.0).toFloat()
            val player = MediaPlayer()
            try {
                player.setDataSource(file.path)
                player.setVolume(volume, volume)
                player.isLooping = audio.optBoolean("loop")
                player.setOnPreparedListener { it.start() }
                player.setOnCompletionListener { it.release(); players.remove(it) }
                player.prepareAsync()
                players.add(player)
            } catch (e: Exception) {
                Log.w("pronto", "PRONTO SCENE audio $clip failed", e)
                player.release()
            }
            return
        }
        if (told.add("audio $clip")) Log.i("pronto", "PRONTO SCENE audio $clip not shipped")
    }

    fun stopSounds() {
        for (p in players) p.release()
        players.clear()
    }

    override fun onDetachedFromWindow() {
        stopSounds()
        super.onDetachedFromWindow()
    }
}

private class Mesh(val data: FloatBuffer, val count: Int)

private class Run(val anim: Anim, var time: Float = 0f)

private class SceneRenderer(private val view: GLSurfaceView) : GLSurfaceView.Renderer {
    private var scene: SceneData? = null
    private val running = ArrayList<Run>()
    private val meshes = HashMap<String, Mesh>()
    private var program = 0
    private var aspect = 1f
    private var last = 0L

    // Unity's default light is a directional one turned (50, -30, 0); this is the way to it, from a surface.
    private val light = floatArrayOf(0.3214f, 0.766f, -0.5567f)

    // Runs on the GL thread.
    fun set(next: SceneData, appeared: List<Anim>) {
        scene = next
        val keep = next.anims.filter { it.loop }.map { it.key }
        running.removeAll { it.anim.loop && it.anim.key !in keep }
        for (a in appeared) running.add(Run(a))
    }

    override fun onSurfaceCreated(gl: GL10?, config: EGLConfig?) {
        program = link(
            "uniform mat4 uMvp; uniform mat4 uNormal; attribute vec3 aPos; attribute vec3 aNormal; varying vec3 vN;" +
                "void main() { vN = (uNormal * vec4(aNormal, 0.0)).xyz; gl_Position = uMvp * vec4(aPos, 1.0); }",
            "precision mediump float; uniform vec4 uColor; uniform vec3 uLight; varying vec3 vN;" +
                "void main() { float d = max(dot(normalize(vN), uLight), 0.0); gl_FragColor = vec4(uColor.rgb * (0.3 + 0.7 * d), 1.0); }")
        meshes.clear()
        for (shape in listOf("cube", "sphere", "capsule", "cylinder", "plane", "quad")) meshes[shape] = mesh(shape)
        GLES20.glEnable(GLES20.GL_DEPTH_TEST)
        last = 0
    }

    override fun onSurfaceChanged(gl: GL10?, width: Int, height: Int) {
        GLES20.glViewport(0, 0, width, height)
        aspect = width.toFloat() / maxOf(1, height)
    }

    override fun onDrawFrame(gl: GL10?) {
        val now = System.nanoTime()
        val dt = if (last == 0L) 0f else (now - last) / 1e9f
        last = now
        val s = scene
        val bg = s?.background ?: 0xFF212B38.toInt()
        GLES20.glClearColor(Color.red(bg) / 255f, Color.green(bg) / 255f, Color.blue(bg) / 255f, 1f)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT or GLES20.GL_DEPTH_BUFFER_BIT)
        if (s == null) return

        // Unity is left-handed: lookAt and perspective are the right-handed ones with the screen's x mirrored.
        val proj = FloatArray(16)
        val flip = FloatArray(16)
        val look = FloatArray(16)
        val vp = FloatArray(16)
        val c = s.camera
        Matrix.perspectiveM(proj, 0, c.fov, aspect, 0.1f, 200f)
        Matrix.setIdentityM(flip, 0)
        Matrix.scaleM(flip, 0, -1f, 1f, 1f)
        Matrix.multiplyMM(proj, 0, flip, 0, proj.copyOf(), 0)
        Matrix.setLookAtM(look, 0, c.pos[0], c.pos[1], c.pos[2], c.look[0], c.look[1], c.look[2], 0f, 1f, 0f)
        Matrix.multiplyMM(vp, 0, proj, 0, look, 0)

        GLES20.glUseProgram(program)
        GLES20.glUniform3fv(GLES20.glGetUniformLocation(program, "uLight"), 1, light, 0)
        val aPos = GLES20.glGetAttribLocation(program, "aPos")
        val aNormal = GLES20.glGetAttribLocation(program, "aNormal")
        for (m in s.models) {
            val pos = m.pos.copyOf()
            var spin = 0f
            for (r in running) {
                if (r.anim.target != m.key && !m.key.endsWith("/" + r.anim.target)) continue
                val f = (r.time / r.anim.duration).coerceIn(0f, 1f)
                val out = sin(PI * f).toFloat()
                for (i in 0..2) pos[i] += r.anim.delta[i] * out
                spin += r.anim.spin * f
            }
            val model = FloatArray(16)
            Matrix.setIdentityM(model, 0)
            Matrix.translateM(model, 0, pos[0], pos[1], pos[2])
            Matrix.rotateM(model, 0, m.rot[1], 0f, 1f, 0f)
            Matrix.rotateM(model, 0, m.rot[0], 1f, 0f, 0f)
            Matrix.rotateM(model, 0, m.rot[2], 0f, 0f, 1f)
            Matrix.rotateM(model, 0, spin, 0f, 1f, 0f)
            Matrix.scaleM(model, 0, m.scale[0], m.scale[1], m.scale[2])
            val mvp = FloatArray(16)
            val inverse = FloatArray(16)
            val normal = FloatArray(16)
            Matrix.multiplyMM(mvp, 0, vp, 0, model, 0)
            Matrix.invertM(inverse, 0, model, 0)
            Matrix.transposeM(normal, 0, inverse, 0)
            GLES20.glUniformMatrix4fv(GLES20.glGetUniformLocation(program, "uMvp"), 1, false, mvp, 0)
            GLES20.glUniformMatrix4fv(GLES20.glGetUniformLocation(program, "uNormal"), 1, false, normal, 0)
            GLES20.glUniform4f(GLES20.glGetUniformLocation(program, "uColor"), Color.red(m.color) / 255f, Color.green(m.color) / 255f, Color.blue(m.color) / 255f, 1f)
            val mesh = meshes[m.shape] ?: meshes.getValue("cube")
            mesh.data.position(0)
            GLES20.glVertexAttribPointer(aPos, 3, GLES20.GL_FLOAT, false, 24, mesh.data)
            GLES20.glEnableVertexAttribArray(aPos)
            mesh.data.position(3)
            GLES20.glVertexAttribPointer(aNormal, 3, GLES20.GL_FLOAT, false, 24, mesh.data)
            GLES20.glEnableVertexAttribArray(aNormal)
            GLES20.glDrawArrays(GLES20.GL_TRIANGLES, 0, mesh.count)
        }

        // An anim runs out and back over its duration; a looping one starts over, the others end.
        val live = running.iterator()
        while (live.hasNext()) {
            val r = live.next()
            r.time += dt
            if (r.time >= r.anim.duration) { if (r.anim.loop) r.time = 0f else live.remove() }
        }
        if (running.isNotEmpty()) view.requestRender()
    }

    private fun link(vertex: String, fragment: String): Int {
        fun shader(type: Int, source: String): Int {
            val id = GLES20.glCreateShader(type)
            GLES20.glShaderSource(id, source)
            GLES20.glCompileShader(id)
            return id
        }
        val id = GLES20.glCreateProgram()
        GLES20.glAttachShader(id, shader(GLES20.GL_VERTEX_SHADER, vertex))
        GLES20.glAttachShader(id, shader(GLES20.GL_FRAGMENT_SHADER, fragment))
        GLES20.glLinkProgram(id)
        return id
    }

    // The primitives at Unity's sizes: cube 1, sphere d=1, capsule h=2 d=1, cylinder h=2 d=1, plane 10x10 on XZ, quad 1x1 facing -Z.
    private fun mesh(shape: String): Mesh {
        val v = ArrayList<Float>()
        fun vertex(p: FloatArray, n: FloatArray) { v.addAll(p.toList()); v.addAll(n.toList()) }
        // A square of side 2*half centred dist along n, spanned by u and v.
        fun quad(n: FloatArray, u: FloatArray, w: FloatArray, half: Float, dist: Float) {
            fun at(a: Float, b: Float) = FloatArray(3) { n[it] * dist + (u[it] * a + w[it] * b) * half }
            for ((a, b) in listOf(-1f to -1f, 1f to -1f, 1f to 1f, -1f to -1f, 1f to 1f, -1f to 1f)) vertex(at(a, b), n)
        }
        // A profile of (radius, y, normal radius, normal y) turned about the y axis.
        fun revolve(profile: List<FloatArray>) {
            val slices = 24
            fun at(p: FloatArray, i: Int): Pair<FloatArray, FloatArray> {
                val a = (2 * PI * i / slices).toFloat()
                return floatArrayOf(p[0] * cos(a), p[1], p[0] * sin(a)) to floatArrayOf(p[2] * cos(a), p[3], p[2] * sin(a))
            }
            for (k in 0 until profile.size - 1) for (i in 0 until slices) {
                val corners = listOf(at(profile[k], i), at(profile[k + 1], i), at(profile[k + 1], i + 1), at(profile[k], i), at(profile[k + 1], i + 1), at(profile[k], i + 1))
                for ((p, n) in corners) vertex(p, n)
            }
        }
        fun arc(from: Double, to: Double, y: Float, steps: Int) = List(steps + 1) {
            val t = from + (to - from) * it / steps
            floatArrayOf(0.5f * sin(t).toFloat(), y + 0.5f * cos(t).toFloat(), sin(t).toFloat(), cos(t).toFloat())
        }
        when (shape) {
            "cube" -> for (s in listOf(1f, -1f)) {
                quad(floatArrayOf(s, 0f, 0f), floatArrayOf(0f, 1f, 0f), floatArrayOf(0f, 0f, 1f), 0.5f, 0.5f)
                quad(floatArrayOf(0f, s, 0f), floatArrayOf(1f, 0f, 0f), floatArrayOf(0f, 0f, 1f), 0.5f, 0.5f)
                quad(floatArrayOf(0f, 0f, s), floatArrayOf(1f, 0f, 0f), floatArrayOf(0f, 1f, 0f), 0.5f, 0.5f)
            }
            "plane" -> quad(floatArrayOf(0f, 1f, 0f), floatArrayOf(1f, 0f, 0f), floatArrayOf(0f, 0f, 1f), 5f, 0f)
            "quad" -> quad(floatArrayOf(0f, 0f, -1f), floatArrayOf(1f, 0f, 0f), floatArrayOf(0f, 1f, 0f), 0.5f, 0f)
            "sphere" -> revolve(arc(0.0, PI, 0f, 12))
            "capsule" -> revolve(arc(0.0, PI / 2, 0.5f, 6) + arc(PI / 2, PI, -0.5f, 6))
            "cylinder" -> {
                revolve(listOf(floatArrayOf(0f, 1f, 0f, 1f), floatArrayOf(0.5f, 1f, 0f, 1f)))
                revolve(listOf(floatArrayOf(0.5f, 1f, 1f, 0f), floatArrayOf(0.5f, -1f, 1f, 0f)))
                revolve(listOf(floatArrayOf(0f, -1f, 0f, -1f), floatArrayOf(0.5f, -1f, 0f, -1f)))
            }
        }
        val data = ByteBuffer.allocateDirect(v.size * 4).order(ByteOrder.nativeOrder()).asFloatBuffer()
        data.put(v.toFloatArray()).position(0)
        return Mesh(data, v.size / 6)
    }
}
