package __APPLICATION_ID__

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test

// The sticky, one-way choice of storage (Kv.kt) and the move into the sealed store, over the cases in android_cases.json
// (android/cases.cue).
class StorageTest {
    private fun map(o: JSONObject): Map<String, String> = o.keys().asSequence().associateWith { o.getString(it) }
    private fun ints(a: JSONArray): List<Int> = (0 until a.length()).map { a.getInt(it) }

    @Test
    fun whichStoreALaunchUses() {
        for (c in Cases.list(Cases.all.getJSONArray("pick"))) {
            val flag = if (c.isNull("flag")) null else c.getBoolean("flag")
            assertEquals(c.getString("why"), c.getString("want"), Storage.pick(c.getBoolean("marker"), flag))
        }
    }

    @Test
    fun whatAFlagAnswerSays() {
        for (c in Cases.list(Cases.all.getJSONArray("flag"))) {
            val want = if (c.isNull("want")) null else c.getBoolean("want")
            assertEquals(c.getString("why"), want, Flag.parse(c.getString("body")))
        }
    }

    // One launch: a fresh Migration opens each namespace in order over the stores as they are. Returns what it moved per namespace
    // and whether it threw. A sealed write of `failPut` fails, and the puts of a namespace are one transaction.
    private fun launch(namespaces: List<String>, plain: MutableMap<String, String>, sealed: MutableMap<String, String>, failPut: String?, clears: IntArray): Pair<List<Int>, Boolean> {
        val migration = Migration()
        val moved = ArrayList<Int>()
        var threw = false
        for (ns in namespaces) {
            try {
                moved.add(migration.once(ns,
                    { plain.filterKeys { it.startsWith("$ns/") }.mapKeys { it.key.removePrefix("$ns/") } },
                    { k, v -> if (k == failPut) throw IllegalStateException("write failed") else sealed["$ns/$k"] = v },
                    { clears[0]++; plain.keys.removeAll { it.startsWith("$ns/") }; true },
                ) { puts ->
                    val before = sealed.toMap()
                    try { puts() } catch (e: Exception) { sealed.clear(); sealed.putAll(before); throw e }
                })
            } catch (e: IllegalStateException) {
                threw = true
                moved.add(0)
            }
        }
        return Pair(moved, threw)
    }

    @Test
    fun turningItOnMovesThePlainValuesOnceAndLosesNothing() {
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

    @Test
    fun anInterruptedMoveResumesOnTheNextLaunch() {
        for (c in Cases.list(Cases.all.getJSONArray("resume"))) {
            val why = c.getString("why")
            val ns = c.getJSONObject("namespaces")
            val names = ns.keys().asSequence().toList().sorted()
            val plain = HashMap<String, String>()
            for (n in names) for ((k, v) in map(ns.getJSONObject(n))) plain["$n/$k"] = v
            val sealed = HashMap<String, String>()
            val want = c.getJSONObject("want")
            val moves = ArrayList<List<Int>>()
            val threw = ArrayList<Boolean>()
            for (f in Cases.strings(c.getJSONArray("launches"))) {
                val (m, t) = launch(names, plain, sealed, f.ifEmpty { null }, IntArray(1))
                moves.add(m)
                threw.add(t)
            }
            assertEquals("$why: sealed", map(want.getJSONObject("sealed")), sealed)
            assertEquals("$why: plain", map(want.getJSONObject("plain")), plain)
            val wantMoved = want.getJSONArray("movedPerLaunch").let { a -> (0 until a.length()).map { ints(a.getJSONArray(it)) } }
            assertEquals("$why: moved per launch", wantMoved, moves)
            assertEquals("$why: threw per launch", (0 until want.getJSONArray("threwPerLaunch").length()).map { want.getJSONArray("threwPerLaunch").getBoolean(it) }, threw)
        }
    }
}
