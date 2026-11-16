package __APPLICATION_ID__

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test

// The ask over JSON, as both modes make it, over the cases in android_cases.json (android/cases.cue).
class AskTest {
    private val ask = Cases.all.getJSONObject("ask")
    private val contract = Autofill(ask.getJSONObject("contract"))
    private fun probe(o: JSONObject) = Probe(o.getString("kind"), o.getString("target"))

    @Test
    fun whatTheHandlerIsTold() {
        for (c in Cases.list(ask.getJSONArray("stated"))) {
            val stated = Ask.stated(contract, probe(c.getJSONObject("probe")), Cases.strings(c.getJSONArray("signers")))
            val got = stated.getJSONArray("probe").getJSONObject(0)
            val want = c.getJSONObject("want")
            val why = c.getString("why")
            for (k in listOf("id", "kind", "target", "signers")) assertEquals("$why: $k", want.getString(k), got.getString(k))
            assertEquals("$why: candidates", want.getInt("candidates"), stated.getJSONArray("candidate").length())
        }
    }

    @Test
    fun picks() {
        for (c in Cases.list(ask.getJSONArray("picks"))) {
            assertEquals(c.getString("why"), Cases.strings(c.getJSONArray("want")), Ask.picks(contract, c.getJSONObject("reply")))
        }
    }

    @Test
    fun pins() {
        for (c in Cases.list(ask.getJSONArray("pins"))) {
            val rows = Cases.list(c.getJSONArray("rows"))
            val pins = Ask.pins(contract, probe(c.getJSONObject("probe")), Cases.strings(c.getJSONArray("signers")), rows)
            val want = Cases.list(c.getJSONArray("want"))
            val why = c.getString("why")
            assertEquals(why, want.size, pins.length())
            for ((i, w) in want.withIndex()) {
                assertEquals("$why: op", w.getString("op"), pins.getJSONObject(i).getString("op"))
                assertEquals("$why: id", w.getString("id"), pins.getJSONObject(i).getString("id"))
                assertEquals("$why: signer", w.getString("signer"), pins.getJSONObject(i).getJSONObject("row").getString("signer"))
            }
        }
    }
}
