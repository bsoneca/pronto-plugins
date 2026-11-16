package __APPLICATION_ID__

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test

// The terminal's storage is always sealed: the one-time adoption of an earlier build's plain preferences (Kv.kt) over the cases in
// android_cases.json (android/cases.cue).
class StorageTest {
    private fun map(o: JSONObject): Map<String, String> = o.keys().asSequence().associateWith { o.getString(it) }
    private fun ints(a: JSONArray): List<Int> = (0 until a.length()).map { a.getInt(it) }

    // One launch: a fresh Migration over the stores as they are; each namespace's puts are one transaction (a failure leaves the
    // sealed store as it was). Returns the values moved, or null when the launch failed.
    private fun launch(marked: Boolean, namespaces: List<String>, plain: MutableMap<String, String>, sealed: MutableMap<String, String>, failPut: String?, markerWritten: BooleanArray): Int? {
        val migration = Migration()
        return try {
            Adoption.run(marked, { namespaces }, { ns ->
                migration.once(ns,
                    { plain.filterKeys { it.startsWith("$ns/") }.mapKeys { it.key.removePrefix("$ns/") } },
                    { k, v -> if (k == failPut) throw IllegalStateException("write failed") else sealed["$ns/$k"] = v },
                    { plain.keys.removeAll { it.startsWith("$ns/") }; true },
                ) { puts ->
                    val before = sealed.toMap()
                    try { puts() } catch (e: Exception) { sealed.clear(); sealed.putAll(before); throw e }
                }
            }, { markerWritten[0] = true })
        } catch (e: IllegalStateException) {
            null
        }
    }

    @Test
    fun theStorageIsAlwaysSealedAndAdoptsThePlainPreferencesOnce() {
        for (c in Cases.list(Cases.all.getJSONArray("adoption"))) {
            val why = c.getString("why")
            val ns = c.getJSONObject("namespaces")
            val names = ns.keys().asSequence().toList().sorted()
            val plain = HashMap<String, String>()
            for (n in names) for ((k, v) in map(ns.getJSONObject(n))) plain["$n/$k"] = v
            val sealed = HashMap<String, String>()
            val marker = BooleanArray(1)
            val markers = ArrayList<Boolean>()
            val moved = ArrayList<Int>()
            for (f in Cases.strings(c.getJSONArray("launches"))) {
                moved.add(launch(marker[0], names, plain, sealed, f.ifEmpty { null }, marker) ?: 0)
                markers.add(marker[0])
            }
            val want = c.getJSONObject("want")
            assertEquals("$why: sealed", map(want.getJSONObject("sealed")), sealed)
            assertEquals("$why: plain", map(want.getJSONObject("plain")), plain)
            assertEquals("$why: marker", (0 until want.getJSONArray("marker").length()).map { want.getJSONArray("marker").getBoolean(it) }, markers)
            assertEquals("$why: moved", ints(want.getJSONArray("moved")), moved)
        }
    }

    @Test
    fun turningUpAPlainNamespaceMovesItsValuesOnceAndLosesNothing() {
        for (c in Cases.list(Cases.all.getJSONArray("migration"))) {
            val why = c.getString("why")
            val plain = map(c.getJSONObject("plain")).mapKeys { "ns/${it.key}" }.toMutableMap()
            val sealed = map(c.getJSONObject("sealed")).mapKeys { "ns/${it.key}" }.toMutableMap()
            val failPut = Cases.str(c, "failPut")
            val failClear = c.optBoolean("failClear", false)
            var clears = 0
            val moved = ArrayList<Int>()
            var threw = false
            val migration = Migration()
            repeat(c.getInt("runs")) {
                try {
                    moved.add(migration.once("ns",
                        { plain.mapKeys { it.key.removePrefix("ns/") } },
                        { k, v -> if (k == failPut) throw IllegalStateException("write failed") else sealed["ns/$k"] = v },
                        { clears++; if (failClear) false else { plain.clear(); true } },
                    ) { puts ->
                        val before = sealed.toMap()
                        try { puts() } catch (e: Exception) { sealed.clear(); sealed.putAll(before); throw e }
                    })
                } catch (e: IllegalStateException) {
                    threw = true
                }
            }
            val want = c.getJSONObject("want")
            assertEquals("$why: sealed", map(want.getJSONObject("sealed")).mapKeys { "ns/${it.key}" }, sealed)
            assertEquals("$why: plain", map(want.getJSONObject("plain")).mapKeys { "ns/${it.key}" }, plain)
            assertEquals("$why: moved", ints(want.getJSONArray("moved")), moved)
            assertEquals("$why: clears", want.getInt("clears"), clears)
            assertEquals("$why: threw", want.getBoolean("threw"), threw)
        }
    }
}
