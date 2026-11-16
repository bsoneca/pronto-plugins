package __APPLICATION_ID__

import org.json.JSONArray
import org.json.JSONObject

// The unit cases are data (android/cases.cue in pronto-plugins, exported as android_cases.json): a test is a loop over its cases.
object Cases {
    val all: JSONObject by lazy {
        JSONObject(requireNotNull(Cases::class.java.getResourceAsStream("/android_cases.json")) { "android_cases.json is not on the test classpath" }.bufferedReader().readText())
    }

    fun list(a: JSONArray): List<JSONObject> = (0 until a.length()).map { a.getJSONObject(it) }
    fun strings(a: JSONArray): List<String> = (0 until a.length()).map { a.getString(it) }
    fun hex(s: String): ByteArray = ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
    fun str(o: JSONObject, k: String): String? = if (o.isNull(k)) null else o.getString(k)
}
