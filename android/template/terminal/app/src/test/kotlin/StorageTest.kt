package __APPLICATION_ID__

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test

// The two sides of the sealed-storage switch, and the move between them, over the cases in android_cases.json (android/cases.cue).
class StorageTest {
    private fun map(o: JSONObject): Map<String, String> = o.keys().asSequence().associateWith { o.getString(it) }

    @Test
    fun whichStoreABuildUses() {
        for (c in Cases.list(Cases.all.getJSONArray("storage"))) {
            assertEquals(c.getString("why"), c.getString("want"), Storage.choose(c.getString("switch"), c.getBoolean("unlock")))
        }
    }

    @Test
    fun turningItOnMovesThePlainValuesOnceAndLosesNothing() {
        for (c in Cases.list(Cases.all.getJSONArray("migration"))) {
            val why = c.getString("why")
            val plain = map(c.getJSONObject("plain")).toMutableMap()
            val sealed = map(c.getJSONObject("sealed")).toMutableMap()
            val failPut = Cases.str(c, "failPut")
            val failClear = c.optBoolean("failClear", false)
            var clears = 0
            val moved = ArrayList<Int>()
            var threw = false
            val migration = Migration()
            repeat(c.getInt("runs")) {
                try {
                    moved.add(migration.once("ns",
                        { plain.toMap() },
                        { k, v -> if (k == failPut) throw IllegalStateException("write failed") else sealed[k] = v },
                        { clears++; if (failClear) false else { plain.clear(); true } },
                    ) { puts ->
                        // a transaction: a failure leaves the sealed store as it was
                        val before = sealed.toMap()
                        try { puts() } catch (e: Exception) { sealed.clear(); sealed.putAll(before); throw e }
                    })
                } catch (e: IllegalStateException) {
                    threw = true
                }
            }
            val want = c.getJSONObject("want")
            assertEquals("$why: sealed", map(want.getJSONObject("sealed")), sealed)
            assertEquals("$why: plain", map(want.getJSONObject("plain")), plain)
            assertEquals("$why: moved", (0 until want.getJSONArray("moved").length()).map { want.getJSONArray("moved").getInt(it) }, moved)
            assertEquals("$why: clears", want.getInt("clears"), clears)
            assertEquals("$why: threw", want.getBoolean("threw"), threw)
        }
    }
}
