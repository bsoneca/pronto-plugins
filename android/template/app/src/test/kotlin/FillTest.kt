package __APPLICATION_ID__

import android.text.InputType
import org.junit.Assert.assertEquals
import org.junit.Test

class FillTest {
    private fun hex(b: ByteArray) = java.security.MessageDigest.getInstance("SHA-256").digest(b).joinToString("") { "%02x".format(it) }

    // The current signer first, then each it rotated from: a pin from before
    // a rotation still names the same app.
    @Test
    fun signerTokensLeadWithTheCurrentCertificate() {
        val old = byteArrayOf(1); val now = byteArrayOf(2)
        assertEquals(listOf(hex(now), hex(old)), Signer.tokens(listOf(now), listOf(old)))
    }

    // Several signers are one identity, whatever order the platform lists them in.
    @Test
    fun severalSignersJoinInAFixedOrder() {
        val a = byteArrayOf(1); val b = byteArrayOf(2)
        val joined = listOf(hex(a), hex(b)).sorted().joinToString("+")
        assertEquals(listOf(joined), Signer.tokens(listOf(a, b), emptyList()))
        assertEquals(listOf(joined), Signer.tokens(listOf(b, a), emptyList()))
    }

    @Test
    fun noCertificatesNoTokens() {
        assertEquals(emptyList<String>(), Signer.tokens(emptyList(), emptyList()))
    }

    // A non-browser app reports whatever its WebView loaded: trusting that
    // domain would hand any app the site's login.
    @Test
    fun aDomainCountsOnlyFromABrowser() {
        val on = { domain: String? -> Field("p", domain = domain, scheme = "https") }
        assertEquals(Probe("web", "login.example.com"), Fill.probe("com.android.chrome", on("Login.Example.com:443")))
        assertEquals(Probe("app", "com.evil.app"), Fill.probe("com.evil.app", on("example.com")))
        assertEquals(Probe("app", "com.example.app"), Fill.probe("com.example.app", null))
        assertEquals(Probe("app", "com.android.chrome"), Fill.probe("com.android.chrome", on("")))
    }

    // Anyone on the network could have written an http page's form.
    @Test
    fun aPlainHttpPageGetsNothing() {
        assertEquals(null, Fill.probe("com.android.chrome", Field("p", domain = "bank.com", scheme = "http")))
    }

    // An ad frame on bank.com is not bank.com: its field never takes the username.
    @Test
    fun aFrameFromElsewhereLendsNoUsername() {
        val fields = listOf(
            Field("ad", domain = "ads.example.net", hints = listOf("username")),
            Field("p", domain = "bank.com", htmlType = "password"),
        )
        assertEquals(Targets(null, "p"), Fill.targets(fields))
    }

    @Test
    fun hintsAndTypesNameTheFields() {
        val fields = listOf(
            Field("search", inputType = InputType.TYPE_CLASS_TEXT),
            Field("email", hints = listOf("emailAddress")),
            Field("pass", inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD),
        )
        assertEquals(Targets("email", "pass"), Fill.targets(fields))
        assertEquals(Targets("u", "p"), Fill.targets(listOf(Field("u", htmlName = "login"), Field("p", htmlType = "password"))))
    }

    // An unmarked username is the text field right before the password.
    @Test
    fun anUnmarkedUsernameIsTheFieldBeforeThePassword() {
        val fields = listOf(Field("a"), Field("b"), Field("p", hints = listOf("password")), Field("c"))
        assertEquals(Targets("b", "p"), Fill.targets(fields))
        assertEquals(Targets(null, null), Fill.targets(listOf(Field("a"), Field("b"))))
    }
}
