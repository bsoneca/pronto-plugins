package __APPLICATION_ID__

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test

// Fill.kt's pure half over the cases in android_cases.json (android/cases.cue): each case says what it asserts.
class FillTest {
    private fun field(o: JSONObject) = Field(
        o.getString("id"),
        domain = Cases.str(o, "domain"),
        scheme = Cases.str(o, "scheme"),
        hints = if (o.has("hints")) Cases.strings(o.getJSONArray("hints")) else emptyList(),
        inputType = o.optInt("inputType", 0),
        htmlType = Cases.str(o, "htmlType"),
        htmlName = Cases.str(o, "htmlName"),
    )

    @Test
    fun signerTokens() {
        for (c in Cases.list(Cases.all.getJSONArray("signer"))) {
            val got = Signer.tokens(Cases.strings(c.getJSONArray("current")).map(Cases::hex), Cases.strings(c.getJSONArray("past")).map(Cases::hex))
            assertEquals(c.getString("why"), Cases.strings(c.getJSONArray("want")), got)
        }
    }

    @Test
    fun probes() {
        for (c in Cases.list(Cases.all.getJSONArray("probe"))) {
            val want = if (c.isNull("want")) null else c.getJSONObject("want").let { Probe(it.getString("kind"), it.getString("target")) }
            assertEquals(c.getString("why"), want, Fill.probe(c.getString("package"), field(c.getJSONObject("field"))))
        }
    }

    @Test
    fun targets() {
        for (c in Cases.list(Cases.all.getJSONArray("targets"))) {
            val want = c.getJSONObject("want")
            val fields = Cases.list(c.getJSONArray("fields")).map(::field)
            assertEquals(c.getString("why"), Targets(Cases.str(want, "username"), Cases.str(want, "password")), Fill.targets(fields))
        }
    }
}
