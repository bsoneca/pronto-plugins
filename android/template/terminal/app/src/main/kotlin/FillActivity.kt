package __APPLICATION_ID__

import android.app.assist.AssistStructure
import android.content.Intent
import android.os.Bundle
import android.service.autofill.Dataset
import android.service.autofill.FillResponse
import android.util.Log
import android.view.autofill.AutofillManager
import android.view.autofill.AutofillValue
import android.widget.RemoteViews
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import org.json.JSONObject

// The locked entry's other side: one biometric prompt opens the storage's key (Unlock.kt), the
// terminal boots headless over it, the probe is stated to the app's own handler (main.js __ask), and
// the system gets one dataset per login it named. The handler answers ids; the secret is read here,
// by id, from the rows just opened, and goes nowhere but the dataset.
class FillActivity : AppCompatActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        @Suppress("DEPRECATION")
        val structure = intent.getParcelableExtra<AssistStructure>(AutofillManager.EXTRA_ASSIST_STRUCTURE)
        val contract = FillService.contract(this)
        if (structure == null || contract == null) return done(null)
        val request = Request.read(structure)
        val probe = request.probe ?: return done(null)
        lifecycleScope.launch {
            val key = try {
                Unlock.open(this@FillActivity, "Fill ${probe.target}")
            } catch (e: Locked) {
                return@launch if (e.canceled) done(null) else tell(e.message.orEmpty())
            }
            val base = getString(R.string.pronto_base).trimEnd('/')
            // Headless: nothing collects its screens, and it never reloads, exits or opens a page.
            TerminalEngine(this@FillActivity, base, "$base/", "me", {}, {}, {}, key).use { engine ->
                engine.start().join()
                // A shell that never boots (main.js's bridges wait on it) ends the fill, not hangs it.
                try { withTimeout(30_000) {
                    // Only an app has certificates; a site's probe states none.
                    val signers = if (probe.kind == "app") Signer.of(packageManager, request.packageName) else emptyList()
                    val reply = engine.ask(contract.handler, contract.reads, Ask.stated(contract, probe, signers), Ask.event())
                    val logins = engine.rows(contract.vault).associateBy { it.getString("id") }
                    val chosen = Ask.picks(contract, reply).mapNotNull(logins::get)
                    // Trust on first use: an app login added before its app was installed is
                    // pinned now, behind the fingerprint just given, to the app asking.
                    val pins = Ask.pins(contract, probe, signers, chosen)
                    if (pins.length() > 0) engine.commit(contract.vault, pins)?.let { error("pinning refused: $it") }
                    val datasets = chosen.map { dataset(request, contract, it) }
                    if (datasets.isEmpty()) tell("Nothing here fills ${probe.target}.")
                    else done(FillResponse.Builder().apply { datasets.forEach(::addDataset) }.build())
                } } catch (e: Exception) {
                    Log.e("pronto", "the fill failed", e)
                    tell(e.message.orEmpty())
                }
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun dataset(request: Request, contract: Autofill, login: JSONObject): Dataset {
        val label = RemoteViews(packageName, android.R.layout.simple_list_item_1).apply {
            setTextViewText(android.R.id.text1, "${login.getString(contract.title)} · ${login.getString(contract.username)}")
        }
        return Dataset.Builder(label).apply {
            request.username?.let { setValue(it, AutofillValue.forText(login.getString(contract.username))) }
            request.password?.let { setValue(it, AutofillValue.forText(login.getString(contract.secret))) }
        }.build()
    }

    // Says why nothing filled, over the app being filled, and ends the fill once read.
    private fun tell(why: String) {
        AlertDialog.Builder(this)
            .setTitle(applicationInfo.loadLabel(packageManager))
            .setMessage(why)
            .setPositiveButton(android.R.string.ok, null)
            .setOnDismissListener { done(null) }
            .show()
    }

    private fun done(response: FillResponse?) {
        if (response == null) setResult(RESULT_CANCELED)
        else setResult(RESULT_OK, Intent().putExtra(AutofillManager.EXTRA_AUTHENTICATION_RESULT, response))
        finish()
    }
}
