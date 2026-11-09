package __APPLICATION_ID__

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test

// The ask over JSON, as both modes make it: what the handler is told, and what is read back.
class AskTest {
    private val contract = Autofill(JSONObject("""
        {"handler": "match", "reads": ["login", "probe", "candidate"], "probe": "probe", "candidate": "candidate",
         "vault": "login", "title": "title", "username": "username", "secret": "secret", "signer": "signer", "signers": "signers"}
    """))

    @Test
    fun theProbeIsStatedWithItsSignersAndNoCandidates() {
        val stated = Ask.stated(contract, Probe("app", "com.bank"), listOf("aa+bb", "cc"))
        val probe = stated.getJSONArray("probe").getJSONObject(0)
        assertEquals("probe", probe.getString("id"))
        assertEquals("app", probe.getString("kind"))
        assertEquals("com.bank", probe.getString("target"))
        assertEquals("aa+bb,cc", probe.getString("signers"))
        assertEquals(0, stated.getJSONArray("candidate").length())
    }

    @Test
    fun aSiteStatesNoSigners() {
        val probe = Ask.stated(contract, Probe("web", "bank.com"), emptyList()).getJSONArray("probe").getJSONObject(0)
        assertEquals("", probe.getString("signers"))
    }

    @Test
    fun picksAreTheCandidatesPutInTheHandlersOrder() {
        val reply = JSONObject().put("updates", JSONArray()
            .put(JSONObject().put("op", "put").put("entity", "candidate").put("id", "b"))
            .put(JSONObject().put("op", "put").put("entity", "login").put("id", "x"))
            .put(JSONObject().put("op", "delete").put("entity", "candidate").put("id", "c"))
            .put(JSONObject().put("op", "put").put("entity", "candidate").put("id", "a")))
        assertEquals(listOf("b", "a"), Ask.picks(contract, reply))
    }

    @Test
    fun aReplyWithNoUpdatesPicksNothing() {
        assertEquals(emptyList<String>(), Ask.picks(contract, JSONObject()))
    }

    @Test
    fun onlyAnUnpinnedAppLoginIsPinnedToTheCurrentSigner() {
        val unpinned = JSONObject().put("id", "1")
        val pinned = JSONObject().put("id", "2").put("signer", "old")
        val pins = Ask.pins(contract, Probe("app", "com.bank"), listOf("now", "before"), listOf(unpinned, pinned))
        assertEquals(1, pins.length())
        assertEquals("patch", pins.getJSONObject(0).getString("op"))
        assertEquals("1", pins.getJSONObject(0).getString("id"))
        assertEquals("now", pins.getJSONObject(0).getJSONObject("row").getString("signer"))
        assertEquals(0, Ask.pins(contract, Probe("web", "bank.com"), listOf("now"), listOf(unpinned)).length())
        assertEquals(0, Ask.pins(contract, Probe("app", "com.bank"), emptyList(), listOf(unpinned)).length())
    }
}
