package __APPLICATION_ID__

import android.app.assist.AssistStructure
import android.content.Intent
import android.os.Bundle
import android.service.autofill.Dataset
import android.service.autofill.FillResponse
import android.view.autofill.AutofillManager
import android.view.autofill.AutofillValue
import android.widget.RemoteViews
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject

// The locked entry's other side: unlock, state the probe, ask the program's
// handler, and hand the system one dataset per login it named. The handler
// answers ids, titles and usernames; the secret is read here, by id, from the
// rows just unsealed, and goes nowhere but the dataset.
class FillActivity : AppCompatActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        @Suppress("DEPRECATION")
        val structure = intent.getParcelableExtra<AssistStructure>(AutofillManager.EXTRA_ASSIST_STRUCTURE)
        val program = Program(this)
        val contract = program.autofill
        if (structure == null || contract == null) return done(null)
        val request = Request.read(structure)
        val probe = request.probe ?: return done(null)
        lifecycleScope.launch {
            val key = try {
                Seal.unlock(this@FillActivity, "Fill ${probe.target}")
            } catch (e: Locked) {
                return@launch if (e.canceled) done(null) else tell(e.message.orEmpty())
            }
            RowStore(this@FillActivity, key).use { store ->
                program.engine(store, withScreen = false).use { engine ->
                    engine.start().join()
                    // Only an app has certificates; a site's probe states none.
                    val signers = if (probe.kind == "app") Signer.of(packageManager, request.packageName) else emptyList()
                    val stated = JSONObject()
                        .put(contract.probe, JSONArray().put(JSONObject().put("id", contract.probe).put("kind", probe.kind).put("target", probe.target)
                            .put(contract.signers, signers.joinToString(","))))
                        .put(contract.candidate, JSONArray())
                    val reply = engine.ask(contract.handler, contract.reads, stated, JSONObject().put("type", "mutation"))
                    val picked = reply.getJSONArray("updates").let { u -> List(u.length(), u::getJSONObject) }
                        .filter { it.getString("op") == "put" && it.optString("entity") == contract.candidate }
                        .map { it.getString("id") }
                    val logins = store.load(contract.vault).map(::JSONObject).associateBy { it.getString("id") }
                    val chosen = picked.mapNotNull(logins::get)
                    // Trust on first use: an app login added before its app was
                    // installed is pinned now, behind the fingerprint just given,
                    // to the app asking.
                    val pins = chosen.filter { probe.kind == "app" && it.optString(contract.signer).isEmpty() && signers.isNotEmpty() }
                        .map { JSONObject().put("op", "patch").put("id", it.getString("id")).put("row", JSONObject().put(contract.signer, signers.first())) }
                    if (pins.isNotEmpty()) engine.commit(contract.vault, JSONArray(pins))?.let { error("pinning refused: $it") }
                    val datasets = chosen.map { dataset(request, contract, it) }
                    if (datasets.isEmpty()) return@launch tell("Nothing in the vault fills ${probe.target}.")
                    done(FillResponse.Builder().apply { datasets.forEach(::addDataset) }.build())
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

    // Says why nothing filled, over the app being filled, and ends the fill once
    // read. A toast cannot: the system kills this activity's toasts as it finishes.
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
